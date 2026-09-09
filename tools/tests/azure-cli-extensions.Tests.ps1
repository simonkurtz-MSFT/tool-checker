# Azure CLI extension selected-only worker contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'

Describe 'Azure CLI extensions selected-only worker' {
    It 'runs alone with CheckOnly=<CheckOnly>' -TestCases @(@{ CheckOnly = $false }, @{ CheckOnly = $true }) {
        param($CheckOnly)
        $selectionFile = Join-Path $TestDrive 'azure-cli-extensions.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=azure-cli-extensions'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile, $checkOnly)
                . $path -EnvFile $envFile -SkipUpdate:$checkOnly
                $checks = @(@{ Name = 'Azure CLI extensions'; Block = {
                    function Test-CommandExists { $true }
                    function az {
                        if ($args -contains 'list-versions') {
                            if ($SkipUpdate) { throw 'Unexpected extension lookup' }
                            '[{"version":"2.0.0"}]'
                        } else { '[{"name":"example","version":"1.0.0"}]' }
                    }
                    Invoke-ToolEntryPoint -ToolId 'azure-cli-extensions' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                } })
                Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 10
                [PSCustomObject]@{ Ids = @($script:ToolDefinitions.Keys); Results = $results }
            }).AddArgument($scriptPath).AddArgument($selectionFile).AddArgument($CheckOnly)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].Ids | Should Be 'azure-cli-extensions'
            $observed[0].Results.Tools['  az ext: example'].Installed | Should Be '1.0.0'
            $observed[0].Results.AvailableUpdates.Count | Should Be $(if ($CheckOnly) { 0 } else { 1 })
            $observed[0].Results.Errors.Count | Should Be 0
        } finally { $session.Dispose() }
    }
}