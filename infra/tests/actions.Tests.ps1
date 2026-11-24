# Action planning, dispatch, completion, and automatic-mode contracts. Commands are mocked
# or synthetic; no real installs, updates, or registry repairs execute.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) "actions-tests-$([guid]::NewGuid()).env")

Describe 'Action planning' {
    BeforeEach {
        $script:SkipUpdate = $false
        $results.NotInstalled = @(
            [PSCustomObject]@{
                Name = 'Missing CLI'
                InstallCommands = [ordered]@{ $script:PlatformKey = 'install missing-cli' }
            }
        )
        $results.AvailableUpdates = @(
            @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct'; Details = '1.0.0 -> 1.1.0' },
            @{ Name = 'npm registry'; Command = ''; Type = 'registry'; Details = 'old -> new'; RegistryKey = 'npm' }
        )
    }

    It 'builds install and update actions in display order' {
        $actions = @(Get-AvailableActions)

        $actions.Count | Should Be 3
        $actions[0].Label | Should Be 'Install Missing CLI'
        $actions[0].Command | Should Be 'install missing-cli'
        $actions[1].Label | Should Be 'Update Example CLI (1.0.0 -> 1.1.0)'
        $actions[2].Label | Should Be 'Align npm registry (old -> new)'
    }

    It 'returns only registry actions for approval-gated alignment' {
        $actions = @(Get-AvailableActions -RegistryOnly)

        $actions.Count | Should Be 1
        $actions[0].Type | Should Be 'registry'
        $actions[0].RegistryKey | Should Be 'npm'
    }

    It 'offers the older duplicate installation as an approval-gated cleanup action' {
        $toolsConfig['Example CLI'] = @{ Id = 'example-cli'; Name = 'Example CLI'; UpdateCommand = 'npm install -g @example/cli@latest' }
        $results.ToolState['example-cli'] = @{
            Installations = @(
                @{ PackageManager = 'npm'; PackageName = '@example/cli'; Version = '2.0.0'; Status = 'Found'; RemoveCommand = 'npm uninstall --global @example/cli' },
                @{ PackageManager = 'pnpm'; PackageName = '@example/cli'; Version = '1.0.0'; Status = 'Found'; RemoveCommand = 'pnpm remove --global @example/cli' }
            )
        }

        $actions = @(Get-AvailableActions -ApprovalOnly)
        $cleanup = @($actions | Where-Object Type -eq 'cleanup')

        $cleanup.Count | Should Be 1
        $cleanup[0].Command | Should Be 'pnpm remove --global @example/cli'
        $cleanup[0].Label | Should Match 'recommended: remove version 1.0.0'
        $toolsConfig.Remove('Example CLI')
    }

    It 'recommends removing the non-update-manager duplicate when versions match' {
        $toolsConfig['Example CLI'] = @{ Id = 'example-cli'; Name = 'Example CLI'; UpdateCommand = 'npm install -g @example/cli@latest' }
        $results.ToolState['example-cli'] = @{
            Installations = @(
                @{ PackageManager = 'pnpm'; PackageName = '@example/cli'; Version = '2.0.0'; Status = 'Found'; RemoveCommand = 'pnpm remove --global @example/cli' },
                @{ PackageManager = 'npm'; PackageName = '@example/cli'; Version = '2.0.0'; Status = 'Found'; RemoveCommand = 'npm uninstall --global @example/cli' }
            )
        }

        $cleanup = @(Get-DuplicateInstallationActions)

        $cleanup[0].Command | Should Be 'pnpm remove --global @example/cli'
        $toolsConfig.Remove('Example CLI')
    }

    It 'uses the removal command supplied by discovery and skips records without one' {
        $toolsConfig['Example CLI'] = @{ Id = 'example-cli'; Name = 'Example CLI'; UpdateCommand = 'synthetic install example' }
        $results.ToolState['example-cli'] = @{
            Installations = @(
                @{ PackageManager = 'synthetic'; PackageName = 'example'; Version = '2.0.0'; Status = 'Found'; RemoveCommand = 'synthetic remove example' },
                @{ PackageManager = 'other'; PackageName = 'example'; Version = '1.0.0'; Status = 'Found'; RemoveCommand = 'other erase example' }
            )
        }

        @(Get-DuplicateInstallationActions)[0].Command | Should Be 'other erase example'

        $results.ToolState['example-cli'].Installations[1].Remove('RemoveCommand')
        @(Get-DuplicateInstallationActions).Count | Should Be 0
        $results.ToolState.Remove('example-cli')
        $toolsConfig.Remove('Example CLI')
    }
}

Describe 'Read-only details menu' {
    BeforeEach {
        $results = New-ToolCheckResults
        $SkipUpdate = $false
        $script:MenuResponses = [System.Collections.Generic.Queue[string]]::new()
        $script:MenuResponses.Enqueue(' d ')
        $script:MenuResponses.Enqueue('0')
        Mock Read-ActionMenuResponse { $script:MenuResponses.Dequeue() }
        Mock Write-Host {}
        Mock Show-ToolDetails {}
        Mock Invoke-CheckWorkflow {}
        Mock Invoke-ActionCommand { throw 'Details must not execute actions' }
    }

    It 'offers alphabetical details with no executable actions' {
        Invoke-ActionMenu
        Assert-MockCalled Show-ToolDetails 1 -Scope It
        Assert-MockCalled Read-ActionMenuResponse 2 -Scope It
        Assert-MockCalled Invoke-ActionCommand 0 -Scope It
    }

    It 'separates Exit and details with exactly one blank line' {
        $script:MenuLines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { param($Object) $script:MenuLines.Add([string]$Object) }
        $script:MenuResponses.Clear()
        $script:MenuResponses.Enqueue('0')
        Invoke-ActionMenu
        $exitIndex = $script:MenuLines.IndexOf('  [0] Exit')
        $exitIndex | Should BeGreaterThan -1
        $script:MenuLines[$exitIndex + 1] | Should Be ''
        $script:MenuLines[$exitIndex + 2] | Should Be '  [D] Update / Install commands and Release Notes'
        $script:MenuLines[$exitIndex + 3] | Should Be '  [R] Re-check'
    }

    It 're-checks tools and rebuilds actions from fresh results' {
        $results.AvailableUpdates = @(@{ Name = 'Old CLI'; Command = 'old update'; Type = 'direct' })
        $script:MenuResponses.Clear()
        foreach ($response in @(' R ', '1')) { $script:MenuResponses.Enqueue($response) }
        Mock Invoke-CheckWorkflow {
            $results.AvailableUpdates = @(@{ Name = 'Fresh CLI'; Command = 'fresh update'; Type = 'direct' })
        }
        Mock Invoke-ActionCommand { @{ ExitCode = 0 } }
        Mock Complete-UpdateExecution { $true }
        Mock Show-ResultsTable {}

        Invoke-ActionMenu

        Assert-MockCalled Invoke-CheckWorkflow 1 -Scope It -ParameterFilter { $ResetResults }
        Assert-MockCalled Invoke-ActionCommand 1 -Scope It -ParameterFilter { $Action.Name -eq 'Fresh CLI' }
        Assert-MockCalled Invoke-ActionCommand 0 -Scope It -ParameterFilter { $Action.Name -eq 'Old CLI' }
    }

    It 'recalculates numeric input choices after completed actions are removed' {
        $results.AvailableUpdates = @(1..10 | ForEach-Object { @{ Name = "CLI $_"; Command = "update $_"; Type = 'direct' } })
        $script:MenuResponses.Clear()
        foreach ($response in @('10', '1', '0')) { $script:MenuResponses.Enqueue($response) }
        Mock Invoke-ActionCommand { @{ ExitCode = 0 } }
        Mock Complete-UpdateExecution { $true }
        Mock Show-ResultsTable {}

        Invoke-ActionMenu

        foreach ($count in @(10, 9, 8)) {
            Assert-MockCalled Read-ActionMenuResponse 1 -Scope It -ParameterFilter { $ActionCount -eq $count }
        }
        Assert-MockCalled Invoke-ActionCommand 1 -Scope It -ParameterFilter { $Action.Name -eq 'CLI 10' }
        Assert-MockCalled Invoke-ActionCommand 1 -Scope It -ParameterFilter { $Action.Name -eq 'CLI 1' }
    }

    It 'preserves numeric actions and approval-only restrictions after viewing details' {
        $results.AvailableUpdates = @(
            @{ Name = 'Example'; Command = 'example update'; Type = 'direct' },
            @{ Name = 'npm registry'; Type = 'registry'; RegistryKey = 'npm' }
        )
        $script:MenuResponses.Clear()
        foreach ($response in @('D', '1', '0')) { $script:MenuResponses.Enqueue($response) }
        Mock Invoke-ActionCommand { @{ ExitCode = 0 } }
        Mock Complete-RegistryExecution { $true }
        Mock Show-ResultsTable {}
        Invoke-ActionMenu -ApprovalOnly
        Assert-MockCalled Show-ToolDetails 1 -Scope It
        Assert-MockCalled Invoke-ActionCommand 1 -Scope It -ParameterFilter { $Action.Type -eq 'registry' }
        Assert-MockCalled Invoke-ActionCommand 0 -Scope It -ParameterFilter { $Action.Type -eq 'direct' }
    }

    It 'prints the tool name and exact command for an interactive <Kind> action' -TestCases @(
        @{ Kind = 'install' }, @{ Kind = 'update' }
    ) {
        param($Kind)
        if ($Kind -eq 'install') {
            $results.NotInstalled = @([pscustomobject]@{
                Name = 'Example CLI'
                InstallCommands = @{ $script:PlatformKey = 'example install --version 1.1.0' }
            })
        } else {
            $results.AvailableUpdates = @(@{ Name = 'Example CLI'; Command = 'example update --version 1.1.0'; Type = 'direct' })
        }
        $script:MenuResponses.Clear()
        $script:MenuResponses.Enqueue('1')
        Mock Invoke-ActionCommand { @{ Output = ''; ExitCode = 0 } }
        Mock Complete-InstallExecution { $true }
        Mock Complete-UpdateExecution { $true }
        Mock Show-ResultsTable {}
        Invoke-ActionMenu
        Assert-MockCalled Write-Host 1 -Scope It -ParameterFilter { $Object -eq "Executing Example CLI: example $Kind --version 1.1.0" }
    }
}

Describe 'Action menu input' {
    It 'shows only a concise selection prompt' {
        Mock Write-Host {}

        Read-ActionMenuResponse -ActionCount 3 -ReadKey { [pscustomobject]@{ Character = [char]'0' } } | Should Be '0'

        Assert-MockCalled Write-Host 1 -Scope It -ParameterFilter {
            $Object -eq 'Select option: ' -and $NoNewline
        }
        Assert-MockCalled Write-Host 2 -Exactly -Scope It
    }

    It 'returns hotkeys immediately without reading Enter' -TestCases @(
        @{ Key = 'r'; Expected = 'R' },
        @{ Key = 'D'; Expected = 'D' },
        @{ Key = '0'; Expected = '0' }
        @{ Key = 'a'; Expected = 'A' }
    ) {
        param($Key, $Expected)
        $script:Keys = [System.Collections.Generic.Queue[object]]::new()
        $script:Keys.Enqueue([pscustomobject]@{ Character = [char]$Key })
        Mock Write-Host {}

        Read-ActionMenuResponse -ReadKey { $script:Keys.Dequeue() } | Should Be $Expected

        $script:Keys.Count | Should Be 0
    }

    It 'accepts a unique numeric option without Enter' -TestCases @(
        @{ Count = 3; InputText = '1'; Expected = '1' },
        @{ Count = 9; InputText = '9'; Expected = '9' },
        @{ Count = 10; InputText = '2'; Expected = '2' },
        @{ Count = 10; InputText = '10'; Expected = '10' },
        @{ Count = 100; InputText = '100'; Expected = '100' },
        @{ Count = 119; InputText = '12'; Expected = '12' }
    ) {
        param($Count, $InputText, $Expected)
        $script:Keys = [System.Collections.Generic.Queue[object]]::new()
        foreach ($character in $InputText.ToCharArray()) {
            $script:Keys.Enqueue([pscustomobject]@{ Character = $character })
        }
        Mock Write-Host {}

        Read-ActionMenuResponse -ActionCount $Count -ReadKey { $script:Keys.Dequeue() } | Should Be $Expected
        $script:Keys.Count | Should Be 0
    }

    It 'waits for Enter for ambiguous or invalid numbers' -TestCases @(
        @{ Count = 10; InputText = '1'; Expected = '1' },
        @{ Count = 100; InputText = '10'; Expected = '10' },
        @{ Count = 3; InputText = '4'; Expected = '4' },
        @{ Count = 0; InputText = '1'; Expected = '1' }
    ) {
        param($Count, $InputText, $Expected)
        $script:Keys = [System.Collections.Generic.Queue[object]]::new()
        foreach ($character in ($InputText + "`r").ToCharArray()) {
            $script:Keys.Enqueue([pscustomobject]@{ Character = $character })
        }
        Mock Write-Host {}

        Read-ActionMenuResponse -ActionCount $Count -ReadKey { $script:Keys.Dequeue() } | Should Be $Expected
        $script:Keys.Count | Should Be 0
    }

    It 'retains comma-separated selections after an ambiguous prefix or a leading comma' -TestCases @(
        @{ Count = 120; InputText = '12,3'; Expected = '12,3' },
        @{ Count = 3; InputText = ',1,3'; Expected = ',1,3' }
    ) {
        param($Count, $InputText, $Expected)
        $script:Keys = [System.Collections.Generic.Queue[object]]::new()
        foreach ($character in ($InputText + "`r").ToCharArray()) {
            $script:Keys.Enqueue([pscustomobject]@{ Character = $character })
        }
        Mock Write-Host {}

        Read-ActionMenuResponse -ActionCount $Count -ReadKey { $script:Keys.Dequeue() } | Should Be $Expected
        $script:Keys.Count | Should Be 0
    }

    It 'supports editing a pending selection with Backspace' {
        $script:Keys = [System.Collections.Generic.Queue[object]]::new()
        foreach ($character in "1`b2".ToCharArray()) {
            $script:Keys.Enqueue([pscustomobject]@{ Character = $character })
        }
        Mock Write-Host {}

        Read-ActionMenuResponse -ActionCount 10 -ReadKey { $script:Keys.Dequeue() } | Should Be '2'
    }
}

Describe 'Unattended action metadata' {
    It 'resolves install and update hints independently with a false Windows override' {
        Mock Get-OwnedConfiguration { @{
            InstallUnattended = $true
            UpdateUnattended = $true
            WindowsInstallUnattended = $false
        } }
        Mock Test-IsWindowsPlatform { $true }
        (Resolve-ActionMetadata @{ Name = 'Synthetic'; Type = 'install' }).Unattended | Should Be $false
        (Resolve-ActionMetadata @{ Name = 'Synthetic'; Type = 'direct' }).Unattended | Should Be $true
        Mock Test-IsWindowsPlatform { $false }
        (Resolve-ActionMetadata @{ Name = 'Synthetic'; Type = 'install' }).Unattended | Should Be $true
    }

    It 'defaults unknown operations to potentially interactive and preserves explicit action hints' {
        Mock Get-OwnedConfiguration { @{} }
        (Resolve-ActionMetadata @{ Name = 'Synthetic'; Type = 'install' }).Unattended | Should Be $false
        Mock Get-OwnedConfiguration { @{ UpdateUnattended = $true } }
        (Resolve-ActionMetadata @{ Name = 'Synthetic'; Type = 'direct'; Unattended = $false }).Unattended | Should Be $false
    }

    It 'supports ordered plans produced by update checks' {
        Mock Get-OwnedConfiguration { @{ UpdateUnattended = $true } }
        $action = Resolve-ActionMetadata ([ordered]@{ Name = 'Synthetic'; Type = 'direct' })
        $action.Unattended | Should Be $true
    }
}

Describe 'Sequential bulk actions' {
    BeforeEach {
        $results = New-ToolCheckResults
        $SkipUpdate = $false
        $script:BulkActions = @(
            @{ Name = 'Interactive install'; Type = 'install'; Command = 'synthetic'; Unattended = $false },
            @{ Name = 'Unattended update'; Type = 'direct'; Command = 'synthetic'; Unattended = $true },
            @{ Name = 'Unattended install'; Type = 'install'; Command = 'synthetic'; Unattended = $true },
            @{ Name = 'Unknown update'; Type = 'direct'; Command = 'synthetic' },
            @{ Name = 'Registry'; Type = 'registry'; Command = 'synthetic' },
            @{ Name = 'Cleanup'; Type = 'cleanup'; Command = 'synthetic' },
            @{ Name = 'Unsupported'; Type = 'install'; Command = '' }
        )
        $script:BulkResponses = [System.Collections.Generic.Queue[string]]::new()
        foreach ($response in @('A', '0')) { $script:BulkResponses.Enqueue($response) }
        $script:BulkEvents = [System.Collections.Generic.List[string]]::new()
        $script:BulkMessages = [System.Collections.Generic.List[string]]::new()
        Mock Get-AvailableActions { $script:BulkActions }
        Mock Read-ActionMenuResponse { $script:BulkResponses.Dequeue() }
        Mock Write-Host { param($Object) $script:BulkMessages.Add([string]$Object) }
        Mock Show-ResultsTable {}
        Mock Invoke-ActionCommand {
            $script:BulkEvents.Add("start:$($Action.Name)")
            @{ ExitCode = 0 }
        }
        Mock Complete-InstallExecution {
            $script:BulkEvents.Add("complete:$($Action.Name)")
            $true
        }
        Mock Complete-UpdateExecution {
            $script:BulkEvents.Add("complete:$($Action.Name)")
            $true
        }
        Mock Invoke-ParallelUpdates { throw 'Bulk actions must not run in parallel' }
    }

    It 'finishes each operation before starting the next, with unattended actions first and stable ordering' {
        Invoke-ActionMenu

        ($script:BulkEvents -join ',') | Should Be (
            'start:Unattended update,complete:Unattended update,' +
            'start:Unattended install,complete:Unattended install,' +
            'start:Interactive install,complete:Interactive install,' +
            'start:Unknown update,complete:Unknown update'
        )
        Assert-MockCalled Invoke-ActionCommand 4 -Scope It
        Assert-MockCalled Invoke-ParallelUpdates 0 -Scope It
        Assert-MockCalled Complete-UpdateExecution 2 -Scope It -ParameterFilter { $Refresh }
    }

    It 'numbers runnable actions in execution order with the operation, tool name, and command' {
        Invoke-ActionMenu

        ($script:BulkMessages -match '^\d+/\d+: ' -join ',') | Should Be (
            '1/4: Updating Unattended update: synthetic,' +
            '2/4: Installing Unattended install: synthetic,' +
            '3/4: Installing Interactive install: synthetic,' +
            '4/4: Updating Unknown update: synthetic'
        )
    }

    It 'restarts progress with the remaining runnable action count when retrying a batch' {
        Mock Complete-UpdateExecution { $false }
        $script:BulkResponses.Clear()
        foreach ($response in @('A', 'A', '0')) { $script:BulkResponses.Enqueue($response) }

        Invoke-ActionMenu

        $progress = @($script:BulkMessages -match '^\d+/\d+: ')
        $progress.Count | Should Be 6
        $progress[4] | Should Be '1/2: Updating Unattended update: synthetic'
        $progress[5] | Should Be '2/2: Updating Unknown update: synthetic'
    }

    It 'offers all only when at least two runnable install or update actions remain' -TestCases @(
        @{ Count = 0 }, @{ Count = 1 }, @{ Count = 2 }
    ) {
        param($Count)
        $script:BulkActions = @($script:BulkActions | Select-Object -First $Count) + @(
            @{ Name = 'Registry'; Type = 'registry'; Command = 'synthetic' },
            @{ Name = 'Cleanup'; Type = 'cleanup'; Command = 'synthetic' },
            @{ Name = 'Unsupported'; Type = 'install'; Command = '' }
        )
        $script:BulkResponses.Clear()
        $script:BulkResponses.Enqueue('0')
        Invoke-ActionMenu
        $expected = if ($Count -gt 1) { 1 } else { 0 }
        Assert-MockCalled Write-Host $expected -Scope It -ParameterFilter { $Object -eq '  [A] Install / Update all (sequential, unattended first)' }
    }

    It 'keeps failed actions retryable without rerunning successful actions' {
        Mock Complete-UpdateExecution { $Action.Name -ne 'Unattended update' }
        $script:BulkResponses.Clear()
        foreach ($response in @('A', '1', '0')) { $script:BulkResponses.Enqueue($response) }
        Invoke-ActionMenu
        Assert-MockCalled Invoke-ActionCommand 2 -Scope It -ParameterFilter { $Action.Name -eq 'Unattended update' }
        Assert-MockCalled Invoke-ActionCommand 1 -Scope It -ParameterFilter { $Action.Name -eq 'Unattended install' }
        Assert-MockCalled Invoke-ActionCommand 1 -Scope It -ParameterFilter { $Action.Name -eq 'Unknown update' }
    }

    It 'continues after an executor exception and reports the failure' {
        Mock Invoke-ActionCommand {
            if ($Action.Name -eq 'Unattended update') { throw 'synthetic failure' }
            @{ ExitCode = 0 }
        }
        Invoke-ActionMenu
        ($results.UpdateFailed -contains 'Unattended update') | Should Be $true
        $results.Errors[0] | Should Match 'synthetic failure'
        Assert-MockCalled Invoke-ActionCommand 4 -Scope It
        ($script:BulkMessages -match '^\d+/\d+: ').Count | Should Be 4
        ($script:BulkMessages -contains '4/4: Updating Unknown update: synthetic') | Should Be $true
    }

    It 'preserves explicitly selected numeric order' {
        $script:BulkResponses.Clear()
        foreach ($response in @('1,3', '0')) { $script:BulkResponses.Enqueue($response) }
        Invoke-ActionMenu
        ($script:BulkEvents -join ',') | Should Be 'start:Interactive install,complete:Interactive install,start:Unattended install,complete:Unattended install'
        ($script:BulkMessages -match '^\d+/\d+: ').Count | Should Be 0
    }

    It 'does not enable bulk approval of registry alignment or cleanup' {
        $script:BulkActions = @($script:BulkActions | Where-Object { $_.Type -in @('registry', 'cleanup') })
        Invoke-ActionMenu -ApprovalOnly
        Assert-MockCalled Invoke-ActionCommand 0 -Scope It
        Assert-MockCalled Write-Host 0 -Scope It -ParameterFilter { $Object -eq '  [A] Install / Update all (sequential, unattended first)' }
    }
}

Describe 'Unattended actions' {
    BeforeEach {
        $results = New-ToolCheckResults
        $script:UnattendedActions = @(
            @{ Name = 'Safe install'; ToolId = 'safe-install'; Type = 'install'; Command = 'synthetic install'; Unattended = $true },
            @{ Name = 'Safe update'; ToolId = 'safe-update'; Type = 'direct'; Command = 'synthetic update'; Version = '2.0.0'; Unattended = $true },
            @{ Name = 'Interactive'; Type = 'install'; Command = 'never run'; Unattended = $false },
            @{ Name = 'Unknown'; Type = 'direct'; Command = 'never run' },
            @{ Name = 'Registry'; Type = 'registry'; Command = 'never run'; Unattended = $true },
            @{ Name = 'Cleanup'; Type = 'cleanup'; Command = 'never run'; Unattended = $true },
            @{ Name = 'Unsupported'; Type = 'install'; Command = ''; Unattended = $true }
        )
        $results.Tools['Safe update'] = @{ ToolId = 'safe-update'; Installed = '1.0.0'; Latest = '2.0.0' }
        $script:UnattendedEvents = [System.Collections.Generic.List[string]]::new()
        Mock Get-AvailableActions { $script:UnattendedActions }
        Mock Get-OwnedConfiguration { @{ Command = 'synthetic' } }
        Mock Test-CommandExists { $true }
        Mock Test-IsWindowsPlatform { $false }
        Mock Refresh-ToolVersion {
            $results.Tools[$ToolName].Installed = '2.0.0'
            $true
        }
        Mock Invoke-ActionCommand {
            $script:UnattendedEvents.Add($Action.Name)
            @{ ExitCode = 0 }
        }
        Mock Write-Host {}
        Mock Show-ResultsTable {}
        Mock Invoke-ActionMenu { throw 'Unattended runs must not open a menu' }
        Mock Invoke-ParallelUpdates { throw 'Unattended actions must be sequential' }
    }

    It 'runs safe installs and updates once in order, preserving completion and verification' {
        Invoke-UnattendedActions

        ($script:UnattendedEvents -join ',') | Should Be 'Safe install,Safe update'
        $results.Tools['Safe install'].Installed | Should Be '2.0.0'
        $results.Tools['Safe update'].Installed | Should Be '2.0.0'
        $results.Errors.Count | Should Be 0
        Assert-MockCalled Refresh-ToolVersion 2 -Exactly -Scope It
        Assert-MockCalled Get-AvailableActions 1 -Exactly -Scope It
        Assert-MockCalled Invoke-ActionMenu 0 -Scope It
        Assert-MockCalled Invoke-ParallelUpdates 0 -Scope It
        Assert-MockCalled Write-Host 1 -Scope It -ParameterFilter {
            $Object -eq '1/2: Installing Safe install: synthetic install'
        }
        Assert-MockCalled Write-Host 1 -Scope It -ParameterFilter {
            $Object -eq '2/2: Updating Safe update: synthetic update'
        }
    }

    It 'reports every excluded operation without executing it' {
        Mock Write-Warning {}
        Invoke-UnattendedActions

        foreach ($name in @('Interactive', 'Unknown')) {
            Assert-MockCalled Write-Warning 1 -Scope It -ParameterFilter { $Text -eq "Skipped ${name}: may require interaction." }
        }
        foreach ($name in @('Registry', 'Cleanup')) {
            Assert-MockCalled Write-Warning 1 -Scope It -ParameterFilter { $Text -eq "Skipped ${name}: requires explicit approval." }
        }
        Assert-MockCalled Write-Warning 1 -Scope It -ParameterFilter { $Text -like 'Skipped Unsupported: no command configured for *' }
        Assert-MockCalled Invoke-ActionCommand 2 -Exactly -Scope It
    }

    It 'does not retry a failed <Kind> and still attempts the other safe action' -TestCases @(
        @{ Kind = 'install'; FailedName = 'Safe install' },
        @{ Kind = 'direct'; FailedName = 'Safe update' }
    ) {
        param($Kind, $FailedName)
        $script:FailedKind = $Kind
        $script:UnattendedActions = @($script:UnattendedActions | Sort-Object { if ($_.Type -eq $Kind) { 0 } else { 1 } })
        Mock Test-CommandExists { $false }
        Mock Invoke-ActionCommand {
            $script:UnattendedEvents.Add($Action.Name)
            @{ ExitCode = if ($Action.Type -eq $script:FailedKind) { 7 } else { 0 } }
        }

        Invoke-UnattendedActions

        $script:UnattendedEvents.Count | Should Be 2
        $script:UnattendedEvents[0] | Should Be $FailedName
        @($script:UnattendedEvents | Where-Object { $_ -eq $FailedName }).Count | Should Be 1
        $results.Errors.Count | Should Be 1
        $results.Errors[0] | Should Match 'Exit code: 7'
    }

    It 'records an executor exception and continues without retrying or prompting' {
        Mock Invoke-ActionCommand {
            $script:UnattendedEvents.Add($Action.Name)
            if ($Action.Type -eq 'install') { throw 'synthetic installer failure' }
            @{ ExitCode = 0 }
        }

        Invoke-UnattendedActions

        ($script:UnattendedEvents -join ',') | Should Be 'Safe install,Safe update'
        $results.UpdateFailed[0] | Should Be 'Safe install'
        $results.Errors[0] | Should Match 'synthetic installer failure'
    }

    It 'returns without a menu when every action is ineligible' {
        $script:UnattendedActions = @($script:UnattendedActions | Select-Object -Skip 2)

        Invoke-UnattendedActions

        Assert-MockCalled Invoke-ActionCommand 0 -Scope It
        Assert-MockCalled Show-ResultsTable 0 -Scope It
        Assert-MockCalled Invoke-ActionMenu 0 -Scope It
    }

    It 'routes Main directly to one unattended pass even when checks recorded errors' {
        $Unattended = $true
        $Force = $false
        $SkipUpdate = $false
        Mock Assert-ToolConfigurations {}
        Mock Show-StartupInformation {}
        Mock Test-IsAdministrator { $false }
        Mock Invoke-CheckWorkflow { $results.Errors += 'synthetic check failure' }

        Main

        Assert-MockCalled Invoke-CheckWorkflow 1 -Exactly -Scope It
        Assert-MockCalled Get-AvailableActions 1 -Exactly -Scope It
        ($script:UnattendedEvents -join ',') | Should Be 'Safe install,Safe update'
        Assert-MockCalled Invoke-ActionMenu 0 -Scope It
    }
}

Describe 'Post-install inventory' {
    BeforeEach {
        $results = New-ToolCheckResults
        $SkipUpdate = $false
    }

    It 'adds only the Windows PATH directory that makes the installed command available' {
        $originalPath = $env:Path
        try {
            $env:Path = 'C:\existing;C:\TOOLS\'
            function Test-CommandExists {
                param([string]$Command)
                $Command -eq 'example' -and $env:Path -match '(?i);C:\\new-tools$'
            }

            Add-InstalledCommandPath -Command 'example' -Paths @('c:\tools;C:\unrelated;C:\new-tools;C:\later') | Should Be $true
            $env:Path | Should Be 'C:\existing;C:\TOOLS\;C:\new-tools'
        } finally {
            $env:Path = $originalPath
        }
    }

    It 'leaves the process PATH unchanged when no persisted directory contains the command' {
        $originalPath = $env:Path
        try {
            $env:Path = 'C:\existing'
            function Test-CommandExists { $false }

            Add-InstalledCommandPath -Command 'example' -Paths @('C:\unrelated;C:\another') | Should Be $false
            $env:Path | Should Be 'C:\existing'
        } finally {
            $env:Path = $originalPath
        }
    }

    It 'restores the process PATH if command discovery throws' {
        $originalPath = $env:Path
        try {
            $env:Path = 'C:\existing'
            function Test-CommandExists { throw 'synthetic discovery failure' }

            { Add-InstalledCommandPath -Command 'example' -Paths @('C:\new-tools') } | Should Throw 'synthetic discovery failure'
            $env:Path | Should Be 'C:\existing'
        } finally {
            $env:Path = $originalPath
        }
    }

    It 'shows the detected version in the table immediately after an install action' {
        $results.NotInstalled = @([pscustomobject]@{
            Name = 'Dapr CLI'; ToolId = 'dapr-cli'
            InstallCommands = @{ $script:PlatformKey = 'synthetic install' }
        })
        $script:PostInstallCommandFound = $false
        $script:PostInstallResponses = [System.Collections.Generic.Queue[string]]::new()
        foreach ($response in @('1', '0')) { $script:PostInstallResponses.Enqueue($response) }
        function Read-ActionMenuResponse { $script:PostInstallResponses.Dequeue() }
        function Invoke-ActionCommand { @{ Output = 'synthetic install'; ExitCode = 0 } }
        function Test-IsWindowsPlatform { $true }
        function Test-CommandExists { $script:PostInstallCommandFound }
        function Add-InstalledCommandPath { $script:PostInstallCommandFound = $true; $true }
        function Get-CommandVersion { 'CLI version: 1.19.1' }

        $rendered = @(Invoke-ActionMenu 6>&1) -join "`n"

        $rendered | Should Match 'Dapr CLI\s+1\.19\.1'
        $rendered | Should Match 'To use Dapr CLI in other terminals, you may need to update PATH or restart your terminal'
        $results.Tools['Dapr CLI'].Installed | Should Be '1.19.1'
        $results.Tools['Dapr CLI'].ToolId | Should Be 'dapr-cli'
        $results.NotInstalled.Count | Should Be 0
    }

    It 'reports restart guidance when a configured installer cannot yet be verified' {
        $results.NotInstalled = @([pscustomobject]@{ Name = 'Dapr CLI'; ToolId = 'dapr-cli' })
        function Test-IsWindowsPlatform { $true }
        function Test-CommandExists { $false }
        function Add-InstalledCommandPath { $false }
        $action = @{ Name = 'Dapr CLI'; ToolId = 'dapr-cli'; Command = 'synthetic install'; Type = 'install' }

        $messages = @(Complete-InstallExecution -Action $action -Execution @{ ExitCode = 0 } 6>&1) -join "`n"

        $messages | Should Match 'Command could not be verified yet for Dapr CLI.*check PATH or restart your terminal'
        @($messages -split "`n" | Where-Object { $_ -match 'restart' }).Count | Should Be 1
        $results.Tools['Dapr CLI'].Installed | Should Be 'unknown'
    }

    It 'uses the cross-platform restart hint after a Linux install' {
        $results.NotInstalled = @([pscustomobject]@{ Name = 'Deno'; ToolId = 'deno' })
        function Test-IsWindowsPlatform { $false }
        function Test-CommandExists { $true }
        function Get-CommandVersion { 'deno 2.0.0' }
        $action = @{ Name = 'Deno'; ToolId = 'deno'; Command = 'synthetic install'; Type = 'install' }

        $messages = @(Complete-InstallExecution -Action $action -Execution @{ ExitCode = 0 } 6>&1) -join "`n"

        $messages | Should Match 'To use Deno in other terminals, you may need to update PATH or restart your terminal'
    }

    It 'does not show the Windows-only restart hint after a verified Linux install' {
        $results.NotInstalled = @([pscustomobject]@{ Name = 'Dapr CLI'; ToolId = 'dapr-cli' })
        function Test-IsWindowsPlatform { $false }
        function Test-CommandExists { $true }
        function Get-CommandVersion { 'CLI version: 1.19.1' }
        $action = @{ Name = 'Dapr CLI'; ToolId = 'dapr-cli'; Command = 'synthetic install'; Type = 'install' }

        $messages = @(Complete-InstallExecution -Action $action -Execution @{ ExitCode = 0 } 6>&1) -join "`n"

        $messages | Should Not Match 'restart your terminal'
    }

    It 'honors an explicit false Windows restart override' {
        $originalConfig = $toolsConfig['Dapr CLI']
        $toolsConfig['Dapr CLI'] = $originalConfig.Clone()
        $toolsConfig['Dapr CLI'].InstallMayRequireTerminalRestart = $true
        $toolsConfig['Dapr CLI'].WindowsInstallMayRequireTerminalRestart = $false
        try {
            $results.NotInstalled = @([pscustomobject]@{ Name = 'Dapr CLI'; ToolId = 'dapr-cli' })
            function Test-IsWindowsPlatform { $true }
            function Test-CommandExists { $true }
            function Get-CommandVersion { 'CLI version: 1.19.1' }
            $action = @{ Name = 'Dapr CLI'; ToolId = 'dapr-cli'; Command = 'synthetic install'; Type = 'install' }

            $messages = @(Complete-InstallExecution -Action $action -Execution @{ ExitCode = 0 } 6>&1) -join "`n"

            $messages | Should Not Match 'restart your terminal'
        } finally {
            $toolsConfig['Dapr CLI'] = $originalConfig
        }
    }

    It 'shows an unknown version and warns when the installed command cannot be verified' {
        $results.NotInstalled = @([pscustomobject]@{ Name = 'Dapr CLI'; ToolId = 'dapr-cli' })
        function Test-IsWindowsPlatform { $false }
        function Test-CommandExists { $false }
        $action = @{ Name = 'Dapr CLI'; ToolId = 'dapr-cli'; Command = 'synthetic install'; Type = 'install' }

        $messages = @(Complete-InstallExecution -Action $action -Execution @{ ExitCode = 0 } 6>&1) -join "`n"
        $rendered = @(Show-ResultsTable 6>&1) -join "`n"

        $messages | Should Match 'Command could not be verified yet for Dapr CLI'
        $results.Tools['Dapr CLI'].Installed | Should Be 'unknown'
        $rendered | Should Match 'Dapr CLI\s+unknown'
        $results.NotInstalled.Count | Should Be 0
    }

    It 'warns and keeps the version unknown when the command output cannot be parsed' {
        $results.NotInstalled = @([pscustomobject]@{ Name = 'Dapr CLI'; ToolId = 'dapr-cli' })
        function Test-CommandExists { $true }
        function Get-CommandVersion { 'not a Dapr version' }
        $action = @{ Name = 'Dapr CLI'; ToolId = 'dapr-cli'; Command = 'synthetic install'; Type = 'install' }

        $messages = @(Complete-InstallExecution -Action $action -Execution @{ ExitCode = 0 } 6>&1) -join "`n"

        $messages | Should Match 'Installed version could not be determined for Dapr CLI'
        $results.Tools['Dapr CLI'].Installed | Should Be 'unknown'
    }

    It 'reports an unknown Node.js version after installation when the command fails' {
        $results.NotInstalled = @([pscustomobject]@{ Name = 'NodeJS'; ToolId = 'nodejs' })
        function Test-CommandExists { $true }
        function Get-CommandVersion { 'Unable to retrieve version' }
        $action = @{ Name = 'NodeJS'; ToolId = 'nodejs'; Command = 'synthetic install'; Type = 'install' }

        $messages = @(Complete-InstallExecution -Action $action -Execution @{ ExitCode = 0 } 6>&1) -join "`n"

        $messages | Should Match 'Installed version could not be determined for NodeJS'
        $results.Tools.NodeJS.Installed | Should Be 'unknown'
    }

    It 'does not create an installed row after a failed and unverified install' {
        $results.NotInstalled = @([pscustomobject]@{ Name = 'Dapr CLI'; ToolId = 'dapr-cli' })
        function Test-CommandExists { $false }
        $action = @{ Name = 'Dapr CLI'; ToolId = 'dapr-cli'; Command = 'synthetic install'; Type = 'install' }

        $messages = @(Complete-InstallExecution -Action $action -Execution @{ ExitCode = 1 } 6>&1)

        $messages[-1] | Should Be $false
        ($messages -join "`n") | Should Not Match 'restart your terminal'
        $results.Tools.ContainsKey('Dapr CLI') | Should Be $false
        $results.NotInstalled.Count | Should Be 1
        $results.Errors.Count | Should Be 1
    }

    It 'uses the custom package inventory rather than the runtime version after installation' {
        $results.NotInstalled = @([pscustomobject]@{ Name = 'Python Install Manager (py)'; ToolId = 'python-install-manager' })
        function Test-IsWindowsPlatform { $true }
        function Test-CommandExists { $true }
        function Get-AppxPackage { [pscustomobject]@{ Version = [version]'26.4.240.0' } }
        function Get-CommandVersion { throw 'The Python runtime is not the install-manager package' }
        $action = @{ Name = 'Python Install Manager (py)'; ToolId = 'python-install-manager'; Command = 'synthetic install'; Type = 'install' }

        Complete-InstallExecution -Action $action -Execution @{ ExitCode = 0 } | Should Be $true

        $results.Tools['Python Install Manager (py)'].Installed | Should Be '26.4.240.0'
        $SkipUpdate | Should Be $false
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'keeps custom multi-version inventory without an extra placeholder row' {
        $results.NotInstalled = @([pscustomobject]@{ Name = 'Python'; ToolId = 'python' })
        function Test-CommandExists { param([string]$Command) $Command -eq 'py' }
        function py { $global:LASTEXITCODE = 0; '3.14 * Python 3.14.2' }
        $action = @{ Name = 'Python'; ToolId = 'python'; Command = 'synthetic install'; Type = 'install' }

        Complete-InstallExecution -Action $action -Execution @{ ExitCode = 0 } | Should Be $true

        $results.Tools.ContainsKey('Python') | Should Be $false
        $results.Tools['Python 3.14'].Installed | Should Be '3.14.2'
        $results.Tools['Python 3.14'].ToolId | Should Be 'python'
        $SkipUpdate | Should Be $false
    }

    It 'initializes all .NET SDK rows without checking releases after installation' {
        $results.NotInstalled = @([pscustomobject]@{ Name = '.NET SDK'; ToolId = 'dotnet-sdk' })
        function Test-CommandExists { $true }
        function dotnet { '8.0.301 [C:\synthetic]'; '9.0.102 [C:\synthetic]' }
        function Invoke-SafeApiRequest { throw 'Post-install inventory must not check releases' }
        $action = @{ Name = '.NET SDK'; ToolId = 'dotnet-sdk'; Command = 'synthetic install'; Type = 'install' }

        Complete-InstallExecution -Action $action -Execution @{ ExitCode = 0 } | Should Be $true

        $results.Tools.ContainsKey('.NET SDK') | Should Be $false
        $results.Tools['.NET SDK 8.0.301'].Installed | Should Be '8.0.301'
        $results.Tools['.NET SDK 9.0.102'].Installed | Should Be '9.0.102'
        $results.AvailableUpdates.Count | Should Be 0
        $SkipUpdate | Should Be $false
    }

    It 'preserves previously checked release information for an existing custom-tool row' {
        $results.NotInstalled = @([pscustomobject]@{ Name = 'NodeJS'; ToolId = 'nodejs' })
        $results.Tools.NodeJS = @{
            ToolId = 'nodejs'; Installed = 'v1.0.0'; Latest = 'v2.0.0'
            LatestCooldown = 'v2.0.0'; LatestReleased = 'v2.1.0'; AgeDays = 10
        }
        function Test-CommandExists { $true }
        function Get-CommandVersion { 'v2.0.0' }
        $action = @{ Name = 'NodeJS'; ToolId = 'nodejs'; Command = 'synthetic install'; Type = 'install' }

        Complete-InstallExecution -Action $action -Execution @{ ExitCode = 0 } | Should Be $true

        $results.Tools.NodeJS.Latest | Should Be 'v2.0.0'
        $results.Tools.NodeJS.LatestCooldown | Should Be 'v2.0.0'
        $results.Tools.NodeJS.LatestReleased | Should Be 'v2.1.0'
        $results.Tools.NodeJS.AgeDays | Should Be 10
    }
}

Describe 'Action execution' {
    BeforeEach {
        $results.UpdateFailed = @()
        $results.Errors = @()
    }

    It 'records a repeated update failure once while keeping each message' {
        Register-UpdateFailure -Name 'Example CLI' -Message 'first failure'
        Register-UpdateFailure -Name 'Example CLI' -Message 'second failure'

        $results.UpdateFailed.Count | Should Be 1
        $results.Errors.Count | Should Be 2
    }

    It 'dispatches ordinary actions through the tool command runner' {
        Mock Invoke-ToolCommand { @{ Output = 'done'; ExitCode = 0 } }
        $action = @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct' }

        $execution = Invoke-ActionCommand -Action $action

        $execution.ExitCode | Should Be 0
        Assert-MockCalled Invoke-ToolCommand 1 -ParameterFilter { $Command -eq 'example update' -and $Type -eq 'direct' }
    }

    It 'dispatches direct Node updates through the verified installer' {
        Mock Invoke-ToolEntryPoint { @{ Output = 'done'; ExitCode = 0 } }
        $action = @{ Name = 'NodeJS'; ToolId = 'nodejs'; Command = 'Node.js MSI'; Type = 'node-direct'; Executor = 'tool'; EntryPoint = 'Invoke-ToolUpdate'; Arguments = @{ Version = '26.8.1' }; ExecutionMode = 'CurrentSession' }

        $execution = Invoke-ActionCommand -Action $action

        $execution.ExitCode | Should Be 0
        Assert-MockCalled Invoke-ToolEntryPoint 1 -ParameterFilter { $ToolId -eq 'nodejs' -and $EntryPoint -eq 'Invoke-ToolUpdate' -and $Arguments.Version -eq '26.8.1' }
    }

    It 'completes a successful update without recording a failure' {
        $action = @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct' }

        Complete-UpdateExecution -Action $action -Execution @{ Output = 'done'; ExitCode = 0 } | Should Be $true
        $results.UpdateFailed.Count | Should Be 0
        $results.Errors.Count | Should Be 0
    }

    It 'fails a Deno update when refresh still reports the previous version' {
        $results.Tools['Deno'] = @{ Installed = '2.9.6'; Latest = '2.9.7' }
        Mock Refresh-ToolVersion { $true }
        $action = @{ Name = 'Deno'; ToolId = 'deno'; Command = 'deno upgrade'; Type = 'direct'; Version = '2.9.7' }

        Complete-UpdateExecution -Action $action -Execution @{ Output = ''; ExitCode = 0 } -Refresh | Should Be $false

        $results.UpdateFailed[0] | Should Be 'Deno'
        $results.Errors[0] | Should Be 'Update verification failed for Deno. Expected at least 2.9.7, but found 2.9.6.'
    }

    It 'completes a versioned update after refresh reaches the planned version' {
        $results.Tools['Deno'] = @{ Installed = '2.9.6'; Latest = '2.9.7' }
        Mock Refresh-ToolVersion { $results.Tools['Deno'].Installed = '2.9.7'; $true }
        $action = @{ Name = 'Deno'; ToolId = 'deno'; Command = 'deno upgrade'; Type = 'direct'; Version = '2.9.7' }

        Complete-UpdateExecution -Action $action -Execution @{ Output = ''; ExitCode = 0 } -Refresh | Should Be $true

        $results.UpdateFailed.Count | Should Be 0
        $results.Errors.Count | Should Be 0
    }

    It 'classifies a WinGet no-update response as a retryable failure' {
        $action = @{ Name = 'Example CLI'; Command = 'winget upgrade Example.CLI'; Type = 'winget'; OutcomePackageManager = 'winget.ps1' }

        Complete-UpdateExecution -Action $action -Execution @{ Output = 'No applicable upgrade found'; ExitCode = 1 } | Should Be $false
        $results.UpdateFailed[0] | Should Be 'Example CLI'
        $results.Errors[0] | Should Match '^Skipped: Example CLI'
    }

    It 'completes an install when its command is verified despite a nonzero package-manager exit' {
        $results.NotInstalled = @(@{ Name = 'Example CLI' })
        $toolsConfig['Example CLI'] = @{ Command = 'example'; RefreshMethod = 'standard' }
        Mock Test-CommandExists { $true }
        Mock Refresh-ToolVersion { $true }
        $action = @{ Name = 'Example CLI'; Command = 'winget install Example.CLI'; Type = 'install' }

        Complete-InstallExecution -Action $action -Execution @{ Output = 'already present'; ExitCode = 1 } | Should Be $true

        $results.NotInstalled.Count | Should Be 0
        Assert-MockCalled Refresh-ToolVersion 1 -ParameterFilter { $ToolName -eq 'Example CLI' }
    }

    It 'keeps an unverifiable no-update install pending and records an error' {
        $results.NotInstalled = @(@{ Name = 'Missing CLI' })
        $toolsConfig['Missing CLI'] = @{ Command = 'missing-cli' }
        Mock Test-CommandExists { $false }
        $action = @{ Name = 'Missing CLI'; Command = 'winget install Missing.CLI'; Type = 'install'; OutcomePackageManager = 'winget.ps1' }

        Complete-InstallExecution -Action $action -Execution @{ Output = 'No applicable upgrade found'; ExitCode = 1 } | Should Be $false

        $results.NotInstalled[0].Name | Should Be 'Missing CLI'
        $results.Errors[0] | Should Match '^Install could not be verified for Missing CLI'
        $toolsConfig.Remove('Missing CLI')
    }

    It 'classifies registry alignment success and failure' {
        $action = @{ Name = 'npm registry'; Command = 'npm config set registry'; Type = 'registry' }

        Complete-RegistryExecution -Action $action -Execution @{ Output = 'aligned'; ExitCode = 0 } | Should Be $true
        Complete-RegistryExecution -Action $action -Execution @{ Output = 'access denied'; ExitCode = 1 } | Should Be $false

        $results.Errors.Count | Should Be 1
        $results.Errors[0] | Should Be 'Registry alignment failed for npm registry. access denied'
    }

    It 'completes an ordinary force-mode update through a background job' {
        $update = @{ Name = 'Synthetic CLI'; Command = "Write-Output 'job completed'"; Type = 'direct' }
        Mock Write-Host {}

        Invoke-ParallelUpdates -Updates @($update)

        $results.UpdateFailed.Count | Should Be 0
        $results.Errors.Count | Should Be 0
        Assert-MockCalled Write-Host 1 -Scope It -ParameterFilter { $Object -eq "Starting Synthetic CLI: Write-Output 'job completed'" }
    }

    It 'records a nonzero background update command as failed' {
        $update = @{ Name = 'Broken CLI'; Command = 'cmd /c exit 7'; Type = 'direct' }

        Invoke-ParallelUpdates -Updates @($update)

        $results.UpdateFailed[0] | Should Be 'Broken CLI'
        $results.Errors[0] | Should Match '^Failed: Broken CLI'
    }

    It 'uses shared dispatch and completion for direct force-mode updates' {
        Mock Write-Host {}
        Mock Invoke-ActionCommand { @{ Output = 'done'; ExitCode = 0 } }
        Mock Complete-UpdateExecution { $true }
        $update = @{ Name = 'NodeJS'; ToolId = 'nodejs'; Command = 'Node.js MSI'; Type = 'node-direct'; Executor = 'tool'; EntryPoint = 'Invoke-ToolUpdate'; Arguments = @{ Version = '26.8.1' }; ExecutionMode = 'CurrentSession' }

        Invoke-ParallelUpdates -Updates @($update)

        Assert-MockCalled Invoke-ActionCommand 1 -ParameterFilter { $Action.Name -eq 'NodeJS' }
        Assert-MockCalled Complete-UpdateExecution 1 -ParameterFilter { $Action.Name -eq 'NodeJS' -and $Execution.ExitCode -eq 0 }
        Assert-MockCalled Write-Host 1 -Scope It -ParameterFilter { $Object -eq 'Starting NodeJS: Node.js MSI' }
    }

    It 'excludes registry and cleanup actions in force mode' {
        $results.AvailableUpdates = @(
            @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct' },
            @{ Name = 'npm registry'; Command = 'npm config set registry'; Type = 'registry' },
            @{ Name = 'Example cleanup'; Command = 'npm uninstall --global example'; Type = 'cleanup' }
        )
        Mock Invoke-ParallelUpdates { }
        Mock Show-ResultsTable { }

        Invoke-ForceUpdates

        Assert-MockCalled Invoke-ParallelUpdates 1 -ParameterFilter {
            $Updates.Count -eq 1 -and $Updates[0].Name -eq 'Example CLI'
        }
    }
}
