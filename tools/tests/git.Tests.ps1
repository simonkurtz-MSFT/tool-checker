# Git-owned comparison, rendering, and selected-worker contracts; no real updates.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'

Describe 'Git version comparison' {
    BeforeEach {
        $selectionFile = Join-Path $TestDrive 'git-only.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=git'
        . $scriptPath -EnvFile $selectionFile
    }

    It 'compares <First> to <Second> as <Expected>' -TestCases @(
        @{ First = '2.55.0.windows.3'; Second = '2.55.0.3'; Expected = 0 },
        @{ First = '2.55.0.3'; Second = 'v2.55.0.windows.3'; Expected = 0 },
        @{ First = 'v2.55.0.windows.3'; Second = 'v2.55.0.3'; Expected = 0 },
        @{ First = '2.55.0.windows.3'; Second = '2.55.0.4'; Expected = -1 },
        @{ First = '2.55.0.windows.3'; Second = '2.55.0.windows.10'; Expected = -1 },
        @{ First = '2.55.0.windows.3'; Second = '2.56.0.1'; Expected = -1 },
        @{ First = '2.55.0.windows.3'; Second = '2.55.0.2'; Expected = 1 },
        @{ First = '2.55.0'; Second = '2.56.0'; Expected = -1 }
    ) {
        param($First, $Second, $Expected)
        Compare-OwnedToolVersions -ToolName Git -Version1 $First -Version2 $Second | Should Be $Expected
        Test-UpdateAvailable -ToolName Git -InstalledVersion $First -LatestVersion $Second | Should Be ($Expected -eq -1)
    }

    It 'keeps the normalization specific to Git' {
        Compare-OwnedToolVersions -ToolName 'Unrelated' -Version1 '2.55.0.windows.3' -Version2 '2.55.0.3' |
            Should Be (Compare-SemanticVersions -Version1 '2.55.0.windows.3' -Version2 '2.55.0.3')
    }

    It 'renders both equivalent latest columns green without changing the displayed versions' {
        $results.Tools.Git = @{ ToolId = 'git'; Installed = '2.55.0.windows.3'; Latest = '2.55.0.3' }
        $before = ConvertTo-Json $results -Depth 10 -Compress
        $rendered = @(Show-ResultsTable 6>&1) -join "`n"
        $rendered | Should Match ([regex]::Escape($ColorGreen) + '  Git\s+2\.55\.0\.windows\.3\s+2\.55\.0\.3')
        $rendered | Should Match ([regex]::Escape("$ColorReset   ${ColorGreen}2.55.0.3$ColorReset"))
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
    }

    It 'uses the Git override in a selected-alone check worker' -TestCases @(
        @{ Latest = '2.55.0.3'; Updates = 0 },
        @{ Latest = '2.55.0.4'; Updates = 1 }
    ) {
        param($Latest, $Updates)
        $script:ToolDefinitions.Count | Should Be 1
        $script:ToolDefinitions.ContainsKey('git') | Should Be $true
        $block = {
            function Test-CommandExists { $true }
            function Get-CommandVersion { 'git version 2.55.0.windows.3' }
            function Get-ConfiguredPackageManager {
                param($Configuration, $Operation)
                if ($Operation -eq 'Release') { 'winget.ps1' }
            }
            function Invoke-PackageManagerOperation {
                @{ Latest = '__LATEST__'; Installable = $true; Command = 'must not run'; Type = 'direct' }
            }
            Test-StandardTool -ToolName Git
        }.ToString().Replace('__LATEST__', $Latest)
        Invoke-ParallelChecks -Total 1 -TimeoutSec 10 -Checks @(@{ Name = 'Git'; Block = [scriptblock]::Create($block) })
        $results.Errors.Count | Should Be 0
        $results.Tools.Git.Installed | Should Be '2.55.0.windows.3'
        $results.Tools.Git.Latest | Should Be $Latest
        $results.AvailableUpdates.Count | Should Be $Updates
    }

    It 'preserves check-only inventory without querying releases' {
        $SkipUpdate = $true
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { 'git version 2.55.0.windows.3' }
        Mock Get-StandardToolUpdates { throw 'Check-only must not request releases' }
        Test-StandardTool -ToolName Git
        $results.Tools.Git.Installed | Should Be '2.55.0.windows.3'
        $results.Tools.Git.Latest | Should BeNullOrEmpty
        $results.AvailableUpdates.Count | Should Be 0
        Assert-MockCalled Get-StandardToolUpdates 0 -Scope It
    }
}
