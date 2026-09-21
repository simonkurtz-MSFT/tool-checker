# Azure Developer CLI parsing, package-version, and comparison contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-azd-tests-absent.env')

Describe 'Azure Developer CLI API version extraction' {
    It 'normalizes Azure Developer CLI GitHub release tags' {
        $apiData = [PSCustomObject]@{ tag_name = 'azure-dev-cli_1.33.0' }
        Get-LatestVersionFromApi -ApiData $apiData -ToolName 'Azure Developer CLI' | Should Be '1.33.0'
    }

    It 'rejects release tags that do not match the configured pattern' {
        Get-LatestVersionFromApi -ToolName 'Azure Developer CLI' -ApiData ([PSCustomObject]@{ tag_name = 'another-product_2.0.0' }) | Should BeNullOrEmpty
    }
}

Describe 'Azure Developer CLI package version' {
    BeforeEach {
        $results.Tools = @{ 'Azure Developer CLI' = @{ Installed = '1.33.0'; Latest = '' } }
        $results.Updates = @()
        $results.AvailableUpdates = @()
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { 'azd version 1.33.0 (commit abc123)' }
        Mock Get-WingetLatestVersion { '1.33.100' }
        Mock Invoke-SafeApiRequest { throw 'Windows azd checks must use WinGet' }
    }

    It 'does not offer an update for an already installed package build' -Skip:(-not $IsWindows) {
        Mock winget.exe { $global:LASTEXITCODE = 0; 'Azure Developer CLI Microsoft.Azd 1.33.100' }
        $installed = Get-InstalledVersionFromOutput -ToolName 'Azure Developer CLI' -Output 'azd version 1.33.0 (commit abc123)'
        Get-StandardToolUpdates -ToolName 'Azure Developer CLI' -InstalledVersion $installed
        $installed | Should Be '1.33.100'
        $results.Tools['Azure Developer CLI'].Latest | Should Be '1.33.100'
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'refreshes the installed package build after an update' -Skip:(-not $IsWindows) {
        Mock winget.exe { $global:LASTEXITCODE = 0; 'Azure Developer CLI Microsoft.Azd 1.33.100' }
        Refresh-ToolVersion -ToolName 'Azure Developer CLI' | Should Be $true
        $results.Tools['Azure Developer CLI'].Installed | Should Be '1.33.100'
    }

    It 'still offers a genuinely newer package build' -Skip:(-not $IsWindows) {
        Mock winget.exe {
            $global:LASTEXITCODE = 0
            'Name                Id            Version  Available Source'
            '----------------------------------------------------------'
            'Azure Developer CLI Microsoft.Azd 1.32.100 1.33.100  winget'
        }
        $installed = Get-InstalledVersionFromOutput -ToolName 'Azure Developer CLI' -Output 'azd version 1.32.0'
        Get-StandardToolUpdates -ToolName 'Azure Developer CLI' -InstalledVersion $installed
        $installed | Should Be '1.32.100'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Details | Should Be '1.32.100 -> 1.33.100'
    }

    It 'falls back to the CLI version when the package lookup fails' -Skip:(-not $IsWindows) {
        Mock winget.exe { $global:LASTEXITCODE = 1; 'No installed package found matching input criteria.' }
        Get-InstalledVersionFromOutput -ToolName 'Azure Developer CLI' -Output 'azd version 1.33.0' | Should Be '1.33.0'
    }

    It 'falls back to the CLI version when WinGet is unavailable' {
        Mock Test-CommandExists { $false }
        Get-InstalledVersionFromOutput -ToolName 'Azure Developer CLI' -Output 'azd version 1.33.0' | Should Be '1.33.0'
    }

    It 'does not offer an MSI encoding-only update after the reported inventory failure' -Skip:(-not $IsWindows) {
        Mock winget.exe { $global:LASTEXITCODE = -2147020496; 'Inventory failed' }
        Test-StandardTool -ToolName 'Azure Developer CLI'
        $results.Tools['Azure Developer CLI'].Installed | Should Be '1.33.0'
        $results.Tools['Azure Developer CLI'].Latest | Should Be '1.33.100'
        $results.Updates.Count | Should Be 0
        $results.AvailableUpdates.Count | Should Be 0
        (Get-UpdateCommand -ToolName 'Azure Developer CLI' -Installed '1.33.0' -Latest '1.33.100') | Should Be ''
        (Compare-OwnedToolVersions -ToolName 'Azure Developer CLI' -Version1 '1.33.0' -Version2 '1.33.100') | Should Be 0
    }

    It 'preserves a genuine CLI patch update after inventory failure' -Skip:(-not $IsWindows) {
        Mock winget.exe { $global:LASTEXITCODE = -2147020496; 'Inventory failed' }
        Mock Get-WingetLatestVersion { '1.33.200' }
        Test-StandardTool -ToolName 'Azure Developer CLI'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Details | Should Be '1.33.0 -> 1.33.200'
    }

    It 'includes the installed-package lookup in parallel checks' {
        $functionBlock = Get-ParallelCheckFunctionBlock
        $functionBlock | Should Match 'function Get-WingetInstalledVersion'
    }
}

Describe 'Azure Developer CLI version comparison' {
    BeforeEach { . $scriptPath -EnvFile (Join-Path $TestDrive 'absent.env') }

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
        $script:ToolDefinitions = Read-DefinitionRegistry -Files @(Get-ToolDefinitionFiles -ToolsConfiguration $toolsConfig -Directory (Join-Path (Split-Path $scriptPath) 'tools'))
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