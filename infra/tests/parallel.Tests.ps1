# Real runspace lifecycle, worker-definition, merge, and timeout checks with synthetic inputs.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) "parallel-tests-$([guid]::NewGuid()).env")

Describe 'Parallel check resource cleanup' {
    It 'disposes workers and their pool on the <FailureStage> path' -TestCases @(
        @{ FailureStage = 'startup' }
        @{ FailureStage = 'collection' }
        @{ FailureStage = 'cleanup' }
        @{ FailureStage = 'success' }
        @{ FailureStage = 'timeout' }
    ) {
        param($FailureStage)

        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($entryPath, $envPath, $failureStage)
                . $entryPath -EnvFile $envPath
                $script:capturedWorkers = [System.Collections.Generic.List[object]]::new()
                $script:capturedPool = $null
                $workerStarted = [System.Threading.ManualResetEventSlim]::new()
                $toolsConfig = @{ WorkerStarted = $workerStarted }
                function Get-ParallelCheckWorkerScript {
                    $script:capturedWorkers.Add($ps)
                    if ($null -eq $script:capturedPool) {
                        $script:capturedPool = $pool
                        $pool | Add-Member -MemberType NoteProperty -Name DisposedByOwner -Value $false
                        $pool | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
                            $this.PSBase.Dispose()
                            $this.DisposedByOwner = $true
                        } -Force
                    }
                    if ($failureStage -eq 'startup' -and $script:capturedWorkers.Count -eq 2) {
                        if (-not $workerStarted.Wait(5000)) { throw 'Worker did not start' }
                        throw 'Synthetic startup failure'
                    }
                    if ($failureStage -in @('startup', 'timeout')) {
                        return {
                            param($definitions, $check, $progress, $index, $configuration)
                            $configuration.WorkerStarted.Set()
                            Wait-Event -Timeout 30 | Out-Null
                        }
                    }
                    if ($failureStage -eq 'success') {
                        return {
                            param($definitions)
                            . ([scriptblock]::Create($definitions))
                            New-ToolCheckResults
                        }
                    }
                    if ($failureStage -eq 'cleanup' -and $script:capturedWorkers.Count -eq 1) {
                        $ps | Add-Member -MemberType ScriptMethod -Name Stop -Value { throw 'Synthetic cleanup failure' } -Force
                    }
                    { throw 'Synthetic collection failure' }
                }
                $timeout = if ($failureStage -eq 'timeout') { 0 } else { 10 }
                $message = try {
                    Invoke-ParallelChecks -Total 2 -TimeoutSec $timeout -Checks @(
                        @{ Name = 'First'; Block = {} }
                        @{ Name = 'Second'; Block = {} }
                    )
                } catch { $_.Exception.Message }
                $disposed = @()
                foreach ($worker in $script:capturedWorkers) {
                    $disposed += try { $null = $worker.AddScript('1'); $false } catch {
                        $_.Exception.GetBaseException() -is [System.ObjectDisposedException]
                    }
                }
                $poolState = $script:capturedPool.RunspacePoolStateInfo.State.ToString()
                $poolDisposed = $script:capturedPool.DisposedByOwner
                $firstWorkerState = $script:capturedWorkers[0].InvocationStateInfo.State.ToString()
                foreach ($worker in $script:capturedWorkers) { $worker.Dispose() }
                $script:capturedPool.Dispose()
                $workerStarted.Dispose()
                [PSCustomObject]@{
                    Message = $message; Disposed = $disposed; PoolState = $poolState
                    PoolDisposed = $poolDisposed; FirstWorkerState = $firstWorkerState
                    Errors = $results.Errors
                }
            }).AddArgument($scriptPath).AddArgument((Join-Path $TestDrive 'missing.env')).AddArgument($FailureStage)
            $observed = @($session.Invoke())[-1]
            if ($FailureStage -eq 'startup') {
                $observed.Message | Should Match 'Synthetic startup failure'
                $observed.FirstWorkerState | Should Be 'Stopped'
            } elseif ($FailureStage -in @('collection', 'cleanup')) {
                $observed.Message | Should Match 'Synthetic collection failure'
            } else {
                [string]::IsNullOrEmpty($observed.Message) | Should Be $true
                if ($FailureStage -eq 'timeout') {
                    $observed.Errors.Count | Should Be 2
                    $observed.Errors[0] | Should Match 'check timed out'
                } else {
                    $observed.Errors.Count | Should Be 0
                }
            }
            $observed.Disposed.Count | Should Be 2
            @($observed.Disposed | Where-Object { -not $_ }).Count | Should Be 0
            $observed.PoolState | Should Be 'Closed'
            $observed.PoolDisposed | Should Be $true
        } finally {
            $session.Dispose()
        }
    }
}

Describe 'Parallel check orchestration' {
    It 'rehydrates configured checker dependencies without including the main entry point' {
        $scriptContent = Get-Content $scriptPath -Raw
        $customChecker = $toolsConfig.Values |
            Where-Object { $_.CheckType -eq 'custom' } |
            Select-Object -First 1 -ExpandProperty CustomFunction

        $functionBlock = Get-ParallelCheckFunctionBlock -ScriptContent $scriptContent -ToolsConfiguration $toolsConfig

        $functionBlock | Should Match "function $customChecker"
        $functionBlock | Should Match 'function Set-LatestToolVersion'
        $functionBlock | Should Not Match 'function Main'
    }

    It 'creates a mergeable timeout result with an unknown tool marker' {
        $timeoutResult = New-ParallelCheckTimeoutResult -Index 2 -Name 'Slow CLI' -TimeoutSec 5

        $timeoutResult.Index | Should Be 2
        $timeoutResult.Tools['Slow CLI'].Installed | Should Be 'unknown'
        $timeoutResult.Tools['Slow CLI'].CheckTimedOut | Should Be $true
        $timeoutResult.Errors[0] | Should Be 'Slow CLI check timed out after 5s'
    }

    It 'merges a completed check result into shared state' {
        $results.Tools = @{}
        $results.ToolState['dotnet-sdk'] = @{}
        $results.NotInstalled = @()
        $results.Updates = @()
        $results.Errors = @()
        $results.UpdateFailed = @()
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
        (Get-ToolState 'npm-global-packages').Packages = @()
        (Get-ToolState 'npm-global-packages').UpdateCommand = 'ncu -g -u --loglevel=error'
        $checkResult = @{
            Output = @()
            Tools = @{ 'Example CLI' = @{ Installed = '1.0.0'; Latest = '1.1.0' } }
            ToolState = @{ 'dotnet-sdk' = @{ '10.0.100' = @{ Major = '10' } }; 'npm-global-packages' = @{ Packages = @(); UpdateCommand = 'npm update command' } }
            NotInstalled = @('Missing CLI')
            Updates = @('Example CLI')
            Errors = @()
            UpdateFailed = @()
            AvailableUpdates = @(@{ Name = 'Example CLI' })
            MaturityBlockedUpdates = @()
        }

        Merge-ParallelCheckResult -CheckResult $checkResult

        $results.Tools['Example CLI'].Installed | Should Be '1.0.0'
        (Get-ToolState 'dotnet-sdk').ContainsKey('10.0.100') | Should Be $true
        $results.Updates[0] | Should Be 'Example CLI'
        $results.AvailableUpdates[0].Name | Should Be 'Example CLI'
        (Get-ToolState 'npm-global-packages').UpdateCommand | Should Be 'npm update command'
    }

    It 'runs and merges a network-free check through the runspace pool' {
        $results.Tools = @{}
        $results.ToolState['dotnet-sdk'] = @{}
        $results.NotInstalled = @()
        $results.Updates = @()
        $results.Errors = @()
        $results.UpdateFailed = @()
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
        (Get-ToolState 'npm-global-packages').Packages = @()
        (Get-ToolState 'npm-global-packages').UpdateCommand = 'ncu -g -u --loglevel=error'
        $checks = @(
            @{
                Name = 'Synthetic CLI'
                Block = { $results.Tools['Synthetic CLI'] = @{ Installed = '1.0.0'; Latest = '' } }
            }
        )

        Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5

        $results.Tools['Synthetic CLI'].Installed | Should Be '1.0.0'
        $results.Errors.Count | Should Be 0
    }

    It 'stops an overlong check and merges its timeout marker' {
        $results.Tools = @{}
        $results.Errors = @()
        $checks = @(
            @{
                Name = 'Slow CLI'
                Block = {
                    while ($true) { $null = 1 + 1 }
                }
            }
        )

        Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 1

        $results.Tools['Slow CLI'].Installed | Should Be 'unknown'
        $results.Tools['Slow CLI'].CheckTimedOut | Should Be $true
        $results.Errors[0] | Should Be 'Slow CLI check timed out after 1s'
    }

    It 'merges checks in declaration order when they complete out of order' {
        $results.Tools = @{}
        $results.Updates = @()
        $results.Errors = @()
        $checks = @(
            @{
                Name = 'First CLI'
                Block = {
                    $waitHandle = [System.Threading.ManualResetEventSlim]::new($false)
                    $null = $waitHandle.Wait(300)
                    $results.Updates += 'First CLI'
                }
            },
            @{
                Name = 'Second CLI'
                Block = { $results.Updates += 'Second CLI' }
            }
        )

        Invoke-ParallelChecks -Checks $checks -Total 2 -TimeoutSec 5

        $results.Updates.Count | Should Be 2
        $results.Updates[0] | Should Be 'First CLI'
        $results.Updates[1] | Should Be 'Second CLI'
        $results.Errors.Count | Should Be 0
    }
}