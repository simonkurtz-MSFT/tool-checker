$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tool-checker.ps1'
$testEnvFile = Join-Path ([System.IO.Path]::GetTempPath()) "tool-checker-tests-$([guid]::NewGuid()).env"
. $scriptPath -EnvFile $testEnvFile

Describe 'Tool configuration' {
    It 'loads stable, unique catalog IDs for display-named tools' {
        $catalogIds = @($toolsConfig.Values | ForEach-Object { $_.Id })

        $toolsConfig['Azure CLI Extensions'].Id | Should Be 'azure-cli-extensions'
        $toolsConfig['Azure Developer CLI'].Id | Should Be 'azure-dev-cli'
        $catalogIds.Count | Should Be ($catalogIds | Select-Object -Unique).Count
        $catalogIds | ForEach-Object { $_ | Should Match '^[a-z][a-z0-9-]*$' }
    }

    It 'applies defaults for optional custom-check properties' {
        $toolsConfig['Azure CLI Extensions'].Enabled | Should Be $true
        $toolsConfig['Azure CLI Extensions'].ProductionReleasesOnly | Should Be $true
    }

    It 'returns a configured custom checker with required properties' {
        $config = Get-ToolConfiguration -ToolName 'NodeJS' -RequiredProperties @('CustomFunction', 'Command')

        $config.CustomFunction | Should Be 'Test-Tool'
        $config.Command | Should Be 'node'
    }

    It 'rejects an unknown tool' {
        { Get-ToolConfiguration -ToolName 'Missing Tool' } | Should Throw 'Tool configuration not found: Missing Tool'
    }

    It 'rejects a missing required property' {
        { Get-ToolConfiguration -ToolName 'Azure CLI Extensions' -RequiredProperties @('ApiUrl') } |
            Should Throw "Tool 'Azure CLI Extensions' requires configuration property 'ApiUrl'."
    }

    It 'resolves every configured custom checker function' {
        { Assert-ToolConfigurations } | Should Not Throw
    }

    It 'rejects a configured custom checker function that does not exist' {
        $toolsConfig['Broken Custom Tool'] = @{
            Enabled = $true
            CheckType = 'custom'
            CustomFunction = 'Test-MissingCustomTool'
            UpdateType = 'direct'
            UpdateCommand = 'broken update'
        }
        try {
            { Assert-ToolConfigurations } |
                Should Throw "Custom checker 'Test-MissingCustomTool' configured for 'Broken Custom Tool' was not found."
        } finally {
            $toolsConfig.Remove('Broken Custom Tool')
        }
    }

    It 'rejects an unsupported check type during startup validation' {
        $toolsConfig['Broken Tool'] = @{
            Enabled = $true
            CheckType = 'manual'
        }
        try {
            { Assert-ToolConfigurations } |
                Should Throw "Tool 'Broken Tool' has unsupported CheckType 'manual'."
        } finally {
            $toolsConfig.Remove('Broken Tool')
        }
    }

    It 'rejects a standard tool without a version command form' {
        $toolsConfig['Broken Standard Tool'] = @{
            Enabled = $true
            CheckType = 'standard'
            Command = 'broken'
            ApiUrl = 'https://example.invalid/releases'
            UpdateType = 'direct'
            UpdateCommand = 'broken update'
        }
        try {
            { Assert-ToolConfigurations } |
                Should Throw "Standard tool 'Broken Standard Tool' requires either 'VersionFlag' or 'VersionCommand'."
        } finally {
            $toolsConfig.Remove('Broken Standard Tool')
        }
    }
}

Describe 'pnpm version refresh' {
    It 'reports the updated global package instead of an older command version' {
        $previousTools = $results.Tools.Clone()
        $results.Tools['pnpm'] = @{ Installed = '10.0.0'; Latest = '10.1.0' }
        Mock Get-GlobalNpmInstalledVersion { '10.1.0' } -ParameterFilter { $PackageName -eq 'pnpm' }
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { '10.0.0' }

        try {
            Refresh-ToolVersion -ToolName 'pnpm' | Should Be $true

            $results.Tools['pnpm'].Installed | Should Be '10.1.0'
            Assert-MockCalled Get-GlobalNpmInstalledVersion 1 -ParameterFilter { $PackageName -eq 'pnpm' }
            Assert-MockCalled Get-CommandVersion 0
        } finally {
            $results.Tools = $previousTools
        }
    }

    It 'falls back to the command version when global npm metadata is unavailable' {
        $previousTools = $results.Tools.Clone()
        $results.Tools['pnpm'] = @{ Installed = '10.0.0'; Latest = '10.1.0' }
        Mock Get-GlobalNpmInstalledVersion { $null } -ParameterFilter { $PackageName -eq 'pnpm' }
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { '10.1.0' }

        try {
            Refresh-ToolVersion -ToolName 'pnpm' | Should Be $true

            $results.Tools['pnpm'].Installed | Should Be '10.1.0'
            Assert-MockCalled Get-CommandVersion 1 -ParameterFilter { $Command -eq 'pnpm' }
        } finally {
            $results.Tools = $previousTools
        }
    }
}

Describe 'Tool catalog selection' {
    It 'selects the complete catalog when no IDs are requested' {
        $selection = Get-ToolCatalogSelection -Tools $toolsJson.tools

        $selection.CatalogToolIds.Count | Should Be 19
        $selection.SelectedEntries.Count | Should Be $selection.CatalogToolIds.Count
    }

    It 'filters requested catalog IDs and retains display sort order' {
        $selection = Get-ToolCatalogSelection -Tools $toolsJson.tools -RequestedToolIds @('deno', 'azure-cli-extensions')

        $selection.SelectedEntries.Count | Should Be 2
        $selection.SelectedEntries[0].Id | Should Be 'azure-cli-extensions'
        $selection.SelectedEntries[0].Name | Should Be 'Azure CLI Extensions'
        $selection.SelectedEntries[1].Id | Should Be 'deno'
    }

    It 'rejects a requested ID that is absent from the catalog' {
        { Get-ToolCatalogSelection -Tools $toolsJson.tools -RequestedToolIds @('deno', 'missing-tool') } |
            Should Throw 'TOOL_CHECKER_TOOLS contains unknown catalog ID(s): missing-tool'
    }

    It 'rejects a catalog ID that is not a lowercase semantic identifier' {
        $invalidCatalog = [PSCustomObject]@{
            'Invalid Tool' = [PSCustomObject]@{ Name = 'Invalid Tool' }
        }

        { Get-ToolCatalogSelection -Tools $invalidCatalog } |
            Should Throw "Tool catalog ID 'Invalid Tool' must use lowercase letters, numbers, and hyphens."
    }

    It 'rejects a catalog entry without a display name' {
        $missingNameCatalog = [PSCustomObject]@{
            'valid-tool' = [PSCustomObject]@{}
        }

        { Get-ToolCatalogSelection -Tools $missingNameCatalog } |
            Should Throw "Tool catalog entry 'valid-tool' requires a display Name."
    }

    It 'rejects duplicate display names even when neither entry is selected' {
        $duplicateNameCatalog = [PSCustomObject]@{
            'first-tool' = [PSCustomObject]@{ Name = 'Same Tool' }
            'second-tool' = [PSCustomObject]@{ Name = 'Same Tool' }
        }

        { Get-ToolCatalogSelection -Tools $duplicateNameCatalog -RequestedToolIds @('first-tool') } |
            Should Throw "Tool catalog display Name 'Same Tool' must be unique."
    }
}

Describe 'Result state' {
    It 'creates complete independent result containers' {
        $first = New-ToolCheckResults
        $second = New-ToolCheckResults
        $expectedKeys = @(
            'AvailableUpdates', 'DotNetSDKs', 'Errors', 'GlobalNpmPackageUpdates',
            'GlobalNpmUpdateCommand', 'MaturityBlockedUpdates', 'NotInstalled',
            'RegistryChecks', 'Tools', 'UpdateFailed', 'Updates'
        ) | Sort-Object

        @($first.Keys | Sort-Object) -join ',' | Should Be ($expectedKeys -join ',')
        $first.Tools['Example CLI'] = @{ Installed = '1.0.0' }
        $first.Errors += 'example error'

        $second.Tools.Count | Should Be 0
        $second.Errors.Count | Should Be 0
        $second.GlobalNpmUpdateCommand | Should Be 'ncu -g -u --loglevel=error'
    }
}

Describe 'Application banner' {
    It 'keeps border and title widths aligned for varying version lengths' {
        foreach ($version in @('1.2.4', '10.123.4567-preview.89')) {
            $lines = @(Get-ApplicationBannerLines -Version $version)

            $lines.Count | Should Be 3
            $lines | ForEach-Object { $_ | Should Match '^  [^ ]' }
            $lines[1] | Should Match "Tool Checker V$version"
            $lines[0].Length | Should Be $lines[1].Length
            $lines[1].Length | Should Be $lines[2].Length
        }
    }
}

Describe 'Version comparison' {
    It 'orders multi-digit semantic version components numerically' {
        Test-UpdateAvailable -InstalledVersion '1.9.0' -LatestVersion '1.10.0' | Should Be $true
    }

    It 'does not report an older version as an update' {
        Test-UpdateAvailable -InstalledVersion '2.0.0' -LatestVersion '1.10.0' | Should Be $false
    }

    It 'normalizes numeric revision suffixes' {
        ConvertTo-CanonicalSemanticVersion '1.0.83-3' | Should Be '1.0.83.3'
    }

    It 'treats an optional fourth zero component as a production release' {
        Test-IsProductionVersion '26.3.240.0' | Should Be $true
    }
}

Describe 'Latest version acceptance' {
    BeforeEach {
        $results.Tools = @{
            'Example CLI' = @{ Installed = '1.0.0'; Latest = '' }
            'Example CLI Core' = @{ Installed = '1.0.0'; Latest = '' }
        }
    }

    It 'assigns an accepted production version to every requested tool row' {
        $accepted = Set-LatestToolVersion -ToolNames @('Example CLI', 'Example CLI Core') -LatestVersion '1.1.0'

        $accepted | Should Be $true
        $results.Tools['Example CLI'].Latest | Should Be '1.1.0'
        $results.Tools['Example CLI Core'].Latest | Should Be '1.1.0'
    }

    It 'rejects a missing candidate without changing tool state' {
        $accepted = Set-LatestToolVersion -ToolNames 'Example CLI' -LatestVersion $null

        $accepted | Should Be $false
        $results.Tools['Example CLI'].Latest | Should Be ''
    }

    It 'rejects a prerelease without changing tool state' {
        $accepted = Set-LatestToolVersion -ToolNames 'Example CLI' -LatestVersion '1.1.0-preview.1'

        $accepted | Should Be $false
        $results.Tools['Example CLI'].Latest | Should Be ''
    }

    It 'accepts a prerelease when production-only filtering is disabled' {
        $accepted = Set-LatestToolVersion -ToolNames 'Example CLI' -LatestVersion '1.1.0-preview.1' -ProductionReleasesOnly $false

        $accepted | Should Be $true
        $results.Tools['Example CLI'].Latest | Should Be '1.1.0-preview.1'
    }
}

Describe 'API version extraction' {
    It 'normalizes Azure Developer CLI GitHub release tags' {
        $apiData = [PSCustomObject]@{ tag_name = 'azure-dev-cli_1.33.0' }

        Get-LatestVersionFromApi -ApiData $apiData -ToolName 'Azure Developer CLI' |
            Should Be '1.33.0'
    }
}

Describe 'Available update construction' {
    BeforeEach {
        $results.AvailableUpdates = @()
    }

    It 'adds the common update fields without emitting output' {
        $output = Add-AvailableUpdate -Name 'Example CLI' -Command 'example update' -Type 'direct' -Details '1.0.0 -> 1.1.0'

        $output | Should BeNullOrEmpty
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Name | Should Be 'Example CLI'
        $results.AvailableUpdates[0].Command | Should Be 'example update'
        $results.AvailableUpdates[0].Type | Should Be 'direct'
        $results.AvailableUpdates[0].Details | Should Be '1.0.0 -> 1.1.0'
    }

    It 'preserves registry and direct-installer metadata' {
        Add-AvailableUpdate -Name 'npm registry' -Command '' -Type 'registry' -RegistryKey 'npm'
        Add-AvailableUpdate -Name 'NodeJS' -Command 'Node.js MSI' -Type 'node-direct' -Version '26.8.1'

        $results.AvailableUpdates[0].RegistryKey | Should Be 'npm'
        $results.AvailableUpdates[1].Version | Should Be '26.8.1'
    }
}

Describe 'Tool update registration' {
    BeforeEach {
        $results.Updates = @()
        $results.AvailableUpdates = @()
    }

    It 'registers a newer version in both update collections' {
        $registered = Register-ToolUpdate -Name 'Example CLI' -InstalledVersion '1.9.0' -LatestVersion '1.10.0' -Command 'example update' -Type 'direct'

        $registered | Should Be $true
        $results.Updates.Count | Should Be 1
        $results.Updates[0] | Should Be 'Example CLI'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Details | Should Be '1.9.0 -> 1.10.0'
    }

    It 'does not mutate update collections when versions are equal' {
        $registered = Register-ToolUpdate -Name 'Example CLI' -InstalledVersion '1.10.0' -LatestVersion '1.10.0' -Command 'example update' -Type 'direct'

        $registered | Should Be $false
        $results.Updates.Count | Should Be 0
        $results.AvailableUpdates.Count | Should Be 0
    }
}

Describe 'Update legend' {
    BeforeEach {
        $results.Updates = @()
        Mock Write-Host { }
    }

    It 'is hidden when no updates are available' {
        Show-UpdateLegend

        Assert-MockCalled Write-Host 0
    }

    It 'is shown when an update is available' {
        $results.Updates = @('Example CLI')

        Show-UpdateLegend

        Assert-MockCalled Write-Host 2
    }
}

Describe 'Update command resolution' {
    BeforeEach {
        $results.Tools = @{}
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
    }

    It 'returns the configured command for a standard tool' {
        $results.Tools['Deno'] = @{ Installed = '2.0.0'; Latest = '2.1.0' }

        Get-UpdateCommand -ToolName 'Deno' -Installed '2.0.0' -Latest '2.1.0' |
            Should Be $toolsConfig['Deno'].UpdateCommand
    }

    It 'pins an npm update to the checked version' {
        $results.Tools['ncu'] = @{ Installed = '20.0.0'; Latest = '21.0.0'; AgeDays = $script:NpmUpdateCooldownDays }

        Get-UpdateCommand -ToolName 'ncu' -Installed '20.0.0' -Latest '21.0.0' |
            Should Be 'npm install -g npm-check-updates@21.0.0 --loglevel=error'
    }

    It 'uses the platform-specific uv update command' {
        $results.Tools['uv'] = @{ Installed = '0.8.0'; Latest = '0.9.0' }
        $expected = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            'winget install --id astral-sh.uv -e --source winget --silent --disable-interactivity --force'
        } else {
            $toolsConfig['uv'].UpdateCommand
        }

        Get-UpdateCommand -ToolName 'uv' -Installed '0.8.0' -Latest '0.9.0' | Should Be $expected
    }
}

Describe 'Standard tool update flow' {
    BeforeEach {
        $results.Tools = @{
            'Azure Bicep CLI' = @{ Installed = '0.45.0'; Latest = '' }
        }
        $results.Updates = @()
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
    }

    It 'registers a self-reported update with its configured command' {
        Get-StandardToolUpdates `
            -ToolName 'Azure Bicep CLI' `
            -InstalledVersion '0.45.0' `
            -RawOutput 'A new Bicep release is available: v0.46.1' | Out-Null

        $results.Tools['Azure Bicep CLI'].Latest | Should Be '0.46.1'
        $results.Updates[0] | Should Be 'Azure Bicep CLI'
        $results.AvailableUpdates[0].Command | Should Be $toolsConfig['Azure Bicep CLI'].UpdateCommand
    }
}

Describe 'Azure Developer CLI package version' {
    BeforeEach {
        $results.Tools = @{ 'Azure Developer CLI' = @{ Installed = '1.33.0'; Latest = '' } }
        $results.Updates = @()
        $results.AvailableUpdates = @()
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { 'azd version 1.33.0 (commit abc123)' }
        Mock Get-WingetLatestVersion { '1.33.100' }
        Mock Invoke-SafeApiRequest { throw 'Windows azd checks must use WinGet' }
    }

    It 'does not offer an update for an already installed package build' -Skip:(-not $IsWindows) {
        Mock winget.exe { $global:LASTEXITCODE = 0; 'Azure Developer CLI Microsoft.Azd 1.33.100' }

        $installed = Get-InstalledVersionFromOutput -ToolName 'Azure Developer CLI' -Output 'azd version 1.33.0 (commit abc123)'
        Get-StandardToolUpdates -ToolName 'Azure Developer CLI' -InstalledVersion $installed

        $installed | Should Be '1.33.100'
        $results.Tools['Azure Developer CLI'].Latest | Should Be '1.33.100'
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'refreshes the installed package build after an update' -Skip:(-not $IsWindows) {
        Mock winget.exe { $global:LASTEXITCODE = 0; 'Azure Developer CLI Microsoft.Azd 1.33.100' }

        Refresh-ToolVersion -ToolName 'Azure Developer CLI' | Should Be $true

        $results.Tools['Azure Developer CLI'].Installed | Should Be '1.33.100'
    }

    It 'still offers a genuinely newer package build' -Skip:(-not $IsWindows) {
        Mock winget.exe {
            $global:LASTEXITCODE = 0
            'Name                Id            Version  Available Source'
            '----------------------------------------------------------'
            'Azure Developer CLI Microsoft.Azd 1.32.100 1.33.100  winget'
        }

        $installed = Get-InstalledVersionFromOutput -ToolName 'Azure Developer CLI' -Output 'azd version 1.32.0'
        Get-StandardToolUpdates -ToolName 'Azure Developer CLI' -InstalledVersion $installed

        $installed | Should Be '1.32.100'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Details | Should Be '1.32.100 -> 1.33.100'
    }

    It 'falls back to the CLI version when the package lookup fails' -Skip:(-not $IsWindows) {
        Mock winget.exe { $global:LASTEXITCODE = 1; 'No installed package found matching input criteria.' }

        Get-InstalledVersionFromOutput -ToolName 'Azure Developer CLI' -Output 'azd version 1.33.0' |
            Should Be '1.33.0'
    }

    It 'falls back to the CLI version when WinGet is unavailable' {
        Mock Test-CommandExists { $false }

        Get-InstalledVersionFromOutput -ToolName 'Azure Developer CLI' -Output 'azd version 1.33.0' |
            Should Be '1.33.0'
    }

    It 'includes the installed-package lookup in parallel checks' {
        $functionBlock = Get-ParallelCheckFunctionBlock -ScriptContent (Get-Content $scriptPath -Raw) -ToolsConfiguration $toolsConfig

        $functionBlock | Should Match 'function Get-WingetInstalledVersion'
    }
}

Describe 'Tool definition loading' {
    It 'resolves only enabled selected catalog files and ignores unrelated files' {
        $directory = Join-Path $TestDrive 'tool-definitions'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        foreach ($fileName in @('nodejs.ps1', 'git.ps1', 'unselected.ps1', '_tool-template.ps1')) {
            Set-Content -LiteralPath (Join-Path $directory $fileName) -Value "throw 'Must not execute during discovery'"
        }
        $configuration = [ordered]@{
            NodeJS = @{ Id = 'nodejs'; Enabled = $true }
            Git = @{ Id = 'git'; Enabled = $false }
            Standard = @{ Id = 'standard'; Enabled = $true }
        }

        $files = @(Get-ToolDefinitionFiles -ToolsConfiguration $configuration -Directory $directory)

        $files.Count | Should Be 1
        $files[0].Name | Should Be 'nodejs.ps1'
        $configuration.NodeJS.Enabled = $false
        @(Get-ToolDefinitionFiles -ToolsConfiguration $configuration -Directory $directory).Count | Should Be 0
    }

    It 'does not require a Tools directory for selected tools without specialized files' {
        $configuration = @{ Git = @{ Id = 'git'; Enabled = $true } }

        @(Get-ToolDefinitionFiles -ToolsConfiguration $configuration -Directory (Join-Path $TestDrive 'absent')).Count | Should Be 0
    }

    It 'does not load Node.js into the main session or workers when only Git is selected' {
        $selectionFile = Join-Path $TestDrive 'git-only.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=git'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile)
                . $path -EnvFile $envFile
                [PSCustomObject]@{
                    LoadedCount = @($script:ToolDefinitionFiles).Count
                    HasNodeChecker = $script:ToolDefinitions.ContainsKey('nodejs')
                    HasNodeUpdater = [bool](Get-Command -CommandType Function | Where-Object Name -eq 'Invoke-ToolUpdate')
                    WorkerDefinitions = Get-ParallelCheckFunctionBlock -ScriptContent (Get-Content $path -Raw) -ToolsConfiguration $toolsConfig
                }
            }).AddArgument($scriptPath).AddArgument($selectionFile)
            $observed = @($session.Invoke())

            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].LoadedCount | Should Be 0
            $observed[0].HasNodeChecker | Should Be $false
            $observed[0].HasNodeUpdater | Should Be $false
            $observed[0].WorkerDefinitions | Should Not Match 'function (Test-Tool|Get-NodeReleasePlan|Invoke-ToolUpdate)\s*\{'
        } finally {
            $session.Dispose()
        }
    }

    It 'registers Node.js functions without exposing them in the caller scope' {
        foreach ($functionName in @('Get-NodeReleasePlan', 'Test-Tool', 'Invoke-ToolUpdate')) {
            $script:ToolDefinitions['nodejs'].ContainsKey($functionName) | Should Be $true
            [bool](Get-Command -CommandType Function | Where-Object Name -eq $functionName) | Should Be $false
        }
        @($script:ToolDefinitionFiles.Name) -contains '_tool-template.ps1' | Should Be $false
    }

    It 'isolates identical entry points and private helpers across tools and workers' {
        $previousDefinitions = $script:ToolDefinitions
        $previousResults = $results
        $script:ToolDefinitions = @{
            'probe-a' = @{
                'Test-Tool' = 'function Test-Tool { param([string]$Progress) Get-ProbeValue }'
                'Get-ProbeValue' = 'function Get-ProbeValue { "first" }'
            }
            'probe-b' = @{
                'Test-Tool' = 'function Test-Tool { param([string]$Progress) Get-ProbeValue }'
                'Get-ProbeValue' = 'function Get-ProbeValue { "second" }'
            }
        }
        $results = New-ToolCheckResults
        try {
            Invoke-ToolEntryPoint -ToolId 'probe-a' -EntryPoint 'Test-Tool' | Should Be 'first'
            Invoke-ToolEntryPoint -ToolId 'probe-b' -EntryPoint 'Test-Tool' | Should Be 'second'
            Invoke-ToolEntryPoint -ToolId 'probe-a' -EntryPoint 'Test-Tool' | Should Be 'first'
            [bool](Get-Command -CommandType Function | Where-Object Name -in @('Test-Tool', 'Get-ProbeValue')) | Should Be $false

            $checks = @(@{
                Name = 'Probe'
                Block = {
                    $first = Invoke-ToolEntryPoint -ToolId 'probe-a' -EntryPoint 'Test-Tool'
                    $second = Invoke-ToolEntryPoint -ToolId 'probe-b' -EntryPoint 'Test-Tool'
                    $results.Tools['Probe'] = @{ Installed = $first; Latest = $second }
                    if (Get-Command -CommandType Function | Where-Object Name -in @('Test-Tool', 'Get-ProbeValue')) {
                        throw 'Tool functions leaked into worker scope.'
                    }
                }
            })
            Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5
            $results.Tools['Probe'].Installed | Should Be 'first'
            $results.Tools['Probe'].Latest | Should Be 'second'
            $results.Errors.Count | Should Be 0
        } finally {
            $script:ToolDefinitions = $previousDefinitions
            $results = $previousResults
        }
    }

    It 'rejects absent entry points instead of falling back to caller functions' {
        function Invoke-ToolInstall { throw 'Must not reach caller function' }
        { Invoke-ToolEntryPoint -ToolId 'nodejs' -EntryPoint 'Invoke-ToolInstall' } |
            Should Throw "Tool 'nodejs' does not define entry point 'Invoke-ToolInstall'."
        { Invoke-ToolEntryPoint -ToolId 'unselected' -EntryPoint 'Test-Tool' } |
            Should Throw "Tool 'unselected' does not define entry point 'Test-Tool'."
    }

    It 'keeps all tool files including the template definition-only and syntactically valid' {
        $toolDirectory = Join-Path (Split-Path -Parent $scriptPath) 'Tools'
        foreach ($toolFile in Get-ChildItem -LiteralPath $toolDirectory -Filter '*.ps1' -File) {
            $parseErrors = $null
            $toolAst = [System.Management.Automation.Language.Parser]::ParseFile($toolFile.FullName, [ref]$null, [ref]$parseErrors)
            @($parseErrors).Count | Should Be 0
            @($toolAst.EndBlock.Statements | Where-Object {
                $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst]
            }).Count | Should Be 0
        }
    }

    It 'marks every tool function public or private and standardizes public names' {
        $toolDirectory = Join-Path (Split-Path -Parent $scriptPath) 'Tools'
        foreach ($toolFile in Get-ChildItem -LiteralPath $toolDirectory -Filter '*.ps1' -File) {
            $content = Get-Content -LiteralPath $toolFile.FullName -Raw
            $regions = [regex]::Matches($content, '(?ms)^#region (Public entry points|Private helpers)\r?\n(.*?)^#endregion')
            $regions.Count | Should Be 2
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
            foreach ($definition in $ast.EndBlock.Statements) {
                $region = @($regions | Where-Object {
                    $definition.Extent.StartOffset -ge $_.Groups[2].Index -and
                    $definition.Extent.EndOffset -le ($_.Groups[2].Index + $_.Groups[2].Length)
                })
                $region.Count | Should Be 1
                if ($region[0].Groups[1].Value -eq 'Public entry points') {
                    $definition.Name | Should Match '^(Test-Tool|Refresh-ToolStatus|Invoke-Tool(Install|Update))$'
                }
            }
        }
    }

    It 'includes tool-local helpers in worker definitions but excludes the template' {
        $functionBlock = Get-ParallelCheckFunctionBlock -ScriptContent (Get-Content $scriptPath -Raw) -ToolsConfiguration $toolsConfig

        $functionBlock | Should Match 'function Get-NodeReleasePlan'
        $functionBlock | Should Match 'function Test-Tool'
        $functionBlock | Should Match 'function Invoke-ToolUpdate'
        $functionBlock | Should Not Match 'Implement the tool-specific check before registering this file'
    }

    It 'runs the extracted Node.js checker and release planner in a network-free worker' {
        $previousResults = $results
        $results = New-ToolCheckResults
        try {
            $checks = @(@{
                Name = 'NodeJS'
                Block = {
                    function Test-CommandExists { $true }
                    function Get-CommandVersion { 'v22.1.0' }
                    function Get-WingetLatestVersion { '22.1.1' }
                    function Invoke-RestMethod {
                        @([PSCustomObject]@{ version = 'v22.1.1'; lts = 'Example' })
                    }
                    $SkipUpdate = $false
                    Invoke-ToolEntryPoint -ToolId 'nodejs' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                }
            })

            Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5

            $results.Tools['NodeJS'].Installed | Should Be 'v22.1.0'
            $results.Tools['NodeJS'].Latest | Should Be 'v22.1.1'
            $results.Updates -contains 'NodeJS (patch)' | Should Be $true
            $results.AvailableUpdates.Count | Should Be 1
            $results.AvailableUpdates[0].Command | Should Be $toolsConfig['NodeJS'].UpdateCommand
            $results.Errors.Count | Should Be 0
        } finally {
            $results = $previousResults
        }
    }

    It 'preserves check-only behavior in the extracted Node.js worker' {
        $previousResults = $results
        $results = New-ToolCheckResults
        try {
            $checks = @(@{
                Name = 'NodeJS'
                Block = {
                    function Test-CommandExists { $true }
                    function Get-CommandVersion { 'v22.1.0' }
                    function Get-WingetLatestVersion { throw 'Unexpected package lookup' }
                    function Invoke-RestMethod { throw 'Unexpected release lookup' }
                    $SkipUpdate = $true
                    Invoke-ToolEntryPoint -ToolId 'nodejs' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
                }
            })

            Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5

            $results.Tools['NodeJS'].Installed | Should Be 'v22.1.0'
            $results.Tools['NodeJS'].Latest | Should Be ''
            $results.AvailableUpdates.Count | Should Be 0
            $results.Errors.Count | Should Be 0
        } finally {
            $results = $previousResults
        }
    }
}

Describe 'Node release planning' {
    BeforeEach {
        . (Join-Path (Split-Path -Parent $scriptPath) 'Tools/nodejs.ps1')
    }

    It 'filters prereleases and classifies the latest patch in the installed major' {
        $distributionIndex = @(
            [PSCustomObject]@{ version = 'v27.0.0-rc.1'; lts = $false },
            [PSCustomObject]@{ version = 'v26.2.0'; lts = $false },
            [PSCustomObject]@{ version = 'v24.12.1'; lts = 'Krypton' },
            [PSCustomObject]@{ version = 'v22.5.1'; lts = 'Jod' }
        )

        $plan = Get-NodeReleasePlan -DistributionIndex $distributionIndex -CurrentVersion '22.5.0'

        $plan.LatestCurrentVersion | Should Be '26.2.0'
        $plan.LatestLTSVersion | Should Be '24.12.1'
        $plan.LatestInMajor | Should Be '22.5.1'
        $plan.UpdateKind | Should Be 'patch'
    }

    It 'classifies a newer minor in the installed major' {
        $distributionIndex = @(
            [PSCustomObject]@{ version = 'v22.6.0'; lts = 'Jod' },
            [PSCustomObject]@{ version = 'v22.5.9'; lts = 'Jod' }
        )

        $plan = Get-NodeReleasePlan -DistributionIndex $distributionIndex -CurrentVersion '22.5.0'

        $plan.UpdateKind | Should Be 'minor'
    }
}

Describe 'Global npm output parsing' {
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

Describe '.NET SDK release planning' {
    It 'parses SDK list output and annotates every row from its channel' {
        $records = ConvertFrom-DotNetSDKList -OutputLines @(
            '8.0.100 [C:\Program Files\dotnet\sdk]',
            '8.0.301 [C:\Program Files\dotnet\sdk]',
            'not an SDK row'
        )
        $inventory = Get-DotNetSDKInventory -SdkRecords $records -LatestSdkByChannel @{
            '8.0' = @{ LatestSdk = '8.0.410'; SupportPhase = 'active' }
        }

        $records.Count | Should Be 2
        $records[0].Path | Should Be 'C:\Program Files\dotnet\sdk'
        $inventory.ByMajor['8'].Count | Should Be 2
        $inventory.DotNetSDKs['8.0.100'].Latest | Should Be '8.0.410'
        $inventory.DotNetSDKs['8.0.100'].HighestInstalled | Should Be '8.0.301'
        $inventory.Tools['.NET SDK 8.0.301'].Latest | Should Be '8.0.410'
    }

    It 'prefers an orchestrator-provided latest version for a major' {
        $records = ConvertFrom-DotNetSDKList -OutputLines @('9.0.100 [C:\dotnet\sdk]')
        $inventory = Get-DotNetSDKInventory -SdkRecords $records `
            -LatestSdkByChannel @{ '9.0' = @{ LatestSdk = '9.0.200' } } `
            -LatestSdkByMajor @{ '9' = '9.0.203' }

        $inventory.DotNetSDKs['9.0.100'].Latest | Should Be '9.0.203'
    }

    It 'groups installed SDKs and returns newer supported production majors' {
        $index = [PSCustomObject]@{ 'releases-index' = @(
            [PSCustomObject]@{ 'channel-version' = '10.0'; 'latest-sdk' = '10.0.101'; 'support-phase' = 'active' },
            [PSCustomObject]@{ 'channel-version' = '11.0'; 'latest-sdk' = '11.0.100-preview.2'; 'support-phase' = 'preview' },
            [PSCustomObject]@{ 'channel-version' = '9.0'; 'latest-sdk' = '9.0.203'; 'support-phase' = 'active' },
            [PSCustomObject]@{ 'channel-version' = '8.0'; 'latest-sdk' = '8.0.410'; 'support-phase' = 'active' },
            [PSCustomObject]@{ 'channel-version' = '7.0'; 'latest-sdk' = '7.0.410'; 'support-phase' = 'eol' }
        ) }

        $plan = Get-DotNetSDKReleasePlan -InstalledVersions @('8.0.100', '8.0.301', '9.0.100') -ReleasesIndex $index

        $plan.ByMajor['8'].Count | Should Be 2
        $plan.LatestSdkByChannel['9.0'].LatestSdk | Should Be '9.0.203'
        $plan.LatestSdkByChannel.ContainsKey('11.0') | Should Be $false
        $plan.NewerMajors.Count | Should Be 1
        $plan.NewerMajors[0] | Should Be 10
    }

    It 'allows an installed preview channel when prereleases are enabled' {
        $index = [PSCustomObject]@{ 'releases-index' = @(
            [PSCustomObject]@{ 'channel-version' = '11.0'; 'latest-sdk' = '11.0.100-preview.2'; 'support-phase' = 'preview' },
            [PSCustomObject]@{ 'channel-version' = '10.0'; 'latest-sdk' = '10.0.101'; 'support-phase' = 'active' }
        ) }

        $plan = Get-DotNetSDKReleasePlan -InstalledVersions @('11.0.100-preview.1') -ReleasesIndex $index -ProductionReleasesOnly $false

        $plan.LatestSdkByChannel.ContainsKey('11.0') | Should Be $true
        $plan.NewerMajors.Count | Should Be 0
    }
}

Describe 'Python launcher planning' {
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

Describe 'Action planning' {
    BeforeEach {
        $script:SkipUpdate = $false
        $results.NotInstalled = @(
            [PSCustomObject]@{
                Name = 'Missing CLI'
                InstallCommands = [ordered]@{ $script:PlatformKey = 'install missing-cli' }
            }
        )
        $results.AvailableUpdates = @(
            @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct'; Details = '1.0.0 -> 1.1.0' },
            @{ Name = 'npm registry'; Command = ''; Type = 'registry'; Details = 'old -> new'; RegistryKey = 'npm' }
        )
    }

    It 'builds install and update actions in display order' {
        $actions = @(Get-AvailableActions)

        $actions.Count | Should Be 3
        $actions[0].Label | Should Be 'Install Missing CLI'
        $actions[0].Command | Should Be 'install missing-cli'
        $actions[1].Label | Should Be 'Update Example CLI (1.0.0 -> 1.1.0)'
        $actions[2].Label | Should Be 'Align npm registry (old -> new)'
    }

    It 'returns only registry actions for approval-gated alignment' {
        $actions = @(Get-AvailableActions -RegistryOnly)

        $actions.Count | Should Be 1
        $actions[0].Type | Should Be 'registry'
        $actions[0].RegistryKey | Should Be 'npm'
    }
}

Describe 'Action execution' {
    BeforeEach {
        $results.UpdateFailed = @()
        $results.Errors = @()
    }

    It 'dispatches ordinary actions through the tool command runner' {
        Mock Invoke-ToolCommand { @{ Output = 'done'; ExitCode = 0 } }
        $action = @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct' }

        $execution = Invoke-ActionCommand -Action $action

        $execution.ExitCode | Should Be 0
        Assert-MockCalled Invoke-ToolCommand 1 -ParameterFilter { $Command -eq 'example update' -and $Type -eq 'direct' }
    }

    It 'dispatches direct Node updates through the verified installer' {
        Mock Invoke-ToolEntryPoint { @{ Output = 'done'; ExitCode = 0 } }
        $action = @{ Name = 'NodeJS'; Command = 'Node.js MSI'; Type = 'node-direct'; Version = '26.8.1' }

        $execution = Invoke-ActionCommand -Action $action

        $execution.ExitCode | Should Be 0
        Assert-MockCalled Invoke-ToolEntryPoint 1 -ParameterFilter { $ToolId -eq 'nodejs' -and $EntryPoint -eq 'Invoke-ToolUpdate' -and $Arguments.Version -eq '26.8.1' }
    }

    It 'completes a successful update without recording a failure' {
        $action = @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct' }

        Complete-UpdateExecution -Action $action -Execution @{ Output = 'done'; ExitCode = 0 } | Should Be $true
        $results.UpdateFailed.Count | Should Be 0
        $results.Errors.Count | Should Be 0
    }

    It 'classifies a WinGet no-update response as a retryable failure' {
        $action = @{ Name = 'Example CLI'; Command = 'winget upgrade Example.CLI'; Type = 'winget' }

        Complete-UpdateExecution -Action $action -Execution @{ Output = 'No applicable upgrade found'; ExitCode = 1 } | Should Be $false
        $results.UpdateFailed[0] | Should Be 'Example CLI'
        $results.Errors[0] | Should Match '^Skipped: Example CLI'
    }

    It 'completes an install when its command is verified despite a nonzero package-manager exit' {
        $results.NotInstalled = @(@{ Name = 'Example CLI' })
        $toolsConfig['Example CLI'] = @{ Command = 'example'; RefreshMethod = 'standard' }
        Mock Test-CommandExists { $true }
        Mock Refresh-ToolVersion { $true }
        $action = @{ Name = 'Example CLI'; Command = 'winget install Example.CLI'; Type = 'install' }

        Complete-InstallExecution -Action $action -Execution @{ Output = 'already present'; ExitCode = 1 } | Should Be $true

        $results.NotInstalled.Count | Should Be 0
        Assert-MockCalled Refresh-ToolVersion 1 -ParameterFilter { $ToolName -eq 'Example CLI' }
    }

    It 'keeps an unverifiable no-update install pending and records an error' {
        $results.NotInstalled = @(@{ Name = 'Missing CLI' })
        $toolsConfig['Missing CLI'] = @{ Command = 'missing-cli' }
        Mock Test-CommandExists { $false }
        $action = @{ Name = 'Missing CLI'; Command = 'winget install Missing.CLI'; Type = 'install' }

        Complete-InstallExecution -Action $action -Execution @{ Output = 'No applicable upgrade found'; ExitCode = 1 } | Should Be $false

        $results.NotInstalled[0].Name | Should Be 'Missing CLI'
        $results.Errors[0] | Should Match '^Install could not be verified for Missing CLI'
        $toolsConfig.Remove('Missing CLI')
    }

    It 'classifies registry alignment success and failure' {
        $action = @{ Name = 'npm registry'; Command = 'npm config set registry'; Type = 'registry' }

        Complete-RegistryExecution -Action $action -Execution @{ Output = 'aligned'; ExitCode = 0 } | Should Be $true
        Complete-RegistryExecution -Action $action -Execution @{ Output = 'access denied'; ExitCode = 1 } | Should Be $false

        $results.Errors.Count | Should Be 1
        $results.Errors[0] | Should Be 'Registry alignment failed for npm registry. access denied'
    }

    It 'completes an ordinary force-mode update through a background job' {
        $update = @{ Name = 'Synthetic CLI'; Command = "Write-Output 'job completed'"; Type = 'direct' }

        Invoke-ParallelUpdates -Updates @($update)

        $results.UpdateFailed.Count | Should Be 0
        $results.Errors.Count | Should Be 0
    }

    It 'records a nonzero background update command as failed' {
        $update = @{ Name = 'Broken CLI'; Command = 'cmd /c exit 7'; Type = 'direct' }

        Invoke-ParallelUpdates -Updates @($update)

        $results.UpdateFailed[0] | Should Be 'Broken CLI'
        $results.Errors[0] | Should Match '^Failed: Broken CLI'
    }

    It 'uses shared dispatch and completion for direct force-mode updates' {
        Mock Invoke-ActionCommand { @{ Output = 'done'; ExitCode = 0 } }
        Mock Complete-UpdateExecution { $true }
        $update = @{ Name = 'NodeJS'; Command = 'Node.js MSI'; Type = 'node-direct'; Version = '26.8.1' }

        Invoke-ParallelUpdates -Updates @($update)

        Assert-MockCalled Invoke-ActionCommand 1 -ParameterFilter { $Action.Name -eq 'NodeJS' }
        Assert-MockCalled Complete-UpdateExecution 1 -ParameterFilter { $Action.Name -eq 'NodeJS' -and $Execution.ExitCode -eq 0 }
    }

    It 'excludes registry actions and refreshes successful automatic updates in force mode' {
        $results.AvailableUpdates = @(
            @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct' },
            @{ Name = 'npm registry'; Command = 'npm config set registry'; Type = 'registry' }
        )
        Mock Invoke-ParallelUpdates { }
        Mock Refresh-ToolVersion { $true }
        Mock Show-ResultsTable { }

        Invoke-ForceUpdates

        Assert-MockCalled Invoke-ParallelUpdates 1 -ParameterFilter {
            $Updates.Count -eq 1 -and $Updates[0].Name -eq 'Example CLI'
        }
        Assert-MockCalled Refresh-ToolVersion 1 -ParameterFilter { $ToolName -eq 'Example CLI' }
        Assert-MockCalled Refresh-ToolVersion 0 -ParameterFilter { $ToolName -eq 'npm registry' }
    }
}

Describe 'Parallel check orchestration' {
    It 'rehydrates configured checker dependencies without including the main entry point' {
        $scriptContent = Get-Content $scriptPath -Raw
        $customChecker = $toolsConfig.Values |
            Where-Object { $_.CheckType -eq 'custom' } |
            Select-Object -First 1 -ExpandProperty CustomFunction

        $functionBlock = Get-ParallelCheckFunctionBlock -ScriptContent $scriptContent -ToolsConfiguration $toolsConfig

        $functionBlock | Should Match "function $customChecker"
        $functionBlock | Should Match 'function Set-LatestToolVersion'
        $functionBlock | Should Not Match 'function Main'
    }

    It 'creates a mergeable timeout result with an unknown tool marker' {
        $timeoutResult = New-ParallelCheckTimeoutResult -Index 2 -Name 'Slow CLI' -TimeoutSec 5

        $timeoutResult.Index | Should Be 2
        $timeoutResult.Tools['Slow CLI'].Installed | Should Be 'unknown'
        $timeoutResult.Tools['Slow CLI'].CheckTimedOut | Should Be $true
        $timeoutResult.Errors[0] | Should Be 'Slow CLI check timed out after 5s'
    }

    It 'merges a completed check result into shared state' {
        $results.Tools = @{}
        $results.DotNetSDKs = @{}
        $results.NotInstalled = @()
        $results.Updates = @()
        $results.Errors = @()
        $results.UpdateFailed = @()
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
        $results.GlobalNpmPackageUpdates = @()
        $results.GlobalNpmUpdateCommand = 'ncu -g -u --loglevel=error'
        $checkResult = @{
            Output = @()
            Tools = @{ 'Example CLI' = @{ Installed = '1.0.0'; Latest = '1.1.0' } }
            DotNetSDKs = @{ '10.0.100' = @{ Major = '10' } }
            NotInstalled = @('Missing CLI')
            Updates = @('Example CLI')
            Errors = @()
            UpdateFailed = @()
            AvailableUpdates = @(@{ Name = 'Example CLI' })
            MaturityBlockedUpdates = @()
            GlobalNpmPackageUpdates = @()
            GlobalNpmUpdateCommand = 'npm update command'
        }

        Merge-ParallelCheckResult -CheckResult $checkResult

        $results.Tools['Example CLI'].Installed | Should Be '1.0.0'
        $results.DotNetSDKs.ContainsKey('10.0.100') | Should Be $true
        $results.Updates[0] | Should Be 'Example CLI'
        $results.AvailableUpdates[0].Name | Should Be 'Example CLI'
        $results.GlobalNpmUpdateCommand | Should Be 'npm update command'
    }

    It 'runs and merges a network-free check through the runspace pool' {
        $results.Tools = @{}
        $results.DotNetSDKs = @{}
        $results.NotInstalled = @()
        $results.Updates = @()
        $results.Errors = @()
        $results.UpdateFailed = @()
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
        $results.GlobalNpmPackageUpdates = @()
        $results.GlobalNpmUpdateCommand = 'ncu -g -u --loglevel=error'
        $checks = @(
            @{
                Name = 'Synthetic CLI'
                Block = { $results.Tools['Synthetic CLI'] = @{ Installed = '1.0.0'; Latest = '' } }
            }
        )

        Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5

        $results.Tools['Synthetic CLI'].Installed | Should Be '1.0.0'
        $results.Errors.Count | Should Be 0
    }

    It 'stops an overlong check and merges its timeout marker' {
        $results.Tools = @{}
        $results.Errors = @()
        $checks = @(
            @{
                Name = 'Slow CLI'
                Block = {
                    while ($true) { $null = 1 + 1 }
                }
            }
        )

        Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 1

        $results.Tools['Slow CLI'].Installed | Should Be 'unknown'
        $results.Tools['Slow CLI'].CheckTimedOut | Should Be $true
        $results.Errors[0] | Should Be 'Slow CLI check timed out after 1s'
    }

    It 'merges checks in declaration order when they complete out of order' {
        $results.Tools = @{}
        $results.Updates = @()
        $results.Errors = @()
        $checks = @(
            @{
                Name = 'First CLI'
                Block = {
                    $waitHandle = [System.Threading.ManualResetEventSlim]::new($false)
                    $null = $waitHandle.Wait(300)
                    $results.Updates += 'First CLI'
                }
            },
            @{
                Name = 'Second CLI'
                Block = { $results.Updates += 'Second CLI' }
            }
        )

        Invoke-ParallelChecks -Checks $checks -Total 2 -TimeoutSec 5

        $results.Updates.Count | Should Be 2
        $results.Updates[0] | Should Be 'First CLI'
        $results.Updates[1] | Should Be 'Second CLI'
        $results.Errors.Count | Should Be 0
    }
}

Describe 'npm release selection' {
    It 'selects the newest production version when latest points to a prerelease' {
        $apiData = [PSCustomObject]@{
            versions = [PSCustomObject]@{
                '2.0.0-beta.1' = @{}
                '1.10.0' = @{}
                '1.9.0' = @{}
            }
        }

        Get-LatestProductionNpmVersion -ApiData $apiData | Should Be '1.10.0'
    }

    It 'selects the newest release that has completed the cooldown' {
        $apiData = [PSCustomObject]@{
            versions = [PSCustomObject]@{
                '1.2.0' = @{}
                '1.1.0' = @{}
                '1.0.0' = @{}
            }
            time = [PSCustomObject]@{
                '1.2.0' = [DateTimeOffset]::UtcNow.AddDays(-2).ToString('O')
                '1.1.0' = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('O')
                '1.0.0' = [DateTimeOffset]::UtcNow.AddDays(-30).ToString('O')
            }
        }

        $release = Get-LatestMatureNpmRelease -ApiData $apiData -MinimumVersion '1.0.0' -MaximumVersion '1.2.0'

        $release.Version | Should Be '1.1.0'
        $release.Installable | Should Be $true
    }
}