# .NET SDK worker, refresh, inventory, and release-planning contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-dotnet-tests-absent.env')

Describe '.NET SDK tool integration' {
    BeforeEach {
        $previousResults = $results
        $results = New-ToolCheckResults
    }

    AfterEach { $results = $previousResults }

    It 'loads only the .NET definition when its catalog ID is selected' {
        $selectionFile = Join-Path $TestDrive 'dotnet-only.env'
        Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=dotnet-sdk'
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($path, $envFile)
                . $path -EnvFile $envFile
                Assert-ToolConfigurations
                [PSCustomObject]@{
                    LoadedFiles = @($script:ToolDefinitionFiles.Name)
                    EntryPoints = @($script:ToolDefinitions['dotnet-sdk'].Keys)
                    LeakedFunctions = @(Get-Command -CommandType Function | Where-Object Name -in @(
                        'Test-Tool', 'Refresh-ToolStatus', 'ConvertFrom-DotNetSDKList',
                        'Get-DotNetSDKInventory', 'Get-DotNetSDKReleasePlan'
                    ))
                    WorkerDefinitions = Get-ParallelCheckFunctionBlock
                }
            }).AddArgument($scriptPath).AddArgument($selectionFile)
            $observed = @($session.Invoke())
            $session.HadErrors | Should Be $false
            $observed.Count | Should Be 1
            $observed[0].LoadedFiles.Count | Should Be 1
            $observed[0].LoadedFiles[0] | Should Be 'dotnet-sdk.ps1'
            $observed[0].EntryPoints -contains 'Test-Tool' | Should Be $true
            $observed[0].EntryPoints -contains 'Refresh-ToolStatus' | Should Be $true
            $observed[0].LeakedFunctions.Count | Should Be 0
            $observed[0].WorkerDefinitions | Should Match 'function Get-DotNetSDKReleasePlan'
            $observed[0].WorkerDefinitions | Should Not Match 'function Get-NodeReleasePlan'
        } finally { $session.Dispose() }
    }

    It 'plans patch updates and newer majors in a network-free worker' {
        $checks = @(@{
            Name = '.NET SDK'
            Block = {
                function Test-CommandExists { $true }
                function dotnet { '8.0.100 [C:\dotnet\sdk]'; '8.0.301 [C:\dotnet\sdk]' }
                function Get-WingetLatestVersion {
                    param($ToolName, $PackageId)
                    if ($PackageId -eq 'Microsoft.DotNet.SDK.8') { '8.0.410' } else { '9.0.203' }
                }
                function Invoke-RestMethod {
                    [PSCustomObject]@{ 'releases-index' = @(
                        [PSCustomObject]@{ 'channel-version' = '8.0'; 'latest-sdk' = '8.0.410'; 'support-phase' = 'active' },
                        [PSCustomObject]@{ 'channel-version' = '9.0'; 'latest-sdk' = '9.0.203'; 'support-phase' = 'active' }
                    ) }
                }
                $SkipUpdate = $false
                Invoke-ToolEntryPoint -ToolId 'dotnet-sdk' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
            }
        })
        Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5
        (Get-ToolState 'dotnet-sdk').Count | Should Be 2
        (Get-ToolState 'dotnet-sdk')['8.0.100'].HighestInstalled | Should Be '8.0.301'
        $results.Tools['.NET SDK 8.0.100'].Latest | Should Be '8.0.410'
        $results.Tools['.NET SDK 8.0.301'].Latest | Should Be '8.0.410'
        $results.Updates -contains '.NET SDK: 8.0.301 -> 8.0.410' | Should Be $true
        $results.Updates -contains '.NET SDK: Major version 9 available' | Should Be $true
        $results.AvailableUpdates.Count | Should Be 2
        ($results.AvailableUpdates | Where-Object Type -eq 'winget').Command | Should Be 'winget upgrade Microsoft.DotNet.SDK.8 --silent'
        ($results.AvailableUpdates | Where-Object Type -eq 'winget-new').Command | Should Be 'winget install Microsoft.DotNet.SDK.9 --silent'
        $results.Errors.Count | Should Be 0
    }

    It 'plans the WinGet Preview package for .NET 11 in a network-free worker' {
        $checks = @(@{
            Name = '.NET SDK'
            Block = {
                function Test-CommandExists { $true }
                function dotnet { '10.0.401 [C:\dotnet\sdk]'; '11.0.100-rc.1.26425.100 [C:\dotnet\sdk]' }
                function Get-WingetLatestVersion {
                    param($ToolName, $PackageId)
                    switch ($PackageId) {
                        'Microsoft.DotNet.SDK.10' { '10.0.401' }
                        'Microsoft.DotNet.SDK.Preview' { '11.0.100-rc.1.26425.128' }
                        default { $results.Errors += "Unexpected package $PackageId"; $null }
                    }
                }
                function Invoke-RestMethod {
                    [PSCustomObject]@{ 'releases-index' = @(
                        [PSCustomObject]@{ 'channel-version' = '11.0'; 'latest-sdk' = '11.0.100-rc.1.26425.128'; 'support-phase' = 'go-live' },
                        [PSCustomObject]@{ 'channel-version' = '10.0'; 'latest-sdk' = '10.0.401'; 'support-phase' = 'active' }
                    ) }
                }
                $SkipUpdate = $false
                Invoke-ToolEntryPoint -ToolId 'dotnet-sdk' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
            }
        })
        Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5
        $results.Tools['.NET SDK 11.0.100-rc.1.26425.100'].Latest | Should Be '11.0.100-rc.1.26425.128'
        $results.Updates -contains '.NET SDK: 11.0.100-rc.1.26425.100 -> 11.0.100-rc.1.26425.128' | Should Be $true
        ($results.AvailableUpdates | Where-Object Name -eq '.NET SDK 11.0.100-rc.1.26425.100').Command |
            Should Be 'winget upgrade Microsoft.DotNet.SDK.Preview --silent'
        $results.Errors.Count | Should Be 0
    }

    It 'plans a new .NET 11 install with the WinGet Preview package' {
        $checks = @(@{
            Name = '.NET SDK'
            Block = {
                function Test-CommandExists { $true }
                function dotnet { '10.0.401 [C:\dotnet\sdk]' }
                function Get-WingetLatestVersion {
                    param($ToolName, $PackageId)
                    switch ($PackageId) {
                        'Microsoft.DotNet.SDK.10' { '10.0.401' }
                        'Microsoft.DotNet.SDK.Preview' { '11.0.100-rc.1.26425.128' }
                        default { $results.Errors += "Unexpected package $PackageId"; $null }
                    }
                }
                function Invoke-RestMethod {
                    [PSCustomObject]@{ 'releases-index' = @(
                        [PSCustomObject]@{ 'channel-version' = '11.0'; 'latest-sdk' = '11.0.100-rc.1.26425.128'; 'support-phase' = 'go-live' },
                        [PSCustomObject]@{ 'channel-version' = '10.0'; 'latest-sdk' = '10.0.401'; 'support-phase' = 'active' }
                    ) }
                }
                $SkipUpdate = $false
                Invoke-ToolEntryPoint -ToolId 'dotnet-sdk' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
            }
        })
        Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5
        $results.Updates -contains '.NET SDK: Major version 11 available' | Should Be $true
        ($results.AvailableUpdates | Where-Object Type -eq 'winget-new').Command | Should Be 'winget install Microsoft.DotNet.SDK.Preview --silent'
        $results.Errors.Count | Should Be 0
    }

    It 'preserves check-only inventory without release or package lookups in a worker' {
        $checks = @(@{
            Name = '.NET SDK'
            Block = {
                function Test-CommandExists { $true }
                function dotnet { '8.0.301 [C:\dotnet\sdk]' }
                function Get-WingetLatestVersion { $results.Errors += 'Unexpected package lookup'; throw 'Unexpected package lookup' }
                function Invoke-RestMethod { $results.Errors += 'Unexpected release lookup'; throw 'Unexpected release lookup' }
                $SkipUpdate = $true
                Invoke-ToolEntryPoint -ToolId 'dotnet-sdk' -EntryPoint 'Test-Tool' -Arguments @{ Progress = $args[0] }
            }
        })
        Invoke-ParallelChecks -Checks $checks -Total 1 -TimeoutSec 5
        (Get-ToolState 'dotnet-sdk').Count | Should Be 1
        $results.Tools['.NET SDK 8.0.301'].Installed | Should Be '8.0.301'
        $results.Tools['.NET SDK 8.0.301'].Latest | Should Be ''
        $results.Updates.Count | Should Be 0
        $results.AvailableUpdates.Count | Should Be 0
        $results.Errors.Count | Should Be 0
    }

    It 'refreshes catalog and dynamic SDK rows and prunes only satisfied updates' {
        function dotnet { '8.0.410 [C:\dotnet\sdk]' }
        Mock Test-CommandExists { $true }
        Mock Invoke-RestMethod {
            [PSCustomObject]@{ 'releases-index' = @(
                [PSCustomObject]@{ 'channel-version' = '8.0'; 'latest-sdk' = '8.0.410'; 'support-phase' = 'active' }
            ) }
        }
        foreach ($toolName in @('.NET SDK', '.NET SDK 8.0.301')) {
            $results = New-ToolCheckResults
            $results.Tools['.NET SDK 8.0.301'] = @{ ToolId = 'dotnet-sdk'; Installed = '8.0.301'; Latest = '8.0.410' }
            $results.Tools['NodeJS'] = @{ Installed = '22.1.0'; Latest = '22.1.1' }
            (Get-ToolState 'dotnet-sdk')['8.0.301'] = @{ Installed = '8.0.301'; Latest = '8.0.410' }
            $results.Updates = @('.NET SDK: 8.0.301 -> 8.0.410', '.NET SDK: Major version 9 available', 'NodeJS')
            $results.AvailableUpdates = @(
                @{ Name = '.NET SDK 8.0.301' },
                @{ Name = '.NET SDK 9 (new major version)' },
                @{ Name = 'NodeJS' }
            )
            Refresh-ToolVersion -ToolName $toolName | Should Be $true
            $results.Tools.ContainsKey('.NET SDK 8.0.301') | Should Be $false
            (Get-ToolState 'dotnet-sdk').ContainsKey('8.0.301') | Should Be $false
            (Get-ToolState 'dotnet-sdk')['8.0.410'].HighestInstalled | Should Be '8.0.410'
            $results.Tools['.NET SDK 8.0.410'].Latest | Should Be '8.0.410'
            $results.Tools['NodeJS'].Installed | Should Be '22.1.0'
            $results.Updates.Count | Should Be 2
            $results.Updates -contains '.NET SDK: Major version 9 available' | Should Be $true
            $results.Updates -contains 'NodeJS' | Should Be $true
            $results.AvailableUpdates.Count | Should Be 2
            $results.AvailableUpdates.Name -contains '.NET SDK 9 (new major version)' | Should Be $true
            $results.AvailableUpdates.Name -contains 'NodeJS' | Should Be $true
        }
    }

    It 'keeps refreshed inventory when release metadata is unavailable' {
        function dotnet { '8.0.410 [C:\dotnet\sdk]' }
        Mock Test-CommandExists { $true }
        Mock Invoke-RestMethod { throw 'Synthetic offline response' }
        $results.Tools['.NET SDK 8.0.301'] = @{ ToolId = 'dotnet-sdk'; Installed = '8.0.301'; Latest = '8.0.410' }
        Refresh-ToolVersion -ToolName '.NET SDK 8.0.301' | Should Be $true
        (Get-ToolState 'dotnet-sdk').Count | Should Be 1
        $results.Tools['.NET SDK 8.0.410'].Installed | Should Be '8.0.410'
        $results.Tools['.NET SDK 8.0.410'].Latest | Should Be ''
    }
}

Describe '.NET SDK release planning' {
    BeforeEach { . (Join-Path (Split-Path -Parent $scriptPath) 'tools/dotnet-sdk.ps1') }

    It 'keeps inventory planning working when a preview SDK is installed' {
        $records = ConvertFrom-DotNetSDKList -OutputLines @(
            '10.0.100-rc.1.25451.107 [C:\dotnet\sdk]',
            '10.0.100 [C:\dotnet\sdk]'
        )
        $inventory = Get-DotNetSDKInventory -SdkRecords $records -LatestSdkByChannel @{
            '10.0' = @{ LatestSdk = '10.0.101'; SupportPhase = 'active' }
        }
        $inventory.DotNetSDKs['10.0.100'].HighestInstalled | Should Be '10.0.100'
        $inventory.Tools['.NET SDK 10.0.100'].Covered | Should Be $false
    }

    It 'parses SDK list output and annotates every row from its channel' {
        $records = ConvertFrom-DotNetSDKList -OutputLines @(
            '8.0.100 [C:\Program Files\dotnet\sdk]',
            '8.0.301 [C:\Program Files\dotnet\sdk]',
            'not an SDK row'
        )
        $inventory = Get-DotNetSDKInventory -SdkRecords $records -LatestSdkByChannel @{
            '8.0' = @{ LatestSdk = '8.0.410'; SupportPhase = 'active' }
        }
        $records.Count | Should Be 2
        $records[0].Path | Should Be 'C:\Program Files\dotnet\sdk'
        $inventory.ByMajor['8'].Count | Should Be 2
        $inventory.DotNetSDKs['8.0.100'].Latest | Should Be '8.0.410'
        $inventory.DotNetSDKs['8.0.100'].HighestInstalled | Should Be '8.0.301'
        $inventory.Tools['.NET SDK 8.0.301'].Latest | Should Be '8.0.410'
    }

    It 'prefers an orchestrator-provided latest version for a major' {
        $records = ConvertFrom-DotNetSDKList -OutputLines @('9.0.100 [C:\dotnet\sdk]')
        $inventory = Get-DotNetSDKInventory -SdkRecords $records `
            -LatestSdkByChannel @{ '9.0' = @{ LatestSdk = '9.0.200' } } `
            -LatestSdkByMajor @{ '9' = '9.0.203' }
        $inventory.DotNetSDKs['9.0.100'].Latest | Should Be '9.0.203'
    }

    It 'groups installed SDKs and returns newer supported production majors' {
        $index = [PSCustomObject]@{ 'releases-index' = @(
            [PSCustomObject]@{ 'channel-version' = '10.0'; 'latest-sdk' = '10.0.101'; 'support-phase' = 'active' },
            [PSCustomObject]@{ 'channel-version' = '11.0'; 'latest-sdk' = '11.0.100-preview.2'; 'support-phase' = 'preview' },
            [PSCustomObject]@{ 'channel-version' = '9.0'; 'latest-sdk' = '9.0.203'; 'support-phase' = 'active' },
            [PSCustomObject]@{ 'channel-version' = '8.0'; 'latest-sdk' = '8.0.410'; 'support-phase' = 'active' },
            [PSCustomObject]@{ 'channel-version' = '7.0'; 'latest-sdk' = '7.0.410'; 'support-phase' = 'eol' }
        ) }
        $plan = Get-DotNetSDKReleasePlan -InstalledVersions @('8.0.100', '8.0.301', '9.0.100') -ReleasesIndex $index
        $plan.ByMajor['8'].Count | Should Be 2
        $plan.LatestSdkByChannel['9.0'].LatestSdk | Should Be '9.0.203'
        $plan.LatestSdkByChannel.ContainsKey('11.0') | Should Be $false
        $plan.NewerMajors.Count | Should Be 1
        $plan.NewerMajors[0] | Should Be 10
    }

    It 'offers a go-live channel as a newer major using the WinGet Preview package' {
        $index = [PSCustomObject]@{ 'releases-index' = @(
            [PSCustomObject]@{ 'channel-version' = '11.0'; 'latest-sdk' = '11.0.100-rc.1.26425.128'; 'support-phase' = 'go-live' },
            [PSCustomObject]@{ 'channel-version' = '10.0'; 'latest-sdk' = '10.0.401'; 'support-phase' = 'active' },
            [PSCustomObject]@{ 'channel-version' = '9.0'; 'latest-sdk' = '9.0.318'; 'support-phase' = 'maintenance' }
        ) }
        $plan = Get-DotNetSDKReleasePlan -InstalledVersions @('10.0.401') -ReleasesIndex $index
        $plan.LatestSdkByChannel['11.0'].LatestSdk | Should Be '11.0.100-rc.1.26425.128'
        $plan.NewerMajors.Count | Should Be 1
        $plan.NewerMajors[0] | Should Be 11
        $plan.WingetPackageIds['11'] | Should Be 'Microsoft.DotNet.SDK.Preview'
        $plan.WingetPackageIds['10'] | Should Be 'Microsoft.DotNet.SDK.10'
    }

    It 'switches to the numbered WinGet package once .NET 11 is generally available' {
        $index = [PSCustomObject]@{ 'releases-index' = @(
            [PSCustomObject]@{ 'channel-version' = '11.0'; 'latest-sdk' = '11.0.100'; 'support-phase' = 'active' },
            [PSCustomObject]@{ 'channel-version' = '10.0'; 'latest-sdk' = '10.0.401'; 'support-phase' = 'active' }
        ) }
        $plan = Get-DotNetSDKReleasePlan -InstalledVersions @('10.0.401') -ReleasesIndex $index
        $plan.WingetPackageIds['11'] | Should Be 'Microsoft.DotNet.SDK.11'
        $plan.NewerMajors[0] | Should Be 11
    }

    It 'allows an installed preview channel when prereleases are enabled' {
        $index = [PSCustomObject]@{ 'releases-index' = @(
            [PSCustomObject]@{ 'channel-version' = '11.0'; 'latest-sdk' = '11.0.100-preview.2'; 'support-phase' = 'preview' },
            [PSCustomObject]@{ 'channel-version' = '10.0'; 'latest-sdk' = '10.0.101'; 'support-phase' = 'active' }
        ) }
        $plan = Get-DotNetSDKReleasePlan -InstalledVersions @('11.0.100-preview.1') -ReleasesIndex $index -ProductionReleasesOnly $false
        $plan.LatestSdkByChannel.ContainsKey('11.0') | Should Be $true
        $plan.NewerMajors.Count | Should Be 0
    }
}