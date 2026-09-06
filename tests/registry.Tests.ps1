$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tool-checker.ps1'
$registryPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Infra/registry.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) "registry-tests-$([guid]::NewGuid()).env")

Describe 'Registry infrastructure' {
    BeforeEach {
        $results = New-ToolCheckResults
        $SkipUpdate = $false
        Mock Invoke-RegistryCommand { throw 'Unexpected external registry command' }
    }

    It 'contains only function definitions and loads them from the infrastructure file' {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($registryPath, [ref]$null, [ref]$parseErrors)
        $parseErrors.Count | Should Be 0
        @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] }).Count | Should Be 0
        $ast.EndBlock.Statements.Count | Should Be 13
        (Get-Command Test-RegistryConfiguration).ScriptBlock.File | Should Be $registryPath
        (Get-Command Set-NpmRegistryApiUrls).ScriptBlock.File | Should Be $registryPath
        Assert-MockCalled Invoke-RegistryCommand 0 -Scope It
    }

    It 'loads registry infrastructure independently of selected tool files' {
        $selectionFile = Join-Path $TestDrive 'git.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=git'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($mainPath, $envPath)
                . $mainPath -EnvFile $envPath
                [PSCustomObject]@{
                    ToolFiles = $script:ToolDefinitions.Count
                    RegistryFile = (Get-Command Set-RegistryConfiguration).ScriptBlock.File
                }
            }).AddArgument($scriptPath).AddArgument($selectionFile)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed[0].ToolFiles | Should Be 0
            $observed[0].RegistryFile | Should Be $registryPath
        } finally {
            $session.Dispose()
        }
    }

    It 'reports all configured backends without repairing them' {
        Mock Test-CommandExists { $true }
        Mock Invoke-RegistryCommand { [PSCustomObject]@{ Output = 'https://old.example'; ExitCode = 0 } }
        Mock Get-PythonCommand { [PSCustomObject]@{ Command = 'py'; Prefix = @('-V:3', '-m', 'pip') } }
        Mock Get-UvDefaultIndex { 'https://old.example' }
        Mock Get-NuGetSource { [PSCustomObject]@{ Url = 'https://old.example'; Enabled = $true } }
        Mock Set-RegistryConfiguration { throw 'Checks must not repair' }

        Test-RegistryConfiguration -EnvironmentConfig @{
            NPM_CONFIG_REGISTRY = 'https://new.example'
            PNPM_CONFIG_REGISTRY = 'https://new.example'
            PIP_INDEX_URL = 'https://new.example'
            UV_DEFAULT_INDEX = 'https://new.example'
            NUGET_SOURCE_URL = 'https://new.example'
        }

        $results.RegistryChecks.Count | Should Be 5
        @($results.RegistryChecks | Where-Object Status -EQ 'Misaligned').Count | Should Be 5
        @(Get-AvailableActions -RegistryOnly).Count | Should Be 5
        Assert-MockCalled Set-RegistryConfiguration 0 -Scope It
    }

    It 'reports check-only drift without offering alignment' {
        $SkipUpdate = $true
        Add-RegistryCheck -Key npm -Name npm -Current 'https://old.example' -Expected 'https://new.example'
        $results.RegistryChecks[0].Status | Should Be 'Misaligned'
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'normalizes aligned URLs and redacts credentials from repair details' {
        Add-RegistryCheck -Key npm -Name npm -Current ' https://example.test/ ' -Expected 'https://example.test'
        $results.RegistryChecks[0].Status | Should Be 'Aligned'
        Add-RegistryCheck -Key pnpm -Name pnpm -Current 'https://user:old-secret@old.example' -Expected 'https://user:new-secret@new.example'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Details | Should Not Match 'old-secret|new-secret'
    }

    It 'does not offer repairs for unavailable tools' {
        Mock Test-CommandExists { $false }
        Test-RegistryConfiguration -EnvironmentConfig @{ NPM_CONFIG_REGISTRY = 'https://new.example' }
        $results.RegistryChecks[0].Status | Should Be 'Unavailable'
        $results.AvailableUpdates.Count | Should Be 0
        Assert-MockCalled Invoke-RegistryCommand 0 -Scope It
    }
}

Describe 'Approved registry repairs' {
    BeforeEach {
        $results = New-ToolCheckResults
        Mock Invoke-RegistryCommand { throw 'Unexpected external registry command' }
    }

    It 'dispatches an approved npm repair with the policy URL and user scope' {
        $script:RegistryEnvironment = @{ NPM_CONFIG_REGISTRY = 'https://new.example' }
        Mock Invoke-RegistryCommand { [PSCustomObject]@{ Output = 'aligned'; ExitCode = 0 } }
        $execution = Invoke-ActionCommand -Action @{ Type = 'registry'; RegistryKey = 'npm' }
        $execution.ExitCode | Should Be 0
        Assert-MockCalled Invoke-RegistryCommand 1 -Exactly -Scope It -ParameterFilter {
            $Command -eq 'npm' -and ($Arguments -join ' ') -eq 'config set registry https://new.example --location=user'
        }
    }

    It 'uses global scope for an approved pnpm repair' {
        Mock Invoke-RegistryCommand { [PSCustomObject]@{ Output = 'aligned'; ExitCode = 0 } }
        Set-RegistryConfiguration -RegistryKey pnpm -EnvironmentConfig @{ PNPM_CONFIG_REGISTRY = 'https://new.example' } | Out-Null
        Assert-MockCalled Invoke-RegistryCommand 1 -Exactly -Scope It -ParameterFilter {
            $Command -eq 'pnpm' -and ($Arguments -join ' ') -eq 'config set registry https://new.example --location=global'
        }
    }

    It 'uses the selected interpreter for an approved pip repair' {
        Mock Get-PythonCommand { [PSCustomObject]@{ Command = 'py'; Prefix = @('-V:3', '-m', 'pip') } }
        Mock Invoke-RegistryCommand { [PSCustomObject]@{ Output = 'aligned'; ExitCode = 0 } }
        Set-RegistryConfiguration -RegistryKey pip -EnvironmentConfig @{ PIP_INDEX_URL = 'https://new.example' } | Out-Null
        Assert-MockCalled Invoke-RegistryCommand 1 -Exactly -Scope It -ParameterFilter {
            $Command -eq 'py' -and ($Arguments -join ' ') -eq '-V:3 -m pip config --user set global.index-url https://new.example'
        }
    }

    It 'repairs uv only in an isolated test configuration file' {
        $uvPath = Join-Path $TestDrive 'uv/uv.toml'
        Mock Get-UvUserConfigPath { $uvPath }
        $execution = Set-RegistryConfiguration -RegistryKey uv -EnvironmentConfig @{ UV_DEFAULT_INDEX = 'https://new.example/simple' }
        $execution.ExitCode | Should Be 0
        Get-UvDefaultIndex | Should Be 'https://new.example/simple'
        Assert-MockCalled Invoke-RegistryCommand 0 -Scope It
    }

    It 'updates and enables an existing NuGet source' {
        Mock Get-NuGetSource { [PSCustomObject]@{ Url = 'https://old.example'; Enabled = $false } }
        Mock Invoke-RegistryCommand { [PSCustomObject]@{ Output = 'aligned'; ExitCode = 0 } }
        Set-RegistryConfiguration -RegistryKey nuget -EnvironmentConfig @{ NUGET_SOURCE_URL = 'https://new.example' } | Out-Null
        Assert-MockCalled Invoke-RegistryCommand 1 -Exactly -Scope It -ParameterFilter {
            $Command -eq 'dotnet' -and ($Arguments -join ' ') -eq 'nuget update source nuget.org --source https://new.example'
        }
        Assert-MockCalled Invoke-RegistryCommand 1 -Exactly -Scope It -ParameterFilter {
            $Command -eq 'dotnet' -and ($Arguments -join ' ') -eq 'nuget enable source nuget.org'
        }
    }

    It 'stops a NuGet repair when the source write fails' {
        Mock Get-NuGetSource { $null }
        Mock Invoke-RegistryCommand { [PSCustomObject]@{ Output = 'denied'; ExitCode = 1 } }
        (Set-RegistryConfiguration -RegistryKey nuget -EnvironmentConfig @{ NUGET_SOURCE_URL = 'https://new.example' }).ExitCode | Should Be 1
        Assert-MockCalled Invoke-RegistryCommand 1 -Exactly -Scope It
        Assert-MockCalled Invoke-RegistryCommand 0 -Scope It -ParameterFilter { $Arguments -contains 'enable' }
    }
}

Describe 'Registry endpoint resolution' {
    function npm { throw 'Unexpected real npm invocation' }

    BeforeEach {
        $script:NpmRegistryResolution = @{ Source = 'tool-checker.json'; Url = $null; Details = $null }
        $toolsConfig = [ordered]@{
            Example = @{ VersionExtractor = 'npmDistTagLatest'; NpmPackageName = '@example/cli'; ApiUrl = 'https://registry.npmjs.org/%40example%2Fcli' }
            Other = @{ ApiUrl = 'https://other.example/releases' }
        }
        $LASTEXITCODE = 0
        Mock Test-CommandExists { $true }
    }

    It 'resolves npm metadata URLs with encoded package names' {
        Mock npm { 'https://packages.example/npm/' }
        Set-NpmRegistryApiUrls
        $toolsConfig.Example.ApiUrl | Should Be 'https://packages.example/npm/%40example%2Fcli'
        $toolsConfig.Other.ApiUrl | Should Be 'https://other.example/releases'
        $script:NpmRegistryResolution.Source | Should Be 'npm machine/user configuration'
    }

    It 'retains catalog endpoints when npm is absent' {
        Mock Test-CommandExists { $false }
        Set-NpmRegistryApiUrls
        $toolsConfig.Example.ApiUrl | Should Be 'https://registry.npmjs.org/%40example%2Fcli'
        $script:NpmRegistryResolution.Url | Should Be 'https://registry.npmjs.org'
        $script:NpmRegistryResolution.Details | Should Match 'npm was not found'
    }

    It 'retains catalog endpoints when npm returns an invalid URL' {
        Mock npm { 'not-a-url' }
        Set-NpmRegistryApiUrls
        $toolsConfig.Example.ApiUrl | Should Be 'https://registry.npmjs.org/%40example%2Fcli'
        $script:NpmRegistryResolution.Details | Should Match 'invalid registry URL'
    }
}