# Generic version policy contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'

Describe 'Version comparison contracts' {
    BeforeEach {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'absent.env')
    }

    It 'retains default ordering without an override or owner' {
        Compare-OwnedToolVersions -Version1 '1.9.0' -Version2 '1.10.0' | Should Be -1
        Compare-OwnedToolVersions -Version1 '1.2.3.0' -Version2 '1.2.3' -ToolName 'Azure CLI' | Should Be 0
        Compare-OwnedToolVersions -Version1 '2.0.0' -Version2 '1.10.0' | Should Be 1
        Test-UpdateAvailable -InstalledVersion '1.0.0' -LatestVersion '' | Should Be $false
    }

    It 'isolates same-named overrides by row owner and does not leak public functions' {
        $script:ToolDefinitions = @{
            first = @{ 'Compare-ToolVersions' = 'function Compare-ToolVersions { param($Version1,$Version2,$Version1Source,$Version2Source) 0 }' }
            second = @{ 'Compare-ToolVersions' = 'function Compare-ToolVersions { param($Version1,$Version2,$Version1Source,$Version2Source) -1 }' }
        }
        $results.Tools = @{
            'Renamed first' = @{ ToolId = 'first' }
            'Renamed second' = @{ ToolId = 'second' }
        }
        Test-UpdateAvailable -InstalledVersion '1.0.0' -LatestVersion '2.0.0' -ToolName 'Renamed first' | Should Be $false
        Test-UpdateAvailable -InstalledVersion '1.0.0' -LatestVersion '1.0.0' -ToolName 'Renamed second' | Should Be $true
        @(Get-Command -CommandType Function | Where-Object Name -eq 'Compare-ToolVersions').Count | Should Be 0
    }

    It 'rejects an invalid comparison result instead of silently accepting it' {
        $script:ToolDefinitions['invalid'] = @{ 'Compare-ToolVersions' = 'function Compare-ToolVersions { "equal" }' }
        $results.Tools.Example = @{ ToolId = 'invalid' }
        $message = try { Compare-OwnedToolVersions -Version1 '1.0.0' -Version2 '2.0.0' -ToolName Example } catch { $_.Exception.Message }
        $message | Should Match 'must return exactly one integer'
    }

}