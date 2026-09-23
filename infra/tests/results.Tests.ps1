# Shared result-container contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) "results-tests-$([guid]::NewGuid()).env")

Describe 'Result state' {
    It 'creates complete independent result containers' {
        $first = New-ToolCheckResults
        $second = New-ToolCheckResults
        $expectedKeys = @(
            'AvailableUpdates', 'Errors', 'ToolState', 'MaturityBlockedUpdates', 'NotInstalled',
            'RegistryChecks', 'Tools', 'UpdateFailed', 'Updates'
        ) | Sort-Object

        @($first.Keys | Sort-Object) -join ',' | Should Be ($expectedKeys -join ',')
        $first.Tools['Example CLI'] = @{ Installed = '1.0.0' }
        $first.Errors += 'example error'

        $second.Tools.Count | Should Be 0
        $second.Errors.Count | Should Be 0
        $second.ToolState.Count | Should Be 0
    }
}
