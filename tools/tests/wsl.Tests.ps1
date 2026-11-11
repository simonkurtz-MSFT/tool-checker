# WSL selected-only worker contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'

Describe 'WSL selected-only worker' {
    It 'blocks a young release while retaining the upstream version for information' {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'absent.env')
        Mock Test-IsWindowsPlatform { $true }
        Mock Test-CommandExists { $true }
        Mock Invoke-Expression { 'wslc 1.0.0.0' }
        Mock Invoke-SafeApiRequest {
            @([PSCustomObject]@{ tag_name = 'v2.0.0'; published_at = [DateTimeOffset]::UtcNow.AddDays(-2).ToString('O') })
        }
        Invoke-ToolEntryPoint -ToolId 'wsl' -EntryPoint 'Test-Tool' -Arguments @{ Progress = '1/1' }
        $results.Tools.WSL.LatestReleased | Should Be '2.0.0'
        $results.Tools.WSL.LatestCooldown | Should BeNullOrEmpty
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'runs alone with CheckOnly=<CheckOnly>' -TestCases @(@{ CheckOnly = $false }, @{ CheckOnly = $true }) {
        param($CheckOnly)
        $selectionFile = Join-Path $TestDrive 'wsl.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=wsl'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile, $checkOnly)
                . $path -EnvFile $envFile -SkipUpdate:$checkOnly
                $checks = @(@{ Name = 'WSL'; Block = {
                    function Test-CommandExists { $true }
                    function Invoke-Expression { 'wslc 1.0.0.0' }
                    function Invoke-SafeApiRequest {
                        if ($SkipUpdate) { throw 'Unexpected WSL release lookup' }
                        @([PSCustomObject]@{ tag_name = 'v2.0.0'; draft = $false; prerelease = $false; published_at = '2020-01-01' })
                    }
                    Invoke-ToolEntryPoint -ToolId 'wsl' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                } })
                Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 10
                [PSCustomObject]@{ Ids = @($script:ToolDefinitions.Keys); Results = $results }
            }).AddArgument($scriptPath).AddArgument($selectionFile).AddArgument($CheckOnly)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].Ids | Should Be 'wsl'
            $observed[0].Results.Tools['WSL'].Installed | Should Be '1.0.0'
            $observed[0].Results.AvailableUpdates.Count | Should Be $(if ($CheckOnly) { 0 } else { 1 })
            $observed[0].Results.Errors.Count | Should Be 0
        } finally { $session.Dispose() }
    }
}