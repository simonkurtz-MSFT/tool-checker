# Dapr CLI catalog integration; checks and actions use synthetic inputs only.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'

Describe 'Dapr CLI catalog integration' {
    BeforeEach {
        $selectionFile = Join-Path $TestDrive 'dapr-only.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=dapr-cli'
        . $scriptPath -EnvFile $selectionFile
    }

    It 'extracts the CLI version, not the runtime version, and rejects malformed output' {
        Get-InstalledVersionFromOutput -ToolName 'Dapr CLI' -Output "CLI version: 1.18.0 `nRuntime version: 1.17.2" | Should Be '1.18.0'
        Get-InstalledVersionFromOutput -ToolName 'Dapr CLI' -Output "CLI version: n/a`nRuntime version: 1.17.2" | Should BeNullOrEmpty
        Get-LatestVersionFromApi -ToolName 'Dapr CLI' -ApiData ([PSCustomObject]@{ tag_name = 'v1.19.1' }) | Should Be '1.19.1'
    }

    It 'offers the matching platform install when Dapr is absent' {
        function Test-CommandExists { $false }
        Test-StandardTool -ToolName 'Dapr CLI'
        $results.NotInstalled.Count | Should Be 1
        $results.NotInstalled[0].ToolId | Should Be 'dapr-cli'
        Get-InstallCommand $results.NotInstalled[0] | Should Be $toolsConfig['Dapr CLI'].InstallCommands[$script:PlatformKey]
    }

    It 'does not query releases in check-only mode' {
        $SkipUpdate = $true
        function Test-CommandExists { $true }
        function Get-CommandVersion { 'CLI version: 1.18.0' }
        Mock Get-StandardToolUpdates { throw 'Check-only must not request releases' }
        Test-StandardTool -ToolName 'Dapr CLI'
        $results.Tools['Dapr CLI'].Installed | Should Be '1.18.0'
        $results.AvailableUpdates.Count | Should Be 0
        Assert-MockCalled Get-StandardToolUpdates -Times 0 -Scope It
    }

    It 'plans a pinned Linux update only after the release cooldown' {
        function Test-IsWindowsPlatform { $false }
        function Test-CommandExists { $true }
        function Get-CommandVersion { 'CLI version: 1.18.0' }
        function Invoke-SafeApiRequest { [PSCustomObject]@{ tag_name = 'v1.19.1'; published_at = [DateTimeOffset]::UtcNow.AddDays(-9).ToString('O') } }
        Test-StandardTool -ToolName 'Dapr CLI'
        $results.Tools['Dapr CLI'].Latest | Should Be '1.19.1'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Command | Should Match 'bash -s -- 1\.19\.1$'
        $results.AvailableUpdates[0].Executor | Should Be 'command'
    }

    It 'does not offer a Linux update before the release cooldown' {
        function Test-IsWindowsPlatform { $false }
        function Test-CommandExists { $true }
        function Get-CommandVersion { 'CLI version: 1.18.0' }
        function Invoke-SafeApiRequest { [PSCustomObject]@{ tag_name = 'v1.19.1'; published_at = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('O') } }
        Test-StandardTool -ToolName 'Dapr CLI'
        $results.Tools['Dapr CLI'].LatestReleased | Should Be '1.19.1'
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'uses the WinGet package release and update command on Windows' {
        function Test-IsWindowsPlatform { $true }
        function Test-CommandExists { $true }
        function Get-CommandVersion { 'CLI version: 1.18.0' }
        function Get-WingetLatestVersion { '1.19.1' }
        function Get-WingetReleaseDate { [DateTimeOffset]::UtcNow.AddDays(-9).ToString('O') }
        Test-StandardTool -ToolName 'Dapr CLI'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Command | Should Match '^winget upgrade --id Dapr\.CLI '
        $results.AvailableUpdates[0].Executor | Should Be 'winget.ps1'
    }

    It 'checks Dapr alone in a real worker without running an action' {
        Invoke-ParallelChecks -Total 1 -TimeoutSec 10 -Checks @(@{
            Name = 'Dapr CLI'
            Block = {
                function Test-CommandExists { $true }
                function Get-CommandVersion { 'CLI version: 1.18.0' }
                function Get-ConfiguredPackageManager { $null }
                function Invoke-SafeApiRequest { [PSCustomObject]@{ tag_name = 'v1.19.1'; published_at = [DateTimeOffset]::UtcNow.AddDays(-9).ToString('O') } }
                Test-StandardTool -ToolName 'Dapr CLI'
            }
        })
        $results.Errors.Count | Should Be 0
        $results.Tools['Dapr CLI'].Installed | Should Be '1.18.0'
        $results.Tools['Dapr CLI'].Latest | Should Be '1.19.1'
        $results.AvailableUpdates.Count | Should Be 1
    }
}
