# Configuration loading/snapshot contracts using temporary catalog and env fixtures.
# Isolated sessions verify that readers do not load tools or replace caller state.
$repositoryPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repositoryPath 'tool-checker.ps1'
$configurationPath = Join-Path $repositoryPath 'infra/configuration.ps1'
$testEnvFile = Join-Path ([System.IO.Path]::GetTempPath()) "configuration-tests-$([guid]::NewGuid()).env"
. $scriptPath -EnvFile $testEnvFile
$toolsJson = Get-Content (Join-Path $repositoryPath 'tool-checker.json') -Raw | ConvertFrom-Json

Describe 'Configuration infrastructure' {
    It 'defines functions only and loads each from the configuration file' {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($configurationPath, [ref]$null, [ref]$parseErrors)
        $parseErrors.Count | Should Be 0
        @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] }).Count | Should Be 0
        $ast.EndBlock.Statements.Count | Should Be 7
        foreach ($definition in $ast.EndBlock.Statements) {
            (Get-Command $definition.Name).ScriptBlock.File | Should Be $configurationPath
        }
        @(& { . $configurationPath } *>&1).Count | Should Be 0
    }

    It 'fails clearly for missing <Infrastructure> infrastructure while Version remains independent' -TestCases @(
        @{ Infrastructure = 'configuration' }
        @{ Infrastructure = 'output' }
        @{ Infrastructure = 'results' }
        @{ Infrastructure = 'runtime' }
        @{ Infrastructure = 'versions' }
        @{ Infrastructure = 'checks' }
        @{ Infrastructure = 'actions' }
        @{ Infrastructure = 'parallel' }
        @{ Infrastructure = 'package-managers' }
        @{ Infrastructure = 'registry' }
    ) {
        param($Infrastructure)

        $appRoot = Join-Path $TestDrive "missing-$Infrastructure"
        $null = New-Item -ItemType Directory -Path $appRoot
        Copy-Item $scriptPath -Destination $appRoot
        Copy-Item (Join-Path (Split-Path $scriptPath) 'infra') -Destination $appRoot -Recurse
        $missingPath = Join-Path $appRoot "infra/$Infrastructure.ps1"
        Remove-Item -LiteralPath $missingPath
        $copiedScript = Join-Path $appRoot 'tool-checker.ps1'
        $message = try {
            & { . $copiedScript -EnvFile (Join-Path $appRoot 'missing.env') }
        } catch { $_.Exception.Message }
        $label = (Get-Culture).TextInfo.ToTitleCase($Infrastructure)
        $loadedScriptRoot = Split-Path (Get-Command -Name $copiedScript).ScriptBlock.File
        $expectedPath = Join-Path $loadedScriptRoot "infra/$Infrastructure.ps1"
        $message | Should Be "$label infrastructure file not found: $expectedPath"
        (& $copiedScript -Version) | Should Be $script:ToolCheckerVersion
    }

    It 'ships the lookup helper to workers without configuration readers or startup validation' {
        $functionBlock = Get-ParallelCheckFunctionBlock
        $functionBlock | Should Match 'function Get-ToolConfiguration'
        $functionBlock | Should Not Match 'function Read-ToolCheckerConfiguration|function Read-DotEnvFile|function Get-ToolCatalogSelection|function Assert-ToolConfigurations|function Get-ToolSortKey'
    }
}

Describe 'Configuration snapshots' {
    BeforeEach {
        $fixtureCatalog = Join-Path $TestDrive 'catalog.json'
        $fixtureEnv = Join-Path $TestDrive 'selection.env'
        $catalog = [ordered]@{
            settings = @{ CooldownDays = 8 }
            tools = [ordered]@{
                zulu = @{ Name = 'Zulu CLI'; ToolFile = 'missing.ps1'; Enabled = $false; ProductionReleasesOnly = $false }
                alpha = @{ Name = 'Alpha CLI'; InstallCommands = [ordered]@{ 'Windows (amd64)' = 'install alpha'; Linux = 'install-alpha' } }
            }
        }
        $catalog | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixtureCatalog
        Set-Content -LiteralPath $fixtureEnv -Value ''
    }

    It 'reads configuration standalone without loading the main script or tool definitions' {
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($infraPath, $catalogPath, $envPath)
                . $infraPath
                Read-ToolCheckerConfiguration -ConfigPath $catalogPath -EnvFile $envPath
            }).AddArgument($configurationPath).AddArgument($fixtureCatalog).AddArgument($fixtureEnv)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].ToolsConfiguration.Count | Should Be 2
            $observed[0].CooldownDays | Should Be 8
        } finally {
            $session.Dispose()
        }
    }

    It 'applies defaults while retaining explicit false values and ordered install commands' {
        $snapshot = Read-ToolCheckerConfiguration -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv
        ($snapshot.ToolsConfiguration.Keys -join ',') | Should Be 'Alpha CLI,Zulu CLI'
        $snapshot.ToolsConfiguration['Alpha CLI'].Id | Should Be 'alpha'
        $snapshot.ToolsConfiguration['Alpha CLI'].Enabled | Should Be $true
        $snapshot.ToolsConfiguration['Alpha CLI'].ProductionReleasesOnly | Should Be $true
        $snapshot.ToolsConfiguration['Zulu CLI'].Enabled | Should Be $false
        $snapshot.ToolsConfiguration['Zulu CLI'].ProductionReleasesOnly | Should Be $false
        ($snapshot.ToolsConfiguration['Alpha CLI'].InstallCommands -is [System.Collections.Specialized.OrderedDictionary]) | Should Be $true
        ($snapshot.ToolsConfiguration['Alpha CLI'].InstallCommands.Keys -join ',') | Should Be 'Windows (amd64),Linux'
    }

    It 'normalizes and deduplicates selection while retaining the complete catalog ID count' {
        Set-Content -LiteralPath $fixtureEnv -Value 'TOOL_CHECKER_TOOLS= ALPHA,alpha, , '
        $snapshot = Read-ToolCheckerConfiguration -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv
        $snapshot.ToolsConfiguration.Count | Should Be 1
        $snapshot.ToolsConfiguration.Contains('Alpha CLI') | Should Be $true
        $snapshot.CatalogToolIds.Count | Should Be 2
    }

    It 'preserves dotenv quoting export comments and last-value behavior' {
        Set-Content -LiteralPath $fixtureEnv -Value @(
            '# ignored comment'
            'export TOOL_CHECKER_TOOLS="alpha"'
            'EXAMPLE=old'
            "EXAMPLE='value # retained'"
            'UNQUOTED=value # ignored'
            'EMPTY='
            'not an assignment'
        )
        $snapshot = Read-ToolCheckerConfiguration -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv
        $snapshot.RegistryEnvironment.EXAMPLE | Should Be 'value # retained'
        $snapshot.RegistryEnvironment.UNQUOTED | Should Be 'value'
        $snapshot.RegistryEnvironment.EMPTY | Should Be ''
        $snapshot.RegistryEnvironment.Count | Should Be 4
        $snapshot.ToolsConfiguration.Count | Should Be 1
    }

    It 'uses the catalog default unless a runtime override is explicitly supplied including zero' {
        (Read-ToolCheckerConfiguration -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv -CooldownDays 0).CooldownDays | Should Be 8
        (Read-ToolCheckerConfiguration -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv -HasCooldownOverride $true -CooldownDays 0).CooldownDays | Should Be 0
        (Read-ToolCheckerConfiguration -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv -HasCooldownOverride $true -CooldownDays 12).CooldownDays | Should Be 12
    }

    It 'still rejects invalid catalog cooldowns when an override is supplied' {
        $catalog.settings.CooldownDays = 'invalid'
        $catalog | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixtureCatalog
        { Read-ToolCheckerConfiguration -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv -HasCooldownOverride $true -CooldownDays 0 } | Should Throw 'Catalog settings.CooldownDays'
    }

    It 'accepts a missing optional env file and resolves relative paths from the caller location' {
        Push-Location $TestDrive
        try {
            $snapshot = Read-ToolCheckerConfiguration -ConfigPath $fixtureCatalog -EnvFile 'missing.env'
            $snapshot.ResolvedEnvFile | Should Be (Join-Path (Get-Location).Path 'missing.env')
            $snapshot.RegistryEnvironment.Count | Should Be 0
            $snapshot.ToolsConfiguration.Count | Should Be 2
        } finally {
            Pop-Location
        }
    }

    It 'does not replace shared state or load tool definitions when reading another snapshot' {
        $beforeTools = ConvertTo-Json $toolsConfig -Depth 10 -Compress
        $beforeEnvironment = ConvertTo-Json $script:RegistryEnvironment -Depth 10 -Compress
        $beforeDefinitions = ConvertTo-Json $script:ToolDefinitions -Depth 5 -Compress
        $beforeCooldown = $script:ReleaseCooldownDays
        $null = Read-ToolCheckerConfiguration -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv -HasCooldownOverride $true -CooldownDays 3
        (ConvertTo-Json $toolsConfig -Depth 10 -Compress) | Should Be $beforeTools
        (ConvertTo-Json $script:RegistryEnvironment -Depth 10 -Compress) | Should Be $beforeEnvironment
        (ConvertTo-Json $script:ToolDefinitions -Depth 5 -Compress) | Should Be $beforeDefinitions
        $script:ReleaseCooldownDays | Should Be $beforeCooldown
    }
}

Describe 'Interactive environment setup' {
    BeforeEach {
        $fixtureCatalog = Join-Path $TestDrive 'setup-catalog.json'
        $fixtureEnv = Join-Path $TestDrive 'setup.env'
        $fixtureTemplate = Join-Path $TestDrive '.env.example'
        Remove-Item -LiteralPath $fixtureEnv -Force -ErrorAction SilentlyContinue
        [ordered]@{
            settings = @{ CooldownDays = 8 }
            tools = [ordered]@{
                zulu = @{ Name = 'Zulu CLI'; enabled = $true }
                disabled = @{ Name = 'Disabled CLI'; enabled = $false }
                alpha = @{ Name = 'Alpha CLI'; enabled = $true }
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fixtureCatalog
        Set-Content -LiteralPath $fixtureTemplate -Value @(
            '# Tool selection'
            '# TOOL_CHECKER_TOOLS=alpha,zulu'
            ''
            '# npm user registry'
            '# NPM_CONFIG_REGISTRY=https://registry.npmjs.org/'
        )
    }

    It 'creates the environment from the template with all enabled tools when the user presses Enter' {
        Mock Read-Host { '' }

        $completed = Initialize-ToolCheckerEnvironment -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv -TemplatePath $fixtureTemplate

        $completed | Should Be $true
        $environmentContent = Get-Content -LiteralPath $fixtureEnv -Raw
        $environmentContent | Should Match '(?m)^TOOL_CHECKER_TOOLS=alpha,zulu$'
        $environmentContent | Should Match '# npm user registry'
        $environmentContent | Should Match '# NPM_CONFIG_REGISTRY=https://registry.npmjs.org/'
        Assert-MockCalled Read-Host 1 -Scope It
    }

    It 'writes the selected tools and retries invalid input' {
        $script:responses = [System.Collections.Queue]::new()
        $script:responses.Enqueue('999999999999999999999999')
        $script:responses.Enqueue('2,1,2')
        Mock Read-Host { $script:responses.Dequeue() }

        $completed = Initialize-ToolCheckerEnvironment -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv -TemplatePath $fixtureTemplate

        $completed | Should Be $true
        (Get-Content -LiteralPath $fixtureEnv -Raw) | Should Match '(?m)^TOOL_CHECKER_TOOLS=zulu,alpha$'
        Assert-MockCalled Read-Host 2 -Scope It
    }

    It 'returns false without creating an environment file when the user selects zero' {
        Mock Read-Host { '0' }

        $completed = Initialize-ToolCheckerEnvironment -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv -TemplatePath $fixtureTemplate

        $completed | Should Be $false
        Test-Path -LiteralPath $fixtureEnv | Should Be $false
        Assert-MockCalled Read-Host 1 -Scope It
    }

    It 'fails clearly when the environment template is missing' {
        Mock Read-Host { throw 'Setup must validate its template before prompting.' }

        { Initialize-ToolCheckerEnvironment -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv -TemplatePath (Join-Path $TestDrive 'missing.example') } |
            Should Throw 'Environment template file not found'
        Assert-MockCalled Read-Host 0 -Scope It
    }
}

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
        $config = Get-ToolConfiguration -ToolName 'NodeJS' -RequiredProperties @('ToolFile', 'Command')

        $config.ToolFile | Should Be 'nodejs.ps1'
        $config.Command | Should Be 'node'
    }

    It 'rejects an unknown tool' {
        { Get-ToolConfiguration -ToolName 'Missing Tool' } | Should Throw 'Tool configuration not found: Missing Tool'
    }

    It 'rejects a missing required property' {
        { Get-ToolConfiguration -ToolName 'Azure CLI Extensions' -RequiredProperties @('ApiUrl') } |
            Should Throw "Tool 'Azure CLI Extensions' requires configuration property 'ApiUrl'."
    }

    It 'resolves every configured custom checker' {
        { Assert-ToolConfigurations } | Should Not Throw
    }

    It 'rejects a custom tool without a declared tool file' {
        $toolsConfig['Broken Custom Tool'] = @{
            Enabled = $true
            CheckType = 'custom'
            UpdateType = 'direct'
            UpdateCommand = 'broken update'
        }
        try {
            { Assert-ToolConfigurations } |
                Should Throw "Tool 'Broken Custom Tool' requires configuration property 'ToolFile'."
        } finally {
            $toolsConfig.Remove('Broken Custom Tool')
        }
    }

    It 'rejects a custom tool whose file does not define the checker and ignores a retired CustomFunction value' {
        $toolsConfig['Broken Custom Tool'] = @{
            Id = 'uv'
            Enabled = $true
            CheckType = 'custom'
            CustomFunction = 'Get-Date'
            ToolFile = 'uv.ps1'
            UpdateType = 'direct'
            UpdateCommand = 'broken update'
        }
        try {
            { Assert-ToolConfigurations } |
                Should Throw "Custom tool 'Broken Custom Tool' requires its ToolFile to define Test-Tool."
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