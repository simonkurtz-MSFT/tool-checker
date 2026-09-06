$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tool-checker.ps1'

Describe 'Extracted tool workers' {
    $cases = foreach ($tool in @(
        @{ Id = 'python'; Row = 'Python 3.12'; Installed = '3.12.1' },
        @{ Id = 'python-install-manager'; Row = 'Python Install Manager (py)'; Installed = '1.0.0' },
        @{ Id = 'npm-global-packages'; Row = ''; Installed = '1.0.0' },
        @{ Id = 'azure-cli-extensions'; Row = '  az ext: example'; Installed = '1.0.0' },
        @{ Id = 'powershell'; Row = 'PowerShell Core'; Installed = '1.0.0' },
        @{ Id = 'wsl'; Row = 'WSL'; Installed = '1.0.0' }
    )) {
        foreach ($checkOnly in @($false, $true)) {
            @{ Id = $tool.Id; Row = $tool.Row; Installed = $tool.Installed; CheckOnly = $checkOnly }
        }
    }

    It 'runs <Id> alone in a synthetic worker with CheckOnly=<CheckOnly>' -TestCases $cases {
        param($Id, $Row, $Installed, $CheckOnly)
        $selectionFile = Join-Path $TestDrive "$Id.env"
        Set-Content -LiteralPath $selectionFile -Value "TOOL_CHECKER_TOOLS=$Id"
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $selectionFile, $checkOnly)
                . $path -EnvFile $selectionFile -SkipUpdate:$checkOnly
                $checks = @(@{
                    Name = 'Synthetic tool'
                    Block = {
                        function Test-CommandExists { $true }
                        function Get-CommandVersion { 'PowerShell 1.0.0' }
                        function Get-AppxPackage { [PSCustomObject]@{ Version = [version]'1.0.0' } }
                        function Get-WingetLatestVersion {
                            if ($SkipUpdate) { throw 'Unexpected package lookup' }
                            '2.0.0'
                        }
                        function Invoke-Expression { 'wslc 1.0.0.0' }
                        function py {
                            if ($args -contains '--online') {
                                if ($SkipUpdate) { throw 'Unexpected online lookup' }
                                '3.12[-64] Python 3.12.2'
                            } else { '3.12[-64] * Python 3.12.1' }
                        }
                        function az {
                            if ($args -contains 'list-versions') {
                                if ($SkipUpdate) { throw 'Unexpected extension lookup' }
                                '[{"version":"2.0.0"}]'
                            } else { '[{"name":"example","version":"1.0.0"}]' }
                        }
                        function ncu {
                            $global:LASTEXITCODE = 0
                            "example 1.0.0 $([char]0x2192) 2.0.0"
                        }
                        function npm {
                            if ($args -contains 'config') { 'https://registry.npmjs.org/' }
                            else { throw "Unexpected npm invocation: $($args -join ',')" }
                        }
                        function Invoke-SafeApiRequest {
                            param($Uri)
                            if ($Uri -match '/WSL/') {
                                if ($SkipUpdate) { throw 'Unexpected WSL release lookup' }
                                @([PSCustomObject]@{ tag_name = 'v2.0.0'; draft = $false; prerelease = $false; published_at = '2020-01-01' })
                            } else {
                                [PSCustomObject]@{
                                    versions = [PSCustomObject]@{ '2.0.0' = @{} }
                                    time = [PSCustomObject]@{ '2.0.0' = '2020-01-01T00:00:00Z' }
                                }
                            }
                        }
                        function Invoke-RestMethod {
                            if ($SkipUpdate) { throw 'Unexpected release lookup' }
                            [PSCustomObject]@{ tag_name = 'v2.0.0' }
                        }
                        Invoke-ToolEntryPoint -ToolId @($toolsConfig.Values)[0].Id -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                    }
                })
                Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 10
                [PSCustomObject]@{
                    Ids = @($script:ToolDefinitions.Keys)
                    Results = $results
                    LeakedFunctions = @(Get-Command -CommandType Function | Where-Object Name -in @(
                        'Test-Tool', 'ConvertFrom-PythonLauncherList', 'ConvertFrom-NcuGlobalOutput'
                    ))
                }
            }).AddArgument($scriptPath).AddArgument($selectionFile).AddArgument($CheckOnly)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].Ids.Count | Should Be 1
            $observed[0].Ids[0] | Should Be $Id
            $observed[0].LeakedFunctions.Count | Should Be 0
            $result = $observed[0].Results
            $result.Errors.Count | Should Be 0
            if ($Id -in @('wsl', 'python-install-manager') -and -not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
                $result.Tools.Count | Should Be 0
                $result.AvailableUpdates.Count | Should Be 0
            } else {
                if ($Row) { $result.Tools[$Row].Installed | Should Be $Installed }
                else { $result.GlobalNpmPackageUpdates[0].Current | Should Be $Installed }
                if (-not $CheckOnly -and $result.AvailableUpdates.Count -ne 1) {
                    Write-Host ($session.Streams.Information | Out-String)
                }
                $result.AvailableUpdates.Count | Should Be $(if ($CheckOnly) { 0 } else { 1 })
                if ($Id -eq 'npm-global-packages' -and -not $CheckOnly) {
                    $result.AvailableUpdates[0].Command | Should Be 'npm install -g example@2.0.0 --loglevel=error'
                }
            }
        } finally { $session.Dispose() }
    }
}

Describe 'Catalog-driven version parsing' {
    BeforeEach {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'empty.env')
    }

    It 'reads the configured installed JSON property and rejects malformed output' {
        Get-InstalledVersionFromOutput -ToolName 'Azure CLI' -Output '{"azure-cli":"2.80.0"}' | Should Be '2.80.0'
        Get-InstalledVersionFromOutput -ToolName 'Azure CLI' -Output 'not json' | Should BeNullOrEmpty
    }

    It 'parses a configured regex across multiple output lines' {
        Get-InstalledVersionFromOutput -ToolName 'Azure Bicep CLI' -Output @('Warning: example', 'Bicep CLI version 0.46.0') | Should Be '0.46.0'
        Get-InstalledVersionFromOutput -ToolName 'Azure Bicep CLI' -Output 'Warning only' | Should BeNullOrEmpty
    }

    It 'uses the configured API property path and handles missing properties' {
        Get-LatestVersionFromApi -ToolName 'Azure CLI' -ApiData ([PSCustomObject]@{ info = [PSCustomObject]@{ version = '2.80.0' } }) | Should Be '2.80.0'
        Get-LatestVersionFromApi -ToolName 'Azure CLI' -ApiData ([PSCustomObject]@{}) | Should BeNullOrEmpty
    }

    It 'rejects release tags that do not match the configured pattern' {
        Get-LatestVersionFromApi -ToolName 'Azure Developer CLI' -ApiData ([PSCustomObject]@{ tag_name = 'another-product_2.0.0' }) | Should BeNullOrEmpty
    }
}

Describe 'Extracted refresh and install handlers' {
    BeforeEach {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'empty.env')
        $results = New-ToolCheckResults
    }

    It 'refreshes Azure CLI and Bicep through their catalog-loaded entry points' {
        Mock Test-CommandExists { $true }
        function az { }
        Mock az {
            if ($args -contains 'bicep') { 'Bicep CLI version 0.46.0' }
            else { '{"azure-cli":"2.80.0"}' }
        }
        $results.Tools['Azure CLI'] = @{ Installed = '2.70.0'; Latest = '2.80.0' }
        $results.Tools['Azure Bicep CLI'] = @{ Installed = '0.45.0'; Latest = '0.46.0' }
        Refresh-ToolVersion -ToolName 'Azure CLI' | Should Be $true
        Refresh-ToolVersion -ToolName 'Azure Bicep CLI' | Should Be $true
        $results.Tools['Azure CLI'].Installed | Should Be '2.80.0'
        $results.Tools['Azure Bicep CLI'].Installed | Should Be '0.46.0'
    }

    It 'refreshes a dynamic Python row without a direct catalog entry' {
        Mock Test-CommandExists { $true }
        function py { }
        Mock py { '3.12[-64] Python 3.12.2' }
        $results.Tools['Python 3.12'] = @{ Installed = '3.12.1'; Latest = '3.12.2' }
        Refresh-ToolVersion -ToolName 'Python 3.12' | Should Be $true
        $results.Tools['Python 3.12'].Installed | Should Be '3.12.2'
    }

    It 'refreshes a global package through its owning tool' {
        Mock Get-GlobalNpmInstalledVersion { '2.0.0' }
        $results.GlobalNpmPackageUpdates = @(@{ Name = 'example'; Current = '1.0.0'; Latest = '2.0.0' })
        $results.Updates = @('ncu global packages', 'Other CLI')
        Refresh-ToolVersion -ToolName 'npm: example' | Should Be $true
        $results.GlobalNpmPackageUpdates[0].Current | Should Be '2.0.0'
        $results.Updates.Count | Should Be 1
        $results.Updates[0] | Should Be 'Other CLI'
    }

    It 'dispatches the Windows uv installer without executing it' -Skip:(-not $IsWindows) {
        Mock Invoke-ToolEntryPoint { @{ Output = 'synthetic uv'; ExitCode = 0 } }
        $result = Invoke-ActionCommand -Action @{ Name = 'uv'; Type = 'install'; Command = 'unused' }
        $result.ExitCode | Should Be 0
        Assert-MockCalled Invoke-ToolEntryPoint 1 -ParameterFilter { $ToolId -eq 'uv' -and $EntryPoint -eq 'Invoke-ToolInstall' }
    }

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