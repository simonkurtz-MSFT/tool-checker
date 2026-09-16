# npm release selection contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-npm-tests-absent.env')

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

    It 'requires eight full days before a release completes the cooldown' {
        $script:ReleaseCooldownDays | Should Be 8
        $apiData = [PSCustomObject]@{
            versions = [PSCustomObject]@{
                '1.2.0' = @{}
                '1.1.0' = @{}
                '1.0.0' = @{}
            }
            time = [PSCustomObject]@{
                '1.2.0' = [DateTimeOffset]::UtcNow.AddDays(-7.5).ToString('O')
                '1.1.0' = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('O')
                '1.0.0' = [DateTimeOffset]::UtcNow.AddDays(-30).ToString('O')
            }
        }

        $release = Get-LatestMatureNpmRelease -ApiData $apiData -MinimumVersion '1.0.0' -MaximumVersion '1.2.0'

        $release.Version | Should Be '1.1.0'
        $release.Installable | Should Be $true
    }
}

Describe 'npm installed version refresh' {
    BeforeEach {
        $results = New-ToolCheckResults
        Mock Get-GlobalNpmInstalledVersion { '1.0.84-2' }
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { 'GitHub Copilot CLI 1.0.83-3.' }
    }

    It 'uses the package revision instead of the CLI banner during discovery' {
        Get-InstalledVersionFromOutput -ToolName 'GitHub Copilot CLI' -Output 'GitHub Copilot CLI 1.0.83-3.' | Should Be '1.0.84-2'
        $results.ToolState['github-copilot-cli'].InstalledVersionSource | Should Be 'npm.ps1'
        Assert-MockCalled Get-GlobalNpmInstalledVersion 1 -Scope It -ParameterFilter { $PackageName -eq '@github/copilot' }
    }

    It 'refreshes the installed package revision and clears the displayed update command' {
        $results.Tools['GitHub Copilot CLI'] = @{ ToolId = 'github-copilot-cli'; Installed = '1.0.83'; Latest = '1.0.84-2' }

        Refresh-ToolVersion -ToolName 'GitHub Copilot CLI' | Should Be $true

        $row = $results.Tools['GitHub Copilot CLI']
        $row.Installed | Should Be '1.0.84-2'
        $row.Latest | Should Be '1.0.84-2'
        Get-UpdateCommand -ToolName 'GitHub Copilot CLI' -Installed $row.Installed -Latest $row.Latest | Should Be ''
    }

    It 'falls back to CLI versions with or without a package revision when npm metadata is unavailable' {
        Mock Get-GlobalNpmInstalledVersion { $null }

        Get-InstalledVersionFromOutput -ToolName 'GitHub Copilot CLI' -Output 'GitHub Copilot CLI 1.0.84' | Should Be '1.0.84'
        Get-InstalledVersionFromOutput -ToolName 'GitHub Copilot CLI' -Output 'GitHub Copilot CLI 1.0.84-2' | Should Be '1.0.84-2'
        $results.ToolState['github-copilot-cli'].InstalledVersionSource | Should Be 'command'
    }
}

Describe 'npm installed version worker' {
    It 'reads npm metadata with only Copilot selected in check-only mode' {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'absent.env') -SkipUpdate
        $toolsConfig = @{ 'GitHub Copilot CLI' = $toolsConfig['GitHub Copilot CLI'] }
        $script:ToolDefinitions = @{}
        $script:PackageManagerDefinitions = Read-DefinitionRegistry -Files @(Get-PackageManagerDefinitionFiles -ToolsConfiguration $toolsConfig -Directory (Join-Path (Split-Path $scriptPath) 'infra/PackageManagers'))

        Invoke-ParallelChecks -Total 1 -TimeoutSec 10 -Checks @(@{
            Name = 'GitHub Copilot CLI'
            Block = {
                function copilot { 'GitHub Copilot CLI 1.0.83-3.' }
                function npm {
                    if ($args -contains 'list' -and $args -contains '@github/copilot' -and $args -contains '--json') {
                        '{"dependencies":{"@github/copilot":{"version":"1.0.84-2"}}}'
                    } else { throw 'Unexpected npm operation' }
                }
                Test-StandardTool -ToolName 'GitHub Copilot CLI'
            }
        })

        $results.Tools['GitHub Copilot CLI'].Installed | Should Be '1.0.84-2'
        $results.ToolState['github-copilot-cli'].InstalledVersionSource | Should Be 'npm.ps1'
        $results.AvailableUpdates.Count | Should Be 0
        $results.Errors.Count | Should Be 0
    }
}