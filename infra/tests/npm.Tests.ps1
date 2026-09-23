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

Describe 'Node package installation discovery' {
    function npm { throw 'Unexpected npm execution' }
    BeforeEach {
        $results = New-ToolCheckResults
        Mock Test-CommandExists { $true }
        Mock Get-GlobalNodePackageInventory {
            if ($PackageManager -eq 'npm') {
                '{"dependencies":{"@github/copilot":{"version":"1.0.84-2","path":"/npm/node_modules/@github/copilot"}}}' | ConvertFrom-Json
            } else {
                '[{"dependencies":{"@github/copilot":{"version":"1.0.83-3","path":"/pnpm/node_modules/@github/copilot"}}}]' | ConvertFrom-Json
            }
        }
    }

    It 'discovers duplicate installations with their own versions and paths' {
        $before = ConvertTo-Json $results -Depth 10 -Compress
        $installations = @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' })
        $installations.Count | Should Be 2
        $installations[0].PackageManager | Should Be 'npm'
        $installations[0].Version | Should Be '1.0.84-2'
        $installations[0].Path | Should Be '/npm/node_modules/@github/copilot'
        $installations[0].RemoveCommand | Should Be 'npm uninstall --global @github/copilot'
        $installations[1].PackageManager | Should Be 'pnpm'
        $installations[1].Version | Should Be '1.0.83-3'
        $installations[1].RemoveCommand | Should Be 'pnpm remove --global @github/copilot'
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
    }

    It 'discovers a package installed only through <Manager>' -TestCases @(@{ Manager = 'npm' }, @{ Manager = 'pnpm' }) {
        param($Manager)
        $script:ExpectedManager = $Manager
        Mock Test-CommandExists { $Command -eq $script:ExpectedManager }
        $installations = @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' })
        $installations.Count | Should Be 1
        $installations[0].PackageManager | Should Be $Manager
    }

    It 'uses the npm global root when inventory omits the package path' {
        Mock Test-CommandExists { $Command -eq 'npm' }
        Mock Get-GlobalNodePackageInventory { '{"dependencies":{"@github/copilot":{"version":"1.0.84-2"}}}' | ConvertFrom-Json }
        Mock npm { $global:LASTEXITCODE = 0; Join-Path $TestDrive 'node_modules' }

        $installations = @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' })

        $installations.Count | Should Be 1
        $installations[0].Path | Should Be (Join-Path $TestDrive 'node_modules/@github/copilot')
        Assert-MockCalled npm 1 -Scope It -ParameterFilter { $args -contains 'root' -and $args -contains '-g' }
    }

    It 'skips absent package managers' {
        Mock Test-CommandExists { $false }
        @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' }).Count | Should Be 0
        Assert-MockCalled Get-GlobalNodePackageInventory 0 -Scope It
    }

    It 'does not report unrelated packages as installations' {
        Mock Get-GlobalNodePackageInventory { '{"dependencies":{"other":{"version":"1.0.0"}}}' | ConvertFrom-Json }
        @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' }).Count | Should Be 0
    }

    It 'treats inventories without dependencies as empty rather than unavailable' {
        Mock Get-GlobalNodePackageInventory { '{"name":"empty"}' | ConvertFrom-Json }
        @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' }).Count | Should Be 0
    }

    It 'distinguishes unavailable inventory from an absent package' {
        Mock Get-GlobalNodePackageInventory { throw 'Invalid inventory' }
        $installations = @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' })
        $installations.Count | Should Be 2
        $installations[0].Status | Should Be 'Unavailable'
        $installations[1].Status | Should Be 'Unavailable'
    }
}

Describe 'Node package inventory commands' {
    function npm { throw 'Unexpected npm execution' }
    It 'rejects malformed inventory and nonzero npm exits' {
        Mock npm { $global:LASTEXITCODE = 0; 'not JSON' }
        $message = try { Get-GlobalNodePackageInventory -PackageManager npm } catch { $_.Exception.Message }
        [string]::IsNullOrEmpty($message) | Should Be $false

        Mock npm { $global:LASTEXITCODE = 1; '{"dependencies":{}}' }
        $message = try { Get-GlobalNodePackageInventory -PackageManager npm } catch { $_.Exception.Message }
        $message | Should Match 'Could not read npm global inventory'
    }
}

Describe 'npm installed version refresh' {
    BeforeEach {
        $results = New-ToolCheckResults
        Mock Get-GlobalNodePackageInventory {
            '{"dependencies":{"@github/copilot":{"version":"1.0.84-2","path":"/packages/@github/copilot"}}}' | ConvertFrom-Json
        }
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
        (Get-ToolState 'github-copilot-cli').Installations = @(@{ PackageManager = 'npm'; Version = '1.0.83'; Status = 'Found' })

        Refresh-ToolVersion -ToolName 'GitHub Copilot CLI' | Should Be $true

        $row = $results.Tools['GitHub Copilot CLI']
        $row.Installed | Should Be '1.0.84-2'
        $row.Latest | Should Be '1.0.84-2'
        $results.ToolState['github-copilot-cli'].Installations.Count | Should Be 2
        $results.ToolState['github-copilot-cli'].Installations[0].Version | Should Be '1.0.84-2'
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
                    $global:LASTEXITCODE = 0
                    if ($args -contains 'list' -and $args -contains '--json') {
                        '{"dependencies":{"@github/copilot":{"version":"1.0.84-2","path":"/npm/@github/copilot"}}}'
                    } else { throw 'Unexpected npm operation' }
                }
                function pnpm {
                    $global:LASTEXITCODE = 0
                    if ($args -contains 'list' -and $args -contains '--json') {
                        '[{"dependencies":{"@github/copilot":{"version":"1.0.83-3","path":"/pnpm/@github/copilot"}}}]'
                    } else { throw 'Unexpected pnpm operation' }
                }
                Test-StandardTool -ToolName 'GitHub Copilot CLI'
            }
        })

        $results.Tools['GitHub Copilot CLI'].Installed | Should Be '1.0.84-2'
        $results.ToolState['github-copilot-cli'].InstalledVersionSource | Should Be 'npm.ps1'
        $results.ToolState['github-copilot-cli'].Installations.Count | Should Be 2
        $results.ToolState['github-copilot-cli'].Installations[1].PackageManager | Should Be 'pnpm'
        $results.ToolState['github-copilot-cli'].Installations[1].Version | Should Be '1.0.83-3'
        $results.AvailableUpdates.Count | Should Be 0
        $results.Errors.Count | Should Be 0
    }
}