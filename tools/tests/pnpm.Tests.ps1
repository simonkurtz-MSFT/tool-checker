# pnpm update planning targets the active installation and preserves release eligibility.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'

Describe 'pnpm update planning' {
    $cases = @(
        @{ Location = 'bin'; CheckOnly = $false; Mature = $true; ExpectedCommand = 'pnpm self-update 12.1.0' },
        @{ Location = 'home'; CheckOnly = $false; Mature = $true; ExpectedCommand = 'pnpm self-update 12.1.0' },
        @{ Location = 'npm'; CheckOnly = $false; Mature = $true; ExpectedCommand = 'npm install -g pnpm@12.1.0 --loglevel=error' },
        @{ Location = 'bin'; CheckOnly = $true; Mature = $true; ExpectedCommand = '' },
        @{ Location = 'bin'; CheckOnly = $false; Mature = $false; ExpectedCommand = '' }
    )

    It 'plans <Location> with CheckOnly=<CheckOnly> and Mature=<Mature> in a selected-only worker' -TestCases $cases {
        param($Location, $CheckOnly, $Mature, $ExpectedCommand)

        $selectionFile = Join-Path $TestDrive 'pnpm.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=pnpm'
        $previousPnpmHome = $env:PNPM_HOME
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $selectionFile, $location, $checkOnly, $mature)
                . $path -EnvFile $selectionFile -SkipUpdate:$checkOnly
                $block = {
                    function Test-CommandExists { $true }
                    function Get-CommandVersion { '12.0.0' }
                    function Get-Command {
                        [PSCustomObject]@{ Source = '__COMMAND_PATH__' }
                    }
                    function Invoke-SafeApiRequest {
                        if ($SkipUpdate) { throw 'Unexpected release lookup' }
                        [PSCustomObject]@{
                            'dist-tags' = [PSCustomObject]@{ latest = '12.2.0' }
                            versions = [PSCustomObject]@{ '12.1.0' = @{}; '12.2.0' = @{} }
                            time = [PSCustomObject]@{
                                '12.1.0' = '__PUBLISHED_AT__'
                                '12.2.0' = [DateTimeOffset]::UtcNow.ToString('o')
                            }
                        }
                    }
                    function Get-NpmVersionReleaseInfo {
                        [PSCustomObject]@{ AgeDays = 0; Installable = $false }
                    }
                    function npm { throw 'Unexpected npm execution' }
                    function pnpm { throw 'Unexpected pnpm execution' }
                    Invoke-ToolEntryPoint -ToolId 'pnpm' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                }.ToString()
                $homeDirectory = if ($env:PNPM_HOME) { $env:PNPM_HOME } else { Join-Path ([IO.Path]::GetTempPath()) 'pnpm-home' }
                $commandPath = switch ($location) {
                    'bin' { Join-Path $homeDirectory 'bin/pnpm.cmd' }
                    'home' { Join-Path $homeDirectory 'pnpm.cmd' }
                    'npm' { Join-Path ([IO.Path]::GetTempPath()) 'npm-global/pnpm.cmd' }
                }
                $publishedAt = if ($mature) { '2020-01-01T00:00:00Z' } else { [DateTimeOffset]::UtcNow.ToString('o') }
                $block = $block.Replace('__COMMAND_PATH__', $commandPath.Replace("'", "''")).Replace('__PUBLISHED_AT__', $publishedAt)
                $block = '$env:PNPM_HOME = ''' + $homeDirectory.Replace("'", "''") + "'`n" + $block
                Invoke-ParallelChecks -Checks @(@{ Name = 'pnpm'; Block = [scriptblock]::Create($block) }) -Total 1 -TimeoutSec 10
                [PSCustomObject]@{ Results = $results; Ids = @($script:ToolDefinitions.Keys) }
            }).AddArgument($scriptPath).AddArgument($selectionFile).AddArgument($Location).AddArgument($CheckOnly).AddArgument($Mature)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].Ids.Count | Should Be 1
            $observed[0].Ids[0] | Should Be 'pnpm'
            $result = $observed[0].Results
            $result.Errors.Count | Should Be 0
            $result.Tools['pnpm'].Installed | Should Be '12.0.0'
            if ($ExpectedCommand) {
                $result.AvailableUpdates.Count | Should Be 1
                $result.Tools['pnpm'].Latest | Should Be '12.1.0'
                $result.AvailableUpdates[0].Command | Should Be $ExpectedCommand
                $result.AvailableUpdates[0].Executor | Should Be 'command'
            } else {
                $result.AvailableUpdates.Count | Should Be 0
            }
        } finally {
            $session.Dispose()
            $env:PNPM_HOME = $previousPnpmHome
        }
    }
}

Describe 'pnpm version refresh' {
    . $scriptPath -EnvFile (Join-Path $TestDrive 'empty.env')
    Mock Get-GlobalNpmInstalledVersion { '10.1.0' }
    Mock Test-CommandExists { $true }
    Mock Get-CommandVersion { $script:mockPnpmVersion }

    It 'reports the active command instead of a newer shadowed global package' {
        $previousTools = $results.Tools.Clone()
        $results.Tools['pnpm'] = @{ Installed = '10.0.0'; Latest = '10.1.0' }
        $script:mockPnpmVersion = '10.0.0'

        try {
            Refresh-ToolVersion -ToolName 'pnpm' | Should Be $true

            $results.Tools['pnpm'].Installed | Should Be '10.0.0'
            $results.Tools['pnpm'].Latest | Should Be '10.1.0'
            Assert-MockCalled Get-GlobalNpmInstalledVersion -Times 0 -Exactly -Scope It
            Assert-MockCalled Get-CommandVersion -Times 1 -Exactly -Scope It
        } finally {
            $results.Tools = $previousTools
        }
    }

    It 'reports the updated command when global npm metadata is unavailable' {
        $previousTools = $results.Tools.Clone()
        $results.Tools['pnpm'] = @{ Installed = '10.0.0'; Latest = '10.1.0' }
        $script:mockPnpmVersion = '10.1.0'

        try {
            Refresh-ToolVersion -ToolName 'pnpm' | Should Be $true

            $results.Tools['pnpm'].Installed | Should Be '10.1.0'
            Assert-MockCalled Get-CommandVersion -Times 1 -Exactly -Scope It -ParameterFilter { $Command -eq 'pnpm' }
        } finally {
            $results.Tools = $previousTools
        }
    }
}

Describe 'pnpm npm metadata fallback' {
    It 'retains npm metadata fallback when global package checks are not selected' {
        $selectionFile = Join-Path $TestDrive 'pnpm-only.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=pnpm'
        . $scriptPath -EnvFile $selectionFile
        function npm { }
        Mock npm { '{"2.0.0":"2020-01-01T00:00:00Z"}' }
        $script:ToolDefinitions.ContainsKey('npm-global-packages') | Should Be $false
        (Get-NpmVersionReleaseInfo -PackageName 'pnpm' -Version '2.0.0').Installable | Should Be $true
        $worker = Get-ParallelCheckFunctionBlock -ScriptContent (Get-Content $scriptPath -Raw) -ToolsConfiguration $toolsConfig
        $worker | Should Match 'function Get-NpmVersionReleaseInfo'
        $worker | Should Not Match 'function ConvertFrom-NcuGlobalOutput'
    }
}