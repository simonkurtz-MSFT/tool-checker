# Verify dated WinGet plans against synthetic show output without running a package manager.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-winget-tests-absent.env')

Describe 'WinGet release cooldowns' {
    function winget { throw 'Unexpected WinGet invocation' }
    BeforeEach {
        $results = New-ToolCheckResults
        Mock Test-IsWindowsPlatform { $true }
        Mock Test-CommandExists { $true }
        Mock winget {
            $global:LASTEXITCODE = 0
            @('Version: 2.0.0', "  Release Date: $script:PackagePublishedAt")
        }
    }

    It 'keeps a young release informational using the owners cooldown' {
        $script:PackagePublishedAt = [DateTimeOffset]::UtcNow.AddDays(-3).ToString('O')
        $plan = Invoke-PackageManagerOperation -PackageManager 'winget.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'GitHub CLI'; InstalledVersion = '1.0.0' }
        $plan.Installable | Should Be $false
        $plan.LatestReleased | Should Be '2.0.0'
        $plan.LatestCooldown | Should BeNullOrEmpty
        $plan.RequiredAgeDays | Should Be 8
        $results.Tools['GitHub CLI'] = @{ Installed = '1.0.0'; Latest = '' }
        Register-ReleasePlan -ToolName 'GitHub CLI' -InstalledVersion '1.0.0' -Plan $plan
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'accepts a mature release and respects a zero-day tool override' {
        $script:PackagePublishedAt = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('O')
        $plan = Invoke-PackageManagerOperation -PackageManager 'winget.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'GitHub CLI'; InstalledVersion = '1.0.0' }
        $plan.LatestCooldown | Should Be '2.0.0'
        $toolsConfig['GitHub CLI'].CooldownDays = 0
        try {
            $script:PackagePublishedAt = [DateTimeOffset]::UtcNow.ToString('O')
            $plan = Invoke-PackageManagerOperation -PackageManager 'winget.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'GitHub CLI'; InstalledVersion = '1.0.0' }
            $plan.Installable | Should Be $true
        } finally { $toolsConfig['GitHub CLI'].CooldownDays = 8 }
    }

    It 'does not reuse a cached date for a different version' {
        $script:PackagePublishedAt = '2020-01-01'
        Get-WingetLatestVersion -ToolName 'GitHub CLI' -PackageId 'GitHub.cli' | Should Be '2.0.0'
        Get-WingetReleaseDate -ToolName 'GitHub CLI' -PackageId 'GitHub.cli' -Version '2.1.0' | Should BeNullOrEmpty
    }

    It 'preserves the source policy when show output has no release date' {
        Mock winget { $global:LASTEXITCODE = 0; 'Version: 2.0.0' }
        $plan = Invoke-PackageManagerOperation -PackageManager 'winget.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'GitHub CLI'; InstalledVersion = '1.0.0' }
        $plan.Installable | Should Be $true
        $plan.ContainsKey('LatestCooldown') | Should Be $false
    }
}
