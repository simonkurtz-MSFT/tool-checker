# Validate catalog authoring rules without running checks, loading tool files, or accessing the network.
$repositoryPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$schemaPath = Join-Path $repositoryPath 'tool-checker.schema.json'
$catalogPath = Join-Path $repositoryPath 'tool-checker.json'

Describe 'Catalog JSON Schema' {
    BeforeEach {
        $catalog = @{
            settings = @{ CooldownDays = 8 }
            tools = @{
                example = @{
                    Name = 'Example CLI'
                    CheckType = 'standard'
                    Command = 'example'
                    VersionFlag = '--version'
                    ApiUrl = 'https://example.com/releases/latest'
                    UpdateType = 'direct'
                    UpdateCommand = 'example update --version {latest}'
                }
            }
        }
    }

    It 'associates the shipped catalog with a local schema and validates every entry' {
        $json = Get-Content -LiteralPath $catalogPath -Raw
        ($json | ConvertFrom-Json).'$schema' | Should Be './tool-checker.schema.json'
        $json | Test-Json -SchemaFile $schemaPath -ErrorAction Stop | Should Be $true
    }

    It 'accepts <Name>' -TestCases @(
        @{ Name = 'omitted enabled and production defaults'; Change = { param($catalog) } },
        @{ Name = 'zero cooldown'; Change = { param($catalog) $catalog.settings.CooldownDays = 0 } },
        @{ Name = 'maximum cooldown'; Change = { param($catalog) $catalog.settings.CooldownDays = 2147483647 } },
        @{ Name = 'an upstream informational release endpoint'; Change = { param($catalog) $catalog.tools.example.LatestReleaseApiUrl = 'https://api.github.com/repos/example/cli/releases/latest' } },
        @{ Name = 'an explicit version command'; Change = { param($catalog) $catalog.tools.example.Remove('VersionFlag'); $catalog.tools.example.VersionCommand = 'example version --json' } },
        @{ Name = 'a custom checker without standard-only fields'; Change = { param($catalog) $catalog.tools.example = @{ Name = 'Custom'; CheckType = 'custom'; ToolFile = 'different.filename.ps1'; UpdateType = 'custom'; UpdateCommand = 'custom update'; ReleaseNotesUrl = '' } } },
        @{ Name = 'a disabled entry without runnable configuration'; Change = { param($catalog) $catalog.tools.example = @{ Name = 'Disabled'; enabled = $false } } },
        @{ Name = 'package managers and platform-specific action metadata'; Change = {
            param($catalog)
            $catalog.tools.example.PackageManagerFiles = @('npm.ps1')
            $catalog.tools.example.WindowsPackageManagerFiles = @('winget.ps1')
            $catalog.tools.example.ReleasePackageManager = 'npm.ps1'
            $catalog.tools.example.InstallationsPackageManager = 'npm.ps1'
            $catalog.tools.example.WindowsInstallationsPackageManager = 'npm.ps1'
            $catalog.tools.example.WindowsInstalledVersionPackageManager = 'winget.ps1'
            $catalog.tools.example.WindowsUpdateExecutor = 'tool'
            $catalog.tools.example.WindowsUpdateEntryPoint = 'Invoke-ToolInstall'
            $catalog.tools.example.WindowsUpdateExecutionMode = 'CurrentSession'
            $catalog.tools.example.WindowsUpdateOutcomePackageManager = 'winget.ps1'
            $catalog.tools.example.ToolFile = 'example.ps1'
        } }
    ) {
        param($Name, $Change)
        & $Change $catalog
        $catalog | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop | Should Be $true
    }

    It 'rejects <Name>' -TestCases @(
        @{ Name = 'unknown root properties'; Change = { param($catalog) $catalog.setting = @{} } },
        @{ Name = 'missing settings'; Change = { param($catalog) $catalog.Remove('settings') } },
        @{ Name = 'missing tools'; Change = { param($catalog) $catalog.Remove('tools') } },
        @{ Name = 'missing cooldown'; Change = { param($catalog) $catalog.settings.Remove('CooldownDays') } },
        @{ Name = 'negative cooldown'; Change = { param($catalog) $catalog.settings.CooldownDays = -1 } },
        @{ Name = 'fractional cooldown'; Change = { param($catalog) $catalog.settings.CooldownDays = 1.5 } },
        @{ Name = 'string cooldown'; Change = { param($catalog) $catalog.settings.CooldownDays = '8' } },
        @{ Name = 'out-of-range cooldown'; Change = { param($catalog) $catalog.settings.CooldownDays = 2147483648 } },
        @{ Name = 'unknown settings'; Change = { param($catalog) $catalog.settings.CooldownDay = 8 } },
        @{ Name = 'invalid catalog IDs'; Change = { param($catalog) $catalog.tools['Bad_ID'] = $catalog.tools.example; $catalog.tools.Remove('example') } },
        @{ Name = 'missing display name'; Change = { param($catalog) $catalog.tools.example.Remove('Name') } },
        @{ Name = 'blank display name'; Change = { param($catalog) $catalog.tools.example.Name = '  ' } },
        @{ Name = 'misspelled tool properties'; Change = { param($catalog) $catalog.tools.example.UpdateComand = 'typo' } },
        @{ Name = 'string booleans'; Change = { param($catalog) $catalog.tools.example.enabled = 'false' } },
        @{ Name = 'missing check type'; Change = { param($catalog) $catalog.tools.example.Remove('CheckType') } },
        @{ Name = 'unsupported check type'; Change = { param($catalog) $catalog.tools.example.CheckType = 'other' } },
        @{ Name = 'missing standard command'; Change = { param($catalog) $catalog.tools.example.Remove('Command') } },
        @{ Name = 'missing standard API URL'; Change = { param($catalog) $catalog.tools.example.Remove('ApiUrl') } },
        @{ Name = 'an empty upstream release endpoint'; Change = { param($catalog) $catalog.tools.example.LatestReleaseApiUrl = '' } },
        @{ Name = 'an invalid upstream release endpoint'; Change = { param($catalog) $catalog.tools.example.LatestReleaseApiUrl = 42 } },
        @{ Name = 'missing version command forms'; Change = { param($catalog) $catalog.tools.example.Remove('VersionFlag') } },
        @{ Name = 'missing update command'; Change = { param($catalog) $catalog.tools.example.Remove('UpdateCommand') } },
        @{ Name = 'blank update command'; Change = { param($catalog) $catalog.tools.example.UpdateCommand = ' ' } },
        @{ Name = 'missing update type'; Change = { param($catalog) $catalog.tools.example.Remove('UpdateType') } },
        @{ Name = 'a custom check without a tool file'; Change = { param($catalog) $catalog.tools.example.CheckType = 'custom' } },
        @{ Name = 'the retired CustomFunction property'; Change = { param($catalog) $catalog.tools.example.CheckType = 'custom'; $catalog.tools.example.CustomFunction = 'Test-Tool'; $catalog.tools.example.ToolFile = 'example.ps1' } },
        @{ Name = 'JSON extraction without its property'; Change = { param($catalog) $catalog.tools.example.VersionExtractor = 'jsonProperty' } },
        @{ Name = 'unsupported version extractor'; Change = { param($catalog) $catalog.tools.example.VersionExtractor = 'magic' } },
        @{ Name = 'tool file paths'; Change = { param($catalog) $catalog.tools.example.ToolFile = '../example.ps1' } },
        @{ Name = 'the tool template'; Change = { param($catalog) $catalog.tools.example.ToolFile = '_tool-template.ps1' } },
        @{ Name = 'non-PowerShell tool files'; Change = { param($catalog) $catalog.tools.example.ToolFile = 'example.cmd' } },
        @{ Name = 'package manager paths'; Change = { param($catalog) $catalog.tools.example.PackageManagerFiles = @('infra/npm.ps1') } },
        @{ Name = 'installation discovery paths'; Change = { param($catalog) $catalog.tools.example.InstallationsPackageManager = '../npm.ps1' } },
        @{ Name = 'duplicate package manager filenames'; Change = { param($catalog) $catalog.tools.example.PackageManagerFiles = @('npm.ps1', 'npm.ps1') } },
        @{ Name = 'invalid executors'; Change = { param($catalog) $catalog.tools.example.UpdateExecutor = 'unknown' } },
        @{ Name = 'invalid Windows execution modes'; Change = { param($catalog) $catalog.tools.example.WindowsUpdateExecutionMode = 'Background' } },
        @{ Name = 'invalid action entry points'; Change = { param($catalog) $catalog.tools.example.UpdateEntryPoint = 'Update-Example' } },
        @{ Name = 'unsupported install platforms'; Change = { param($catalog) $catalog.tools.example.InstallCommands = @{ 'Windows (x64)' = 'install example' } } },
        @{ Name = 'blank install commands'; Change = { param($catalog) $catalog.tools.example.InstallCommands = @{ 'Windows (amd64)' = '' } } }
    ) {
        param($Name, $Change)
        & $Change $catalog
        $catalog | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue | Should Be $false
    }
}