# Output contracts: definition-only loading, caller-scoped colors, read-only
# rendering, and host-message capture in synthetic workers without external checks.
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tool-checker.ps1'
$outputPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Infra/output.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) "output-tests-$([guid]::NewGuid()).env")

Describe 'Output infrastructure' {
    It 'clears before normal startup but preserves the screen for version and dot-sourced use' {
        $appRoot = Join-Path $TestDrive 'clear-startup'
        $null = New-Item -ItemType Directory -Path $appRoot
        Copy-Item $scriptPath -Destination $appRoot
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($incompletePath, $mainPath, $envPath)
                $global:ClearCount = 0
                function Clear-Host { $global:ClearCount++ }
                $startupError = try { & $incompletePath } catch { $_.Exception.Message }
                $afterNormal = $global:ClearCount
                $reportedVersion = & $incompletePath -Version
                $afterVersion = $global:ClearCount
                . $mainPath -EnvFile $envPath
                [PSCustomObject]@{
                    StartupError = $startupError
                    AfterNormal = $afterNormal
                    Version = $reportedVersion
                    AfterVersion = $afterVersion
                    AfterDotSource = $global:ClearCount
                }
            }).AddArgument((Join-Path $appRoot 'tool-checker.ps1')).AddArgument($scriptPath).AddArgument((Join-Path $TestDrive 'absent.env'))
            $observed = @($session.Invoke())[0]
            $observed.StartupError | Should Match 'Configuration infrastructure file not found'
            $observed.AfterNormal | Should Be 1
            $observed.Version | Should Be '2.0.0'
            $observed.AfterVersion | Should Be 1
            $observed.AfterDotSource | Should Be 1
        } finally {
            $session.Dispose()
        }
    }

    It 'contains only functions and loads each from the output file' {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($outputPath, [ref]$null, [ref]$parseErrors)
        $parseErrors.Count | Should Be 0
        @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] }).Count | Should Be 0
        $ast.EndBlock.Statements.Count | Should Be 12
        foreach ($definition in $ast.EndBlock.Statements) {
            (Get-Command $definition.Name).ScriptBlock.File | Should Be $outputPath
        }
        @(& { . $outputPath } *>&1).Count | Should Be 0
    }

    It 'initializes all colors only on request in the immediate caller scope' {
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($definitionsPath)
                $ColorGreen = 'parent sentinel'
                . $definitionsPath
                $before = $ColorGreen
                $initialized = & {
                    $emitted = @(Initialize-ConsoleColors)
                    [PSCustomObject]@{
                        Emitted = $emitted.Count
                        Colors = @($ColorReset, $ColorGreen, $ColorYellow, $ColorRed, $ColorCyan, $ColorBlue, $ColorOrange)
                    }
                }
                [PSCustomObject]@{ Before = $before; After = $ColorGreen; Initialized = $initialized }
            }).AddArgument($outputPath)
            $observed = @($session.Invoke())[0]
            $session.HadErrors | Should Be $false
            $observed.Before | Should Be 'parent sentinel'
            $observed.After | Should Be 'parent sentinel'
            $observed.Initialized.Emitted | Should Be 0
            ($observed.Initialized.Colors -join '|') | Should Be ("`e[0m|`e[32m|`e[33m|`e[31m|`e[36m|`e[34m|`e[38;5;208m")
        } finally {
            $session.Dispose()
        }
    }

    It 'loads independently of selected tool files' {
        $selectionFile = Join-Path $TestDrive 'git.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=git'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($mainPath, $envPath)
                . $mainPath -EnvFile $envPath
                [PSCustomObject]@{
                    ToolFiles = $script:ToolDefinitions.Count
                    OutputFile = (Get-Command Show-ResultsTable).ScriptBlock.File
                    ColorGreen = $ColorGreen
                }
            }).AddArgument($scriptPath).AddArgument($selectionFile)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed[0].ToolFiles | Should Be 0
            $observed[0].OutputFile | Should Be $outputPath
            $observed[0].ColorGreen | Should Be "`e[32m"
        } finally {
            $session.Dispose()
        }
    }

    It 'fails clearly when the output infrastructure is missing' {
        $appRoot = Join-Path $TestDrive 'missing-output'
        $null = New-Item -ItemType Directory -Path $appRoot
        Copy-Item $scriptPath -Destination $appRoot
        Copy-Item (Join-Path (Split-Path $scriptPath) 'tool-checker.json') -Destination $appRoot
        $infraRoot = Join-Path $appRoot 'Infra'
        $null = New-Item -ItemType Directory -Path $infraRoot
        Copy-Item (Join-Path (Split-Path $scriptPath) 'Infra/configuration.ps1') -Destination $infraRoot
        $selectionFile = Join-Path $appRoot 'git.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=git'
        { . (Join-Path $appRoot 'tool-checker.ps1') -EnvFile $selectionFile } | Should Throw 'Output infrastructure file not found'
    }

    It 'includes only worker-needed output helpers in the function block' {
        $functionBlock = Get-ParallelCheckFunctionBlock -ScriptContent (Get-Content $scriptPath -Raw) -ToolsConfiguration @{}
        foreach ($name in @('Write-Header', 'Write-Success', 'Write-Warning', 'Write-Error')) {
            $functionBlock | Should Match "function $name"
        }
        $functionBlock | Should Not Match 'function Show-|function Get-ApplicationBannerLines|function Initialize-ConsoleColors|function Main'
    }

    It 'aligns discovery durations across short long and error descriptions without parentheses' {
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($mainPath, $envPath)
                . $mainPath -EnvFile $envPath
                $checks = @(
                    @{ Name = 'Git'; Block = { $results.Tools.Git = @{ Installed = '1.0.0'; Latest = '' } } }
                    @{ Name = 'A deliberately long tool description (preview)'; Block = { $results.Errors += 'Synthetic failure' } }
                )
                @(Invoke-ParallelChecks -Checks $checks -Total 19 -TimeoutSec 5 6>&1) -join "`n"
            }).AddArgument($scriptPath).AddArgument((Join-Path $TestDrive 'absent.env'))
            $rendered = @($session.Invoke()) -join "`n"
            $session.HadErrors | Should Be $false
        } finally {
            $session.Dispose()
        }
        $plain = $rendered -replace '\x1b\[[0-9;]*m', ''
        $rows = @($plain -split "`n" | Where-Object { $_ -match '\[\s*\d+/19\] Completed' })
        $rows.Count | Should Be 2
        ($rows -join "`n") | Should Match 'Completed: Git\s+\d+[.,]\d+s'
        ($rows -join "`n") | Should Match 'Completed with errors: A deliberately long tool description \(preview\)\s+\d+[.,]\d+s'
        foreach ($row in $rows) {
            $row | Should Not Match '\(\d+[.,]\d+s\)'
        }
        @($rows | ForEach-Object { [regex]::Match($_, 's\s*$').Index } | Select-Object -Unique).Count | Should Be 1
    }

    It 'captures all output helper messages in a real worker without error-stream records' {
        $results = New-ToolCheckResults
        $checks = @(@{
            Name = 'Synthetic output'
            Block = {
                Write-Header 'Worker heading' -Progress $args[0]
                Write-Success 'Worker success'
                Write-Warning 'Worker warning'
                Write-Error 'Worker error message'
                $results.Tools['Synthetic output'] = @{ Installed = '1.0.0'; Latest = '' }
            }
        })
        $rendered = @(Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5 6>&1) -join "`n"
        $results.Errors.Count | Should Be 0
        $results.Tools['Synthetic output'].Installed | Should Be '1.0.0'
        $rendered | Should Match '\[1/1\] Worker heading'
        $rendered | Should Match 'Worker success'
        $rendered | Should Match 'Worker warning'
        $rendered | Should Match 'Worker error message'
        $rendered | Should Match ([regex]::Escape("`e[32m") + '.*Worker success')
    }
}

Describe 'Output rendering' {
    BeforeEach {
        $results = New-ToolCheckResults
        $SkipUpdate = $false
        $Force = $false
        $script:OutputLines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { param($Object) $script:OutputLines.Add([string]$Object) }
        Mock Get-UpdateCommand { '' }
        Mock Get-ReleaseNotesUrl { '' }
    }

    It 'renders startup state without performing checks' {
        $SkipUpdate = $true
        $Force = $true
        Mock Test-IsAdministrator { throw 'Rendering must not probe elevation' }
        Mock Test-RegistryConfiguration { throw 'Rendering must not check registries' }
        Show-StartupInformation -IsElevated $true
        $rendered = $script:OutputLines -join "`n"
        $rendered | Should Match 'Tool Checker V'
        $rendered | Should Match 'Process elevated\s+: Yes'
        $rendered | Should Match 'check-only mode'
        $rendered | Should Match 'automatic update'
        $rendered | Should Match "Selected tool count\s+: $($toolsConfig.Count)/$($catalogToolIds.Count)"
        Assert-MockCalled Test-IsAdministrator 0 -Scope It
        Assert-MockCalled Test-RegistryConfiguration 0 -Scope It
    }

    It 'aligns registry labels and renders existing resolution details' {
        $toolsConfig = [ordered]@{
            'GitHub Copilot CLI' = @{ VersionExtractor = 'npmDistTagLatest'; ApiUrl = 'https://example.test/copilot' }
            'Other CLI' = @{ VersionExtractor = 'regex'; ApiUrl = 'https://example.test/other' }
        }
        $script:NpmRegistryResolution = @{ Source = 'test'; Url = 'https://example.test'; Details = 'Synthetic fallback' }
        Show-RegistryMetadata
        $rendered = $script:OutputLines -join "`n"
        $rendered | Should Match 'GHCP CLI metadata URL\s*: https://example.test/copilot'
        $rendered | Should Match 'Registry resolution detail: Synthetic fallback'
        $rendered | Should Not Match 'Other CLI'
        $rows = @($script:OutputLines | Where-Object { $_ -match '^  (npm registry|GHCP CLI)' })
        @($rows | ForEach-Object { $_.IndexOf(':') } | Select-Object -Unique).Count | Should Be 1
    }

    It 'preserves table colors for current unknown blocked and failed rows' {
        $results.Tools = @{
            Current = @{ Installed = '1.0.0'; Latest = '1.0.0'; AgeDays = 10 }
            Unknown = @{ Installed = '1.0.0'; Latest = '' }
            Blocked = @{ Installed = '1.0.0'; Latest = '2.0.0'; AgeDays = 2 }
            Failed = @{ Installed = '1.0.0'; Latest = '2.0.0' }
        }
        $results.MaturityBlockedUpdates = @(@{ Name = 'Blocked'; AgeDays = 2; RequiredAgeDays = 8 })
        $results.UpdateFailed = @('Failed')
        $before = ConvertTo-Json $results -Depth 10 -Compress
        Show-ResultsTable
        $rendered = $script:OutputLines -join "`n"
        $rendered | Should Match ([regex]::Escape($ColorGreen) + '  Current\s+1.0.0\s+1.0.0\s+-')
        $rendered | Should Match ([regex]::Escape($ColorYellow) + '  Unknown\s+1.0.0\s+unknown')
        $rendered | Should Match ([regex]::Escape($ColorOrange) + '  Blocked\s+1.0.0\s+2.0.0\s+2d')
        $rendered | Should Match ([regex]::Escape($ColorRed) + '  Failed')
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
    }

    It 'renders blank latest versions as a dash in check-only mode' {
        $SkipUpdate = $true
        $results.Tools = @{ Current = @{ Installed = '1.0.0'; Latest = '' } }
        Show-ResultsTable
        ($script:OutputLines -join "`n") | Should Match 'Current\s+1.0.0\s+-'
        ($script:OutputLines -join "`n") | Should Not Match 'unknown'
    }

    It 'renders summary categories from existing state and supplied available updates' {
        $results.NotInstalled = @(@{ Name = 'Missing CLI' })
        $results.Updates = @('Ready CLI', 'Blocked CLI')
        $results.MaturityBlockedUpdates = @(@{ Name = 'Blocked CLI'; AgeDays = 2; RequiredAgeDays = 8 })
        $results.Errors = @('Synthetic failure')
        $before = ConvertTo-Json $results -Depth 10 -Compress
        Show-ResultsSummary -AvailableUpdateNames @('Ready CLI')
        $rendered = $script:OutputLines -join "`n"
        $rendered | Should Match 'Not Installed \(1\)'
        $rendered | Should Match 'Updates Available \(1\)'
        $rendered | Should Match 'Updates Not Yet Available \(1\)'
        $rendered | Should Match '⚠  Updates Available'
        $rendered | Should Match '⚠  Updates Not Yet Available'
        $rendered | Should Match '⚠  Errors'
        $rendered | Should Match 'Blocked CLI: release is 2d old; available at 8d'
        $rendered | Should Match 'Errors \(1\)'
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
    }

    It 'omits empty summary categories and preserves the check progress heading' {
        Show-ResultsSummary -AvailableUpdateNames @()
        Show-CheckProgressHeader -Total 3 -TimeoutSec 12
        $rendered = $script:OutputLines -join "`n"
        $rendered | Should Not Match 'Not Installed|Updates Available|Updates Not Yet Available|Errors \('
        $rendered | Should Match 'Running 3 checks in parallel \(12s timeout\)'
    }
}

Describe 'No-action workflow output' {
    BeforeEach {
        $results = New-ToolCheckResults
        $SkipUpdate = $false
        $Force = $false
        $script:OutputLines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { param($Object) $script:OutputLines.Add([string]$Object) }
        Mock Assert-ToolConfigurations {}
        Mock Test-IsAdministrator { $false }
        Mock Show-StartupInformation {}
        Mock Test-RegistryConfiguration {}
        Mock Show-RegistryMetadata {}
        Mock Get-ConfiguredChecks { @() }
        Mock Show-CheckProgressHeader {}
        Mock Invoke-ParallelChecks {}
        Mock Show-ResultsSummary {}
        Mock Invoke-ActionMenu {}
        Mock Invoke-ForceUpdates {}
    }

    It 'prints a blank-line-delimited exit message when only cooldown-blocked updates exist' {
        $results.Updates = @('pnpm')
        $results.MaturityBlockedUpdates = @(@{ Name = 'pnpm'; AgeDays = 7; RequiredAgeDays = 8 })
        Main
        $script:OutputLines.Count | Should Be 1
        $script:OutputLines[0] | Should Be "`nNothing to do. Exiting.`n"
        Assert-MockCalled Invoke-ActionMenu 0 -Scope It
        Assert-MockCalled Invoke-ForceUpdates 0 -Scope It
    }

    It 'prints the same exit message in Force mode when no actions exist' {
        $Force = $true
        Main
        $script:OutputLines[0] | Should Be "`nNothing to do. Exiting.`n"
        Assert-MockCalled Invoke-ForceUpdates 0 -Scope It
    }

    It 'keeps the action menu when a registry repair is available without tool updates' {
        $results.AvailableUpdates = @(@{ Name = 'npm registry'; Type = 'registry'; RegistryKey = 'npm' })
        Main
        ($script:OutputLines -join "`n") | Should Not Match 'Nothing to do'
        Assert-MockCalled Invoke-ActionMenu 1 -Scope It
    }
}