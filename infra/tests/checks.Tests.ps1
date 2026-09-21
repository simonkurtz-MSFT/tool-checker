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
        $results.AvailableUpdates[0].Version | Should Be '1.10.0'
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
