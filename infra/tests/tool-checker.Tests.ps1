# Core regression suite for configuration, releases, rendering, dispatch, and approval.
# Dot-source bootstrap with an absent env file; individual tests supply mocked or
# synthetic external operations rather than running the real inventory/install workflow.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
$testEnvFile = Join-Path ([System.IO.Path]::GetTempPath()) "tool-checker-tests-$([guid]::NewGuid()).env"
. $scriptPath -EnvFile $testEnvFile
$toolsJson = Get-Content (Join-Path (Split-Path $scriptPath) 'tool-checker.json') -Raw | ConvertFrom-Json

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
        $results.AvailableUpdates[0].Version | Should Be '1.10.0'
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
        $results.Tools['ncu'] = @{ Installed = '20.0.0'; Latest = '21.0.0'; AgeDays = $script:ReleaseCooldownDays }
        Register-ReleasePlan -ToolName 'ncu' -InstalledVersion '20.0.0' -Plan @{
            Latest = '21.0.0'; Installable = $true; VersionLabel = 'latest version'
            Command = 'npm install -g npm-check-updates@21.0.0 --loglevel=error'; Type = 'npm-global'
        }

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

    It 'pins a self-reported Bicep update to the reported version' {
        Get-StandardToolUpdates `
            -ToolName 'Azure Bicep CLI' `
            -InstalledVersion '0.45.0' `
            -RawOutput 'A new Bicep release is available: v0.46.1' | Out-Null

        $results.Tools['Azure Bicep CLI'].Latest | Should Be '0.46.1'
        $results.Updates[0] | Should Be 'Azure Bicep CLI'
        $results.AvailableUpdates[0].Command | Should Be 'az bicep install --version v0.46.1 --only-show-errors'
    }
}

Describe 'Tool definition loading' {
    It 'resolves only explicitly declared enabled tool files without inferring filenames from IDs' {
        $directory = Join-Path $TestDrive 'tool-definitions'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        foreach ($fileName in @('nodejs.ps1', 'git.ps1', 'unselected.ps1', '_tool-template.ps1')) {
            Set-Content -LiteralPath (Join-Path $directory $fileName) -Value "throw 'Must not execute during discovery'"
        }
        $configuration = [ordered]@{
            NodeJS = @{ Id = 'different-id'; Enabled = $true; ToolFile = 'nodejs.ps1' }
            Git = @{ Id = 'git'; Enabled = $false; ToolFile = 'missing.ps1' }
            Standard = @{ Id = 'unselected'; Enabled = $true }
        }

        $files = @(Get-ToolDefinitionFiles -ToolsConfiguration $configuration -Directory $directory)

        $files.Count | Should Be 1
        $files[0].Name | Should Be 'nodejs.ps1'
        $files[0].Id | Should Be 'different-id'
        $configuration.NodeJS.Enabled = $false
        @(Get-ToolDefinitionFiles -ToolsConfiguration $configuration -Directory $directory).Count | Should Be 0
    }

    It 'does not require a Tools directory for selected tools without specialized files' {
        $configuration = @{ Git = @{ Id = 'git'; Enabled = $true } }

        @(Get-ToolDefinitionFiles -ToolsConfiguration $configuration -Directory (Join-Path $TestDrive 'absent')).Count | Should Be 0
    }

    It 'rejects missing declared files instead of silently falling back' {
        $configuration = @{ Probe = @{ Id = 'probe'; Enabled = $true; ToolFile = 'missing.ps1' } }

        { Get-ToolDefinitionFiles -ToolsConfiguration $configuration -Directory $TestDrive } |
            Should Throw "Tool file 'missing.ps1' configured for 'probe' was not found in tools/."
    }

    It 'rejects invalid paths and the template as declared tool filenames' {
        foreach ($fileName in @('', $null, '../nodejs.ps1', '..\nodejs.ps1', 'C:\nodejs.ps1', 'nested/nodejs.ps1', '_tool-template.ps1', 'nodejs.psm1', @('nodejs.ps1'))) {
            $configuration = @{ Probe = @{ Id = 'probe'; Enabled = $true; ToolFile = $fileName } }

            { Get-ToolDefinitionFiles -ToolsConfiguration $configuration -Directory $TestDrive } |
                Should Throw "Tool 'probe' requires ToolFile to be a .ps1 filename directly under tools/."
        }
    }

    It 'registers and dispatches by catalog ID when the declared filename differs' {
        $directory = Join-Path $TestDrive 'explicit-file-catalog'
        $toolDirectory = Join-Path $directory 'tools'
        New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
        Copy-Item -LiteralPath $scriptPath -Destination $directory
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scriptPath) 'infra') -Destination $directory -Recurse -Force
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scriptPath) 'tools/nodejs.ps1') -Destination (Join-Path $toolDirectory 'node-runtime.ps1')
        $catalog = Get-Content (Join-Path (Split-Path -Parent $scriptPath) 'tool-checker.json') -Raw | ConvertFrom-Json -AsHashtable
        $catalog.tools['probe-node'] = $catalog.tools['nodejs']
        $catalog.tools.Remove('nodejs') | Out-Null
        $catalog.tools['probe-node'].ToolFile = 'node-runtime.ps1'
        $catalog | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $directory 'tool-checker.json')
        $selectionFile = Join-Path $directory 'selection.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=probe-node'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile)
                . $path -EnvFile $envFile -SkipUpdate
                Assert-ToolConfigurations
                function Test-CommandExists { $true }
                function Get-CommandVersion { 'v22.1.0' }
                Invoke-ToolEntryPoint -ToolId 'probe-node' -EntryPoint 'Test-Tool' -Arguments @{ Progress = '1/1' }
                [PSCustomObject]@{
                    RegistryIds = @($script:ToolDefinitions.Keys)
                    LoadedFile = $script:ToolDefinitionFiles[0].Name
                    Installed = $results.Tools['NodeJS'].Installed
                }
            }).AddArgument((Join-Path $directory 'tool-checker.ps1')).AddArgument($selectionFile)
            $observed = @($session.Invoke())

            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].RegistryIds.Count | Should Be 1
            $observed[0].RegistryIds[0] | Should Be 'probe-node'
            $observed[0].LoadedFile | Should Be 'node-runtime.ps1'
            $observed[0].Installed | Should Be 'v22.1.0'
        } finally {
            $session.Dispose()
        }
    }

    It 'does not load specialized tools into the main session or workers when only Git is selected' {
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
                    HasDotNetChecker = $script:ToolDefinitions.ContainsKey('dotnet-sdk')
                    HasNodeUpdater = [bool](Get-Command -CommandType Function | Where-Object Name -eq 'Invoke-ToolUpdate')
                    WorkerDefinitions = Get-ParallelCheckFunctionBlock -ScriptContent (Get-Content $path -Raw) -ToolsConfiguration $toolsConfig
                }
            }).AddArgument($scriptPath).AddArgument($selectionFile)
            $observed = @($session.Invoke())

            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].LoadedCount | Should Be 0
            $observed[0].HasNodeChecker | Should Be $false
            $observed[0].HasDotNetChecker | Should Be $false
            $observed[0].HasNodeUpdater | Should Be $false
            $observed[0].WorkerDefinitions | Should Not Match 'function (Test-Tool|Get-NodeReleasePlan|Invoke-ToolUpdate|ConvertFrom-DotNetSDKList|Get-DotNetSDKInventory|Get-DotNetSDKReleasePlan|Refresh-ToolStatus)\s*\{'
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
        $toolDirectory = Join-Path (Split-Path -Parent $scriptPath) 'tools'
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
        $toolDirectory = Join-Path (Split-Path -Parent $scriptPath) 'tools'
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
                    $definition.Name | Should Match '^(Test-Tool|Refresh-ToolStatus|Invoke-Tool(Install|Update)|Get-ToolOutcome|Compare-ToolVersions)$'
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

    It 'offers the older duplicate installation as an approval-gated cleanup action' {
        $toolsConfig['Example CLI'] = @{ Id = 'example-cli'; Name = 'Example CLI'; UpdateCommand = 'npm install -g @example/cli@latest' }
        $results.ToolState['example-cli'] = @{
            Installations = @(
                @{ PackageManager = 'npm'; PackageName = '@example/cli'; Version = '2.0.0'; Status = 'Found' },
                @{ PackageManager = 'pnpm'; PackageName = '@example/cli'; Version = '1.0.0'; Status = 'Found' }
            )
        }

        $actions = @(Get-AvailableActions -ApprovalOnly)
        $cleanup = @($actions | Where-Object Type -eq 'cleanup')

        $cleanup.Count | Should Be 1
        $cleanup[0].Command | Should Be 'pnpm remove --global @example/cli'
        $cleanup[0].Label | Should Match 'recommended: remove version 1.0.0'
        $toolsConfig.Remove('Example CLI')
    }

    It 'recommends removing the non-update-manager duplicate when versions match' {
        $toolsConfig['Example CLI'] = @{ Id = 'example-cli'; Name = 'Example CLI'; UpdateCommand = 'npm install -g @example/cli@latest' }
        $results.ToolState['example-cli'] = @{
            Installations = @(
                @{ PackageManager = 'pnpm'; PackageName = '@example/cli'; Version = '2.0.0'; Status = 'Found' },
                @{ PackageManager = 'npm'; PackageName = '@example/cli'; Version = '2.0.0'; Status = 'Found' }
            )
        }

        $cleanup = @(Get-DuplicateInstallationActions)

        $cleanup[0].Command | Should Be 'pnpm remove --global @example/cli'
        $toolsConfig.Remove('Example CLI')
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
        $action = @{ Name = 'NodeJS'; ToolId = 'nodejs'; Command = 'Node.js MSI'; Type = 'node-direct'; Executor = 'tool'; EntryPoint = 'Invoke-ToolUpdate'; Arguments = @{ Version = '26.8.1' }; ExecutionMode = 'CurrentSession' }

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

    It 'fails a Deno update when refresh still reports the previous version' {
        $results.Tools['Deno'] = @{ Installed = '2.9.6'; Latest = '2.9.7' }
        Mock Refresh-ToolVersion { $true }
        $action = @{ Name = 'Deno'; ToolId = 'deno'; Command = 'deno upgrade'; Type = 'direct'; Version = '2.9.7' }

        Complete-UpdateExecution -Action $action -Execution @{ Output = ''; ExitCode = 0 } -Refresh | Should Be $false

        $results.UpdateFailed[0] | Should Be 'Deno'
        $results.Errors[0] | Should Be 'Update verification failed for Deno. Expected at least 2.9.7, but found 2.9.6.'
    }

    It 'completes a versioned update after refresh reaches the planned version' {
        $results.Tools['Deno'] = @{ Installed = '2.9.6'; Latest = '2.9.7' }
        Mock Refresh-ToolVersion { $results.Tools['Deno'].Installed = '2.9.7'; $true }
        $action = @{ Name = 'Deno'; ToolId = 'deno'; Command = 'deno upgrade'; Type = 'direct'; Version = '2.9.7' }

        Complete-UpdateExecution -Action $action -Execution @{ Output = ''; ExitCode = 0 } -Refresh | Should Be $true

        $results.UpdateFailed.Count | Should Be 0
        $results.Errors.Count | Should Be 0
    }

    It 'classifies a WinGet no-update response as a retryable failure' {
        $action = @{ Name = 'Example CLI'; Command = 'winget upgrade Example.CLI'; Type = 'winget'; OutcomePackageManager = 'winget.ps1' }

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
        $action = @{ Name = 'Missing CLI'; Command = 'winget install Missing.CLI'; Type = 'install'; OutcomePackageManager = 'winget.ps1' }

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
        $update = @{ Name = 'NodeJS'; ToolId = 'nodejs'; Command = 'Node.js MSI'; Type = 'node-direct'; Executor = 'tool'; EntryPoint = 'Invoke-ToolUpdate'; Arguments = @{ Version = '26.8.1' }; ExecutionMode = 'CurrentSession' }

        Invoke-ParallelUpdates -Updates @($update)

        Assert-MockCalled Invoke-ActionCommand 1 -ParameterFilter { $Action.Name -eq 'NodeJS' }
        Assert-MockCalled Complete-UpdateExecution 1 -ParameterFilter { $Action.Name -eq 'NodeJS' -and $Execution.ExitCode -eq 0 }
    }

    It 'excludes registry and cleanup actions in force mode' {
        $results.AvailableUpdates = @(
            @{ Name = 'Example CLI'; Command = 'example update'; Type = 'direct' },
            @{ Name = 'npm registry'; Command = 'npm config set registry'; Type = 'registry' },
            @{ Name = 'Example cleanup'; Command = 'npm uninstall --global example'; Type = 'cleanup' }
        )
        Mock Invoke-ParallelUpdates { }
        Mock Show-ResultsTable { }

        Invoke-ForceUpdates

        Assert-MockCalled Invoke-ParallelUpdates 1 -ParameterFilter {
            $Updates.Count -eq 1 -and $Updates[0].Name -eq 'Example CLI'
        }
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
        $results.ToolState['dotnet-sdk'] = @{}
        $results.NotInstalled = @()
        $results.Updates = @()
        $results.Errors = @()
        $results.UpdateFailed = @()
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
        (Get-ToolState 'npm-global-packages').Packages = @()
        (Get-ToolState 'npm-global-packages').UpdateCommand = 'ncu -g -u --loglevel=error'
        $checkResult = @{
            Output = @()
            Tools = @{ 'Example CLI' = @{ Installed = '1.0.0'; Latest = '1.1.0' } }
            ToolState = @{ 'dotnet-sdk' = @{ '10.0.100' = @{ Major = '10' } }; 'npm-global-packages' = @{ Packages = @(); UpdateCommand = 'npm update command' } }
            NotInstalled = @('Missing CLI')
            Updates = @('Example CLI')
            Errors = @()
            UpdateFailed = @()
            AvailableUpdates = @(@{ Name = 'Example CLI' })
            MaturityBlockedUpdates = @()
        }

        Merge-ParallelCheckResult -CheckResult $checkResult

        $results.Tools['Example CLI'].Installed | Should Be '1.0.0'
        (Get-ToolState 'dotnet-sdk').ContainsKey('10.0.100') | Should Be $true
        $results.Updates[0] | Should Be 'Example CLI'
        $results.AvailableUpdates[0].Name | Should Be 'Example CLI'
        (Get-ToolState 'npm-global-packages').UpdateCommand | Should Be 'npm update command'
    }

    It 'runs and merges a network-free check through the runspace pool' {
        $results.Tools = @{}
        $results.ToolState['dotnet-sdk'] = @{}
        $results.NotInstalled = @()
        $results.Updates = @()
        $results.Errors = @()
        $results.UpdateFailed = @()
        $results.AvailableUpdates = @()
        $results.MaturityBlockedUpdates = @()
        (Get-ToolState 'npm-global-packages').Packages = @()
        (Get-ToolState 'npm-global-packages').UpdateCommand = 'ncu -g -u --loglevel=error'
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

Describe 'Cooldown configuration' {
    BeforeEach {
        $cooldownDirectory = Join-Path $TestDrive 'cooldown-catalog'
        New-Item -ItemType Directory -Path $cooldownDirectory -Force | Out-Null
        Copy-Item -LiteralPath $scriptPath -Destination $cooldownDirectory
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scriptPath) 'infra') -Destination $cooldownDirectory -Recurse -Force
        $cooldownCatalog = Get-Content (Join-Path (Split-Path -Parent $scriptPath) 'tool-checker.json') -Raw | ConvertFrom-Json -AsHashtable
        $cooldownCatalog.tools = @{ git = $cooldownCatalog.tools.git }
        $cooldownCatalog.tools.git.PackageManagerFiles = @('npm.ps1')
    }

    It 'uses catalog <CatalogDays> and runtime <OverrideDays> consistently in the main session and workers' -TestCases @(
        @{ CatalogDays = 8; OverrideDays = $null; ExpectedDays = 8; ExpectedInstallable = $false },
        @{ CatalogDays = 12; OverrideDays = $null; ExpectedDays = 12; ExpectedInstallable = $false },
        @{ CatalogDays = 8; OverrideDays = 2; ExpectedDays = 2; ExpectedInstallable = $true },
        @{ CatalogDays = 8; OverrideDays = 0; ExpectedDays = 0; ExpectedInstallable = $true }
    ) {
        param($CatalogDays, $OverrideDays, $ExpectedDays, $ExpectedInstallable)

        $cooldownCatalog.settings.CooldownDays = $CatalogDays
        $cooldownCatalog | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $cooldownDirectory 'tool-checker.json')
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile, $overrideDays)
                $options = @{ EnvFile = $envFile }
                if ($null -ne $overrideDays) { $options.CooldownDays = $overrideDays }
                . $path @options
                $check = {
                    $apiData = [PSCustomObject]@{
                        versions = [PSCustomObject]@{ '1.1.0' = @{} }
                        time = [PSCustomObject]@{ '1.1.0' = [DateTimeOffset]::UtcNow.AddDays(-3).ToString('O') }
                    }
                    $release = Get-LatestMatureNpmRelease -ApiData $apiData -MinimumVersion '1.0.0' -MaximumVersion '1.1.0'
                    $results.Tools['Cooldown probe'] = @{
                        Days = $script:ReleaseCooldownDays
                        Installable = $null -ne $release -and $release.Installable
                    }
                }
                & $check
                $mainResult = $results.Tools['Cooldown probe']
                $results = New-ToolCheckResults
                Invoke-ParallelChecks -Checks @(@{ Name = 'Cooldown probe'; Block = $check }) -Total 1 -TimeoutSec 5
                [PSCustomObject]@{
                    Main = $mainResult
                    Worker = $results.Tools['Cooldown probe']
                }
            }).AddArgument((Join-Path $cooldownDirectory 'tool-checker.ps1')).AddArgument($testEnvFile).AddArgument($OverrideDays)
            $observed = @($session.Invoke())

            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].Main.Days | Should Be $ExpectedDays
            $observed[0].Worker.Days | Should Be $ExpectedDays
            $observed[0].Main.Installable | Should Be $ExpectedInstallable
            $observed[0].Worker.Installable | Should Be $ExpectedInstallable
        } finally {
            $session.Dispose()
        }
    }

    It 'rejects missing and invalid catalog cooldown values' {
        foreach ($invalidValue in @($null, -1, 1.5, '8', $true, 2147483648)) {
            $cooldownCatalog.settings = @{ CooldownDays = $invalidValue }
            if ($null -eq $invalidValue) { $cooldownCatalog.Remove('settings') | Out-Null }
            $cooldownCatalog | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $cooldownDirectory 'tool-checker.json')
            $session = [powershell]::Create()
            try {
                $null = $session.AddScript({
                    param($path, $envFile)
                    try { . $path -EnvFile $envFile } catch { $_.Exception.Message }
                }).AddArgument((Join-Path $cooldownDirectory 'tool-checker.ps1')).AddArgument($testEnvFile)
                $observed = @($session.Invoke())

                $observed.Count | Should Be 1
                $observed[0] | Should Match 'Catalog settings.CooldownDays must be a nonnegative integer'
            } finally {
                $session.Dispose()
            }
        }
    }

    It 'rejects a negative runtime override' {
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path)
                try { . $path -CooldownDays -1 -Version } catch { $_.FullyQualifiedErrorId }
            }).AddArgument($scriptPath)
            $observed = @($session.Invoke())

            $observed.Count | Should Be 1
            $observed[0] | Should Match 'ParameterArgumentValidationError'
        } finally {
            $session.Dispose()
        }
    }
}
