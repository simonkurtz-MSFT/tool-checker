#Requires -Version 7.0

# Refresh the Bicep CLI managed by az, not a standalone bicep executable.
# Parse the catalog regex and update Installed only, preserving the checked Latest.
#region Public entry points
function Refresh-ToolStatus {
    param([string]$ToolName)
    if (Test-CommandExists "az") {
        $out = az bicep version 2>$null
        $regex = $toolsConfig["Azure Bicep CLI"].VersionParseRegex
        $line = $out | Where-Object { $_ -match 'Bicep CLI' } | Select-Object -First 1
        if ($regex -and $line -match $regex) { $results.Tools[$ToolName].Installed = $Matches[1] }
    }
}
#endregion

#region Private helpers
#endregion
