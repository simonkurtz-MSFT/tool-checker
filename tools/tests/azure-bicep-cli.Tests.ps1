# Azure Bicep CLI catalog parsing and refresh contracts.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
. $scriptPath -EnvFile (Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-bicep-tests-absent.env')

Describe 'Azure Bicep CLI catalog-driven version parsing' {
    It 'parses a configured regex across multiple output lines' {
        Get-InstalledVersionFromOutput -ToolName 'Azure Bicep CLI' -Output @('Warning: example', 'Bicep CLI version 0.46.0') | Should Be '0.46.0'
        Get-InstalledVersionFromOutput -ToolName 'Azure Bicep CLI' -Output 'Warning only' | Should BeNullOrEmpty
    }
}

Describe 'Azure Bicep CLI version refresh' {
    BeforeEach {
        . $scriptPath -EnvFile (Join-Path $TestDrive 'empty.env')
        $results = New-ToolCheckResults
    }

    It 'refreshes through its catalog-loaded entry point' {
        Mock Test-CommandExists { $true }
        function az { }
        Mock az { 'Bicep CLI version 0.46.0' }
        $results.Tools['Azure Bicep CLI'] = @{ Installed = '0.45.0'; Latest = '0.46.0' }
        Refresh-ToolVersion -ToolName 'Azure Bicep CLI' | Should Be $true
        $results.Tools['Azure Bicep CLI'].Installed | Should Be '0.46.0'
    }
}