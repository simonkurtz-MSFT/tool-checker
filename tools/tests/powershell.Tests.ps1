# PowerShell selected-only worker contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'

Describe 'PowerShell selected-only worker' {
    . $scriptPath -EnvFile (Join-Path $TestDrive 'absent.env') -CooldownDays 8
    BeforeEach {
        $results = New-ToolCheckResults
        $SkipUpdate = $false
        $toolsConfig.PowerShell.CooldownDays = 8
    }

    It 'offers <Actions> updates for <Case> with both host rows present' -TestCases @(
        @{ Case = 'a young WinGet release'; Windows = $true; Age = 7.999; Days = 8; Actions = 0 },
        @{ Case = 'a young API release'; Windows = $false; Age = 7.999; Days = 8; Actions = 0 },
        @{ Case = 'a mature release'; Windows = $true; Age = 8; Days = 8; Actions = 1 },
        @{ Case = 'a zero-day override'; Windows = $true; Age = 0; Days = 0; Actions = 1 }
    ) {
        param($Case, $Windows, $Age, $Days, $Actions)
        $toolsConfig.PowerShell.CooldownDays = $Days
        $script:PowerShellIsWindows = $Windows
        $script:PowerShellPublishedAt = [DateTimeOffset]::UtcNow.AddDays(-$Age).ToString('O')
        Mock Test-IsWindowsPlatform { $script:PowerShellIsWindows }
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { 'PowerShell 1.0.0' }
        Mock Get-WingetLatestVersion { '99.0.0' }
        Mock Get-WingetReleaseDate { $script:PowerShellPublishedAt }
        Mock Invoke-SafeApiRequest {
            [PSCustomObject]@{ tag_name = 'v99.0.0'; published_at = $script:PowerShellPublishedAt }
        }
        Invoke-ToolEntryPoint -ToolId 'powershell' -EntryPoint 'Test-Tool' -Arguments @{ Progress = '1/1' }
        foreach ($name in @('PowerShell', 'PowerShell Core')) {
            $results.Tools[$name].LatestReleased | Should Be '99.0.0'
            $results.Tools[$name].Installable | Should Be ([bool]$Actions)
            if ($Actions -eq 0) {
                $results.Tools[$name].LatestCooldown | Should BeNullOrEmpty
                Get-UpdateCommand -ToolName $name -Installed $results.Tools[$name].Installed -Latest '99.0.0' | Should Be ''
            }
        }
        $results.AvailableUpdates.Count | Should Be $Actions
        $menuActions = @(Get-AvailableActions)
        $menuActions.Count | Should Be $Actions
        if ($Actions) { $menuActions[0].Name | Should Be 'PowerShell' }
    }

    It 'withholds menu actions after a young release crosses an isolated worker boundary' {
        $selectionFile = Join-Path $TestDrive 'powershell-young.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=powershell'
        . $scriptPath -EnvFile $selectionFile -CooldownDays 8
        $checks = @(@{ Name = 'PowerShell'; Block = {
            function Test-IsWindowsPlatform { $true }
            function Test-CommandExists { $true }
            function Get-CommandVersion { 'PowerShell 1.0.0' }
            function Get-WingetLatestVersion { '99.0.0' }
            function Get-WingetReleaseDate { [DateTimeOffset]::UtcNow.AddDays(-7).ToString('O') }
            Invoke-ToolEntryPoint -ToolId 'powershell' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
        } })

        Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 10

        $results.Errors.Count | Should Be 0
        $results.Tools.Count | Should Be 2
        foreach ($name in @('PowerShell', 'PowerShell Core')) {
            $results.Tools[$name].Installable | Should Be $false
            $results.Tools[$name].LatestReleased | Should Be '99.0.0'
            $results.Tools[$name].LatestCooldown | Should BeNullOrEmpty
        }
        $results.Updates.Count | Should Be 0
        $results.AvailableUpdates.Count | Should Be 0
        @(Get-AvailableActions).Count | Should Be 0
    }

    It 'runs alone with CheckOnly=<CheckOnly>' -TestCases @(@{ CheckOnly = $false }, @{ CheckOnly = $true }) {
        param($CheckOnly)
        $selectionFile = Join-Path $TestDrive 'powershell.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=powershell'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile, $checkOnly)
                . $path -EnvFile $envFile -SkipUpdate:$checkOnly
                $checks = @(@{ Name = 'PowerShell'; Block = {
                    function Test-CommandExists { $true }
                    function Get-CommandVersion { 'PowerShell 1.0.0' }
                    function Get-WingetLatestVersion {
                        if ($SkipUpdate) { throw 'Unexpected package lookup' }
                        '2.0.0'
                    }
                    Invoke-ToolEntryPoint -ToolId 'powershell' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                } })
                Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 10
                [PSCustomObject]@{ Ids = @($script:ToolDefinitions.Keys); Results = $results }
            }).AddArgument($scriptPath).AddArgument($selectionFile).AddArgument($CheckOnly)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].Ids | Should Be 'powershell'
            $observed[0].Results.Tools['PowerShell Core'].Installed | Should Be '1.0.0'
            $observed[0].Results.AvailableUpdates.Count | Should Be $(if ($CheckOnly) { 0 } else { 1 })
            $observed[0].Results.Errors.Count | Should Be 0
        } finally { $session.Dispose() }
    }
}