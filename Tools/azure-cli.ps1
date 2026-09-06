#Requires -Version 7.0

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
