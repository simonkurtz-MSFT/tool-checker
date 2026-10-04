# Pi catalog and cooldown contracts, using synthetic metadata without installs or network calls.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'

Describe 'Pi npm support' {
    $selectionFile = Join-Path $TestDrive 'pi-only.env'
    Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=pi'
    . $scriptPath -EnvFile $selectionFile

    BeforeEach {
        $results = New-ToolCheckResults
        $SkipUpdate = $false
        $script:ReleaseCooldownDays = 8
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { '0.60.0' }
        Mock Get-GlobalNpmInstalledVersion { '0.60.0' }
        Mock Get-GlobalNodePackageInventory { [pscustomobject]@{} }
        Mock Get-NpmVersionReleaseInfo { $null }
        Mock Invoke-SafeApiRequest {
            if ($Uri -like 'https://api.github.com/*') {
                return [pscustomobject]@{ tag_name = 'v0.64.0'; draft = $false; prerelease = $false }
            }
            [pscustomobject]@{
                'dist-tags' = [pscustomobject]@{ latest = '0.63.0' }
                versions = [pscustomobject]@{ '0.61.0' = @{}; '0.62.0' = @{}; '0.63.0' = @{} }
                time = [pscustomobject]@{
                    '0.61.0' = [DateTimeOffset]::UtcNow.AddDays(-20).ToString('O')
                    '0.62.0' = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('O')
                    '0.63.0' = [DateTimeOffset]::UtcNow.AddDays(-7.5).ToString('O')
                }
            }
        }
    }

    It 'selects Pi alone with the shared npm framework and no source-build dispatch' {
        $toolsConfig.Count | Should Be 1
        $config = $toolsConfig.Pi
        $config.Id | Should Be 'pi'
        $config.CheckType | Should Be 'standard'
        $config.ToolFile | Should BeNullOrEmpty
        $script:ToolDefinitions.Count | Should Be 0
        $script:PackageManagerDefinitions.Count | Should Be 1
        $config.NpmPackageName | Should Be '@earendil-works/pi-coding-agent'
        $config.UpdateCommand | Should Be 'npm install -g @earendil-works/pi-coding-agent@latest --loglevel=error'
        foreach ($command in $config.InstallCommands.Values) {
            $command | Should Be 'npm install -g @earendil-works/pi-coding-agent@latest --loglevel=error'
        }
    }

    It 'pins updates to eight-full-day registry releases even when GitHub is newer' {
        Test-StandardTool -ToolName Pi

        $results.Tools.Pi.Installed | Should Be '0.60.0'
        $results.Tools.Pi.LatestCooldown | Should Be '0.62.0'
        $results.Tools.Pi.LatestReleased | Should Be '0.64.0'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Version | Should Be '0.62.0'
        $results.AvailableUpdates[0].Command | Should Be 'npm install -g @earendil-works/pi-coding-agent@0.62.0 --loglevel=error'
        $results.AvailableUpdates[0].Executor | Should Be 'command'
        Assert-MockCalled Get-GlobalNpmInstalledVersion 1 -Scope It -ParameterFilter { $PackageName -eq '@earendil-works/pi-coding-agent' }
    }

    It 'does not offer a downgrade or update when the safe release is already installed' {
        Mock Get-GlobalNpmInstalledVersion { '0.62.0' }
        Test-StandardTool -ToolName Pi
        $results.Tools.Pi.LatestCooldown | Should Be '0.62.0'
        $results.Tools.Pi.LatestReleased | Should Be '0.64.0'
        $results.AvailableUpdates.Count | Should Be 0
    }

    It 'never uses GitHub as an actionable fallback when registry age is <Age>' -TestCases @(
        @{ Age = 'young'; Days = 1 },
        @{ Age = 'unknown'; Days = $null }
    ) {
        param($Age, $Days)
        $script:PiTestDays = $Days
        $Force = $true
        Mock Get-NpmVersionReleaseInfo {
            if ($null -ne $script:PiTestDays) {
                [pscustomobject]@{ AgeDays = $script:PiTestDays; Installable = $false }
            }
        }
        Mock Invoke-SafeApiRequest {
            if ($Uri -like 'https://api.github.com/*') {
                return [pscustomobject]@{ tag_name = 'v0.64.0'; draft = $false; prerelease = $false }
            }
            $time = if ($null -ne $script:PiTestDays) {
                [pscustomobject]@{ '0.63.0' = [DateTimeOffset]::UtcNow.AddDays(-$script:PiTestDays).ToString('O') }
            } else { [pscustomobject]@{} }
            [pscustomobject]@{
                'dist-tags' = [pscustomobject]@{ latest = '0.63.0' }
                versions = [pscustomobject]@{ '0.63.0' = @{} }
                time = $time
            }
        }
        Test-StandardTool -ToolName Pi
        $results.Tools.Pi.LatestCooldown | Should BeNullOrEmpty
        $results.Tools.Pi.LatestReleased | Should Be '0.64.0'
        $results.Tools.Pi.Installable | Should Be $false
        $results.AvailableUpdates.Count | Should Be 0
        $results.MaturityBlockedUpdates.Count | Should Be $(if ($Age -eq 'young') { 1 } else { 0 })
    }

    It 'uses the runtime cooldown override without making GitHub installable' {
        $script:ReleaseCooldownDays = 0
        Test-StandardTool -ToolName Pi
        $results.Tools.Pi.LatestCooldown | Should Be '0.63.0'
        $results.Tools.Pi.LatestReleased | Should Be '0.64.0'
        $results.AvailableUpdates[0].Command | Should Be 'npm install -g @earendil-works/pi-coding-agent@0.63.0 --loglevel=error'
    }

    It 'falls back to the CLI version when global npm metadata is absent' {
        Mock Get-GlobalNpmInstalledVersion { $null }
        Test-StandardTool -ToolName Pi
        $results.Tools.Pi.Installed | Should Be '0.60.0'
        $results.ToolState.pi.InstalledVersionSource | Should Be 'command'
    }

    It 'inventories Pi in check-only mode without requesting any release metadata' {
        $SkipUpdate = $true
        Test-StandardTool -ToolName Pi
        $results.Tools.Pi.Installed | Should Be '0.60.0'
        $results.Tools.Pi.Latest | Should BeNullOrEmpty
        $results.AvailableUpdates.Count | Should Be 0
        Assert-MockCalled Invoke-SafeApiRequest 0 -Scope It
    }

    It 'preserves pinned registry updates in a selected-alone real worker' {
        Invoke-ParallelChecks -Total 1 -TimeoutSec 10 -Checks @(@{
            Name = 'Pi'
            Block = {
                function Test-CommandExists { $true }
                function Get-CommandVersion { '0.60.0' }
                function Get-GlobalNpmInstalledVersion { '0.60.0' }
                function Get-GlobalNodePackageInventory { [pscustomobject]@{} }
                function Invoke-SafeApiRequest {
                    param($Uri)
                    if ($Uri -like 'https://api.github.com/*') {
                        return [pscustomobject]@{ tag_name = 'v0.64.0'; draft = $false; prerelease = $false }
                    }
                    [pscustomobject]@{
                        'dist-tags' = [pscustomobject]@{ latest = '0.63.0' }
                        versions = [pscustomobject]@{ '0.62.0' = @{}; '0.63.0' = @{} }
                        time = [pscustomobject]@{
                            '0.62.0' = [DateTimeOffset]::UtcNow.AddDays(-9).ToString('O')
                            '0.63.0' = [DateTimeOffset]::UtcNow.ToString('O')
                        }
                    }
                }
                Test-StandardTool -ToolName Pi
            }
        })
        $results.Errors.Count | Should Be 0
        $results.Tools.Pi.LatestCooldown | Should Be '0.62.0'
        $results.Tools.Pi.LatestReleased | Should Be '0.64.0'
        $results.ToolState.pi.LatestVersionSource | Should Be 'npm.ps1'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Command | Should Be 'npm install -g @earendil-works/pi-coding-agent@0.62.0 --loglevel=error'
    }
}
