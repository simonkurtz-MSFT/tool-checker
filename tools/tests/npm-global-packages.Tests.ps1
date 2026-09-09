# Global npm package worker, parser, and refresh contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-npm-global-tests-absent.env')

Describe 'Global npm packages selected-only worker' {
    It 'runs alone with CheckOnly=<CheckOnly>' -TestCases @(@{ CheckOnly = $false }, @{ CheckOnly = $true }) {
        param($CheckOnly)
        $selectionFile = Join-Path $TestDrive 'npm-global-packages.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=npm-global-packages'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile, $checkOnly)
                . $path -EnvFile $envFile -SkipUpdate:$checkOnly
                $checks = @(@{ Name = 'Global npm packages'; Block = {
                    function ncu { $global:LASTEXITCODE = 0; "example 1.0.0 $([char]0x2192) 2.0.0" }
                    function npm { if ($args -contains 'config') { 'https://registry.npmjs.org/' } else { throw 'Unexpected npm invocation' } }
                    function Invoke-SafeApiRequest {
                        [PSCustomObject]@{
                            versions = [PSCustomObject]@{ '2.0.0' = @{} }
                            time = [PSCustomObject]@{ '2.0.0' = '2020-01-01T00:00:00Z' }
                        }
                    }
                    Invoke-ToolEntryPoint -ToolId 'npm-global-packages' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                } })
                Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 10
                [PSCustomObject]@{ Ids = @($script:ToolDefinitions.Keys); Results = $results }
            }).AddArgument($scriptPath).AddArgument($selectionFile).AddArgument($CheckOnly)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].Ids | Should Be 'npm-global-packages'
            $observed[0].Results.ToolState['npm-global-packages'].Packages[0].Current | Should Be '1.0.0'
            $observed[0].Results.AvailableUpdates.Count | Should Be $(if ($CheckOnly) { 0 } else { 1 })
            if (-not $CheckOnly) {
                $observed[0].Results.AvailableUpdates[0].Command | Should Be 'npm install -g example@2.0.0 --loglevel=error'
            }
            $observed[0].Results.Errors.Count | Should Be 0
        } finally { $session.Dispose() }
    }
}

Describe 'Global npm output parsing' {
    BeforeEach { . (Join-Path (Split-Path -Parent $scriptPath) 'tools/npm-global-packages.ps1') }

    It 'parses scoped update rows and normalizes the bulk install command' {
        $output = @(
            '@scope/example  1.2.0  →  1.3.0',
            'plain-package  2.0.0  →  2.1.0',
            'npm -g install @scope/example@1.3.0 plain-package@2.1.0'
        )
        $parsed = ConvertFrom-NcuGlobalOutput -OutputLines $output
        $parsed.Packages.Count | Should Be 2
        $parsed.Packages[0].Name | Should Be '@scope/example'
        $parsed.Packages[1].Latest | Should Be '2.1.0'
        $parsed.InstallCommand | Should Be 'npm -g install @scope/example@1.3.0 plain-package@2.1.0 --loglevel=error'
    }
}

Describe 'Global npm package refresh' {
    BeforeEach {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'empty.env')
        $results = New-ToolCheckResults
    }

    It 'refreshes a global package through its owning tool' {
        Mock Get-GlobalNpmInstalledVersion { '2.0.0' }
        (Get-ToolState 'npm-global-packages').Packages = @(@{ Name = 'example'; Current = '1.0.0'; Latest = '2.0.0' })
        $results.Updates = @('ncu global packages', 'Other CLI')
        $results.AvailableUpdates = @(@{ Name = 'npm: example'; ToolId = 'npm-global-packages' })
        Refresh-ToolVersion -ToolName 'npm: example' | Should Be $true
        (Get-ToolState 'npm-global-packages').Packages[0].Current | Should Be '2.0.0'
        $results.Updates.Count | Should Be 1
        $results.Updates[0] | Should Be 'Other CLI'
    }
}