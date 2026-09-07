# Azure Developer CLI comparison reconciles CLI fallback versions with MSI versions.
# Stable MSI patch encoding: https://github.com/Azure/azure-dev/blob/main/eng/scripts/Get-MsiVersion.ps1

#region Public entry points
function Compare-ToolVersions {
    param([string]$Version1, [string]$Version2, [string]$Version1Source, [string]$Version2Source)

    if ($Version1Source -eq 'command' -and $Version2Source -eq 'winget.ps1' -and
        $Version1 -match '^(\d+)\.(\d+)\.(\d+)$') {
        $msiPatch = ([long]$Matches[3] + 1) * 100
        $Version1 = "$($Matches[1]).$($Matches[2]).$msiPatch"
    }
    Compare-SemanticVersions -Version1 $Version1 -Version2 $Version2
}
#endregion

#region Private helpers
#endregion