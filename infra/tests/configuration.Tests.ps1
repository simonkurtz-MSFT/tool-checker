# Configuration loading/snapshot contracts using temporary catalog and env fixtures.
# Isolated sessions verify that readers do not load tools or replace caller state.
$repositoryPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repositoryPath 'tool-checker.ps1'
$configurationPath = Join-Path $repositoryPath 'infra/configuration.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) "configuration-tests-$([guid]::NewGuid()).env")

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
        $functionBlock = Get-ParallelCheckFunctionBlock -ScriptContent (Get-Content $scriptPath -Raw) -ToolsConfiguration @{}
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