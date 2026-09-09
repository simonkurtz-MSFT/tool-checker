# Azure CLI catalog parsing and refresh contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-azure-cli-tests-absent.env')

Describe 'Azure CLI catalog-driven version parsing' {
    It 'reads the configured installed JSON property and rejects malformed output' {
        Get-InstalledVersionFromOutput -ToolName 'Azure CLI' -Output '{"azure-cli":"2.80.0"}' | Should Be '2.80.0'
        Get-InstalledVersionFromOutput -ToolName 'Azure CLI' -Output 'not json' | Should BeNullOrEmpty
    }

    It 'uses the configured API property path and handles missing properties' {
        Get-LatestVersionFromApi -ToolName 'Azure CLI' -ApiData ([PSCustomObject]@{ info = [PSCustomObject]@{ version = '2.80.0' } }) | Should Be '2.80.0'
        Get-LatestVersionFromApi -ToolName 'Azure CLI' -ApiData ([PSCustomObject]@{}) | Should BeNullOrEmpty
    }
}

Describe 'Azure CLI version refresh' {
    BeforeEach {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'empty.env')
        $results = New-ToolCheckResults
    }

    It 'refreshes through its catalog-loaded entry point' {
        Mock Test-CommandExists { $true }
        function az { }
        Mock az { '{"azure-cli":"2.80.0"}' }
        $results.Tools['Azure CLI'] = @{ Installed = '2.70.0'; Latest = '2.80.0' }
        Refresh-ToolVersion -ToolName 'Azure CLI' | Should Be $true
        $results.Tools['Azure CLI'].Installed | Should Be '2.80.0'
    }
}