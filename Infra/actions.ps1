# Action planning, approval, execution, and completion for both interactive and
# Force workflows. Executors return Output/ExitCode; owners interpret failures.
function Get-InstallCommand {
    param([pscustomobject]$NotInstalledEntry)
    if (-not $NotInstalledEntry -or -not $NotInstalledEntry.InstallCommands) { return "" }

    $commands = $NotInstalledEntry.InstallCommands
    if ($commands.Contains($script:PlatformKey)) { return $commands[$script:PlatformKey] }

    # Best-effort fallback to current OS if an exact arch match is missing.
    $osPrefix = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Windows (' } else { 'Linux (' }
    $fallbackKey = $commands.Keys | Where-Object { $_ -like "$osPrefix*" } | Select-Object -First 1
    if ($fallbackKey) { return $commands[$fallbackKey] }

    return ""
}

function Invoke-ToolCommand {
    param([string]$Command, [string]$Type)
    # Native commands update the global exit code; a local reset would shadow it.
    # Pure PowerShell commands instead use the success flag captured immediately.
    $global:LASTEXITCODE = $null
    try {
        $output = @(Invoke-Expression "$Command 2>&1")
        $succeeded = $?
        @{ Output = ($output | Out-String); ExitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } elseif ($succeeded) { 0 } else { 1 } }
    } catch {
        @{ Output = "$_"; ExitCode = 1 }
    }
}

function Resolve-ActionMetadata {
    # Explicit plan values win over platform/catalog defaults. Resolve before
    # serialization so menu and job execution use the same dispatch contract.
    param([object]$Action)
    if (-not $Action.ToolId) { $Action.ToolId = Get-ResultToolId -Name $Action.Name }
    if (-not $Action.Operation) { $Action.Operation = if ($Action.Type -eq 'install') { 'Install' } else { 'Update' } }
    if (-not $Action.Arguments) { $Action.Arguments = @{} }
    $config = Get-OwnedConfiguration -ToolId $Action.ToolId
    if ($config) {
        foreach ($property in @('Executor','EntryPoint','ExecutionMode','OutcomePackageManager')) {
            $key = "$($Action.Operation)$property"
            $platformKey = "Windows$key"
            $value = if (($IsWindows -or $env:OS -eq 'Windows_NT') -and $config[$platformKey]) { $config[$platformKey] } else { $config[$key] }
            if (-not $Action[$property] -and $value) { $Action[$property] = $value }
        }
    }
    if (-not $Action.Executor) { $Action.Executor = 'command' }
    if (-not $Action.ExecutionMode) { $Action.ExecutionMode = 'Job' }
    if (-not $Action.OutcomePackageManager -and $Action.Executor -notin @('command','tool')) { $Action.OutcomePackageManager = $Action.Executor }
    $Action
}

function Get-ActionOutcome {
    param([object]$Action, [int]$ExitCode, [string]$OutputText)
    $Action = Resolve-ActionMetadata -Action $Action
    if ($Action.OutcomePackageManager) {
        return Invoke-PackageManagerOperation -PackageManager $Action.OutcomePackageManager -Operation 'Get-ExecutionOutcome' -Arguments @{ Action = $Action; ExitCode = $ExitCode; OutputText = $OutputText }
    }
    if ($Action.ToolId -and $script:ToolDefinitions[$Action.ToolId] -and $script:ToolDefinitions[$Action.ToolId].ContainsKey('Get-ToolOutcome')) {
        return Invoke-ToolEntryPoint -ToolId $Action.ToolId -EntryPoint 'Get-ToolOutcome' -Arguments @{ Action = $Action; ExitCode = $ExitCode; OutputText = $OutputText }
    }
}

function Get-AvailableActions {
    param([switch]$RegistryOnly)

    $actions = @()
    foreach ($notInstalled in $results.NotInstalled | Where-Object { -not $RegistryOnly }) {
        $command = Get-InstallCommand -NotInstalledEntry $notInstalled
        $suffix = if ([string]::IsNullOrWhiteSpace($command)) { ' (no install command for this platform)' } else { '' }
        $actions += @{
            Name = $notInstalled.Name
            ToolId = $notInstalled.ToolId
            Label = "Install $($notInstalled.Name)$suffix"
            Type = 'install'
            Command = $command
        }
    }

    if (-not $SkipUpdate) {
        foreach ($update in $results.AvailableUpdates | Where-Object { -not $RegistryOnly -or $_.Type -eq 'registry' }) {
            $details = if ($update.Details) { " ($($update.Details))" } else { '' }
            $verb = if ($update.Type -eq 'registry') { 'Align' } else { 'Update' }
            # Preserve all owner/executor arguments, including fields unknown to the menu.
            $action = @{}
            foreach ($key in $update.Keys) { $action[$key] = $update[$key] }
            $action.Label = "$verb $($update.Name)$details"
            $actions += $action
        }
    }

    $actions | ForEach-Object { Resolve-ActionMetadata -Action $_ }
}

function Invoke-ActionCommand {
    # Execution primitive: callers must obtain approval before invoking this dispatcher.
    param([Parameter(Mandatory)][object]$Action)

    if ($Action.Type -eq 'registry') {
        return Set-RegistryConfiguration -RegistryKey $Action.RegistryKey -EnvironmentConfig $script:RegistryEnvironment
    }
    $Action = Resolve-ActionMetadata -Action $Action
    if ($Action.Executor -eq 'tool') {
        return Invoke-ToolEntryPoint -ToolId $Action.ToolId -EntryPoint $Action.EntryPoint -Arguments $Action.Arguments
    }
    if ($Action.Executor -ne 'command') { return Invoke-PackageManagerOperation -PackageManager $Action.Executor -Operation 'Invoke-Command' -Arguments @{ Command = $Action.Command; Type = $Action.Type } }
    Invoke-ToolCommand -Command $Action.Command -Type $Action.Type
}

function Complete-UpdateExecution {
    # A skipped package manager operation is still an unsuccessful requested update.
    param(
        [Parameter(Mandatory)][object]$Action,
        [Parameter(Mandatory)][object]$Execution,
        [switch]$Refresh
    )

    $exitCode = if ($null -ne $Execution.ExitCode) { [int]$Execution.ExitCode } else { 1 }
    $outputText = @($Execution.Output) -join "`n"
    if ($outputText) { Write-Host $outputText.TrimEnd() }

    if ($exitCode -eq 0) {
        Write-Success "Update completed: $($Action.Name)"
        $results.UpdateFailed = @($results.UpdateFailed | Where-Object { $_ -ne $Action.Name })
        if ($Refresh) {
            $refreshed = Refresh-ToolVersion -ToolName $Action.Name
            if ($refreshed -and $results.Tools.ContainsKey($Action.Name)) {
                Write-Host "  Verified version: $($results.Tools[$Action.Name].Installed)"
            }
        }
        return $true
    }

    $outcome = Get-ActionOutcome -Action $Action -ExitCode $exitCode -OutputText $outputText
    if ($outcome.Message) {
        $message = $outcome.Message
        if ($outcome.Status -eq 'Skipped') { Write-Warning $message } else { Write-Error $message }
    } else {
        $message = "Failed: $($Action.Name) | Command: $($Action.Command) | Exit code: $exitCode"
        Write-Error $message
    }

    if ($Action.Name -notin $results.UpdateFailed) { $results.UpdateFailed += $Action.Name }
    $results.Errors += $message
    $false
}

function Complete-InstallExecution {
    param(
        [Parameter(Mandatory)][object]$Action,
        [Parameter(Mandatory)][object]$Execution
    )

    $outputText = @($Execution.Output) -join "`n"
    $exitCode = if ($null -ne $Execution.ExitCode) { [int]$Execution.ExitCode } else { 1 }
    if ($outputText) { Write-Host $outputText.TrimEnd() }

    $Action = Resolve-ActionMetadata -Action $Action
    $config = Get-OwnedConfiguration -ToolId $Action.ToolId
    if (-not $config) { $config = $toolsConfig[$Action.Name] }
    $commandVerified = $config -and $config.Command -and (Test-CommandExists $config.Command)
    if ($commandVerified -or $exitCode -eq 0) {
        Write-Success "Install completed: $($Action.Name)"
        if ($commandVerified) {
            Write-Success "Verified command found: $($config.Command)"
        } else {
            Write-Warning "Command could not be verified yet for $($Action.Name) — you may need to restart your shell"
        }
        Refresh-ToolVersion -ToolName $Action.Name | Out-Null
        $results.NotInstalled = @($results.NotInstalled | Where-Object { $_.Name -ne $Action.Name })
        return $true
    }

    $outcome = Get-ActionOutcome -Action $Action -ExitCode $exitCode -OutputText $outputText
    if ($outcome.NoApplicablePackage) {
        $message = "Install could not be verified for $($Action.Name). Command: $($Action.Command) | Exit code: $exitCode | The package manager reports no applicable package, but '$($config.Command)' is not available."
    } else {
        $message = "Install failed for $($Action.Name). Command: $($Action.Command) | Exit code: $exitCode"
    }
    Write-Error $message
    $results.Errors += $message
    $false
}

function Invoke-ActionMenu {
    param([switch]$RegistryOnly)

    $actions = @(Get-AvailableActions -RegistryOnly:$RegistryOnly)
    if ($actions.Count -eq 0) { return }

    $completedIdx = @()
    while ($true) {
        $remaining = @()
        for ($i = 0; $i -lt $actions.Count; $i++) {
            if ($i -notin $completedIdx) { $remaining += @{ Idx = $i; Action = $actions[$i] } }
        }
        if ($remaining.Count -eq 0) {
            Write-Host "All actions completed.`n"
            break
        }

        Write-Header "Actions"
        Write-Host ""
        Write-Host "  [0] Exit"
        Write-Host "  ----------------"
        for ($i = 0; $i -lt $remaining.Count; $i++) {
            if ($remaining[$i].Action.Name -in $results.UpdateFailed) {
                Write-Host "  $ColorOrange[$($i+1)] $($remaining[$i].Action.Label)$ColorReset"
            } else {
                Write-Host "  [$($i+1)] $($remaining[$i].Action.Label)"
            }
        }
        Write-Host ""

        $response = Read-Host "Select option"
        if ($response -eq "0" -or [string]::IsNullOrWhiteSpace($response)) { break }

        $selected = @()
        $response -split ',' | ForEach-Object {
            $t = $_.Trim()
            if ($t -match '^\d+$') {
                $n = [int]$t
                if ($n -ge 1 -and $n -le $remaining.Count) { $selected += $n }
            }
        }
        if ($selected.Count -eq 0) { Write-Host "No valid selection. Please try again.`n"; continue }

        foreach ($num in $selected) {
            $ri = $num - 1
            $a  = $remaining[$ri].Action

            if ($a.Type -ne 'registry' -and [string]::IsNullOrWhiteSpace($a.Command)) {
                Write-Warning "No command configured for $($a.Name) on $script:PlatformKey"
                continue
            }

            if ($a.Type -eq 'registry') {
                Write-Host "Executing approved registry alignment: $($a.Name)"
            } else {
                Write-Host "Executing: $($a.Command)"
            }
            try {
                $execution = Invoke-ActionCommand -Action $a
                $outputText = $execution.Output
                $exitCode   = $execution.ExitCode

                if ($a.Type -eq 'registry') {
                    if (Complete-RegistryExecution -Action $a -Execution $execution) {
                        $completedIdx += $remaining[$ri].Idx
                    }
                } elseif ($a.Type -eq "install") {
                    if (Complete-InstallExecution -Action $a -Execution $execution) {
                        $completedIdx += $remaining[$ri].Idx
                    }
                } elseif (Complete-UpdateExecution -Action $a -Execution $execution -Refresh) {
                    $completedIdx += $remaining[$ri].Idx
                }
            } catch {
                $message = "$($a.Type) failed for $($a.Name). Command: $($a.Command) | $(Get-DetailedErrorMessage $_)"
                Write-Error $message
                if ($a.Name -notin $results.UpdateFailed) { $results.UpdateFailed += $a.Name }
                $results.Errors += $message
            }
            Write-Host ""
            Show-ResultsTable
        }
    }
}

function Invoke-ForceUpdates {
    # Force authorizes tool updates only; registry alignment stays in the explicit menu.
    Write-Header "Available Updates (Force mode)"
    $automaticUpdates = @($results.AvailableUpdates | Where-Object { $_.Type -ne 'registry' })
    if ($automaticUpdates.Count -eq 0) { Write-Success "No automatic tool updates available"; return }

    Write-Host "Running all updates in parallel...`n"
    Invoke-ParallelUpdates -Updates $automaticUpdates
    foreach ($u in $automaticUpdates | Where-Object { $_.Name -notin $results.UpdateFailed }) {
        Refresh-ToolVersion -ToolName $u.Name | Out-Null
    }
    Show-ResultsTable
    if ($results.UpdateFailed.Count -gt 0) {
        Write-Error "$($results.UpdateFailed.Count) update(s) failed or were skipped: $($results.UpdateFailed -join ', ')"
    } else {
        Write-Success "All updates were installed successfully."
    }
    Write-Host ""
}

function Invoke-ParallelUpdates {
    param([array]$Updates)
    if ($Updates.Count -eq 0) { return }

    $jobs = @()
    foreach ($u in $Updates) {
        $u = Resolve-ActionMetadata -Action $u
        # Some installers must remain in this process; both modes share completion logic.
        if ($u.ExecutionMode -eq 'CurrentSession') {
            Write-Host "Starting: $($u.Name)"
            $execution = Invoke-ActionCommand -Action $u
            Complete-UpdateExecution -Action $u -Execution $execution | Out-Null
            Write-Host ''
            continue
        }

        Write-Host "Starting: $($u.Name)"
        $jobs += @{
            Job = Start-Job -ScriptBlock {
                param($action, $definitions, $configuration, $packageManagerDefinitions, $toolDefinitions)
                try {
                    $toolsConfig = $configuration
                    $script:PackageManagerDefinitions = $packageManagerDefinitions
                    $script:ToolDefinitions = $toolDefinitions
                    . ([scriptblock]::Create($definitions))
                    $results = New-ToolCheckResults
                    Invoke-ActionCommand -Action $action
                } catch {
                    [PSCustomObject]@{
                        Output = @()
                        ExitCode = 1
                        Error = "$_ | Exception: $($_.Exception.GetType().FullName)"
                    }
                }
            } -ArgumentList $u, (Get-ActionWorkerDefinitions), $toolsConfig, $script:PackageManagerDefinitions, $script:ToolDefinitions
            Update = $u
        }
    }
    Write-Host "`nWaiting for all updates to complete...`n"

    foreach ($j in $jobs) {
        $execution = Receive-Job -Job $j.Job -Wait
        $state = $j.Job.State
        $result = @()
        if ($state -eq "Completed") {
            $exitCode = if ($null -ne $execution.ExitCode) { [int]$execution.ExitCode } else { 1 }
            $result = @($execution.Output)
            if ($execution.Error) { $result += $execution.Error }
            $outputText = if ($result.Count -gt 0) { ($result | Out-String) } else { "" }
            Complete-UpdateExecution -Action $j.Update -Execution @{ Output = $outputText; ExitCode = $exitCode } | Out-Null
        } else {
            $message = "Failed: $($j.Update.Name) | Job state: $state | Command: $($j.Update.Command)"
            Write-Error $message
            if ($j.Update.Name -notin $results.UpdateFailed) { $results.UpdateFailed += $j.Update.Name }
            $results.Errors += $message
            if ($result) { $result | ForEach-Object { Write-Host "  $_" } }
        }
        Remove-Job -Job $j.Job; Write-Host ""
    }
    Write-Host "All parallel updates finished.`n"
}

function Get-ActionWorkerDefinitions {
    # Read allowlisted source definitions, not live Get-Command bodies that may be mocked.
    $names = @('Invoke-ToolCommand','Resolve-ActionMetadata','Invoke-ActionCommand','Invoke-PackageManagerOperation','Get-ResultToolId','Get-OwnedConfiguration','New-ToolCheckResults','Invoke-ToolEntryPoint','Set-ToolResultOwnership','Get-ToolState','Get-DetailedErrorMessage','Get-ToolConfiguration','Test-CommandExists')
    $paths = @('actions.ps1','results.ps1','package-managers.ps1','configuration.ps1','runtime.ps1' | ForEach-Object { Join-Path $PSScriptRoot $_ })
    $source = ($paths | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    $definitions = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in $names } | ForEach-Object { $_.Extent.Text })
    foreach ($packageManager in $script:PackageManagerDefinitions.Values) {
        $definitions += @($packageManager.Keys | Where-Object { $_ -notlike '*-PackageManager' } | ForEach-Object { $packageManager[$_] })
    }
    $definitions -join "`n`n"
}
