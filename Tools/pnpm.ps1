#Requires -Version 7.0

#region Public entry points
function Refresh-ToolStatus {
    param([string]$ToolName)
    $config = $toolsConfig[$ToolName]
    $version = Get-GlobalNpmInstalledVersion -PackageName $config.NpmPackageName
    if ($version) {
        $results.Tools[$ToolName].Installed = $version
    } else {
        Refresh-StandardVersion -ToolName $ToolName -Config $config
    }
}
#endregion

#region Private helpers
#endregion
