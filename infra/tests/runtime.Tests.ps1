# Tool-file resolution, registration, and entry-point dispatch contracts. Isolated
# sessions and synthetic definitions verify selection and scope isolation without real checks.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) "runtime-tests-$([guid]::NewGuid()).env")

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
                    WorkerDefinitions = Get-ParallelCheckFunctionBlock
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
        $functionBlock = Get-ParallelCheckFunctionBlock

        $functionBlock | Should Match 'function Get-NodeReleasePlan'
        $functionBlock | Should Match 'function Test-Tool'
        $functionBlock | Should Match 'function Invoke-ToolUpdate'
        $functionBlock | Should Not Match 'Implement the tool-specific check before registering this file'
    }
}
