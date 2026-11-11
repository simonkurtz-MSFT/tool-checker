# Generic check contracts: latest-version acceptance, update registration, and update
# command resolution against synthetic rows; no external commands or network calls.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) "checks-tests-$([guid]::NewGuid()).env")

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
        $results = New-ToolCheckResults
        $SkipUpdate = $false
    }

    It 'registers a newer version in both update collections' {
        $registered = Register-ToolUpdate -Name 'Example CLI' -InstalledVersion '1.9.0' -LatestVersion '1.10.0' -Command 'example update' -Type 'direct'

        $registered | Should Be $true
        $results.Updates.Count | Should Be 1
        $results.Updates[0] | Should Be 'Example CLI'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Details | Should Be '1.9.0 -> 1.10.0'
        $results.AvailableUpdates[0].Version | Should Be '1.10.0'
    }

    It 'does not mutate update collections when versions are equal' {
        $registered = Register-ToolUpdate -Name 'Example CLI' -InstalledVersion '1.10.0' -LatestVersion '1.10.0' -Command 'example update' -Type 'direct'

        $registered | Should Be $false
        $results.Updates.Count | Should Be 0
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'withholds registration and menu actions for a <Case>' -TestCases @(
        @{ Case = 'young release'; PublishedAt = [DateTimeOffset]::UtcNow.AddDays(-7.999).ToString('O') },
        @{ Case = 'release with an invalid date'; PublishedAt = 'invalid' }
    ) {
        param($Case, $PublishedAt)
        $results.Tools['Example CLI'] = @{ Installed = '1.0.0'; Latest = '' }
        Set-ToolReleaseInformation -ToolName 'Example CLI' -LatestVersion '1.1.0' -PublishedAt $PublishedAt -CooldownDays 8 | Out-Null

        $registered = Register-ToolUpdate -Name 'Example CLI' -InstalledVersion '1.0.0' -LatestVersion '1.1.0' -Command 'example update' -Type 'direct'

        $registered | Should Be $false
        $results.Updates.Count | Should Be 0
        $results.AvailableUpdates.Count | Should Be 0
        @(Get-AvailableActions).Count | Should Be 0
    }

    It 'registers a release once its full cooldown is satisfied' {
        $results.Tools['Example CLI'] = @{ Installed = '1.0.0'; Latest = '' }
        Set-ToolReleaseInformation -ToolName 'Example CLI' -LatestVersion '1.1.0' -PublishedAt ([DateTimeOffset]::UtcNow.AddDays(-8)) -CooldownDays 8 | Out-Null

        Register-ToolUpdate -Name 'Example CLI' -InstalledVersion '1.0.0' -LatestVersion '1.1.0' -Command 'example update' -Type 'direct' | Should Be $true
        @(Get-AvailableActions).Count | Should Be 1
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
        $results.Tools['ncu'] = @{ Installed = '20.0.0'; Latest = '21.0.0'; AgeDays = $script:ReleaseCooldownDays }
        Register-ReleasePlan -ToolName 'ncu' -InstalledVersion '20.0.0' -Plan @{
            Latest = '21.0.0'; Installable = $true; VersionLabel = 'latest version'
            Command = 'npm install -g npm-check-updates@21.0.0 --loglevel=error'; Type = 'npm-global'
        }

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
        Mock Invoke-SafeApiRequest { [PSCustomObject]@{ tag_name = 'v0.46.1'; published_at = '2020-01-01' } }
    }

    It 'pins a self-reported Bicep update to the reported version' {
        Get-StandardToolUpdates `
            -ToolName 'Azure Bicep CLI' `
            -InstalledVersion '0.45.0' `
            -RawOutput 'A new Bicep release is available: v0.46.1' | Out-Null

        $results.Tools['Azure Bicep CLI'].Latest | Should Be '0.46.1'
        $results.Updates[0] | Should Be 'Azure Bicep CLI'
        $results.AvailableUpdates[0].Command | Should Be 'az bicep install --version v0.46.1 --only-show-errors'
    }

    It 'treats self-reported output without an update notice as current' {
        Get-StandardToolUpdates -ToolName 'Azure Bicep CLI' -InstalledVersion '0.45.0' -RawOutput 'Bicep CLI version 0.45.0' | Out-Null

        $results.Tools['Azure Bicep CLI'].Latest | Should Be '0.45.0'
        $results.Updates.Count | Should Be 0
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'applies release dates to a self-reported candidate without substituting a newer API version' {
        Mock Invoke-SafeApiRequest { [PSCustomObject]@{ tag_name = 'v0.46.1'; published_at = [DateTimeOffset]::UtcNow.ToString('O') } }
        Get-StandardToolUpdates -ToolName 'Azure Bicep CLI' -InstalledVersion '0.45.0' -RawOutput 'A new Bicep release is available: v0.46.1'
        $results.Tools['Azure Bicep CLI'].LatestReleased | Should Be '0.46.1'
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'registers an API-reported release through the same path with the checked version' {
        $toolsConfig['Example API CLI'] = @{
            Id = 'example-api'; ApiUrl = 'https://example.invalid/releases'; ProductionReleasesOnly = $true
            UpdateType = 'direct'; UpdateCommand = 'example update {latest}'
        }
        $results.Tools['Example API CLI'] = @{ ToolId = 'example-api'; Installed = '1.1.0'; Latest = '' }
        Mock Invoke-SafeApiRequest { [PSCustomObject]@{ tag_name = 'v1.2.0' } }
        try {
            Get-StandardToolUpdates -ToolName 'Example API CLI' -InstalledVersion '1.1.0' | Out-Null

            $results.Tools['Example API CLI'].Latest | Should Be '1.2.0'
            $results.Updates[0] | Should Be 'Example API CLI'
            $results.AvailableUpdates.Count | Should Be 1
            $results.AvailableUpdates[0].Command | Should Be 'example update 1.2.0'
            $results.AvailableUpdates[0].Version | Should Be '1.2.0'
            (Get-ToolState 'example-api').LatestVersionSource | Should Be 'api'

            $results.Updates = @()
            $results.AvailableUpdates = @()
            Get-StandardToolUpdates -ToolName 'Example API CLI' -InstalledVersion '1.2.0' | Out-Null
            $results.Updates.Count | Should Be 0
            $results.AvailableUpdates.Count | Should Be 0
        } finally {
            $toolsConfig.Remove('Example API CLI')
            $results.ToolState.Remove('example-api')
        }
    }
}

Describe 'Platform configuration' {
    It 'prefers a Windows override only on Windows and falls back to the base property' {
        $config = @{ UpdateCommand = 'base'; WindowsUpdateCommand = 'windows'; InstallExecutor = 'shared' }
        $expected = if (Test-IsWindowsPlatform) { 'windows' } else { 'base' }

        Get-PlatformConfigurationValue -Configuration $config -Property 'UpdateCommand' | Should Be $expected
        Get-PlatformConfigurationValue -Configuration $config -Property 'InstallExecutor' | Should Be 'shared'
        Get-PlatformConfigurationValue -Configuration $config -Property 'Missing' | Should BeNullOrEmpty
    }

    It 'returns no update command for an unknown tool' {
        $results.Tools = @{}
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()

        Get-UpdateCommand -ToolName 'Unknown CLI' -Installed '1.0.0' -Latest '2.0.0' | Should Be ''
    }
}

Describe 'Dated release cooldowns' {
        BeforeEach {
            $results = New-ToolCheckResults
            $results.Tools.Deno = @{ ToolId = 'deno'; Installed = '2.0.0'; Latest = '' }
            $SkipUpdate = $false
            Mock Invoke-SafeApiRequest {
                [PSCustomObject]@{ tag_name = 'v2.1.0'; published_at = $script:CandidatePublishedAt }
            }
        }

        It 'applies the tool cooldown for <Case>' -TestCases @(
            @{ Case = 'a release younger than eight full days'; Age = 7.999; Days = 8; Actions = 0 },
            @{ Case = 'exactly eight full days'; Age = 8; Days = 8; Actions = 1 },
            @{ Case = 'a shorter tool override'; Age = 3; Days = 2; Actions = 1 },
            @{ Case = 'a longer tool override'; Age = 9; Days = 12; Actions = 0 },
            @{ Case = 'zero delay'; Age = 0; Days = 0; Actions = 1 },
            @{ Case = 'a future date even with zero delay'; Age = -1; Days = 0; Actions = 0 }
        ) {
            param($Case, $Age, $Days, $Actions)
            $script:CandidatePublishedAt = [DateTimeOffset]::UtcNow.AddDays(-$Age).ToString('O')
            $toolsConfig.Deno.CooldownDays = $Days
            try {
                Get-StandardToolUpdates -ToolName 'Deno' -InstalledVersion '2.0.0'
                $results.AvailableUpdates.Count | Should Be $Actions
                $results.Tools.Deno.LatestReleased | Should Be '2.1.0'
                $results.Tools.Deno.Installable | Should Be ([bool]$Actions)
                if ($Actions -eq 0) {
                    $results.Tools.Deno.LatestCooldown | Should BeNullOrEmpty
                    $results.MaturityBlockedUpdates[0].RequiredAgeDays | Should Be $Days
                    Get-UpdateCommand -ToolName Deno -Installed '2.0.0' -Latest '2.1.0' | Should Be ''
                } else {
                    $results.Tools.Deno.LatestCooldown | Should Be '2.1.0'
                }
            } finally { $toolsConfig.Deno.CooldownDays = 8 }
        }

        It 'blocks an invalid supplied date instead of offering an unverified update' {
            $script:CandidatePublishedAt = 'invalid'
            Get-StandardToolUpdates -ToolName 'Deno' -InstalledVersion '2.0.0'
            $results.Tools.Deno.Installable | Should Be $false
            $results.AvailableUpdates.Count | Should Be 0
            Get-UpdateCommand -ToolName Deno -Installed '2.0.0' -Latest '2.1.0' | Should Be ''
        }

        It 'preserves existing update behavior for a source without publish dates' {
            $script:CandidatePublishedAt = $null
            Get-StandardToolUpdates -ToolName 'Deno' -InstalledVersion '2.0.0'
            $results.AvailableUpdates.Count | Should Be 1
            $results.Tools.Deno.ContainsKey('LatestCooldown') | Should Be $false
        }

        It 'uses the earliest package upload for the exact checked release' {
            $metadata = '{"releases":{"2.1.0":[{"upload_time_iso_8601":"2020-01-02T00:00:00Z"},{"upload_time_iso_8601":"2020-01-01T00:00:00Z"}]}}' | ConvertFrom-Json
            $publishedAt = Get-ApiReleasePublishedAt -ApiData $metadata -Version '2.1.0' -ToolName Deno
            ([DateTimeOffset]$publishedAt).ToUniversalTime().ToString('yyyy-MM-dd') | Should Be '2020-01-01'
        }

        It 'accepts dates already deserialized by the API client without culture-dependent formatting' {
            $age = Get-ReleaseAgeInfo -PublishedAt ([DateTime]::UtcNow.AddDays(-8)) -CooldownDays 8
            $age.Installable | Should Be $true
        }

        It 'does not use a different upstream versions publish date' {
            $metadata = [PSCustomObject]@{ tag_name = 'v2.2.0'; published_at = '2020-01-01' }
            Get-ApiReleasePublishedAt -ApiData $metadata -Version '2.1.0' -ToolName Deno | Should BeNullOrEmpty
        }
}
