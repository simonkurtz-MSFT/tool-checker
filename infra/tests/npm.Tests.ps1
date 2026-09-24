# npm release selection contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-npm-tests-absent.env')

Describe 'npm release selection' {
    BeforeEach {
        $results = New-ToolCheckResults
        $SkipUpdate = $false
        Mock Invoke-SafeApiRequest {
            [pscustomobject]@{
                'dist-tags' = [pscustomobject]@{ latest = '1.2.0' }
                versions = [pscustomobject]@{ '1.0.0' = @{}; '1.1.0' = @{}; '1.2.0' = @{} }
                time = [pscustomobject]@{
                    '1.0.0' = [DateTimeOffset]::UtcNow.AddDays(-30).ToString('O')
                    '1.1.0' = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('O')
                    '1.2.0' = [DateTimeOffset]::UtcNow.AddDays(-7.5).ToString('O')
                }
            }
        }
        Mock Get-NpmVersionReleaseInfo { throw 'Metadata already contains release dates' }
        Mock Invoke-SafeApiRequest {
            [pscustomobject]@{ tag_name = 'v1.2.0'; draft = $false; prerelease = $false }
        } -ParameterFilter { $Uri -eq $toolsConfig['ncu'].LatestReleaseApiUrl }
    }

    It 'keeps the newest release separate from the pinned cooldown-safe upgrade' {
        $plan = Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'ncu'; InstalledVersion = '1.0.0' }
        $plan.LatestCooldown | Should Be '1.1.0'
        $plan.LatestReleased | Should Be '1.2.0'
        $results.Tools.ncu = @{ Installed = '1.0.0'; Latest = '' }
        Register-ReleasePlan -ToolName 'ncu' -InstalledVersion '1.0.0' -Plan $plan
        $results.Tools.ncu.LatestCooldown | Should Be '1.1.0'
        $results.Tools.ncu.LatestReleased | Should Be '1.2.0'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Version | Should Be '1.1.0'
        $results.AvailableUpdates[0].Command | Should Match 'npm-check-updates@1.1.0'
    }

    It 'reports the newest safe version even when installed is <Installed> without offering a downgrade' -TestCases @(
        @{ Installed = '1.1.0' }, @{ Installed = '1.2.0' }
    ) {
        param($Installed)
        $plan = Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'ncu'; InstalledVersion = $Installed }
        $plan.LatestCooldown | Should Be '1.1.0'
        $plan.LatestReleased | Should Be '1.2.0'
        $results.Tools.ncu = @{ Installed = $Installed; Latest = '' }
        Register-ReleasePlan -ToolName 'ncu' -InstalledVersion $Installed -Plan $plan
        $results.AvailableUpdates.Count | Should Be 0
        $results.Updates.Count | Should Be 0
    }

    It 'uses the same version in both columns with a zero-day cooldown' {
        $script:ReleaseCooldownDays = 0
        try {
            $plan = Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'ncu'; InstalledVersion = '1.0.0' }
            $plan.LatestCooldown | Should Be '1.2.0'
            $plan.LatestReleased | Should Be '1.2.0'
        } finally { $script:ReleaseCooldownDays = 8 }
    }

    It 'does not label an unverified release as cooldown-safe' {
        Mock Invoke-SafeApiRequest { [pscustomobject]@{ 'dist-tags' = [pscustomobject]@{ latest = '1.2.0' } } }
        Mock Get-NpmVersionReleaseInfo { $null }
        $plan = Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'ncu'; InstalledVersion = '1.0.0' }
        $plan.LatestCooldown | Should BeNullOrEmpty
        $plan.LatestReleased | Should Be '1.2.0'
        $plan.Installable | Should Be $false
        $results.Tools.ncu = @{ Installed = '1.0.0'; Latest = '' }
        Register-ReleasePlan -ToolName 'ncu' -InstalledVersion '1.0.0' -Plan $plan
        $results.Updates.Count | Should Be 0
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'uses a verified fallback date when registry metadata lacks history' {
        Mock Invoke-SafeApiRequest { [pscustomobject]@{ 'dist-tags' = [pscustomobject]@{ latest = '1.2.0' } } }
        Mock Get-NpmVersionReleaseInfo { [pscustomobject]@{ AgeDays = 8; Installable = $true } }
        $plan = Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'ncu'; InstalledVersion = '1.0.0' }
        $plan.LatestCooldown | Should Be '1.2.0'
        $plan.LatestReleased | Should Be '1.2.0'
        $plan.Installable | Should Be $true
    }

    It 'keeps a young release informational when there is no safe release' {
        Mock Invoke-SafeApiRequest { [pscustomobject]@{ 'dist-tags' = [pscustomobject]@{ latest = '1.2.0' } } }
        Mock Get-NpmVersionReleaseInfo { [pscustomobject]@{ AgeDays = 2; Installable = $false } }
        $plan = Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'ncu'; InstalledVersion = '1.0.0' }
        $plan.LatestCooldown | Should BeNullOrEmpty
        $plan.LatestReleased | Should Be '1.2.0'
        $results.Tools.ncu = @{ Installed = '1.0.0'; Latest = '' }
        Register-ReleasePlan -ToolName 'ncu' -InstalledVersion '1.0.0' -Plan $plan
        $results.Updates.Count | Should Be 0
        $results.AvailableUpdates.Count | Should Be 0
        $results.MaturityBlockedUpdates.Count | Should Be 1
    }

    It 'selects the newest production version when latest points to a prerelease' {
        $apiData = [PSCustomObject]@{
            versions = [PSCustomObject]@{
                '2.0.0-beta.1' = @{}
                '1.10.0' = @{}
                '1.9.0' = @{}
            }
        }

        Get-LatestProductionNpmVersion -ApiData $apiData | Should Be '1.10.0'
    }

    It 'requires eight full days before a release completes the cooldown' {
        $script:ReleaseCooldownDays | Should Be 8
        $apiData = [PSCustomObject]@{
            versions = [PSCustomObject]@{
                '1.2.0' = @{}
                '1.1.0' = @{}
                '1.0.0' = @{}
            }
            time = [PSCustomObject]@{
                '1.2.0' = [DateTimeOffset]::UtcNow.AddDays(-7.5).ToString('O')
                '1.1.0' = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('O')
                '1.0.0' = [DateTimeOffset]::UtcNow.AddDays(-30).ToString('O')
            }
        }

        $release = Get-LatestMatureNpmRelease -ApiData $apiData -MinimumVersion '1.0.0' -MaximumVersion '1.2.0'

        $release.Version | Should Be '1.1.0'
        $release.Installable | Should Be $true
    }
}

Describe 'Upstream npm tool release information' {
    BeforeEach {
        $results = New-ToolCheckResults
        $SkipUpdate = $false
        $script:UpstreamRequestFailed = $false
        $script:UpstreamReleaseFixture = [pscustomobject]@{ tag_name = 'v2.0.0'; draft = $false; prerelease = $false }
        $script:UpstreamRegistryFixture = [pscustomobject]@{
            'dist-tags' = [pscustomobject]@{ latest = '1.2.0' }
            versions = [pscustomobject]@{ '1.1.0' = @{}; '1.2.0' = @{} }
            time = [pscustomobject]@{
                '1.1.0' = [DateTimeOffset]::UtcNow.AddDays(-9).ToString('O')
                '1.2.0' = [DateTimeOffset]::UtcNow.ToString('O')
            }
        }
        Mock Invoke-SafeApiRequest {
            if ($Uri -like 'https://api.github.com/*') {
                if ($script:UpstreamRequestFailed) {
                    $results.Errors += 'Synthetic upstream request failed'
                    return $null
                }
                $script:UpstreamReleaseFixture
            } else { $script:UpstreamRegistryFixture }
        }
    }

    It 'uses upstream information without changing registry-safe actions for <ToolName>' -TestCases @(
        @{ ToolName = 'ncu' }, @{ ToolName = 'pnpm' }, @{ ToolName = 'GitHub Copilot CLI' }
    ) {
        param($ToolName)
        $plan = Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = $ToolName; InstalledVersion = '1.0.0' }
        $plan.LatestReleased | Should Be '2.0.0'
        $plan.LatestCooldown | Should Be '1.1.0'
        $plan.Latest | Should Be '1.1.0'
        $plan.Command | Should Match '@1.1.0 '
        $results.Tools[$ToolName] = @{ Installed = '1.0.0'; Latest = '' }
        Register-ReleasePlan -ToolName $ToolName -InstalledVersion '1.0.0' -Plan $plan
        $results.Tools[$ToolName].LatestReleased | Should Be '2.0.0'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Version | Should Be '1.1.0'
        $results.Errors.Count | Should Be 0
        Assert-MockCalled Invoke-SafeApiRequest 1 -Scope It -ParameterFilter { $Uri -eq $toolsConfig[$ToolName].LatestReleaseApiUrl }
    }

    It 'retains upstream information when registry metadata is unavailable' {
        $script:UpstreamRegistryFixture = $null
        $plan = Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'pnpm'; InstalledVersion = '1.0.0' }
        $results.Tools.pnpm = @{ Installed = '1.0.0'; Latest = '' }
        Register-ReleasePlan -ToolName 'pnpm' -InstalledVersion '1.0.0' -Plan $plan
        $results.Tools.pnpm.LatestReleased | Should Be '2.0.0'
        $results.Tools.pnpm.LatestCooldown | Should BeNullOrEmpty
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'does not substitute a registry version after an upstream request fails' {
        $script:UpstreamRequestFailed = $true
        $plan = Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'pnpm'; InstalledVersion = '1.0.0' }
        $plan.LatestReleased | Should Be 'unknown'
        $plan.LatestCooldown | Should Be '1.1.0'
        $results.Errors | Should Be 'Synthetic upstream request failed'
    }

    It 'reports an invalid upstream release (<Kind>) without blocking a safe registry update' -TestCases @(
        @{ Kind = 'missing tag'; Release = @{ draft = $false; prerelease = $false } },
        @{ Kind = 'draft'; Release = @{ tag_name = 'v2.0.0'; draft = $true; prerelease = $false } },
        @{ Kind = 'prerelease'; Release = @{ tag_name = 'v2.0.0'; draft = $false; prerelease = $true } },
        @{ Kind = 'invalid version'; Release = @{ tag_name = 'nightly'; draft = $false; prerelease = $false } }
    ) {
        param($Kind, $Release)
        $script:UpstreamReleaseFixture = [pscustomobject]$Release
        $plan = Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'pnpm'; InstalledVersion = '1.0.0' }
        $plan.LatestReleased | Should Be 'unknown'
        $plan.LatestCooldown | Should Be '1.1.0'
        $results.Errors.Count | Should Be 1
        $results.Errors[0] | Should Match 'Could not determine upstream release for pnpm'
    }

    It 'preserves registry-only behavior for catalog entries without an upstream endpoint' {
        $config = $toolsConfig['pnpm']
        $endpoint = $config.LatestReleaseApiUrl
        try {
            $config.Remove('LatestReleaseApiUrl')
            $plan = Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = 'pnpm'; InstalledVersion = '1.0.0' }
            $plan.LatestReleased | Should Be '1.2.0'
            $plan.LatestCooldown | Should Be '1.1.0'
            Assert-MockCalled Invoke-SafeApiRequest 0 -Scope It -ParameterFilter { $Uri -like 'https://api.github.com/*' }
        } finally { $config.LatestReleaseApiUrl = $endpoint }
    }
}

Describe 'Node package installation discovery' {
    function npm { throw 'Unexpected npm execution' }
    BeforeEach {
        $results = New-ToolCheckResults
        Mock Test-CommandExists { $true }
        Mock Get-GlobalNodePackageInventory {
            if ($PackageManager -eq 'npm') {
                '{"dependencies":{"@github/copilot":{"version":"1.0.84-2","path":"/npm/node_modules/@github/copilot"}}}' | ConvertFrom-Json
            } else {
                '[{"dependencies":{"@github/copilot":{"version":"1.0.83-3","path":"/pnpm/node_modules/@github/copilot"}}}]' | ConvertFrom-Json
            }
        }
    }

    It 'discovers duplicate installations with their own versions and paths' {
        $before = ConvertTo-Json $results -Depth 10 -Compress
        $installations = @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' })
        $installations.Count | Should Be 2
        $installations[0].PackageManager | Should Be 'npm'
        $installations[0].Version | Should Be '1.0.84-2'
        $installations[0].Path | Should Be '/npm/node_modules/@github/copilot'
        $installations[0].RemoveCommand | Should Be 'npm uninstall --global @github/copilot'
        $installations[1].PackageManager | Should Be 'pnpm'
        $installations[1].Version | Should Be '1.0.83-3'
        $installations[1].RemoveCommand | Should Be 'pnpm remove --global @github/copilot'
        (ConvertTo-Json $results -Depth 10 -Compress) | Should Be $before
    }

    It 'discovers a package installed only through <Manager>' -TestCases @(@{ Manager = 'npm' }, @{ Manager = 'pnpm' }) {
        param($Manager)
        $script:ExpectedManager = $Manager
        Mock Test-CommandExists { $Command -eq $script:ExpectedManager }
        $installations = @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' })
        $installations.Count | Should Be 1
        $installations[0].PackageManager | Should Be $Manager
    }

    It 'uses the npm global root when inventory omits the package path' {
        Mock Test-CommandExists { $Command -eq 'npm' }
        Mock Get-GlobalNodePackageInventory { '{"dependencies":{"@github/copilot":{"version":"1.0.84-2"}}}' | ConvertFrom-Json }
        Mock npm { $global:LASTEXITCODE = 0; Join-Path $TestDrive 'node_modules' }

        $installations = @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' })

        $installations.Count | Should Be 1
        $installations[0].Path | Should Be (Join-Path $TestDrive 'node_modules/@github/copilot')
        Assert-MockCalled npm 1 -Scope It -ParameterFilter { $args -contains 'root' -and $args -contains '-g' }
    }

    It 'skips absent package managers' {
        Mock Test-CommandExists { $false }
        @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' }).Count | Should Be 0
        Assert-MockCalled Get-GlobalNodePackageInventory 0 -Scope It
    }

    It 'does not report unrelated packages as installations' {
        Mock Get-GlobalNodePackageInventory { '{"dependencies":{"other":{"version":"1.0.0"}}}' | ConvertFrom-Json }
        @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' }).Count | Should Be 0
    }

    It 'treats inventories without dependencies as empty rather than unavailable' {
        Mock Get-GlobalNodePackageInventory { '{"name":"empty"}' | ConvertFrom-Json }
        @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' }).Count | Should Be 0
    }

    It 'distinguishes unavailable inventory from an absent package' {
        Mock Get-GlobalNodePackageInventory { throw 'Invalid inventory' }
        $installations = @(Invoke-PackageManagerOperation -PackageManager 'npm.ps1' -Operation 'Get-Installations' -Arguments @{ ToolName = 'GitHub Copilot CLI' })
        $installations.Count | Should Be 2
        $installations[0].Status | Should Be 'Unavailable'
        $installations[1].Status | Should Be 'Unavailable'
    }
}

Describe 'Node package inventory commands' {
    function npm { throw 'Unexpected npm execution' }
    It 'rejects malformed inventory and nonzero npm exits' {
        Mock npm { $global:LASTEXITCODE = 0; 'not JSON' }
        $message = try { Get-GlobalNodePackageInventory -PackageManager npm } catch { $_.Exception.Message }
        [string]::IsNullOrEmpty($message) | Should Be $false

        Mock npm { $global:LASTEXITCODE = 1; '{"dependencies":{}}' }
        $message = try { Get-GlobalNodePackageInventory -PackageManager npm } catch { $_.Exception.Message }
        $message | Should Match 'Could not read npm global inventory'
    }
}

Describe 'npm installed version refresh' {
    BeforeEach {
        $results = New-ToolCheckResults
        Mock Get-GlobalNodePackageInventory {
            '{"dependencies":{"@github/copilot":{"version":"1.0.84-2","path":"/packages/@github/copilot"}}}' | ConvertFrom-Json
        }
        Mock Get-GlobalNpmInstalledVersion { '1.0.84-2' }
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { 'GitHub Copilot CLI 1.0.83-3.' }
    }

    It 'uses the package revision instead of the CLI banner during discovery' {
        Get-InstalledVersionFromOutput -ToolName 'GitHub Copilot CLI' -Output 'GitHub Copilot CLI 1.0.83-3.' | Should Be '1.0.84-2'
        $results.ToolState['github-copilot-cli'].InstalledVersionSource | Should Be 'npm.ps1'
        Assert-MockCalled Get-GlobalNpmInstalledVersion 1 -Scope It -ParameterFilter { $PackageName -eq '@github/copilot' }
    }

    It 'refreshes the installed package revision and clears the displayed update command' {
        $results.Tools['GitHub Copilot CLI'] = @{ ToolId = 'github-copilot-cli'; Installed = '1.0.83'; Latest = '1.0.84-2'; LatestCooldown = '1.0.84-2'; LatestReleased = '1.0.85' }
        (Get-ToolState 'github-copilot-cli').Installations = @(@{ PackageManager = 'npm'; Version = '1.0.83'; Status = 'Found' })

        Refresh-ToolVersion -ToolName 'GitHub Copilot CLI' | Should Be $true

        $row = $results.Tools['GitHub Copilot CLI']
        $row.Installed | Should Be '1.0.84-2'
        $row.Latest | Should Be '1.0.84-2'
        $row.LatestCooldown | Should Be '1.0.84-2'
        $row.LatestReleased | Should Be '1.0.85'
        $results.ToolState['github-copilot-cli'].Installations.Count | Should Be 2
        $results.ToolState['github-copilot-cli'].Installations[0].Version | Should Be '1.0.84-2'
        Get-UpdateCommand -ToolName 'GitHub Copilot CLI' -Installed $row.Installed -Latest $row.Latest | Should Be ''
    }

    It 'falls back to CLI versions with or without a package revision when npm metadata is unavailable' {
        Mock Get-GlobalNpmInstalledVersion { $null }

        Get-InstalledVersionFromOutput -ToolName 'GitHub Copilot CLI' -Output 'GitHub Copilot CLI 1.0.84' | Should Be '1.0.84'
        Get-InstalledVersionFromOutput -ToolName 'GitHub Copilot CLI' -Output 'GitHub Copilot CLI 1.0.84-2' | Should Be '1.0.84-2'
        $results.ToolState['github-copilot-cli'].InstalledVersionSource | Should Be 'command'
    }
}

Describe 'npm installed version worker' {
    It 'reads npm metadata with only Copilot selected in check-only mode' {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'absent.env') -SkipUpdate
        $toolsConfig = @{ 'GitHub Copilot CLI' = $toolsConfig['GitHub Copilot CLI'] }
        $script:ToolDefinitions = @{}
        $script:PackageManagerDefinitions = Read-DefinitionRegistry -Files @(Get-PackageManagerDefinitionFiles -ToolsConfiguration $toolsConfig -Directory (Join-Path (Split-Path $scriptPath) 'infra/PackageManagers'))

        Invoke-ParallelChecks -Total 1 -TimeoutSec 10 -Checks @(@{
            Name = 'GitHub Copilot CLI'
            Block = {
                function copilot { 'GitHub Copilot CLI 1.0.83-3.' }
                function npm {
                    $global:LASTEXITCODE = 0
                    if ($args -contains 'list' -and $args -contains '--json') {
                        '{"dependencies":{"@github/copilot":{"version":"1.0.84-2","path":"/npm/@github/copilot"}}}'
                    } else { throw 'Unexpected npm operation' }
                }
                function pnpm {
                    $global:LASTEXITCODE = 0
                    if ($args -contains 'list' -and $args -contains '--json') {
                        '[{"dependencies":{"@github/copilot":{"version":"1.0.83-3","path":"/pnpm/@github/copilot"}}}]'
                    } else { throw 'Unexpected pnpm operation' }
                }
                Test-StandardTool -ToolName 'GitHub Copilot CLI'
            }
        })

        $results.Tools['GitHub Copilot CLI'].Installed | Should Be '1.0.84-2'
        $results.ToolState['github-copilot-cli'].InstalledVersionSource | Should Be 'npm.ps1'
        $results.ToolState['github-copilot-cli'].Installations.Count | Should Be 2
        $results.ToolState['github-copilot-cli'].Installations[1].PackageManager | Should Be 'pnpm'
        $results.ToolState['github-copilot-cli'].Installations[1].Version | Should Be '1.0.83-3'
        $results.AvailableUpdates.Count | Should Be 0
        $results.Errors.Count | Should Be 0
    }
}