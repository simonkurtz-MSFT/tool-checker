# Node.js release planning contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-nodejs-tests-absent.env')

Describe 'Node release planning' {
    BeforeEach {
        . (Join-Path (Split-Path -Parent $scriptPath) 'tools/nodejs.ps1')
    }

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

    It 'does not classify an older index entry in the installed major as an update' {
        $distributionIndex = @([PSCustomObject]@{ version = 'v22.4.9'; lts = 'Jod' })

        $plan = Get-NodeReleasePlan -DistributionIndex $distributionIndex -CurrentVersion '22.5.0'

        $plan.LatestInMajor | Should Be '22.4.9'
        $plan.UpdateKind | Should BeNullOrEmpty
    }
}

Describe 'Node.js tool integration' {
    It 'reports an unknown version for invalid Node.js output: <VersionOutput>' -TestCases @(
        @{ VersionOutput = 'Unable to retrieve version' },
        @{ VersionOutput = 'access denied' }
    ) {
        param($VersionOutput)
        $results = New-ToolCheckResults
        $SkipUpdate = $true
        $script:NodeVersionOutput = $VersionOutput
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { $script:NodeVersionOutput }
        try {
            $messages = @(Invoke-ToolEntryPoint -ToolId 'nodejs' -EntryPoint 'Test-Tool' 6>&1) -join "`n"

            $results.Tools.NodeJS.Installed | Should Be 'unknown'
            $messages | Should Match 'Could not parse NodeJS version'
        } finally {
            Remove-Variable -Name NodeVersionOutput -Scope Script -ErrorAction SilentlyContinue
        }
    }

    It 'preserves a valid Node.js prerelease version' {
        $results = New-ToolCheckResults
        $SkipUpdate = $true
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { 'v23.0.0-dev.20250101' }

        Invoke-ToolEntryPoint -ToolId 'nodejs' -EntryPoint 'Test-Tool'

        $results.Tools.NodeJS.Installed | Should Be 'v23.0.0-dev.20250101'
    }

    It 'reports an unknown version in a selected-only check worker' {
        $selectionFile = Join-Path $TestDrive 'nodejs-only.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=nodejs'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile)
                . $path -EnvFile $envFile -SkipUpdate
                $checks = @(@{ Name = 'NodeJS'; Block = {
                    function Test-CommandExists { $true }
                    function Get-CommandVersion { 'Unable to retrieve version' }
                    function Get-WingetLatestVersion { throw 'Unexpected package lookup' }
                    function Invoke-RestMethod { throw 'Unexpected release lookup' }
                    Invoke-ToolEntryPoint -ToolId 'nodejs' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                } })
                Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 10
                [PSCustomObject]@{ Ids = @($script:ToolDefinitions.Keys); Results = $results }
            }).AddArgument($scriptPath).AddArgument($selectionFile)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].Ids | Should Be 'nodejs'
            $observed[0].Results.Tools.NodeJS.Installed | Should Be 'unknown'
            $observed[0].Results.AvailableUpdates.Count | Should Be 0
            $observed[0].Results.Errors.Count | Should Be 0
        } finally { $session.Dispose() }
    }

    It 'enforces a <Days>-day cooldown on a release aged <Age> days' -TestCases @(
        @{ Days = 8; Age = 7.5; Actions = 0 },
        @{ Days = 8; Age = 8; Actions = 1 },
        @{ Days = 0; Age = 0; Actions = 1 }
    ) {
        param($Days, $Age, $Actions)
        $results = New-ToolCheckResults
        $SkipUpdate = $false
        $toolsConfig.NodeJS.CooldownDays = $Days
        $script:NodePublishedAt = [DateTimeOffset]::UtcNow.AddDays(-$Age).ToString('O')
        Mock Test-CommandExists { $true }
        Mock Test-IsWindowsPlatform { $true }
        Mock Get-CommandVersion { 'v22.1.0' }
        Mock Get-WingetLatestVersion { '22.1.1' }
        Mock Invoke-SafeApiRequest {
            @([PSCustomObject]@{ version = 'v22.1.1'; lts = 'Example'; date = $script:NodePublishedAt })
        }
        try {
            Invoke-ToolEntryPoint -ToolId 'nodejs' -EntryPoint 'Test-Tool' -Arguments @{ Progress = '1/1' }
            $results.Tools.NodeJS.LatestReleased | Should Be 'v22.1.1'
            $results.AvailableUpdates.Count | Should Be $Actions
            if ($Actions -gt 0) { $results.AvailableUpdates[0].Command | Should Match '\-\-version 22\.1\.1' }
        } finally { $toolsConfig.NodeJS.CooldownDays = 8 }
    }

    It 'runs the extracted Node.js checker and release planner in a network-free worker' {
        $previousResults = $results
        $results = New-ToolCheckResults
        try {
            $checks = @(@{
                Name = 'NodeJS'
                Block = {
                    function Test-CommandExists { $true }
                    function Get-CommandVersion { 'v22.1.0' }
                    function Get-WingetLatestVersion { '22.1.1' }
                    function Invoke-RestMethod {
                        @([PSCustomObject]@{ version = 'v22.1.1'; lts = 'Example' })
                    }
                    $SkipUpdate = $false
                    Invoke-ToolEntryPoint -ToolId 'nodejs' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                }
            })

            Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5

            $results.Tools['NodeJS'].Installed | Should Be 'v22.1.0'
            $results.Tools['NodeJS'].Latest | Should Be 'v22.1.1'
            $results.Updates -contains 'NodeJS (patch)' | Should Be $true
            $results.AvailableUpdates.Count | Should Be 1
            $results.AvailableUpdates[0].Command | Should Be $toolsConfig['NodeJS'].UpdateCommand
            $results.Errors.Count | Should Be 0
        } finally {
            $results = $previousResults
        }
    }

    It 'preserves check-only behavior in the extracted Node.js worker' {
        $previousResults = $results
        $results = New-ToolCheckResults
        try {
            $checks = @(@{
                Name = 'NodeJS'
                Block = {
                    function Test-CommandExists { $true }
                    function Get-CommandVersion { 'v22.1.0' }
                    function Get-WingetLatestVersion { throw 'Unexpected package lookup' }
                    function Invoke-RestMethod { throw 'Unexpected release lookup' }
                    $SkipUpdate = $true
                    Invoke-ToolEntryPoint -ToolId 'nodejs' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                }
            })

            Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5

            $results.Tools['NodeJS'].Installed | Should Be 'v22.1.0'
            $results.Tools['NodeJS'].Latest | Should Be ''
            $results.AvailableUpdates.Count | Should Be 0
            $results.Errors.Count | Should Be 0
        } finally {
            $results = $previousResults
        }
    }
}