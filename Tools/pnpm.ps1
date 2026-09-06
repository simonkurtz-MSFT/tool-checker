#Requires -Version 7.0

# Refresh pnpm from the global npm package first because its executable may be a shim.
# Fall back to standard command parsing; npm helpers come from the declared package manager.
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
