$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tool-checker.ps1'
$configurationPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Infra/configuration.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) "configuration-tests-$([guid]::NewGuid()).env")

Describe 'Configuration infrastructure' {
    It 'defines functions only and loads each from the configuration file' {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($configurationPath, [ref]$null, [ref]$parseErrors)
        $parseErrors.Count | Should Be 0
        @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] }).Count | Should Be 0
        $ast.EndBlock.Statements.Count | Should Be 6
        foreach ($definition in $ast.EndBlock.Statements) {
            (Get-Command $definition.Name).ScriptBlock.File | Should Be $configurationPath
        }
        @(& { . $configurationPath } *>&1).Count | Should Be 0
    }

    It 'fails clearly for missing infrastructure while Version remains independent' {
        $appRoot = Join-Path $TestDrive 'missing-configuration'
        $null = New-Item -ItemType Directory -Path $appRoot
        Copy-Item $scriptPath -Destination $appRoot
        $copiedScript = Join-Path $appRoot 'tool-checker.ps1'
        { . $copiedScript -EnvFile (Join-Path $appRoot 'missing.env') } | Should Throw 'Configuration infrastructure file not found'
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
        $beforeCooldown = $script:NpmUpdateCooldownDays
        $null = Read-ToolCheckerConfiguration -ConfigPath $fixtureCatalog -EnvFile $fixtureEnv -HasCooldownOverride $true -CooldownDays 3
        (ConvertTo-Json $toolsConfig -Depth 10 -Compress) | Should Be $beforeTools
        (ConvertTo-Json $script:RegistryEnvironment -Depth 10 -Compress) | Should Be $beforeEnvironment
        (ConvertTo-Json $script:ToolDefinitions -Depth 5 -Compress) | Should Be $beforeDefinitions
        $script:NpmUpdateCooldownDays | Should Be $beforeCooldown
    }
}