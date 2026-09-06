#Requires -Version 7.0

#region Public entry points
function Test-Tool {
    param([string]$Progress)
    $config = Get-ToolConfiguration -ToolName 'PowerShell' -RequiredProperties @('Command', 'ApiUrl', 'UpdateCommand', 'UpdateType')
    Write-Header "Checking PowerShell" -Progress $Progress

    $currentVersion = $PSVersionTable.PSVersion
    Write-Success "Current PowerShell: $currentVersion"
    $results.Tools["PowerShell"] = @{ Installed = $currentVersion.ToString(); Latest = "" }

    if (Test-CommandExists "pwsh") {
        $pwshVersion = (Get-CommandVersion "pwsh" "--version") -replace 'PowerShell ', ''
        Write-Success "PowerShell Core installed: $pwshVersion"
        $results.Tools["PowerShell Core"] = @{ Installed = $pwshVersion; Latest = "" }
        if ($SkipUpdate) { return }

        Write-Host "  Checking for PowerShell updates..."
        try {
            $latestVersion = if (($IsWindows -or $env:OS -eq 'Windows_NT') -and $config.WingetId) {
                Get-WingetLatestVersion -ToolName 'PowerShell' -PackageId $config.WingetId
            } else {
                $releases = Invoke-RestMethod -Uri $config.ApiUrl -TimeoutSec $script:ApiRequestTimeout
                $releases.tag_name -replace 'v', ''
            }
            $latestToolNames = @('PowerShell')
            if ($results.Tools['PowerShell Core']) { $latestToolNames += 'PowerShell Core' }
            if (-not (Set-LatestToolVersion -ToolNames $latestToolNames -LatestVersion $latestVersion -ProductionReleasesOnly $config.ProductionReleasesOnly)) { return }

            if (Register-ToolUpdate -Name 'PowerShell' -InstalledVersion $pwshVersion -LatestVersion $latestVersion -Command $config.UpdateCommand -Type $config.UpdateType) {
                $sourceLabel = if ($IsWindows -or $env:OS -eq 'Windows_NT') { ' in WinGet' } else { '' }
                Write-Warning "  PowerShell has available updates${sourceLabel}: $pwshVersion -> $latestVersion"
                Write-Host "  Release notes: $($config.ReleaseNotesUrl)"
            } else { Write-Success "PowerShell is up to date" }
        } catch { Write-Warning "  Could not fetch latest PowerShell version: $_" }
    } else {
        Write-Warning "PowerShell Core (pwsh) not installed"
    }
}
#endregion

#region Private helpers

#endregion
