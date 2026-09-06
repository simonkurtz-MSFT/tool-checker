#Requires -Version 7.0

# Refresh Azure CLI's installed version from its JSON output after an approved action.
# Initial checks stay catalog-driven; the latest known release is not overwritten here.
#region Public entry points
function Refresh-ToolStatus {
    param([string]$ToolName)
    if (Test-CommandExists "az") {
        $json = az version --output json 2>$null | ConvertFrom-Json
        if ($json.'azure-cli') { $results.Tools[$ToolName].Installed = $json.'azure-cli' }
    }
}
#endregion

#region Private helpers
#endregion
