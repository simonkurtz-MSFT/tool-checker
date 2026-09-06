#Requires -Version 7.0

# Check the Windows Python Install Manager Appx package, not its managed runtimes.
# Use package versions for the WinGet comparison; runtime inventory lives in python.ps1.
#region Public entry points
function Test-Tool {
    param([string]$Progress)
    $toolName = "Python Install Manager (py)"
    $config = Get-ToolConfiguration -ToolName $toolName -RequiredProperties @('PackageName', 'WingetId', 'UpdateCommand', 'UpdateType')
    Write-Header "Checking $toolName" -Progress $Progress

    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        Write-Warning "$toolName check skipped: Windows only"
        return
    }

    $package = Get-AppxPackage -Name $config.PackageName -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) {
        Write-Error "$toolName not installed"
        Add-NotInstalledTool $toolName
        return
    }

    $installedVersion = $package.Version.ToString()
    Write-Success "$toolName installed: $installedVersion"
    $results.Tools[$toolName] = @{ Installed = $installedVersion; Latest = "" }

    if ($SkipUpdate) { return }

    Write-Host "  Checking for $toolName updates..."
    $latestVersion = Get-WingetLatestVersion -ToolName $toolName -PackageId $config.WingetId
    if (-not (Set-LatestToolVersion -ToolNames $toolName -LatestVersion $latestVersion -ProductionReleasesOnly $config.ProductionReleasesOnly -VersionLabel 'WinGet version')) { return }

    if (Register-ToolUpdate -Name $toolName -InstalledVersion $installedVersion -LatestVersion $latestVersion -Command $config.UpdateCommand -Type $config.UpdateType) {
        Write-Warning "  $toolName has available updates in WinGet: $installedVersion -> $latestVersion"
        Write-Host "  Release notes: $($config.ReleaseNotesUrl)"
    } else {
        Write-Success "$toolName is up to date with WinGet"
    }
}
#endregion

#region Private helpers

#endregion
