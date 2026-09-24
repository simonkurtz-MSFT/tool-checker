# Compare Git for Windows release tags with their numeric package versions.
#region Public entry points
function Compare-ToolVersions {
    param([string]$Version1, [string]$Version2, [string]$Version1Source, [string]$Version2Source)

    $Version1 = $Version1 -replace '^v?(\d+\.\d+\.\d+)\.windows\.(\d+)$', '$1.$2'
    $Version2 = $Version2 -replace '^v?(\d+\.\d+\.\d+)\.windows\.(\d+)$', '$1.$2'
    Compare-SemanticVersions -Version1 $Version1 -Version2 $Version2
}
#endregion

#region Private helpers
#endregion
