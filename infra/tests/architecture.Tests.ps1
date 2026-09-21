# Cross-file architecture contracts: selected definitions, isolated dispatch, owned
# rows, and complete action metadata. Real jobs run synthetic operations, not installs.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'

Describe 'Generic architecture contracts' {
    BeforeEach {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'absent.env')
    }

    It 'keeps package-manager and tool implementation out of the entry point' {
        $source = Get-Content $scriptPath -Raw
        $source | Should Not Match '(?i)npm|winget|dotnet|nodejs|python|uv\b'
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $functions = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
        $functions.Count | Should Be 1
        $functions[0].Name | Should Be 'Main'
    }

    It 'keeps product names out of generic <File> infrastructure' -TestCases @(
        @{ File = 'actions' }, @{ File = 'checks' }, @{ File = 'parallel' }, @{ File = 'runtime' },
        @{ File = 'results' }, @{ File = 'versions' }, @{ File = 'package-managers' }
    ) {
        param($File)
        $source = Get-Content (Join-Path (Split-Path $scriptPath) "infra/$File.ps1") -Raw
        $source | Should Not Match '(?i)\b(npm|pnpm|winget|dotnet|nodejs|python)\b'
    }

    It 'loads only explicitly selected package manager dependencies once' {
        $config = @{
            Selected = @{ Enabled = $true; PackageManagerFiles = @('npm.ps1','npm.ps1') }
            Disabled = @{ Enabled = $false; PackageManagerFiles = @('missing.ps1') }
        }
        $files = @(Get-PackageManagerDefinitionFiles -ToolsConfiguration $config -Directory (Join-Path (Split-Path $scriptPath) 'infra/PackageManagers'))
        $files.Count | Should Be 1
        $files[0].Id | Should Be 'npm.ps1'
        $config.Selected.PackageManagerFiles = @('../npm.ps1')
        $message = try { Get-PackageManagerDefinitionFiles -ToolsConfiguration $config -Directory $TestDrive } catch { $_.Exception.Message }
        $message | Should Match 'Invalid package manager filename'
        $config.Selected.PackageManagerFiles = @('missing.ps1')
        $message = try { Get-PackageManagerDefinitionFiles -ToolsConfiguration $config -Directory $TestDrive } catch { $_.Exception.Message }
        $message | Should Match 'Package manager file not found'
    }

    It 'rejects executable definition files including begin blocks' {
        $path = Join-Path $TestDrive 'invalid.ps1'
        Set-Content $path 'begin { throw "must never execute" } end { function Test-Tool {} }'
        $message = try { Read-DefinitionRegistry -Files @(@{ Id = 'test'; FullName = $path }) } catch { $_.Exception.Message }
        $message | Should Match 'must contain functions only'
    }

    It 'isolates identical package manager operation names' {
        $script:PackageManagerDefinitions = @{
            'one.ps1' = @{ 'Get-LatestVersion-PackageManager' = 'function Get-LatestVersion-PackageManager { "one" }' }
            'two.ps1' = @{ 'Get-LatestVersion-PackageManager' = 'function Get-LatestVersion-PackageManager { "two" }' }
        }
        (Invoke-PackageManagerOperation 'one.ps1' 'Get-LatestVersion') | Should Be 'one'
        (Invoke-PackageManagerOperation 'two.ps1' 'Get-LatestVersion') | Should Be 'two'
        @(Get-Command -CommandType Function | Where-Object Name -eq 'Get-LatestVersion-PackageManager').Count | Should Be 0
    }

    It 'preserves owner and executor arguments when constructing menu actions' {
        $results.Tools['Renamed row'] = @{ ToolId = 'nodejs'; Installed = '1.0.0'; Latest = '2.0.0' }
        Add-AvailableUpdate -Name 'Renamed row' -Command 'synthetic installer' -Type 'direct' -Executor tool -ExecutionMode CurrentSession -Arguments @{ Version = '2.0.0' }
        $action = @(Get-AvailableActions)[0]
        $action.ToolId | Should Be 'nodejs'
        $action.Executor | Should Be 'tool'
        $action.EntryPoint | Should Be 'Invoke-ToolUpdate'
        $action.Arguments.Version | Should Be '2.0.0'
        $action.ExecutionMode | Should Be 'CurrentSession'
    }

    It 'selects outcome handling from the owner rather than display name' {
        $results.Tools['Renamed package'] = @{ ToolId = 'pnpm' }
        $action = Resolve-ActionMetadata @{ Name = 'Renamed package'; Command = 'synthetic'; Type = 'direct' }
        $action.OutcomePackageManager | Should Be 'npm.ps1'
        (Get-ActionOutcome -Action $action -ExitCode 1 -OutputText 'EALLOWREMOTE').Message | Should Match 'remote'
    }

    It 'routes a synthetic package manager through a real background worker' {
        $script:PackageManagerDefinitions['synthetic.ps1'] = @{
            'Invoke-Command-PackageManager' = 'function Invoke-Command-PackageManager { param($Command,$Type) @{ Output = "synthetic package manager"; ExitCode = 0 } }'
        }
        Invoke-ParallelUpdates @(@{ Name = 'Synthetic package manager'; Command = 'never execute this'; Executor = 'synthetic.ps1'; Type = 'direct' })
        $results.Errors.Count | Should Be 0
        $results.UpdateFailed.Count | Should Be 0
    }

    It 'routes tool arguments through a real background worker' {
        $script:ToolDefinitions['synthetic'] = @{
            'Invoke-ToolUpdate' = 'function Invoke-ToolUpdate { param($Version) if ($Version -ne "2.0.0") { throw "Missing version" }; @{ Output = $Version; ExitCode = 0 } }'
        }
        Invoke-ParallelUpdates @(@{ Name = 'Synthetic tool'; ToolId = 'synthetic'; Command = 'never execute this'; Executor = 'tool'; EntryPoint = 'Invoke-ToolUpdate'; Arguments = @{ Version = '2.0.0' }; Type = 'direct' })
        $results.Errors.Count | Should Be 0
        $results.UpdateFailed.Count | Should Be 0
    }

    It 'serializes selected package manager decisions and action metadata into check workers' {
        $toolsConfig = @{ Example = @{ Id = 'example'; Enabled = $true; UpdateExecutor = 'synthetic.ps1' } }
        $script:PackageManagerDefinitions = @{
            'synthetic.ps1' = @{ 'Get-LatestVersion-PackageManager' = 'function Get-LatestVersion-PackageManager { "2.0.0" }' }
        }
        Invoke-ParallelChecks -Total 1 -TimeoutSec 10 -Checks @(@{
            Name = 'Example'
            Block = {
                $latest = Invoke-PackageManagerOperation 'synthetic.ps1' 'Get-LatestVersion'
                $results.Tools.Example = @{ ToolId = 'example'; Installed = '1.0.0'; Latest = $latest }
                Add-AvailableUpdate -Name Example -Command 'synthetic command' -Type direct
            }
        })
        $results.Errors.Count | Should Be 0
        $results.Tools.Example.Latest | Should Be '2.0.0'
        $results.AvailableUpdates[0].Executor | Should Be 'synthetic.ps1'
        $results.AvailableUpdates[0].ToolId | Should Be 'example'
    }

    It 'does not flatten compound commands in the WinGet executor' {
        . (Join-Path (Split-Path $scriptPath) 'infra/PackageManagers/winget.ps1')
        $message = try { Invoke-WingetCommand 'winget install Example; Write-Output unexpected' } catch { $_.Exception.Message }
        $message | Should Match 'Expected a single winget command'
        $message = try { Invoke-WingetCommand 'winget list | Out-String' } catch { $_.Exception.Message }
        $message | Should Match 'Expected a single winget command'
    }

    It 'sorts owned rows by catalog grouping and descending version' {
        $config = @{ SortGroup = 'Runtime'; SortVersionsDescending = $true }
        $older = Get-ToolSortKey -ToolName 'Unrelated label A' -Configuration $config -Row @{ Installed = '8.0.100' }
        $newer = Get-ToolSortKey -ToolName 'Unrelated label B' -Configuration $config -Row @{ Installed = '10.0.200' }
        $newer.CompareTo($older) | Should BeLessThan 0
        (Get-ToolSortKey -ToolName 'Extension' -Configuration @{ SortGroup = 'CLI'; SortOrder = 1 }) | Should Be 'CLI|1|Extension'
    }

    It 'resolves catalog operations only from each tools declared dependencies' {
        foreach ($config in $toolsConfig.Values) {
            $files = @(Get-PackageManagerDefinitionFiles -ToolsConfiguration @{ Tool = $config } -Directory (Join-Path (Split-Path $scriptPath) 'infra/PackageManagers'))
            $registry = Read-DefinitionRegistry -Files $files
            foreach ($operation in @('Release','ApiVersion','InstalledVersion','Installations')) {
                $packageManager = Get-ConfiguredPackageManager -Configuration $config -Operation $operation
                if ($packageManager) { $registry.ContainsKey($packageManager) | Should Be $true }
                if ($packageManager -and $operation -eq 'Installations') {
                    $registry[$packageManager].ContainsKey('Get-Installations-PackageManager') | Should Be $true
                }
            }
            foreach ($operation in @('Install','Update')) {
                $action = Resolve-ActionMetadata @{ Name = $config.Name; ToolId = $config.Id; Operation = $operation }
                if ($action.Executor -eq 'tool') {
                    $script:ToolDefinitions[$config.Id].ContainsKey($action.EntryPoint) | Should Be $true
                } elseif ($action.Executor -ne 'command') {
                    $registry[$action.Executor].ContainsKey('Invoke-Command-PackageManager') | Should Be $true
                }
                if ($action.OutcomePackageManager) {
                    $registry[$action.OutcomePackageManager].ContainsKey('Get-ExecutionOutcome-PackageManager') | Should Be $true
                }
            }
        }
    }

    It 'keeps generic infrastructure and package manager files definition-only' {
        foreach ($name in @('runtime','versions','checks','results','actions','parallel','package-managers','PackageManagers/npm','PackageManagers/winget')) {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $scriptPath) "infra/$name.ps1"), [ref]$null, [ref]$errors)
            $errors.Count | Should Be 0
            @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] }).Count | Should Be 0
        }
    }
}

Describe 'Owned package row refresh' {
    . $scriptPath -EnvFile (Join-Path $TestDrive 'absent.env')
    It 'refreshes detached rows without overwriting the latest known release' {
        $results = New-ToolCheckResults
        (Get-ToolState 'npm-global-packages').Packages = @(@{ Name = 'example'; Current = '1.0.0'; Latest = '3.0.0' })
        $results.Tools['npm: example'] = @{ ToolId = 'npm-global-packages'; Installed = '1.0.0'; Latest = '3.0.0' }
        Mock Get-GlobalNpmInstalledVersion { '2.0.0' }
        Invoke-ToolEntryPoint -ToolId 'npm-global-packages' -EntryPoint Refresh-ToolStatus
        $results.Tools['npm: example'].Installed | Should Be '2.0.0'
        $results.Tools['npm: example'].Latest | Should Be '3.0.0'
        (Get-ToolState 'npm-global-packages').Packages[0].Current | Should Be '2.0.0'
    }
}

Describe 'Worker definition closure' {
    # Static call-graph check: a helper missing from a worker allowlist otherwise fails only at runtime.
    . $scriptPath -EnvFile (Join-Path $TestDrive 'absent.env')
    $repositoryPath = Split-Path $scriptPath
    $parse = { param($text) [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null) }
    $getFunctions = {
        param($ast)
        $functions = @{}
        foreach ($statement in $ast.EndBlock.Statements) {
            if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $functions[$statement.Name] = $statement }
        }
        $functions
    }
    $getCalls = {
        param($ast)
        @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
    }
    $infrastructure = @{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repositoryPath 'infra') -Filter '*.ps1' -File) {
        foreach ($entry in (& $getFunctions (& $parse (Get-Content -LiteralPath $file.FullName -Raw))).GetEnumerator()) { $infrastructure[$entry.Key] = $entry.Value }
    }
    $checkWorker = & $getFunctions (& $parse (Get-ParallelCheckFunctionBlock))
    $actionWorker = & $getFunctions (& $parse (Get-ActionWorkerDefinitions))
    # Walk local calls from the given roots and report infrastructure calls the worker lacks.
    $getMissing = {
        param($label, $local, $roots, $available, $ignored = @())
        $pending = [System.Collections.Generic.Queue[string]]::new()
        @($roots) | Where-Object { $local.ContainsKey($_) } | ForEach-Object { $pending.Enqueue($_) }
        $visited = @{}
        while ($pending.Count -gt 0) {
            $name = $pending.Dequeue()
            if ($visited.ContainsKey($name)) { continue }
            $visited[$name] = $true
            foreach ($call in & $getCalls $local[$name]) {
                if ($local.ContainsKey($call)) { $pending.Enqueue($call) }
                elseif ($infrastructure.ContainsKey($call) -and -not $available.ContainsKey($call) -and $call -notin $ignored) { "${label}: $name -> $call" }
            }
        }
    }
    $definitionFiles = {
        param($folder)
        Get-ChildItem -LiteralPath (Join-Path $repositoryPath $folder) -Filter '*.ps1' -File | Where-Object Name -ne '_tool-template.ps1'
    }

    It 'gives check workers every infrastructure function their allowlist calls' {
        $allowlisted = @($checkWorker.Keys | Where-Object { $infrastructure.ContainsKey($_) })
        $missing = @(& $getMissing 'infra' $checkWorker $allowlisted $checkWorker)
        if ($missing.Count -gt 0) { throw "Missing from Get-ParallelCheckFunctionBlock: $($missing -join '; ')" }
    }

    It 'gives check workers every infrastructure function reachable from tool checkers and comparers' {
        $missing = @(foreach ($file in & $definitionFiles 'tools') {
            $local = & $getFunctions (& $parse (Get-Content -LiteralPath $file.FullName -Raw))
            & $getMissing $file.Name $local @('Test-Tool', 'Compare-ToolVersions') $checkWorker
        })
        if ($missing.Count -gt 0) { throw "Missing from Get-ParallelCheckFunctionBlock: $($missing -join '; ')" }
    }

    It 'gives check workers every infrastructure function reachable from package-manager lookups' {
        $missing = @(foreach ($file in & $definitionFiles 'infra/PackageManagers') {
            $local = & $getFunctions (& $parse (Get-Content -LiteralPath $file.FullName -Raw))
            $roots = @($local.Keys | Where-Object { $_ -match '^Get-(InstalledVersion|LatestVersion|ReleasePlan|Installations)-PackageManager$' })
            & $getMissing $file.Name $local $roots $checkWorker
        })
        if ($missing.Count -gt 0) { throw "Missing from Get-ParallelCheckFunctionBlock: $($missing -join '; ')" }
    }

    It 'gives action jobs every infrastructure function their allowlist and package-manager executors call' {
        $allowlisted = @($actionWorker.Keys | Where-Object { $infrastructure.ContainsKey($_) })
        # Registry repairs always run in the approving session, never in a job.
        $missing = @(& $getMissing 'infra' $actionWorker $allowlisted $actionWorker @('Set-RegistryConfiguration'))
        $missing += @(foreach ($file in & $definitionFiles 'infra/PackageManagers') {
            $local = & $getFunctions (& $parse (Get-Content -LiteralPath $file.FullName -Raw))
            & $getMissing $file.Name $local @('Invoke-Command-PackageManager') $actionWorker
        })
        if ($missing.Count -gt 0) { throw "Missing from Get-ActionWorkerDefinitions: $($missing -join '; ')" }
    }

    It 'reports a call that an allowlist does not cover' {
        $local = & $getFunctions (& $parse 'function Test-Tool { Get-ProbeHelper }; function Get-ProbeHelper { Show-ResultsTable }')
        $missing = @(& $getMissing 'probe.ps1' $local @('Test-Tool') $checkWorker)
        $missing.Count | Should Be 1
        $missing[0] | Should Be 'probe.ps1: Get-ProbeHelper -> Show-ResultsTable'
    }

    It 'fails fast when an allowlisted infrastructure function no longer exists' {
        $message = try { Get-InfrastructureDefinitions -Names @('Get-ToolState', 'Get-RemovedHelper') } catch { $_.Exception.Message }
        $message | Should Be 'Worker infrastructure function(s) not found: Get-RemovedHelper'
    }
}