# uv installer dispatch contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-uv-tests-absent.env')

Describe 'uv installer dispatch' {
    It 'dispatches the Windows installer without executing it' -Skip:(-not $IsWindows) {
        Mock Invoke-ToolEntryPoint { @{ Output = 'synthetic uv'; ExitCode = 0 } }
        $result = Invoke-ActionCommand -Action @{ Name = 'uv'; Type = 'install'; Command = 'unused' }
        $result.ExitCode | Should Be 0
        Assert-MockCalled Invoke-ToolEntryPoint 1 -ParameterFilter { $ToolId -eq 'uv' -and $EntryPoint -eq 'Invoke-ToolInstall' }
    }
}