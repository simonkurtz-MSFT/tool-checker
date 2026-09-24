# Output contracts: definition-only loading, caller-scoped colors, read-only
# rendering, and host-message capture in synthetic workers without external checks.
$repositoryPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repositoryPath 'tool-checker.ps1'
$outputPath = Join-Path $repositoryPath 'infra/output.ps1'
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
            $observed.Version | Should Be $script:ToolCheckerVersion
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
        $ast.EndBlock.Statements.Count | Should Be 15
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
        $selectionFile = Join-Path $TestDrive 'github-cli.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=github-cli'
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
        $infraRoot = Join-Path $appRoot 'infra'
        $null = New-Item -ItemType Directory -Path $infraRoot
        Copy-Item (Join-Path (Split-Path $scriptPath) 'infra/configuration.ps1') -Destination $infraRoot
        $selectionFile = Join-Path $appRoot 'git.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=git'
        { . (Join-Path $appRoot 'tool-checker.ps1') -EnvFile $selectionFile } | Should Throw 'Output infrastructure file not found'
    }

    It 'includes only worker-needed output helpers in the function block' {
        $functionBlock = Get-ParallelCheckFunctionBlock
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
    }

    It 'renders the application name and version banner' {
        Show-ApplicationBanner

        ($script:OutputLines -join "`n") | Should Match 'Tool Checker V'
    }

    It 'renders startup state without performing checks' {
        $SkipUpdate = $true
        $Force = $true
        Mock Test-IsAdministrator { throw 'Rendering must not probe elevation' }
        Mock Test-RegistryConfiguration { throw 'Rendering must not check registries' }
        Show-StartupInformation -IsElevated $true
        $rendered = $script:OutputLines -join "`n"
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
        $rendered | Should Match 'GHCP CLI metadata URL : https://example.test/copilot'
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
        $rendered | Should Match ([regex]::Escape($ColorGreen) + '  Current\s+1.0.0\s+1.0.0')
        $rendered | Should Match ([regex]::Escape($ColorYellow) + '  Unknown\s+1.0.0\s+unknown')
        $rendered | Should Match ([regex]::Escape($ColorOrange) + '  Blocked\s+1.0.0\s+-')
        $rendered | Should Match ([regex]::Escape($ColorRed) + '  Failed')
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
    }

    It 'renders exactly five columns and keeps newer released versions informational' {
        $results.Tools = @{
            Current = @{ Installed = '1.1.0'; Latest = '1.1.0'; LatestCooldown = '1.1.0'; LatestReleased = '1.2.0' }
            Ready = @{ Installed = '1.0.0'; Latest = '1.1.0'; LatestCooldown = '1.1.0'; LatestReleased = '1.2.0' }
            Unverified = @{ Installed = '1.0.0'; Latest = '1.2.0'; LatestCooldown = $null; LatestReleased = '1.2.0'; Installable = $false }
        }
        Mock Get-UpdateCommand { throw 'Table must not resolve commands' }
        Mock Get-ReleaseNotesUrl { throw 'Table must not resolve links' }
        Show-ResultsTable
        $rendered = $script:OutputLines -join "`n"
        $plain = $rendered -replace '\x1b\[[0-9;]*m', ''
        $plain | Should Match 'Name\s+Installed\s+Latest Cooldown\s+Age\s+Latest Released'
        $plain | Should Not Match 'Update / Install|Release Notes'
        $plain | Should Match 'Current\s+1.1.0\s+1.1.0\s+-\s+1.2.0'
        $plain | Should Match 'Unverified\s+1.0.0\s+-\s+-\s+1.2.0'
        $rendered | Should Match ([regex]::Escape($ColorGreen) + '  Current')
        $rendered | Should Match ([regex]::Escape($ColorYellow) + '  Ready')
        $rendered | Should Match ([regex]::Escape($ColorReset) + '\s+1.2.0')
    }

    It 'preserves candidate age display for <Case>' -TestCases @(
        @{ Case = 'safe update'; Installed = '1.0.0'; Latest = '1.1.0'; Cooldown = '1.1.0'; Age = 8; Expected = '8d'; Skip = $false },
        @{ Case = 'zero-day blocked update'; Installed = '1.0.0'; Latest = '1.1.0'; Cooldown = $null; Age = 0; Expected = '0d'; Skip = $false },
        @{ Case = 'young blocked update'; Installed = '1.0.0'; Latest = '1.1.0'; Cooldown = $null; Age = 2; Expected = '2d'; Skip = $false },
        @{ Case = 'missing age'; Installed = '1.0.0'; Latest = '1.1.0'; Cooldown = '1.1.0'; Age = $null; Expected = '-'; Skip = $false },
        @{ Case = 'current candidate'; Installed = '1.1.0'; Latest = '1.1.0'; Cooldown = '1.1.0'; Age = 8; Expected = '-'; Skip = $false },
        @{ Case = 'newer installed version'; Installed = '1.2.0'; Latest = '1.1.0'; Cooldown = '1.1.0'; Age = 8; Expected = '-'; Skip = $false },
        @{ Case = 'current blocked candidate'; Installed = '1.1.0'; Latest = '1.1.0'; Cooldown = $null; Age = 2; Expected = '-'; Skip = $false },
        @{ Case = 'check-only'; Installed = '1.0.0'; Latest = ''; Cooldown = $null; Age = $null; Expected = '-'; Skip = $true }
    ) {
        param($Case, $Installed, $Latest, $Cooldown, $Age, $Expected, $Skip)
        $SkipUpdate = $Skip
        $results.Tools.Example = @{
            Installed = $Installed; Latest = $Latest; LatestCooldown = $Cooldown
            LatestReleased = '2.0.0'; AgeDays = $Age
        }
        $before = ConvertTo-Json $results -Depth 10 -Compress
        Show-ResultsTable
        $row = ($script:OutputLines | Where-Object { $_ -match '  Example\s' }) -replace '\x1b\[[0-9;]*m', ''
        ($row.Trim() -split '\s{2,}')[3] | Should Be $Expected
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
    }

    It 'right-aligns ages and expands the column for large day counts' {
        $results.Tools = @{
            Short = @{ Installed = '1.0.0'; Latest = '1.1.0'; AgeDays = 8 }
            Long = @{ Installed = '1.0.0'; Latest = '1.1.0'; AgeDays = 1000 }
        }
        Show-ResultsTable
        $plain = @($script:OutputLines | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' })
        $header = $plain | Where-Object { $_ -match 'Name\s+Installed' }
        $short = $plain | Where-Object { $_ -match '  Short\s' }
        $long = $plain | Where-Object { $_ -match '  Long\s' }
        $short.IndexOf('8d') + 2 | Should Be ($long.IndexOf('1000d') + 5)
        $short.IndexOf('8d') + 2 | Should Be ($header.IndexOf('Age') + 3)
    }

    It 'separates header divider and data columns with three spaces' {
        $results.Tools.Example = @{ Installed = '1.0.0'; Latest = '1.1.0'; AgeDays = 8 }
        Show-ResultsTable
        $plain = @($script:OutputLines | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' })
        $header = $plain | Where-Object { $_ -match 'Name\s+Installed' }
        $divider = $plain | Where-Object { $_ -match '^  -{7} ' }
        $row = $plain | Where-Object { $_ -match '^  Example ' }
        $header | Should Be ('  ' + (@('Name'.PadRight(7), 'Installed', 'Latest Cooldown', 'Age', 'Latest Released') -join '   '))
        $divider | Should Be ('  ' + (@(('-' * 7), ('-' * 9), ('-' * 15), ('-' * 3), ('-' * 15)) -join '   '))
        $row | Should Be ('  ' + (@('Example', '1.0.0'.PadRight(9), '1.1.0'.PadRight(15), '8d'.PadLeft(3), '1.1.0') -join '   '))
    }

    It 'colors Latest Released by its relation to Installed (<Installed>, <Released>)' -TestCases @(
        @{ Installed = '1.2.0'; Released = '1.2.0'; Green = $true },
        @{ Installed = 'v1.2.0'; Released = '1.2.0'; Green = $true },
        @{ Installed = '1.1.0'; Released = '1.2.0'; Green = $false },
        @{ Installed = '1.3.0'; Released = '1.2.0'; Green = $false; Older = $true },
        @{ Installed = 'unknown'; Released = 'unknown'; Green = $false },
        @{ Installed = '-'; Released = '-'; Green = $false },
        @{ Installed = ''; Released = '1.2.0'; Green = $false }
    ) {
        param($Installed, $Released, $Green, $Older = $false)
        $results.Tools.Example = @{ Installed = $Installed; Latest = '1.1.0'; LatestReleased = $Released }
        $before = ConvertTo-Json $results -Depth 10 -Compress
        Show-ResultsTable
        $row = $script:OutputLines | Where-Object { $_ -match '  Example\s' }
        $expectedColor = if ($Older) { $ColorCyan } elseif ($Green) { $ColorGreen } else { '' }
        $expectedVersion = if ($Older) { "$Released*" } else { $Released }
        $row | Should Match ([regex]::Escape("$ColorReset   $expectedColor$expectedVersion$ColorReset") + '$')
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
    }

    It 'marks older latest cells independently for <Name> with installed <Installed>' -TestCases @(
        @{ Name = 'WSL'; Installed = '2.9.13'; Cooldown = '2.9.12'; Released = '2.9.12'; ExpectedCooldown = '2.9.12*'; ExpectedReleased = '2.9.12*' },
        @{ Name = 'Example'; Installed = '2.0.0'; Cooldown = '1.0.0'; Released = '3.0.0'; ExpectedCooldown = '1.0.0*'; ExpectedReleased = '3.0.0' },
        @{ Name = 'Example'; Installed = 'unknown'; Cooldown = '1.0.0'; Released = '1.0.0'; ExpectedCooldown = '1.0.0'; ExpectedReleased = '1.0.0' },
        @{ Name = 'Example'; Installed = 'Unable to retrieve version'; Cooldown = '1.0.0'; Released = '1.0.0'; ExpectedCooldown = '1.0.0'; ExpectedReleased = '1.0.0' },
        @{ Name = 'Example'; Installed = '2.0.0'; Cooldown = $null; Released = 'unknown'; ExpectedCooldown = '-'; ExpectedReleased = 'unknown' },
        @{ Name = 'Git'; Installed = '2.55.0.windows.3'; Cooldown = '2.55.0.3'; Released = '2.55.0.3'; ExpectedCooldown = '2.55.0.3'; ExpectedReleased = '2.55.0.3' }
    ) {
        param($Name, $Installed, $Cooldown, $Released, $ExpectedCooldown, $ExpectedReleased)
        $results.Tools[$Name] = @{ Installed = $Installed; Latest = $Cooldown; LatestCooldown = $Cooldown; LatestReleased = $Released }
        $before = ConvertTo-Json $results -Depth 10 -Compress
        Show-ResultsTable
        $row = $script:OutputLines | Where-Object { $_ -match ('  ' + [regex]::Escape($Name) + '\s') }
        $cells = (($row -replace '\x1b\[[0-9;]*m', '').Trim() -split '\s{3,}')
        $cells[2] | Should Be $ExpectedCooldown
        $cells[4] | Should Be $ExpectedReleased
        foreach ($expected in @($ExpectedCooldown, $ExpectedReleased) | Where-Object { $_.EndsWith('*') }) {
            $row | Should Match ([regex]::Escape("$ColorCyan$expected") + '\s*' + [regex]::Escape($ColorReset))
        }
        if (-not $ExpectedCooldown.EndsWith('*') -and -not $ExpectedReleased.EndsWith('*')) {
            $row | Should Not Match '\*'
        }
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
    }

    It 'includes older markers in column widths and explains them in the legend' {
        $version = '1234.1234.1234.12'
        $results.Tools.Example = @{ Installed = '1234.1234.1234.13'; Latest = $version }
        Show-ResultsTable
        $plain = @($script:OutputLines | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' })
        $header = $plain | Where-Object { $_ -match 'Name\s+Installed' }
        $row = $plain | Where-Object { $_ -match '^  Example ' }
        $divider = $plain | Where-Object { $_ -match '^  -+ ' }
        $columns = [regex]::Matches($divider, '-+')
        $columns[2].Length | Should Be ($version.Length + 1)
        $columns[4].Length | Should Be ($version.Length + 1)
        $row.LastIndexOf("$version*") | Should Be $header.IndexOf('Latest Released')
        $row.Substring($columns[2].Index, $columns[2].Length + 3) | Should Be "$version*   "
        Show-UpdateLegend
        ($script:OutputLines -join "`n") | Should Match ([regex]::Escape("${ColorCyan}* Older than installed; informational only, no downgrade offered.$ColorReset"))
    }

    It 'lists pinned commands and release links outside the table without executing anything' {
        $toolsConfig = @{
            Ready = @{ Id = 'ready'; ReleaseNotesUrl = 'https://example.test/ready' }
            Blocked = @{ Id = 'blocked'; ReleaseNotesUrl = 'https://example.test/blocked'; ReleasePackageManager = 'npm.ps1' }
            Missing = @{ Id = 'missing'; ReleaseNotesUrl = 'https://example.test/missing' }
        }
        $results.Tools = @{
            Ready = @{ ToolId = 'ready'; Installed = '1.0.0'; Latest = '1.1.0'; LatestReleased = '1.2.0' }
            Blocked = @{ ToolId = 'blocked'; Installed = '1.0.0'; Latest = '1.2.0'; Installable = $false }
        }
        $results.AvailableUpdates = @(@{ Name = 'Ready'; Command = 'npm install -g ready@1.1.0' })
        $results.NotInstalled = @([pscustomobject]@{ Name = 'Missing'; ToolId = 'missing'; InstallCommands = @{ $script:PlatformKey = 'install missing' } })
        Mock Get-UpdateCommand {
            if ($ToolName -eq 'Ready') { 'npm install -g ready@1.1.0' } else { '' }
        }
        Mock Get-ReleaseNotesUrl { "https://example.test/$($ToolName.ToLowerInvariant())" }
        Mock Invoke-ActionCommand { throw 'Details must never execute actions' }
        $before = ConvertTo-Json $results -Depth 10 -Compress
        Show-ToolDetails
        $rendered = $script:OutputLines -join "`n"
        $rendered | Should Match 'Update / Install: npm install -g ready@1.1.0'
        $rendered | Should Match 'Update / Install: install missing'
        $rendered | Should Not Match 'No action available'
        @($script:OutputLines | Where-Object { $_ -match '^\s+Update / Install:' }).Count | Should Be 2
        $rendered | Should Match 'Release Notes: https://example.test/blocked'
        $rendered | Should Not Match 'ready@1.2.0'
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
        Assert-MockCalled Get-UpdateCommand 1 -Scope It -ParameterFilter { $ToolName -eq 'Ready' -and $Latest -eq '1.1.0' }
        Assert-MockCalled Invoke-ActionCommand 0 -Scope It
    }

    It 'renders duplicate package inventories and command paths without probing or mutating state' {
        $toolsConfig = @{ Example = @{ Id = 'example'; Name = 'Example' } }
        $results.Tools.Example = @{ ToolId = 'example'; Installed = '2.0.0'; Latest = '2.0.0' }
        $results.ToolState.example = @{
            Installations = @(
                @{ PackageManager = 'npm'; PackageName = '@example/cli'; Version = '2.0.0'; Path = '\\?\C:\npm\cli'; Status = 'Found'; RemoveCommand = 'npm uninstall --global @example/cli' },
                @{ PackageManager = 'pnpm'; PackageName = '@example/cli'; Version = '1.0.0'; Path = '/pnpm/cli'; Status = 'Found'; RemoveCommand = 'pnpm remove --global @example/cli' }
            )
            ResolvedCommandPath = '\\?\C:\editor\cli.ps1'
        }
        Mock Invoke-PackageManagerOperation { throw 'Rendering must not discover installations' }
        $before = ConvertTo-Json $results -Depth 10 -Compress

        Show-ResultsTable

        $rendered = $script:OutputLines -join "`n"
        $headingIndex = @($script:OutputLines | ForEach-Object { $_ -replace [regex]::Escape($ColorCyan), '' -replace [regex]::Escape($ColorReset), '' }).IndexOf('  Package installations (global inventories)')
        $script:OutputLines[$headingIndex - 1] | Should Be ''
        $script:OutputLines[$headingIndex + 1] | Should Be ''
        $rendered | Should Match 'Example \[multiple installations\]'
        $rendered | Should Match 'npm: @example/cli@2.0.0'
        $rendered | Should Match 'pnpm: @example/cli@1.0.0'
        $rendered | Should Match ([regex]::Escape('C:\npm\cli'))
        $rendered | Should Match '/pnpm/cli'
        $rendered | Should Not Match ([regex]::Escape('\\?\'))
        $rendered | Should Match 'Recommended removal: pnpm remove --global @example/cli'
        $rendered | Should Match ('\n\n    Command resolves to: ' + [regex]::Escape('C:\editor\cli.ps1') + '\n\n')
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
        Assert-MockCalled Invoke-PackageManagerOperation 0 -Scope It
    }

    It 'omits unavailable, empty, and single-installation inventories' {
        $toolsConfig = @{ Example = @{ Id = 'example'; Name = 'Example' } }
        $results.Tools.Example = @{ ToolId = 'example'; Installed = '2.0.0'; Latest = '2.0.0' }
        $results.ToolState.example = @{ Installations = @(@{ PackageManager = 'pnpm'; Status = 'Unavailable' }) }
        Show-ResultsTable
        ($script:OutputLines -join "`n") | Should Not Match 'Package installations'

        $results.ToolState.example.Installations = @()
        Show-ResultsTable
        ($script:OutputLines -join "`n") | Should Not Match 'Package installations'

        $results.ToolState.example.Installations = @(@{ PackageManager = 'npm'; PackageName = '@example/cli'; Version = '2.0.0'; Status = 'Found' })
        Show-ResultsTable
        ($script:OutputLines -join "`n") | Should Not Match 'Package installations'
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
        $rendered | Should Match 'Blocked CLI : release is 2 days old; available at 8 days'
        $rendered | Should Match 'Errors \(1\)'
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
    }

    It 'pluralizes maturity ages and aligns summary colons to the table name column' {
        $results.Tools = @{
            'GitHub Copilot CLI' = @{ Installed = '0.0.1'; Latest = '0.0.2' }
            pnpm = @{ Installed = '9.0.0'; Latest = '10.0.0' }
            'One Day CLI' = @{ Installed = '1.0.0'; Latest = '1.0.1' }
        }
        $results.Updates = @('GitHub Copilot CLI', 'pnpm', 'One Day CLI')
        $results.MaturityBlockedUpdates = @(
            @{ Name = 'GitHub Copilot CLI'; AgeDays = 0; RequiredAgeDays = 8 },
            @{ Name = 'pnpm'; AgeDays = 7; RequiredAgeDays = 8 },
            @{ Name = 'One Day CLI'; AgeDays = 1; RequiredAgeDays = 1 }
        )

        Show-ResultsSummary -AvailableUpdateNames @()

        $rows = @($script:OutputLines | Where-Object { $_ -match '^  - (GitHub Copilot CLI|pnpm|One Day CLI)' })
        $rows[0] | Should Be '  - GitHub Copilot CLI : release is 0 days old; available at 8 days'
        $rows[1] | Should Be '  - pnpm               : release is 7 days old; available at 8 days'
        $rows[2] | Should Be '  - One Day CLI        : release is 1 day old; available at 1 day'
        @($rows | ForEach-Object { $_.IndexOf(':') } | Select-Object -Unique).Count | Should Be 1
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

    It 'keeps the details menu when only cooldown-blocked updates exist' {
        $results.Updates = @('pnpm')
        $results.MaturityBlockedUpdates = @(@{ Name = 'pnpm'; AgeDays = 7; RequiredAgeDays = 8 })
        Main
        Assert-MockCalled Invoke-ActionMenu 1 -Scope It
        Assert-MockCalled Invoke-ForceUpdates 0 -Scope It
    }

    It 'exits without a new prompt in check-only mode when no actions exist' {
        $SkipUpdate = $true
        Main
        $script:OutputLines[0] | Should Be "`nNothing to do. Exiting.`n"
        Assert-MockCalled Invoke-ActionMenu 0 -Scope It
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

Describe 'Update legend' {
    BeforeEach {
        $results = New-ToolCheckResults
        Mock Write-Host { }
    }

    It 'is hidden when no updates are available' {
        Show-UpdateLegend

        Assert-MockCalled Write-Host 0
    }

    It 'is shown when an update is available' {
        $results.Updates = @('Example CLI')

        Show-UpdateLegend

        Assert-MockCalled Write-Host 9 -Exactly -Scope It
    }

    It 'groups the cooldown color key and notes with consistent indentation' {
        $results.Tools.Example = @{ Installed = '1.0.0'; Latest = '1.0.0' }
        $script:OutputLines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { param($Object) $script:OutputLines.Add([string]$Object) }
        $before = ConvertTo-Json $results -Depth 10 -Compress
        Show-UpdateLegend
        $expected = @(
            "  npm release cooldown: $script:ReleaseCooldownDays full days"
            ''
            "  ${ColorCyan}Legend$ColorReset"
            "    $ColorYellow■ Installable update / version unknown$ColorReset"
            "    $ColorOrange■ No verified installable release$ColorReset"
            "    ${ColorCyan}* Older than installed; informational only, no downgrade offered.$ColorReset"
            ''
            '  Latest Released is informational only.'
            '  "-" means no verified cooldown-safe version or not checked.'
        )
        ($script:OutputLines -join "`n") | Should Be ($expected -join "`n")
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
    }

    It 'explains informational releases even when the cooldown-safe version is already installed' {
        $results.Tools.Example = @{ Installed = '1.0.0'; LatestCooldown = '1.0.0'; LatestReleased = '1.1.0' }
        Show-UpdateLegend
        Assert-MockCalled Write-Host 1 -ParameterFilter { $Object -like '*Latest Released is informational*' }
    }
}