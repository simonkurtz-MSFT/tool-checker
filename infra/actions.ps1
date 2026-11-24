# Action planning, approval, execution, and completion for both interactive and
# automatic workflows. Executors return Output/ExitCode; owners interpret failures.
function Get-InstallCommand {
    param([pscustomobject]$NotInstalledEntry)
    if (-not $NotInstalledEntry -or -not $NotInstalledEntry.InstallCommands) { return "" }

    $commands = $NotInstalledEntry.InstallCommands
    if ($commands.Contains($script:PlatformKey)) { return $commands[$script:PlatformKey] }

    # Best-effort fallback to current OS if an exact arch match is missing.
    $osPrefix = if (Test-IsWindowsPlatform) { 'Windows (' } else { 'Linux (' }
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
            $value = Get-PlatformConfigurationValue -Configuration $config -Property "$($Action.Operation)$property"
            if (-not $Action[$property] -and $value) { $Action[$property] = $value }
        }
    }
    if ('Unattended' -notin $Action.Keys) {
        $Action.Unattended = $config -and (Get-PlatformConfigurationValue -Configuration $config -Property "$($Action.Operation)Unattended") -eq $true
    }
    if (-not $Action.Executor) { $Action.Executor = 'command' }
    if (-not $Action.ExecutionMode) { $Action.ExecutionMode = 'Job' }
    if (-not $Action.OutcomePackageManager -and $Action.Executor -notin @('command','tool')) { $Action.OutcomePackageManager = $Action.Executor }
    $Action
}

function Get-DuplicateInstallationActions {
    foreach ($owner in @($results.ToolState.Keys | Sort-Object)) {
        $state = $results.ToolState[$owner]
        if (-not $state.ContainsKey('Installations')) { continue }
        $found = @($state.Installations | Where-Object Status -eq 'Found')
        if ($found.Count -le 1) { continue }

        $config = Get-OwnedConfiguration -ToolId $owner
        $name = if ($config.Name) { $config.Name } else { $owner }
        # The update command's executable identifies the manager that keeps receiving updates.
        $preferredManager = ("$($config.UpdateCommand)".Trim() -split '\s+', 2)[0]
        $recommended = $found[0]
        foreach ($candidate in $found | Select-Object -Skip 1) {
            $comparison = Compare-OwnedToolVersions -Version1 $candidate.Version -Version2 $recommended.Version -ToolName $name
            if ($comparison -lt 0 -or ($comparison -eq 0 -and $candidate.PackageManager -ne $preferredManager -and $recommended.PackageManager -eq $preferredManager)) {
                $recommended = $candidate
            }
        }

        # Discovery owns removal syntax; planning and rendering never call the package manager.
        if (-not $recommended.RemoveCommand) { continue }
        $manager = $recommended.PackageManager
        $package = $recommended.PackageName
        @{
            Name = $name
            ToolId = $owner
            ItemId = "duplicate:${manager}:$package"
            Label = "Remove $manager duplicate of $name (recommended: remove version $($recommended.Version))"
            Type = 'cleanup'
            Command = $recommended.RemoveCommand
            Recommended = $true
        }
    }
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
    param([switch]$RegistryOnly, [switch]$ApprovalOnly)

    $actions = @()
    foreach ($notInstalled in $results.NotInstalled | Where-Object { -not $RegistryOnly -and -not $ApprovalOnly }) {
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
        $includedTypes = if ($RegistryOnly) { @('registry') } elseif ($ApprovalOnly) { @('registry', 'cleanup') } else { $null }
        foreach ($update in $results.AvailableUpdates | Where-Object { -not $includedTypes -or $_.Type -in $includedTypes }) {
            $details = if ($update.Details) { " ($($update.Details))" } else { '' }
            $verb = if ($update.Type -eq 'registry') { 'Align' } else { 'Update' }
            # Preserve all owner/executor arguments, including fields unknown to the menu.
            $action = @{}
            foreach ($key in $update.Keys) { $action[$key] = $update[$key] }
            $action.Label = "$verb $($update.Name)$details"
            $actions += $action
        }
        if (-not $RegistryOnly) { $actions += @(Get-DuplicateInstallationActions) }
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

function Register-UpdateFailure {
    param([string]$Name, [string]$Message)
    if ($Name -notin $results.UpdateFailed) { $results.UpdateFailed += $Name }
    $results.Errors += $Message
}

function Complete-UpdateExecution {
    # A skipped operation or a version that remains below the planned target is unsuccessful.
    param(
        [Parameter(Mandatory)][object]$Action,
        [Parameter(Mandatory)][object]$Execution,
        [switch]$Refresh
    )

    $exitCode = if ($null -ne $Execution.ExitCode) { [int]$Execution.ExitCode } else { 1 }
    $outputText = @($Execution.Output) -join "`n"
    if ($outputText) { Write-Host $outputText.TrimEnd() }

    if ($exitCode -eq 0 -and $Refresh -and $Action.Version) {
        $refreshed = Refresh-ToolVersion -ToolName $Action.Name
        $installedVersion = if ($refreshed -and $results.Tools.ContainsKey($Action.Name)) { $results.Tools[$Action.Name].Installed } else { $null }
        if (-not $installedVersion -or (Test-UpdateAvailable -InstalledVersion $installedVersion -LatestVersion $Action.Version -ToolName $Action.Name)) {
            $found = if ($installedVersion) { $installedVersion } else { 'unknown' }
            $message = "Update verification failed for $($Action.Name). Expected at least $($Action.Version), but found $found."
            Write-Error $message
            Register-UpdateFailure -Name $Action.Name -Message $message
            return $false
        }
        Write-Host "  Verified version: $installedVersion"
    } elseif ($exitCode -eq 0 -and $Refresh) {
        Refresh-ToolVersion -ToolName $Action.Name | Out-Null
    }

    if ($exitCode -eq 0) {
        Write-Success "Update completed: $($Action.Name)"
        $results.UpdateFailed = @($results.UpdateFailed | Where-Object { $_ -ne $Action.Name })
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

    Register-UpdateFailure -Name $Action.Name -Message $message
    $false
}

function Add-InstalledCommandPath {
    param([string]$Command, [string[]]$Paths)

    $originalPath = "$env:Path"
    $knownPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in ($originalPath -split ';')) {
        $normalized = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\', '/')
        if ($normalized) { [void]$knownPaths.Add($normalized) }
    }

    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        foreach ($entry in ($path -split ';')) {
            $directory = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"'))
            if ([string]::IsNullOrWhiteSpace($directory) -or -not $knownPaths.Add($directory.TrimEnd('\', '/'))) { continue }

            $separator = if (-not $originalPath -or $originalPath.EndsWith(';')) { '' } else { ';' }
            $found = $false
            try {
                $env:Path = "$originalPath$separator$directory"
                $found = Test-CommandExists -Command $Command
            } finally {
                if (-not $found) { $env:Path = $originalPath }
            }
            if ($found) { return $true }
        }
    }
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
    $mayRequireTerminalRestart = $config -and (Get-PlatformConfigurationValue -Configuration $config -Property 'InstallMayRequireTerminalRestart') -eq $true
    $commandVerified = $config -and $config.Command -and (Test-CommandExists $config.Command)
    if (-not $commandVerified -and $exitCode -eq 0 -and $config.Command -and (Test-IsWindowsPlatform)) {
        try {
            $paths = @(
                [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
                [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
            )
            $commandVerified = Add-InstalledCommandPath -Command $config.Command -Paths $paths
        } catch [System.Security.SecurityException], [System.UnauthorizedAccessException] {
            Write-Warning "Unable to inspect Windows PATH for $($Action.Name): $($_.Exception.Message)"
        }
    }
    if ($commandVerified -or $exitCode -eq 0) {
        Write-Success "Install completed: $($Action.Name)"
        if ($commandVerified) {
            Write-Success "Verified command found: $($config.Command)"
            if ($mayRequireTerminalRestart) {
                Write-Warning "To use $($Action.Name) in other terminals, you may need to update PATH or restart your terminal"
            }
        } elseif ($mayRequireTerminalRestart) {
            Write-Warning "Command could not be verified yet for $($Action.Name) — check PATH or restart your terminal"
        } else {
            Write-Warning "Command could not be verified yet for $($Action.Name) — you may need to restart your shell"
        }
        $previousNames = @($results.Tools.Keys)
        $hasPriorInventory = $results.Tools.ContainsKey($Action.Name) -or (
            $Action.ToolId -and @($results.Tools.Values | Where-Object { $_.ToolId -eq $Action.ToolId }).Count -gt 0
        )
        $placeholder = $null
        if (-not $results.Tools.ContainsKey($Action.Name)) {
            $placeholder = @{ ToolId = $Action.ToolId; Installed = 'unknown'; Latest = ''; ReleaseNotesUrl = $config.ReleaseNotesUrl }
            $results.Tools[$Action.Name] = $placeholder
        }
        $refreshed = Refresh-ToolVersion -ToolName $Action.Name -InitializeInventory:(-not $hasPriorInventory)
        if ($placeholder -and $refreshed -and $Action.ToolId -and
            $results.Tools.ContainsKey($Action.Name) -and
            [object]::ReferenceEquals($results.Tools[$Action.Name], $placeholder) -and $placeholder.Installed -eq 'unknown') {
            $newRows = @($results.Tools.GetEnumerator() | Where-Object {
                $_.Key -ne $Action.Name -and $_.Key -notin $previousNames -and $_.Value.ToolId -eq $Action.ToolId
            })
            if ($newRows.Count -gt 0) { $results.Tools.Remove($Action.Name) }
        }
        if ($commandVerified -and $results.Tools.ContainsKey($Action.Name) -and
            $results.Tools[$Action.Name].Installed -in @('', 'unknown', 'Unable to retrieve version')) {
            Write-Warning "Installed version could not be determined for $($Action.Name); re-check later"
        }
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

function Read-ActionMenuResponse {
    param(
        [int]$ActionCount = 0,
        [scriptblock]$ReadKey = { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    )

    Write-Host 'Select option: ' -NoNewline
    $options = @(for ($i = 1; $i -le $ActionCount; $i++) { [string]$i })
    $buffer = [System.Text.StringBuilder]::new()
    while ($true) {
        $key = & $ReadKey
        $character = [char]$key.Character

        if ($character -eq [char]3) { throw [System.Management.Automation.PipelineStoppedException]::new() }
        if ($character -in @([char]13, [char]10)) {
            Write-Host ''
            return $buffer.ToString()
        }
        if ($character -eq [char]8) {
            if ($buffer.Length -gt 0) {
                $buffer.Length--
                Write-Host "`b `b" -NoNewline
            }
            continue
        }

        $normalizedCharacter = [char]::ToUpperInvariant($character)
        if ($buffer.Length -eq 0 -and $normalizedCharacter -in @('0', 'D', 'R', 'A')) {
            Write-Host $normalizedCharacter
            return [string]$normalizedCharacter
        }
        if ([char]::IsDigit($character) -or $character -eq ',') {
            [void]$buffer.Append($character)
            Write-Host $character -NoNewline
            $selection = $buffer.ToString()
            if ($selection -in $options -and @($options | Where-Object { $_.StartsWith($selection) }).Count -eq 1) {
                Write-Host ''
                return $selection
            }
        }
    }
}

function Invoke-ActionExecution {
    param([Parameter(Mandatory)][object]$Action)

    try {
        $execution = Invoke-ActionCommand -Action $Action
        if ($Action.Type -eq 'registry') {
            return Complete-RegistryExecution -Action $Action -Execution $execution
        }
        if ($Action.Type -eq 'install') {
            return Complete-InstallExecution -Action $Action -Execution $execution
        }
        Complete-UpdateExecution -Action $Action -Execution $execution -Refresh
    } catch {
        $message = "$($Action.Type) failed for $($Action.Name). Command: $($Action.Command) | $(Get-DetailedErrorMessage $_)"
        Write-Error $message
        Register-UpdateFailure -Name $Action.Name -Message $message
        $false
    }
}

function Invoke-UnattendedActions {
    Write-Header 'Install / Update (Unattended mode)'
    $runnable = @()
    # Snapshot once: a failed action remains pending but is never scheduled again in this run.
    foreach ($action in @(Get-AvailableActions)) {
        $reason = if ($action.Type -in @('registry', 'cleanup')) { 'requires explicit approval' }
            elseif ([string]::IsNullOrWhiteSpace($action.Command)) { "no command configured for $script:PlatformKey" }
            elseif ($action.Unattended -ne $true) { 'may require interaction' }
        if ($reason) {
            Write-Warning "Skipped $($action.Name): $reason."
        } else {
            $runnable += $action
        }
    }

    if ($runnable.Count -eq 0) {
        Write-Host ''
        Write-Host 'No unattended installs or updates available.'
        Write-Host ''
        
        return
    }

    for ($i = 0; $i -lt $runnable.Count; $i++) {
        $action = $runnable[$i]
        $verb = if ($action.Type -eq 'install') { 'Installing' } else { 'Updating' }
        Write-Host "$($i + 1)/$($runnable.Count): $verb $($action.Name): $($action.Command)"
        Invoke-ActionExecution -Action $action | Out-Null
        Write-Host ''
    }
    Show-ResultsTable
}

function Invoke-ActionMenu {
    param([switch]$RegistryOnly, [switch]$ApprovalOnly)

    $actions = @(Get-AvailableActions -RegistryOnly:$RegistryOnly -ApprovalOnly:$ApprovalOnly)
    if ($actions.Count -eq 0 -and ($RegistryOnly -or $ApprovalOnly -or $SkipUpdate)) { return }

    $completedIdx = @()
    while ($true) {
        $remaining = @()
        for ($i = 0; $i -lt $actions.Count; $i++) {
            if ($i -notin $completedIdx) { $remaining += @{ Idx = $i; Action = $actions[$i] } }
        }
        if ($remaining.Count -eq 0 -and $completedIdx.Count -gt 0) {
            Write-Host "All actions completed.`n"
            break
        }
        $bulkSelections = @(for ($i = 0; $i -lt $remaining.Count; $i++) {
            $action = $remaining[$i].Action
            if ($action.Type -notin @('registry', 'cleanup') -and -not [string]::IsNullOrWhiteSpace($action.Command)) { $i + 1 }
        })

        Write-Header "Actions"
        Write-Host ""
        Write-Host "  [0] Exit"
        Write-Host ""
        Write-Host "  [D] Update / Install commands and Release Notes"
        Write-Host "  [R] Re-check"
        if ($bulkSelections.Count -gt 1) {
            Write-Host "  [A] Install / Update all (sequential, unattended first)"
        }
        Write-Host "  ----------------"
        for ($i = 0; $i -lt $remaining.Count; $i++) {
            if ($remaining[$i].Action.Name -in $results.UpdateFailed) {
                Write-Host "  $ColorOrange[$($i+1)] $($remaining[$i].Action.Label)$ColorReset"
            } else {
                Write-Host "  [$($i+1)] $($remaining[$i].Action.Label)"
            }
        }
        Write-Host ""

        $response = Read-ActionMenuResponse -ActionCount $remaining.Count
        Write-Host ""
        
        if ($response -eq "0" -or [string]::IsNullOrWhiteSpace($response)) { break }
        $normalizedResponse = $response.Trim()
        if ($normalizedResponse -eq 'D') {
            Show-ToolDetails
            continue
        }
        if ($normalizedResponse -eq 'R') {
            Invoke-CheckWorkflow -ResetResults
            $actions = @(Get-AvailableActions -RegistryOnly:$RegistryOnly -ApprovalOnly:$ApprovalOnly)
            $completedIdx = @()
            continue
        }

        $selected = @()
        $isBulkSelection = $normalizedResponse -eq 'A' -and $bulkSelections.Count -gt 1
        if ($isBulkSelection) {
            $selected = @($bulkSelections | Sort-Object @{ Expression = { if ($remaining[$_ - 1].Action.Unattended) { 0 } else { 1 } } }, @{ Expression = { $_ } })
        } else {
            $response -split ',' | ForEach-Object {
                $t = $_.Trim()
                if ($t -match '^\d+$') {
                    $n = [int]$t
                    if ($n -ge 1 -and $n -le $remaining.Count) { $selected += $n }
                }
            }
        }
        if ($selected.Count -eq 0) { Write-Host "No valid selection. Please try again.`n"; continue }

        $actionIndex = 0
        foreach ($num in $selected) {
            $actionIndex++
            $ri = $num - 1
            $a  = $remaining[$ri].Action

            if ($a.Type -ne 'registry' -and [string]::IsNullOrWhiteSpace($a.Command)) {
                Write-Warning "No command configured for $($a.Name) on $script:PlatformKey"
                continue
            }

            if ($isBulkSelection) {
                $verb = if ($a.Type -eq 'install') { 'Installing' } else { 'Updating' }
                Write-Host "$actionIndex/$($selected.Count): $verb $($a.Name): $($a.Command)"
            } elseif ($a.Type -eq 'registry') {
                Write-Host "Executing approved registry alignment: $($a.Name)"
            } else {
                Write-Host "Executing $($a.Name): $($a.Command)"
            }
            if (Invoke-ActionExecution -Action $a) {
                $completedIdx += $remaining[$ri].Idx
            }
            Write-Host ""
            Show-ResultsTable
        }
    }
}

function Invoke-ForceUpdates {
    # Force authorizes tool updates only; registry alignment and cleanup stay in the explicit menu.
    Write-Header "Available Updates (Force mode)"
    $automaticUpdates = @($results.AvailableUpdates | Where-Object { $_.Type -notin @('registry', 'cleanup') })
    if ($automaticUpdates.Count -eq 0) { Write-Success "No automatic tool updates available"; return }

    Write-Host "Running all updates in parallel...`n"
    Invoke-ParallelUpdates -Updates $automaticUpdates
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
    $workerDefinitions = $null
    foreach ($u in $Updates) {
        $u = Resolve-ActionMetadata -Action $u
        Write-Host "Starting $($u.Name): $($u.Command)"
        # Some installers must remain in this process; both modes share completion logic.
        if ($u.ExecutionMode -eq 'CurrentSession') {
            $execution = Invoke-ActionCommand -Action $u
            Complete-UpdateExecution -Action $u -Execution $execution -Refresh | Out-Null
            Write-Host ''
            continue
        }

        if (-not $workerDefinitions) { $workerDefinitions = Get-ActionWorkerDefinitions }
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
            } -ArgumentList $u, $workerDefinitions, $toolsConfig, $script:PackageManagerDefinitions, $script:ToolDefinitions
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
            Complete-UpdateExecution -Action $j.Update -Execution @{ Output = $outputText; ExitCode = $exitCode } -Refresh | Out-Null
        } else {
            $message = "Failed: $($j.Update.Name) | Job state: $state | Command: $($j.Update.Command)"
            Write-Error $message
            Register-UpdateFailure -Name $j.Update.Name -Message $message
            if ($result) { $result | ForEach-Object { Write-Host "  $_" } }
        }
        Remove-Job -Job $j.Job; Write-Host ""
    }
    Write-Host "All parallel updates finished.`n"
}

function Get-ActionWorkerDefinitions {
    # Registry repairs always run in the approving session, so their helpers stay out of jobs.
    $definitions = @(Get-InfrastructureDefinitions -Names @(
        'Invoke-ToolCommand','Resolve-ActionMetadata','Invoke-ActionCommand','Invoke-PackageManagerOperation',
        'Get-ResultToolId','Get-OwnedConfiguration','New-ToolCheckResults','Invoke-ToolEntryPoint',
        'Set-ToolResultOwnership','Get-ToolState','Get-DetailedErrorMessage','Get-ToolConfiguration','Test-CommandExists',
        'Test-IsWindowsPlatform','Get-PlatformConfigurationValue'
    ))
    $definitions += @(Get-SharedPackageManagerDefinitions)
    $definitions -join "`n`n"
}
