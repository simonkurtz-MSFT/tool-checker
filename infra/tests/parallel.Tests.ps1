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
        $functionBlock = Get-ParallelCheckFunctionBlock

        $functionBlock | Should Match 'function Test-Tool'
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

    It 'returns promptly after timing out a check blocked in <BlockingKind>' -TestCases @(
        @{ BlockingKind = 'managed code' }
        @{ BlockingKind = 'a native process tree' }
    ) {
        param($BlockingKind)

        $results.Tools = @{}
        $results.Errors = @()
        $block = if ($BlockingKind -eq 'managed code') {
            { [System.Threading.Thread]::Sleep(8000) }
        } else {
            {
                $executable = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
                & (Join-Path $PSHOME $executable) -NoProfile -NonInteractive -Command '[System.Threading.Thread]::Sleep(8000)'
            }
        }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()

        Invoke-ParallelChecks -Total 2 -TimeoutSec 2 -Checks @(
            @{ Name = 'Blocked CLI'; Block = $block }
            @{ Name = 'Healthy CLI'; Block = { $results.Tools['Healthy CLI'] = @{ Installed = '1.0.0'; Latest = '' } } }
        )

        $clock.Elapsed.TotalSeconds | Should BeLessThan 6
        $results.Tools['Blocked CLI'].CheckTimedOut | Should Be $true
        $results.Tools['Healthy CLI'].Installed | Should Be '1.0.0'
        $results.Errors.Count | Should Be 1
        $results.Errors[0] | Should Be 'Blocked CLI check timed out after 2s'
    }

    It 'terminates the owned check process and native descendants and removes temporary files' {
        $results.Tools = @{}
        $results.Errors = @()
        $ownerPath = Join-Path $TestDrive 'owner.txt'
        $childPath = Join-Path $TestDrive 'child.txt'
        $directoryPath = Join-Path $TestDrive 'directory.txt'
        $toolsConfig['TimeoutTest'] = @{
            OwnerPath = $ownerPath; ChildPath = $childPath; DirectoryPath = $directoryPath
        }
        try {
            Invoke-ParallelChecks -Total 1 -TimeoutSec 3 -Checks @(
                @{
                    Name = 'Native CLI'
                    Block = {
                        $PID | Set-Content -LiteralPath $toolsConfig.TimeoutTest.OwnerPath
                        $workerPath = [System.Environment]::GetCommandLineArgs() |
                            Where-Object { [System.IO.Path]::GetFileName($_) -eq 'worker.ps1' } |
                            Select-Object -First 1
                        (Split-Path -Parent $workerPath) | Set-Content -LiteralPath $toolsConfig.TimeoutTest.DirectoryPath
                        $childPath = $toolsConfig.TimeoutTest.ChildPath.Replace("'", "''")
                        $command = "`$PID | Set-Content -LiteralPath '$childPath'; [System.Threading.Thread]::Sleep(8000)"
                        $executable = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
                        & (Join-Path $PSHOME $executable) -NoProfile -NonInteractive -Command $command
                    }
                }
            )

            $results.Tools['Native CLI'].CheckTimedOut | Should Be $true
            foreach ($path in @($ownerPath, $childPath)) {
                Test-Path -LiteralPath $path | Should Be $true
                $processId = [int](Get-Content -LiteralPath $path)
                @(Get-Process -Id $processId -ErrorAction SilentlyContinue).Count | Should Be 0
            }
            Test-Path -LiteralPath (Get-Content -LiteralPath $directoryPath) | Should Be $false
        } finally {
            $toolsConfig.Remove('TimeoutTest')
            foreach ($path in @($ownerPath, $childPath)) {
                if (Test-Path -LiteralPath $path) {
                    $processId = [int](Get-Content -LiteralPath $path)
                    if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
                        Stop-Process -Id $processId -ErrorAction Stop
                    }
                }

            }
        }
    }

    It 'preserves nonterminating check errors across the process boundary' {
        $results.Tools = @{}
        $results.Errors = @()

        Invoke-ParallelChecks -Total 1 -TimeoutSec 5 -Checks @(
            @{
                Name = 'Error CLI'
                Block = {
                    Microsoft.PowerShell.Utility\Write-Error 'Synthetic worker error' -ErrorAction Continue
                    $results.Tools['Error CLI'] = @{ Installed = '1.0.0'; Latest = '' }
                }
            }
        )

        $results.Tools['Error CLI'].Installed | Should Be '1.0.0'
        $results.Errors.Count | Should Be 1
        $results.Errors[0] | Should Match 'Parallel check error \(job 0\): Synthetic worker error'
    }
}