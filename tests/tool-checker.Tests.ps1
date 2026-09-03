$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tool-checker.ps1'
. $scriptPath

Describe 'Tool configuration' {
    It 'applies defaults for optional custom-check properties' {
        $toolsConfig['Azure CLI Extensions'].Enabled | Should Be $true
        $toolsConfig['Azure CLI Extensions'].ProductionReleasesOnly | Should Be $true
    }

    It 'returns a configured custom checker with required properties' {
        $config = Get-ToolConfiguration -ToolName 'NodeJS' -RequiredProperties @('CustomFunction', 'Command')

        $config.CustomFunction | Should Be 'Test-NodeJS'
        $config.Command | Should Be 'node'
    }

    It 'rejects an unknown tool' {
        { Get-ToolConfiguration -ToolName 'Missing Tool' } | Should Throw 'Tool configuration not found: Missing Tool'
    }

    It 'rejects a missing required property' {
        { Get-ToolConfiguration -ToolName 'Azure CLI Extensions' -RequiredProperties @('ApiUrl') } |
            Should Throw "Tool 'Azure CLI Extensions' requires configuration property 'ApiUrl'."
    }

    It 'resolves every configured custom checker function' {
        { Assert-ToolConfigurations } | Should Not Throw
    }

    It 'rejects a configured custom checker function that does not exist' {
        $toolsConfig['Broken Custom Tool'] = @{
            Enabled = $true
            CheckType = 'custom'
            CustomFunction = 'Test-MissingCustomTool'
            UpdateType = 'direct'
            UpdateCommand = 'broken update'
        }
        try {
            { Assert-ToolConfigurations } |
                Should Throw "Custom checker 'Test-MissingCustomTool' configured for 'Broken Custom Tool' was not found."
        } finally {
            $toolsConfig.Remove('Broken Custom Tool')
        }
    }

    It 'rejects an unsupported check type during startup validation' {
        $toolsConfig['Broken Tool'] = @{
            Enabled = $true
            CheckType = 'manual'
        }
        try {
            { Assert-ToolConfigurations } |
                Should Throw "Tool 'Broken Tool' has unsupported CheckType 'manual'."
        } finally {
            $toolsConfig.Remove('Broken Tool')
        }
    }

    It 'rejects a standard tool without a version command form' {
        $toolsConfig['Broken Standard Tool'] = @{
            Enabled = $true
            CheckType = 'standard'
            Command = 'broken'
            ApiUrl = 'https://example.invalid/releases'
            UpdateType = 'direct'
            UpdateCommand = 'broken update'
        }
        try {
            { Assert-ToolConfigurations } |
                Should Throw "Standard tool 'Broken Standard Tool' requires either 'VersionFlag' or 'VersionCommand'."
        } finally {
            $toolsConfig.Remove('Broken Standard Tool')
        }
    }
}

Describe 'Version comparison' {
    It 'orders multi-digit semantic version components numerically' {
        Test-UpdateAvailable -InstalledVersion '1.9.0' -LatestVersion '1.10.0' | Should Be $true
    }

    It 'does not report an older version as an update' {
        Test-UpdateAvailable -InstalledVersion '2.0.0' -LatestVersion '1.10.0' | Should Be $false
    }

    It 'normalizes numeric revision suffixes' {
        ConvertTo-CanonicalSemanticVersion '1.0.83-3' | Should Be '1.0.83.3'
    }

    It 'treats an optional fourth zero component as a production release' {
        Test-IsProductionVersion '26.3.240.0' | Should Be $true
    }
}

Describe 'Latest version acceptance' {
    BeforeEach {
        $results.Tools = @{
            'Example CLI' = @{ Installed = '1.0.0'; Latest = '' }
            'Example CLI Core' = @{ Installed = '1.0.0'; Latest = '' }
        }
    }

    It 'assigns an accepted production version to every requested tool row' {
        $accepted = Set-LatestToolVersion -ToolNames @('Example CLI', 'Example CLI Core') -LatestVersion '1.1.0'

        $accepted | Should Be $true
        $results.Tools['Example CLI'].Latest | Should Be '1.1.0'
        $results.Tools['Example CLI Core'].Latest | Should Be '1.1.0'
    }

    It 'rejects a missing candidate without changing tool state' {
        $accepted = Set-LatestToolVersion -ToolNames 'Example CLI' -LatestVersion $null

        $accepted | Should Be $false
        $results.Tools['Example CLI'].Latest | Should Be ''
    }

    It 'rejects a prerelease without changing tool state' {
        $accepted = Set-LatestToolVersion -ToolNames 'Example CLI' -LatestVersion '1.1.0-preview.1'

        $accepted | Should Be $false
        $results.Tools['Example CLI'].Latest | Should Be ''
    }

    It 'accepts a prerelease when production-only filtering is disabled' {
        $accepted = Set-LatestToolVersion -ToolNames 'Example CLI' -LatestVersion '1.1.0-preview.1' -ProductionReleasesOnly $false

        $accepted | Should Be $true
        $results.Tools['Example CLI'].Latest | Should Be '1.1.0-preview.1'
    }
}

Describe 'Available update construction' {
    BeforeEach {
        $results.AvailableUpdates = @()
    }

    It 'adds the common update fields without emitting output' {
        $output = Add-AvailableUpdate -Name 'Example CLI' -Command 'example update' -Type 'direct' -Details '1.0.0 -> 1.1.0'

        $output | Should BeNullOrEmpty
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Name | Should Be 'Example CLI'
        $results.AvailableUpdates[0].Command | Should Be 'example update'
        $results.AvailableUpdates[0].Type | Should Be 'direct'
        $results.AvailableUpdates[0].Details | Should Be '1.0.0 -> 1.1.0'
    }

    It 'preserves registry and direct-installer metadata' {
        Add-AvailableUpdate -Name 'npm registry' -Command '' -Type 'registry' -RegistryKey 'npm'
        Add-AvailableUpdate -Name 'NodeJS' -Command 'Node.js MSI' -Type 'node-direct' -Version '26.8.1'

        $results.AvailableUpdates[0].RegistryKey | Should Be 'npm'
        $results.AvailableUpdates[1].Version | Should Be '26.8.1'
    }
}

Describe 'Tool update registration' {
    BeforeEach {
        $results.Updates = @()
        $results.AvailableUpdates = @()
    }

    It 'registers a newer version in both update collections' {
        $registered = Register-ToolUpdate -Name 'Example CLI' -InstalledVersion '1.9.0' -LatestVersion '1.10.0' -Command 'example update' -Type 'direct'

        $registered | Should Be $true
        $results.Updates.Count | Should Be 1
        $results.Updates[0] | Should Be 'Example CLI'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Details | Should Be '1.9.0 -> 1.10.0'
    }

    It 'does not mutate update collections when versions are equal' {
        $registered = Register-ToolUpdate -Name 'Example CLI' -InstalledVersion '1.10.0' -LatestVersion '1.10.0' -Command 'example update' -Type 'direct'

        $registered | Should Be $false
        $results.Updates.Count | Should Be 0
        $results.AvailableUpdates.Count | Should Be 0
    }
}

Describe 'Update command resolution' {
    BeforeEach {
        $results.Tools = @{}
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
    }

    It 'returns the configured command for a standard tool' {
        $results.Tools['Deno'] = @{ Installed = '2.0.0'; Latest = '2.1.0' }

        Get-UpdateCommand -ToolName 'Deno' -Installed '2.0.0' -Latest '2.1.0' |
            Should Be $toolsConfig['Deno'].UpdateCommand
    }

    It 'pins an npm update to the checked version' {
        $results.Tools['ncu'] = @{ Installed = '20.0.0'; Latest = '21.0.0'; AgeDays = $script:NpmUpdateCooldownDays }

        Get-UpdateCommand -ToolName 'ncu' -Installed '20.0.0' -Latest '21.0.0' |
            Should Be 'npm install -g npm-check-updates@21.0.0 --loglevel=error'
    }

    It 'uses the platform-specific uv update command' {
        $results.Tools['uv'] = @{ Installed = '0.8.0'; Latest = '0.9.0' }
        $expected = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            'winget install --id astral-sh.uv -e --source winget --silent --disable-interactivity --force'
        } else {
            $toolsConfig['uv'].UpdateCommand
        }

        Get-UpdateCommand -ToolName 'uv' -Installed '0.8.0' -Latest '0.9.0' | Should Be $expected
    }
}

Describe 'Standard tool update flow' {
    BeforeEach {
        $results.Tools = @{
            'Azure Bicep CLI' = @{ Installed = '0.45.0'; Latest = '' }
        }
        $results.Updates = @()
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
    }

    It 'registers a self-reported update with its configured command' {
        Get-StandardToolUpdates `
            -ToolName 'Azure Bicep CLI' `
            -InstalledVersion '0.45.0' `
            -RawOutput 'A new Bicep release is available: v0.46.1' | Out-Null

        $results.Tools['Azure Bicep CLI'].Latest | Should Be '0.46.1'
        $results.Updates[0] | Should Be 'Azure Bicep CLI'
        $results.AvailableUpdates[0].Command | Should Be $toolsConfig['Azure Bicep CLI'].UpdateCommand
    }
}

Describe 'Node release planning' {
    It 'filters prereleases and classifies the latest patch in the installed major' {
        $distributionIndex = @(
            [PSCustomObject]@{ version = 'v27.0.0-rc.1'; lts = $false },
            [PSCustomObject]@{ version = 'v26.2.0'; lts = $false },
            [PSCustomObject]@{ version = 'v24.12.1'; lts = 'Krypton' },
            [PSCustomObject]@{ version = 'v22.5.1'; lts = 'Jod' }
        )

        $plan = Get-NodeReleasePlan -DistributionIndex $distributionIndex -CurrentVersion '22.5.0'

        $plan.LatestCurrentVersion | Should Be '26.2.0'
        $plan.LatestLTSVersion | Should Be '24.12.1'
        $plan.LatestInMajor | Should Be '22.5.1'
        $plan.UpdateKind | Should Be 'patch'
    }

    It 'classifies a newer minor in the installed major' {
        $distributionIndex = @(
            [PSCustomObject]@{ version = 'v22.6.0'; lts = 'Jod' },
            [PSCustomObject]@{ version = 'v22.5.9'; lts = 'Jod' }
        )

        $plan = Get-NodeReleasePlan -DistributionIndex $distributionIndex -CurrentVersion '22.5.0'

        $plan.UpdateKind | Should Be 'minor'
    }
}

Describe 'Global npm output parsing' {
    It 'parses scoped update rows and normalizes the bulk install command' {
        $output = @(
            '@scope/example  1.2.0  →  1.3.0',
            'plain-package  2.0.0  →  2.1.0',
            'npm -g install @scope/example@1.3.0 plain-package@2.1.0'
        )

        $parsed = ConvertFrom-NcuGlobalOutput -OutputLines $output

        $parsed.Packages.Count | Should Be 2
        $parsed.Packages[0].Name | Should Be '@scope/example'
        $parsed.Packages[1].Latest | Should Be '2.1.0'
        $parsed.InstallCommand | Should Be 'npm -g install @scope/example@1.3.0 plain-package@2.1.0 --loglevel=error'
    }
}

Describe '.NET SDK release planning' {
    It 'groups installed SDKs and returns newer supported production majors' {
        $index = [PSCustomObject]@{ 'releases-index' = @(
            [PSCustomObject]@{ 'channel-version' = '10.0'; 'latest-sdk' = '10.0.101'; 'support-phase' = 'active' },
            [PSCustomObject]@{ 'channel-version' = '11.0'; 'latest-sdk' = '11.0.100-preview.2'; 'support-phase' = 'preview' },
            [PSCustomObject]@{ 'channel-version' = '9.0'; 'latest-sdk' = '9.0.203'; 'support-phase' = 'active' },
            [PSCustomObject]@{ 'channel-version' = '8.0'; 'latest-sdk' = '8.0.410'; 'support-phase' = 'active' },
            [PSCustomObject]@{ 'channel-version' = '7.0'; 'latest-sdk' = '7.0.410'; 'support-phase' = 'eol' }
        ) }

        $plan = Get-DotNetSDKReleasePlan -InstalledVersions @('8.0.100', '8.0.301', '9.0.100') -ReleasesIndex $index

        $plan.ByMajor['8'].Count | Should Be 2
        $plan.LatestSdkByChannel['9.0'].LatestSdk | Should Be '9.0.203'
        $plan.LatestSdkByChannel.ContainsKey('11.0') | Should Be $false
        $plan.NewerMajors.Count | Should Be 1
        $plan.NewerMajors[0] | Should Be 10
    }

    It 'allows an installed preview channel when prereleases are enabled' {
        $index = [PSCustomObject]@{ 'releases-index' = @(
            [PSCustomObject]@{ 'channel-version' = '11.0'; 'latest-sdk' = '11.0.100-preview.2'; 'support-phase' = 'preview' },
            [PSCustomObject]@{ 'channel-version' = '10.0'; 'latest-sdk' = '10.0.101'; 'support-phase' = 'active' }
        ) }

        $plan = Get-DotNetSDKReleasePlan -InstalledVersions @('11.0.100-preview.1') -ReleasesIndex $index -ProductionReleasesOnly $false

        $plan.LatestSdkByChannel.ContainsKey('11.0') | Should Be $true
        $plan.NewerMajors.Count | Should Be 0
    }
}

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
}

Describe 'Action execution' {
    BeforeEach {
        $results.UpdateFailed = @()
        $results.Errors = @()
    }

    It 'dispatches ordinary actions through the tool command runner' {
        Mock Invoke-ToolCommand { @{ Output = 'done'; ExitCode = 0 } }
        $action = @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct' }

        $execution = Invoke-ActionCommand -Action $action

        $execution.ExitCode | Should Be 0
        Assert-MockCalled Invoke-ToolCommand 1 -ParameterFilter { $Command -eq 'example update' -and $Type -eq 'direct' }
    }

    It 'dispatches direct Node updates through the verified installer' {
        Mock Invoke-NodeWindowsUpdate { @{ Output = 'done'; ExitCode = 0 } }
        $action = @{ Name = 'NodeJS'; Command = 'Node.js MSI'; Type = 'node-direct'; Version = '26.8.1' }

        $execution = Invoke-ActionCommand -Action $action

        $execution.ExitCode | Should Be 0
        Assert-MockCalled Invoke-NodeWindowsUpdate 1 -ParameterFilter { $Version -eq '26.8.1' }
    }

    It 'completes a successful update without recording a failure' {
        $action = @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct' }

        Complete-UpdateExecution -Action $action -Execution @{ Output = 'done'; ExitCode = 0 } | Should Be $true
        $results.UpdateFailed.Count | Should Be 0
        $results.Errors.Count | Should Be 0
    }

    It 'classifies a WinGet no-update response as a retryable failure' {
        $action = @{ Name = 'Example CLI'; Command = 'winget upgrade Example.CLI'; Type = 'winget' }

        Complete-UpdateExecution -Action $action -Execution @{ Output = 'No applicable upgrade found'; ExitCode = 1 } | Should Be $false
        $results.UpdateFailed[0] | Should Be 'Example CLI'
        $results.Errors[0] | Should Match '^Skipped: Example CLI'
    }

    It 'completes an ordinary force-mode update through a background job' {
        $update = @{ Name = 'Synthetic CLI'; Command = "Write-Output 'job completed'"; Type = 'direct' }

        Invoke-ParallelUpdates -Updates @($update)

        $results.UpdateFailed.Count | Should Be 0
        $results.Errors.Count | Should Be 0
    }

    It 'records a nonzero background update command as failed' {
        $update = @{ Name = 'Broken CLI'; Command = 'cmd /c exit 7'; Type = 'direct' }

        Invoke-ParallelUpdates -Updates @($update)

        $results.UpdateFailed[0] | Should Be 'Broken CLI'
        $results.Errors[0] | Should Match '^Failed: Broken CLI'
    }

    It 'uses shared dispatch and completion for direct force-mode updates' {
        Mock Invoke-ActionCommand { @{ Output = 'done'; ExitCode = 0 } }
        Mock Complete-UpdateExecution { $true }
        $update = @{ Name = 'NodeJS'; Command = 'Node.js MSI'; Type = 'node-direct'; Version = '26.8.1' }

        Invoke-ParallelUpdates -Updates @($update)

        Assert-MockCalled Invoke-ActionCommand 1 -ParameterFilter { $Action.Name -eq 'NodeJS' }
        Assert-MockCalled Complete-UpdateExecution 1 -ParameterFilter { $Action.Name -eq 'NodeJS' -and $Execution.ExitCode -eq 0 }
    }

    It 'excludes registry actions and refreshes successful automatic updates in force mode' {
        $results.AvailableUpdates = @(
            @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct' },
            @{ Name = 'npm registry'; Command = 'npm config set registry'; Type = 'registry' }
        )
        Mock Invoke-ParallelUpdates { }
        Mock Refresh-ToolVersion { $true }
        Mock Show-ResultsTable { }

        Invoke-ForceUpdates

        Assert-MockCalled Invoke-ParallelUpdates 1 -ParameterFilter {
            $Updates.Count -eq 1 -and $Updates[0].Name -eq 'Example CLI'
        }
        Assert-MockCalled Refresh-ToolVersion 1 -ParameterFilter { $ToolName -eq 'Example CLI' }
        Assert-MockCalled Refresh-ToolVersion 0 -ParameterFilter { $ToolName -eq 'npm registry' }
    }
}

Describe 'Parallel check orchestration' {
    It 'rehydrates configured checker dependencies without including the main entry point' {
        $scriptContent = Get-Content $scriptPath -Raw

        $functionBlock = Get-ParallelCheckFunctionBlock -ScriptContent $scriptContent -ToolsConfiguration $toolsConfig

        $functionBlock | Should Match 'function Test-NodeJS'
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
        $results.DotNetSDKs = @{}
        $results.NotInstalled = @()
        $results.Updates = @()
        $results.Errors = @()
        $results.UpdateFailed = @()
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
        $results.GlobalNpmPackageUpdates = @()
        $results.GlobalNpmUpdateCommand = 'ncu -g -u --loglevel=error'
        $checkResult = @{
            Output = @()
            Tools = @{ 'Example CLI' = @{ Installed = '1.0.0'; Latest = '1.1.0' } }
            DotNetSDKs = @{ '10.0.100' = @{ Major = '10' } }
            NotInstalled = @('Missing CLI')
            Updates = @('Example CLI')
            Errors = @()
            UpdateFailed = @()
            AvailableUpdates = @(@{ Name = 'Example CLI' })
            MaturityBlockedUpdates = @()
            GlobalNpmPackageUpdates = @()
            GlobalNpmUpdateCommand = 'npm update command'
        }

        Merge-ParallelCheckResult -CheckResult $checkResult

        $results.Tools['Example CLI'].Installed | Should Be '1.0.0'
        $results.DotNetSDKs.ContainsKey('10.0.100') | Should Be $true
        $results.Updates[0] | Should Be 'Example CLI'
        $results.AvailableUpdates[0].Name | Should Be 'Example CLI'
        $results.GlobalNpmUpdateCommand | Should Be 'npm update command'
    }

    It 'runs and merges a network-free check through the runspace pool' {
        $results.Tools = @{}
        $results.DotNetSDKs = @{}
        $results.NotInstalled = @()
        $results.Updates = @()
        $results.Errors = @()
        $results.UpdateFailed = @()
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
        $results.GlobalNpmPackageUpdates = @()
        $results.GlobalNpmUpdateCommand = 'ncu -g -u --loglevel=error'
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

Describe 'npm release selection' {
    It 'selects the newest production version when latest points to a prerelease' {
        $apiData = [PSCustomObject]@{
            versions = [PSCustomObject]@{
                '2.0.0-beta.1' = @{}
                '1.10.0' = @{}
                '1.9.0' = @{}
            }
        }

        Get-LatestProductionNpmVersion -ApiData $apiData | Should Be '1.10.0'
    }

    It 'selects the newest release that has completed the cooldown' {
        $apiData = [PSCustomObject]@{
            versions = [PSCustomObject]@{
                '1.2.0' = @{}
                '1.1.0' = @{}
                '1.0.0' = @{}
            }
            time = [PSCustomObject]@{
                '1.2.0' = [DateTimeOffset]::UtcNow.AddDays(-2).ToString('O')
                '1.1.0' = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('O')
                '1.0.0' = [DateTimeOffset]::UtcNow.AddDays(-30).ToString('O')
            }
        }

        $release = Get-LatestMatureNpmRelease -ApiData $apiData -MinimumVersion '1.0.0' -MaximumVersion '1.2.0'

        $release.Version | Should Be '1.1.0'
        $release.Installable | Should Be $true
    }
}