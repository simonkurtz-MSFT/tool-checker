# Python launcher worker, planning, and refresh contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-python-tests-absent.env')

Describe 'Python selected-only worker' {
    It 'runs alone with CheckOnly=<CheckOnly>' -TestCases @(@{ CheckOnly = $false }, @{ CheckOnly = $true }) {
        param($CheckOnly)
        $selectionFile = Join-Path $TestDrive 'python.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=python'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile, $checkOnly)
                . $path -EnvFile $envFile -SkipUpdate:$checkOnly
                $checks = @(@{ Name = 'Python'; Block = {
                    function Test-CommandExists { $true }
                    function Invoke-RestMethod { throw 'Launcher inventory must not request release metadata.' }
                    function py {
                        if ($args -contains '--online') {
                            if ($SkipUpdate) { throw 'Unexpected online lookup' }
                            '3.12[-64] Python 3.12.2'
                        } else { '3.12[-64] * Python 3.12.1' }
                    }
                    Invoke-ToolEntryPoint -ToolId 'python' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                } })
                Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 10
                [PSCustomObject]@{ Ids = @($script:ToolDefinitions.Keys); Results = $results }
            }).AddArgument($scriptPath).AddArgument($selectionFile).AddArgument($CheckOnly)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].Ids | Should Be 'python'
            $observed[0].Results.Tools['Python 3.12'].Installed | Should Be '3.12.1'
            $observed[0].Results.AvailableUpdates.Count | Should Be $(if ($CheckOnly) { 0 } else { 1 })
            if (-not $CheckOnly) { $observed[0].Results.AvailableUpdates[0].Version | Should Be '3.12.2' }
            $observed[0].Results.Tools['Python 3.12'].LatestReleased | Should BeNullOrEmpty
            $observed[0].Results.Errors.Count | Should Be 0
        } finally { $session.Dispose() }
    }

    It 'blocks a dated conventional release in a selected-only network-free worker' {
        $selectionFile = Join-Path $TestDrive 'python-conventional.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=python'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile)
                . $path -EnvFile $envFile
                $checks = @(@{ Name = 'Python'; Block = {
                    function Test-CommandExists { param($Command) $Command -eq 'python' }
                    function Test-IsWindowsPlatform { $false }
                    function Get-CommandVersion { 'Python 3.12.1' }
                    function Invoke-RestMethod {
                        @([PSCustomObject]@{
                            cycle = '3.12'; latest = '3.12.2'; eol = $false
                            latestReleaseDate = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
                        })
                    }
                    $SkipUpdate = $false
                    Invoke-ToolEntryPoint -ToolId 'python' -EntryPoint 'Test-Tool'
                } })
                Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 10
                $results
            }).AddArgument($scriptPath).AddArgument($selectionFile)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].Tools['Python 3.12'].LatestReleased | Should Be '3.12.2'
            $observed[0].Tools['Python 3.12'].Installable | Should Be $false
            $observed[0].AvailableUpdates.Count | Should Be 0
            $observed[0].MaturityBlockedUpdates[0].Name | Should Be 'Python 3.12'
            $observed[0].Errors.Count | Should Be 0
        } finally { $session.Dispose() }
    }
}

Describe 'Python launcher planning' {
    BeforeEach { . (Join-Path (Split-Path -Parent $scriptPath) 'tools/python.ps1') }

    It 'parses current and legacy installed-list formats' {
        $versions = ConvertFrom-PythonLauncherList -OutputLines @(
            '3.15[-arm64] * Python 3.15.0 (ARM64)',
            '3.13[-64] * Python 3.13.7',
            '-V:3.12-64 * C:\Python312\python.exe',
            'launcher heading'
        )
        $versions.Count | Should Be 3
        $versions[0].Channel | Should Be '3.15'
        $versions[0].Version | Should Be '3.15.0'
        $versions[0].IsDefault | Should Be $true
        $versions[1].Channel | Should Be '3.13'
        $versions[1].Version | Should Be '3.13.7'
        $versions[1].IsDefault | Should Be $true
        $versions[2].Version | Should Be '3.12-64'
    }

    It 'normalizes legacy online rows and selects same-channel updates' {
        $installed = ConvertFrom-PythonLauncherList -OutputLines @('-V:3.12 * C:\Python312\python.exe')
        $available = ConvertFrom-PythonLauncherList -OutputLines @('-V:3.12-2', '-V:3.12-1') -Online
        $plan = Get-PythonLauncherUpdatePlan -InstalledVersions $installed -AvailableVersions $available
        $available[0].Version | Should Be '3.12.2'
        $plan.Updates.Count | Should Be 1
        $plan.Updates[0].Latest | Should Be '3.12.2'
    }

    It 'selects the newest available channel above the installed channels' {
        $installed = ConvertFrom-PythonLauncherList -OutputLines @('3.12[-64] Python 3.12.8')
        $available = ConvertFrom-PythonLauncherList -OutputLines @(
            '3.12[-64] Python 3.12.9',
            '3.13[-64] Python 3.13.2',
            '3.14[-64] Python 3.14.0',
            '3.15[-64] Python 3.15.0'
        ) -Online
        $plan = Get-PythonLauncherUpdatePlan -InstalledVersions $installed -AvailableVersions $available
        $plan.Updates[0].Latest | Should Be '3.12.9'
        $plan.NewerChannel | Should Be '3.15'
        $plan.LatestByChannel['3.15'] | Should Be '3.15.0'
    }

    It 'compares conventional release cycles with DedicatedChannelEnabled=<DedicatedChannelEnabled>' -TestCases @(
        @{ DedicatedChannelEnabled = $false }, @{ DedicatedChannelEnabled = $true }
    ) {
        param($DedicatedChannelEnabled)
        Mock Test-IsWindowsPlatform { $false }
        Mock Invoke-SafeApiRequest { @(
            [PSCustomObject]@{ cycle = '3.15'; latest = '3.15.0'; eol = $false },
            [PSCustomObject]@{ cycle = '3.14'; latest = '3.14.1'; eol = $false },
            [PSCustomObject]@{ cycle = '3.10'; latest = '3.10.12'; eol = $false },
            [PSCustomObject]@{ cycle = '3.9'; latest = '3.9.25'; eol = $false }
        ) }
        Mock Write-Warning { }
        $results = New-ToolCheckResults
        $results.Tools['Python 3.10'] = @{ ToolId = 'python'; Installed = '3.10.11'; Latest = '' }
        $SkipUpdate = $false

        $previousEnabled = $toolsConfig['Python 3.15'].Enabled
        $toolsConfig['Python 3.15'].Enabled = $DedicatedChannelEnabled
        try {
            Get-PythonUpdateConventional -InstalledVersion '3.10.11' 6>$null

            $results.Tools['Python 3.10'].Latest | Should Be '3.10.12'
            $results.AvailableUpdates.Count | Should Be 1
            $results.AvailableUpdates[0].Version | Should Be '3.10.12'
            $results.Tools.ContainsKey('Python 3.15') | Should Be (-not $DedicatedChannelEnabled)
            Assert-MockCalled Write-Warning $(if ($DedicatedChannelEnabled) { 0 } else { 1 }) -Scope It -ParameterFilter { $Text -match 'Newer Python major version available: 3\.15 ' }
            Assert-MockCalled Write-Warning 0 -Scope It -ParameterFilter { $Text -match 'major version available: 3\.9 ' }
        } finally {
            $toolsConfig['Python 3.15'].Enabled = $previousEnabled
        }
    }
}

Describe 'Python conventional release cooldown' {
    BeforeEach {
        . (Join-Path (Split-Path -Parent $scriptPath) 'tools\python.ps1')
        $previousResults = $results
        $previousCooldown = $toolsConfig['Python'].CooldownDays
        $results = New-ToolCheckResults
        $results.Tools['Python 3.12'] = @{ ToolId = 'python'; Installed = '3.12.1'; Latest = '' }
        $SkipUpdate = $false
        Mock Test-IsWindowsPlatform { $false }
        Mock Write-Warning {}
    }

    AfterEach {
        $results = $previousResults
        $toolsConfig['Python'].CooldownDays = $previousCooldown
    }

    It 'enforces <Cooldown> days for the exact latest patch <Age> days old' -TestCases @(
        @{ Cooldown = 8; Age = 7.999; Eligible = $false },
        @{ Cooldown = 8; Age = 8; Eligible = $true },
        @{ Cooldown = 0; Age = 0.001; Eligible = $true },
        @{ Cooldown = 3; Age = 2.999; Eligible = $false }
    ) {
        param($Cooldown, $Age, $Eligible)
        $toolsConfig['Python'].CooldownDays = $Cooldown
        $releaseDate = [DateTimeOffset]::UtcNow.AddDays(-$Age).ToString('o')
        Mock Invoke-SafeApiRequest {
            @([PSCustomObject]@{ cycle = '3.12'; latest = '3.12.2'; latestReleaseDate = $releaseDate; eol = $false })
        }

        Get-PythonUpdateConventional -InstalledVersion '3.12.1' 6>$null

        $row = $results.Tools['Python 3.12']
        $row.Latest | Should Be '3.12.2'
        $row.LatestReleased | Should Be '3.12.2'
        $row.LatestCooldown | Should Be $(if ($Eligible) { '3.12.2' } else { $null })
        $row.Installable | Should Be $Eligible
        $results.Updates.Count | Should Be $(if ($Eligible) { 1 } else { 0 })
        $results.AvailableUpdates.Count | Should Be $(if ($Eligible) { 1 } else { 0 })
        if ($Eligible) { $results.AvailableUpdates[0].Version | Should Be '3.12.2' }
        else { $results.MaturityBlockedUpdates[0].Name | Should Be 'Python 3.12' }
    }

    It 'does not borrow a cycle initial-release date for an undated latest patch' {
        Mock Invoke-SafeApiRequest {
            @([PSCustomObject]@{
                cycle = '3.12'; latest = '3.12.2'
                releaseDate = [DateTimeOffset]::UtcNow.ToString('o'); eol = $false
            })
        }

        Get-PythonUpdateConventional -InstalledVersion '3.12.1' 6>$null

        $results.Tools['Python 3.12'].Latest | Should Be '3.12.2'
        $results.Tools['Python 3.12'].LatestReleased | Should BeNullOrEmpty
        $results.AvailableUpdates.Count | Should Be 1
        $results.MaturityBlockedUpdates.Count | Should Be 0
    }

    It 'keeps the installed channel date separate from a young newer-channel suggestion' {
        $toolsConfig['Python'].CooldownDays = 8
        Mock Invoke-SafeApiRequest {
            @(
                [PSCustomObject]@{ cycle = '3.12'; latest = '3.12.2'; latestReleaseDate = '2000-01-01'; eol = $false },
                [PSCustomObject]@{
                    cycle = '3.13'; latest = '3.13.0'
                    latestReleaseDate = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o'); eol = $false
                }
            )
        }

        Get-PythonUpdateConventional -InstalledVersion '3.12.1' 6>$null

        $results.Tools['Python 3.12'].LatestReleased | Should Be '3.12.2'
        $results.Tools['Python 3.12'].Installable | Should Be $true
        $results.Tools['Python 3.13'].LatestReleased | Should Be '3.13.0'
        $results.Tools['Python 3.13'].Installable | Should Be $false
        $results.AvailableUpdates.Count | Should Be 1
        Assert-MockCalled Write-Warning 0 -Scope It -ParameterFilter { $Text -match 'Newer Python major version available' }
    }

    It 'blocks an invalid supplied patch-release date' {
        Mock Invoke-SafeApiRequest {
            @([PSCustomObject]@{ cycle = '3.12'; latest = '3.12.2'; latestReleaseDate = 'invalid-date'; eol = $false })
        }

        Get-PythonUpdateConventional -InstalledVersion '3.12.1' 6>$null

        $results.Tools['Python 3.12'].Installable | Should Be $false
        $results.Tools['Python 3.12'].LatestCooldown | Should BeNullOrEmpty
        $results.Updates.Count | Should Be 0
        $results.AvailableUpdates.Count | Should Be 0
        Assert-MockCalled Write-Warning 1 -Scope It -ParameterFilter { $Text -match 'Could not determine release age' }
    }

    It 'uses the same WinGet package candidate date without a separate API request' {
        $toolsConfig['Python'].CooldownDays = 8
        Mock Test-IsWindowsPlatform { $true }
        Mock Get-WingetLatestVersion { '3.12.2' }
        Mock Get-WingetReleaseDate { [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o') }
        Mock Invoke-SafeApiRequest { throw 'Windows must use WinGet metadata.' }

        Get-PythonUpdateConventional -InstalledVersion '3.12.1' 6>$null

        $results.Tools['Python 3.12'].LatestReleased | Should Be '3.12.2'
        $results.Tools['Python 3.12'].Installable | Should Be $false
        $results.AvailableUpdates.Count | Should Be 0
        Assert-MockCalled Get-WingetReleaseDate 1 -Scope It -ParameterFilter {
            $ToolName -eq 'Python 3.12' -and $PackageId -eq 'Python.Python.3.12' -and $Version -eq '3.12.2'
        }
        Assert-MockCalled Invoke-SafeApiRequest 0 -Scope It
    }
}

Describe 'Python version refresh' {
    function py { }
    BeforeEach {
        $results = New-ToolCheckResults
    }

    It 'refreshes a dynamic Python row without a direct catalog entry' {
        Mock Test-CommandExists { $true }
        Mock py {
            if ($args.Count -ne 1 -or $args[0] -ne 'list') { throw 'Refresh must use the same inventory command as discovery.' }
            '3.15[-arm64] * Python 3.15.0 (ARM64)'
        }
        $results.Tools['Python 3.15'] = @{ ToolId = 'python'; Installed = '3.15.0rc3'; Latest = '3.15.0' }
        Refresh-ToolVersion -ToolName 'Python 3.15' | Should Be $true
        $results.Tools['Python 3.15'].Installed | Should Be '3.15.0'
        $results.Tools['Python 3.15'].Latest | Should Be '3.15.0'
    }

    It 'refreshes only the requested channel and preserves release metadata' {
        Mock Test-CommandExists { $true }
        Mock py { @('3.12[-64] Python 3.12.9', '3.13[-64] * Python 3.13.2') }
        $results.Tools['Python 3.12'] = @{ ToolId = 'python'; Installed = '3.12.8'; Latest = '3.12.9'; LatestCooldown = '3.12.9'; LatestReleased = '3.12.10' }
        $results.Tools['Python 3.13'] = @{ ToolId = 'python'; Installed = '3.13.1'; Latest = '3.13.2' }

        Refresh-ToolVersion -ToolName 'Python 3.12' | Should Be $true

        $results.Tools['Python 3.12'].Installed | Should Be '3.12.9'
        $results.Tools['Python 3.12'].LatestCooldown | Should Be '3.12.9'
        $results.Tools['Python 3.12'].LatestReleased | Should Be '3.12.10'
        $results.Tools['Python 3.13'].Installed | Should Be '3.13.1'
    }

    It 'queries the runtime patch version for a legacy launcher row' {
        Mock Test-CommandExists { $true }
        Mock py {
            if ($args[0] -eq 'list') { '-V:3.12-64 * C:\Python312\python.exe' }
            elseif ($args[0] -eq '-V:3.12' -and $args[1] -eq '--version') { 'Python 3.12.9' }
            else { throw "Unexpected launcher arguments: $args" }
        }
        $results.Tools['Python 3.12'] = @{ ToolId = 'python'; Installed = '3.12-64'; Latest = '3.12.9' }

        Refresh-ToolVersion -ToolName 'Python 3.12' | Should Be $true
        $results.Tools['Python 3.12'].Installed | Should Be '3.12.9'
    }

    It 'refreshes a conventional <Command> installation without py' -TestCases @(
        @{ Command = 'python' }, @{ Command = 'python3' }
    ) {
        param($Command)
        Mock Test-CommandExists { param($Command) $Command -eq $availableCommand }
        $availableCommand = $Command
        Mock Get-CommandVersion { 'Python 3.12.9' }
        $results.Tools['Python 3.12'] = @{ ToolId = 'python'; Installed = '3.12.8'; Latest = '3.12.9' }

        Refresh-ToolVersion -ToolName 'Python 3.12' | Should Be $true
        $results.Tools['Python 3.12'].Installed | Should Be '3.12.9'
        Assert-MockCalled Get-CommandVersion 1 -Scope It -ParameterFilter { $Command -eq $availableCommand -and $VersionFlag -eq '--version' }
    }

    It 'rejects a missing, invalid, or wrong-channel conventional runtime' -TestCases @(
        @{ Available = $false; VersionOutput = '' },
        @{ Available = $true; VersionOutput = 'Unable to retrieve version' },
        @{ Available = $true; VersionOutput = 'Python 3.13.2' }
    ) {
        param($Available, $VersionOutput)
        Mock Test-CommandExists { param($Command) $Available -and $Command -eq 'python' }
        Mock Get-CommandVersion { $VersionOutput }
        Mock Write-Warning {}
        $results.Tools['Python 3.12'] = @{ ToolId = 'python'; Installed = '3.12.8'; Latest = '3.12.9' }

        Refresh-ToolVersion -ToolName 'Python 3.12' | Should Be $false
        $results.Tools['Python 3.12'].Installed | Should Be '3.12.8'
        Assert-MockCalled Write-Warning 1 -Scope It
    }

    It 'renders the newly installed patch in the post-update summary table' {
        Mock Test-CommandExists { $true }
        Mock py { '3.12[-64] * Python 3.12.9' }
        $script:SummaryLines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { param($Object) $script:SummaryLines.Add([string]$Object) }
        $results.Tools['Python 3.12'] = @{ ToolId = 'python'; Installed = '3.12.8'; Latest = '3.12.9' }
        $action = @{ Name = 'Python 3.12'; ToolId = 'python'; Type = 'py'; Command = 'synthetic'; Version = '3.12.9' }

        Complete-UpdateExecution -Action $action -Execution @{ ExitCode = 0; Output = '' } -Refresh | Should Be $true
        Show-ResultsTable

        $row = @($script:SummaryLines | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' } |
            Where-Object { $_ -match '^\s+Python 3\.12\s+' })
        $row.Count | Should Be 1
        $row[0] | Should Match 'Python 3\.12\s+3\.12\.9\s+'
        $row[0] | Should Not Match '3\.12\.8'
    }

    It 'reports a failed refresh for missing, invalid, or failed launcher inventory' -TestCases @(
        @{ OutputText = '3.13[-64] Python 3.13.2'; ExitCode = 0 },
        @{ OutputText = 'unexpected output'; ExitCode = 0 },
        @{ OutputText = '3.12[-64] Python 3.12.9'; ExitCode = 1 }
    ) {
        param($OutputText, $ExitCode)
        Mock Test-CommandExists { $true }
        Mock py { $global:LASTEXITCODE = $ExitCode; $OutputText }
        Mock Write-Warning {}
        $results.Tools['Python 3.12'] = @{ ToolId = 'python'; Installed = '3.12.8'; Latest = '3.12.9' }

        Refresh-ToolVersion -ToolName 'Python 3.12' | Should Be $false
        $results.Tools['Python 3.12'].Installed | Should Be '3.12.8'
        Assert-MockCalled Write-Warning 1 -Scope It
    }

    It 'verifies a completed Python update against the refreshed installed version' -TestCases @(
        @{ Installed = '3.12.9'; Succeeded = $true },
        @{ Installed = '3.12.8'; Succeeded = $false }
    ) {
        param($Installed, $Succeeded)
        Mock Test-CommandExists { $true }
        Mock py { "3.12[-64] Python $Installed" }
        Mock Write-Host {}
        Mock Write-Error {}
        $results.Tools['Python 3.12'] = @{ ToolId = 'python'; Installed = '3.12.8'; Latest = '3.12.9' }
        $action = @{ Name = 'Python 3.12'; ToolId = 'python'; Type = 'py'; Command = 'synthetic'; Version = '3.12.9' }

        Complete-UpdateExecution -Action $action -Execution @{ ExitCode = 0; Output = '' } -Refresh | Should Be $Succeeded
        $results.Tools['Python 3.12'].Installed | Should Be $Installed
        $results.UpdateFailed.Count | Should Be $(if ($Succeeded) { 0 } else { 1 })
    }
}