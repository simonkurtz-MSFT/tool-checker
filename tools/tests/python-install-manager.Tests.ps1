# Python Install Manager selected-only worker contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'

Describe 'Python Install Manager selected-only worker' {
    It 'runs alone with CheckOnly=<CheckOnly>' -TestCases @(@{ CheckOnly = $false }, @{ CheckOnly = $true }) {
        param($CheckOnly)
        $selectionFile = Join-Path $TestDrive 'python-install-manager.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=python-install-manager'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile, $checkOnly)
                . $path -EnvFile $envFile -SkipUpdate:$checkOnly
                $checks = @(@{ Name = 'Python Install Manager'; Block = {
                    function Test-CommandExists { $true }
                    function Get-AppxPackage { [PSCustomObject]@{ Version = [version]'1.0.0' } }
                    function Get-WingetLatestVersion {
                        if ($SkipUpdate) { throw 'Unexpected package lookup' }
                        '2.0.0'
                    }
                    Invoke-ToolEntryPoint -ToolId 'python-install-manager' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                } })
                Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 10
                [PSCustomObject]@{ Ids = @($script:ToolDefinitions.Keys); Results = $results }
            }).AddArgument($scriptPath).AddArgument($selectionFile).AddArgument($CheckOnly)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].Ids | Should Be 'python-install-manager'
            $observed[0].Results.Tools['Python Install Manager (py)'].Installed | Should Be '1.0.0'
            $observed[0].Results.AvailableUpdates.Count | Should Be $(if ($CheckOnly) { 0 } else { 1 })
            $observed[0].Results.Errors.Count | Should Be 0
        } finally { $session.Dispose() }
    }
}