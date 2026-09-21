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