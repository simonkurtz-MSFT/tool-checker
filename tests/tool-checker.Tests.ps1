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
        { Assert-CustomToolConfigurations } | Should Not Throw
    }

    It 'rejects a configured custom checker function that does not exist' {
        $toolsConfig['Broken Custom Tool'] = @{
            CheckType = 'custom'
            CustomFunction = 'Test-MissingCustomTool'
        }
        try {
            { Assert-CustomToolConfigurations } |
                Should Throw "Custom checker 'Test-MissingCustomTool' configured for 'Broken Custom Tool' was not found."
        } finally {
            $toolsConfig.Remove('Broken Custom Tool')
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