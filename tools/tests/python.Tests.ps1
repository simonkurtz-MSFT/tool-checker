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
            $observed[0].Results.Errors.Count | Should Be 0
        } finally { $session.Dispose() }
    }
}

Describe 'Python launcher planning' {
    BeforeEach { . (Join-Path (Split-Path -Parent $scriptPath) 'tools/python.ps1') }

    It 'parses current and legacy installed-list formats' {
        $versions = ConvertFrom-PythonLauncherList -OutputLines @(
            '3.13[-64] * Python 3.13.7',
            '-V:3.12-64 * C:\Python312\python.exe',
            'launcher heading'
        )
        $versions.Count | Should Be 2
        $versions[0].Channel | Should Be '3.13'
        $versions[0].Version | Should Be '3.13.7'
        $versions[0].IsDefault | Should Be $true
        $versions[1].Version | Should Be '3.12-64'
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
            '3.14[-64] Python 3.14.0'
        ) -Online
        $plan = Get-PythonLauncherUpdatePlan -InstalledVersions $installed -AvailableVersions $available
        $plan.Updates[0].Latest | Should Be '3.12.9'
        $plan.NewerChannel | Should Be '3.14'
        $plan.LatestByChannel['3.14'] | Should Be '3.14.0'
    }
}

Describe 'Python version refresh' {
    BeforeEach {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'empty.env')
        $results = New-ToolCheckResults
    }

    It 'refreshes a dynamic Python row without a direct catalog entry' {
        Mock Test-CommandExists { $true }
        function py { }
        Mock py { '3.12[-64] Python 3.12.2' }
        $results.Tools['Python 3.12'] = @{ ToolId = 'python'; Installed = '3.12.1'; Latest = '3.12.2' }
        Refresh-ToolVersion -ToolName 'Python 3.12' | Should Be $true
        $results.Tools['Python 3.12'].Installed | Should Be '3.12.2'
    }
}