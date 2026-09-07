# Real runspace lifecycle checks with synthetic startup and collection failures.
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tool-checker.ps1'

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