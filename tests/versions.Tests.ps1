# Version policy contracts: defaults, isolated overrides, and source-aware azd checks.
$scriptPath = Join-Path (Split-Path $PSScriptRoot) 'tool-checker.ps1'

Describe 'Version comparison contracts' {
    BeforeEach {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'absent.env')
    }

    It 'retains default ordering without an override or owner' {
        Compare-OwnedToolVersions -Version1 '1.9.0' -Version2 '1.10.0' | Should Be -1
        Compare-OwnedToolVersions -Version1 '1.2.3.0' -Version2 '1.2.3' -ToolName 'Azure CLI' | Should Be 0
        Compare-OwnedToolVersions -Version1 '2.0.0' -Version2 '1.10.0' | Should Be 1
        Test-UpdateAvailable -InstalledVersion '1.0.0' -LatestVersion '' | Should Be $false
    }

    It 'isolates same-named overrides by row owner and does not leak public functions' {
        $script:ToolDefinitions = @{
            first = @{ 'Compare-ToolVersions' = 'function Compare-ToolVersions { param($Version1,$Version2,$Version1Source,$Version2Source) 0 }' }
            second = @{ 'Compare-ToolVersions' = 'function Compare-ToolVersions { param($Version1,$Version2,$Version1Source,$Version2Source) -1 }' }
        }
        $results.Tools = @{
            'Renamed first' = @{ ToolId = 'first' }
            'Renamed second' = @{ ToolId = 'second' }
        }
        Test-UpdateAvailable -InstalledVersion '1.0.0' -LatestVersion '2.0.0' -ToolName 'Renamed first' | Should Be $false
        Test-UpdateAvailable -InstalledVersion '1.0.0' -LatestVersion '1.0.0' -ToolName 'Renamed second' | Should Be $true
        @(Get-Command -CommandType Function | Where-Object Name -eq 'Compare-ToolVersions').Count | Should Be 0
    }

    It 'rejects an invalid comparison result instead of silently accepting it' {
        $script:ToolDefinitions['invalid'] = @{ 'Compare-ToolVersions' = 'function Compare-ToolVersions { "equal" }' }
        $results.Tools.Example = @{ ToolId = 'invalid' }
        $message = try { Compare-OwnedToolVersions -Version1 '1.0.0' -Version2 '2.0.0' -ToolName Example } catch { $_.Exception.Message }
        $message | Should Match 'must return exactly one integer'
    }

    It 'applies azd encoding only to command-to-WinGet comparisons and preserves patch ordering' {
        $state = Get-ToolState 'azure-dev-cli'
        $state.InstalledVersionSource = 'command'
        $state.LatestVersionSource = 'winget.ps1'
        Compare-OwnedToolVersions -Version1 '1.33.1' -Version2 '1.33.200' -ToolName 'Azure Developer CLI' | Should Be 0
        Compare-OwnedToolVersions -Version1 '1.33.0' -Version2 '1.34.100' -ToolName 'Azure Developer CLI' | Should Be -1
        Compare-OwnedToolVersions -Version1 '1.33.2' -Version2 '1.33.200' -ToolName 'Azure Developer CLI' | Should Be 1
        $state.InstalledVersionSource = 'winget.ps1'
        Compare-OwnedToolVersions -Version1 '1.33.100' -Version2 '1.33.200' -ToolName 'Azure Developer CLI' | Should Be -1
        $state.InstalledVersionSource = 'command'
        $state.LatestVersionSource = 'api'
        Compare-OwnedToolVersions -Version1 '1.33.0' -Version2 '1.33.1' -ToolName 'Azure Developer CLI' | Should Be -1
    }

    It 'runs azd alone in a real check worker and preserves comparison sources on merge' {
        $toolsConfig = @{ 'Azure Developer CLI' = $toolsConfig['Azure Developer CLI'] }
        $script:ToolDefinitions = Read-DefinitionRegistry -Files @(Get-ToolDefinitionFiles -ToolsConfiguration $toolsConfig -Directory (Join-Path (Split-Path $scriptPath) 'Tools'))
        $script:ToolDefinitions.Count | Should Be 1
        Invoke-ParallelChecks -Total 1 -TimeoutSec 10 -Checks @(@{
            Name = 'Azure Developer CLI'
            Block = {
                function Test-CommandExists { $true }
                function Get-CommandVersion { 'azd version 1.33.0' }
                function Get-ConfiguredPackageManager { param($Configuration,$Operation) 'winget.ps1' }
                function Invoke-PackageManagerOperation {
                    param($PackageManager,$Operation,$Arguments)
                    if ($Operation -eq 'Get-InstalledVersion') { return $null }
                    @{ Latest = '1.33.100'; Installable = $true; Command = 'must not run'; Type = 'direct' }
                }
                Test-StandardTool -ToolName 'Azure Developer CLI'
            }
        })
        $results.Errors.Count | Should Be 0
        $results.Tools['Azure Developer CLI'].Installed | Should Be '1.33.0'
        $results.Tools['Azure Developer CLI'].Latest | Should Be '1.33.100'
        $results.AvailableUpdates.Count | Should Be 0
        $results.ToolState['azure-dev-cli'].InstalledVersionSource | Should Be 'command'
        $results.ToolState['azure-dev-cli'].LatestVersionSource | Should Be 'winget.ps1'
        (Get-UpdateCommand -ToolName 'Azure Developer CLI' -Installed '1.33.0' -Latest '1.33.100') | Should Be ''
    }

    It 'does not request release information or compare during check-only inventory' {
        $SkipUpdate = $true
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { 'azd version 1.33.0' }
        Mock Invoke-PackageManagerOperation { $null }
        Mock Get-StandardToolUpdates { throw 'Release checks must not run' }
        Mock Compare-OwnedToolVersions { throw 'Comparison must not run' }
        Test-StandardTool -ToolName 'Azure Developer CLI'
        $results.Tools['Azure Developer CLI'].Installed | Should Be '1.33.0'
        $results.AvailableUpdates.Count | Should Be 0
        Assert-MockCalled Get-StandardToolUpdates -Times 0 -Scope It
        Assert-MockCalled Compare-OwnedToolVersions -Times 0 -Scope It
    }
}