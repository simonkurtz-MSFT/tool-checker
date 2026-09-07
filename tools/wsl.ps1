#Requires -Version 7.0

# Windows-only WSL inventory and GitHub release selection. Normalize packaging
# suffixes and plan updates through shared helpers; the checker never runs wsl --update.
#region Public entry points
function Test-Tool {
    param([string]$Progress)
    $config = Get-ToolConfiguration -ToolName 'WSL' -RequiredProperties @('Command', 'VersionCommand', 'VersionParseRegex', 'ApiUrl', 'UpdateCommand', 'UpdateType')
    Write-Header "Checking WSL" -Progress $Progress

    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        Write-Warning "WSL check skipped: Windows only"
        return
    }

    if (-not (Test-CommandExists $config.Command)) {
        Write-Error "WSL not installed"
        Add-NotInstalledTool "WSL"
        return
    }

    try { $versionOutput = Invoke-Expression "$($config.VersionCommand) 2>&1" | Out-String }
    catch { $versionOutput = "" }

    if (-not ($versionOutput -match $config.VersionParseRegex)) {
        Write-Warning "Could not parse WSL version from wslc -v"
        $results.Tools["WSL"] = @{ Installed = "unknown"; Latest = "" }
        return
    }

    $installedVersion = ConvertTo-CanonicalSemanticVersion $Matches[1]
    Write-Success "WSL installed: $installedVersion"
    $results.Tools["WSL"] = @{ Installed = $installedVersion; Latest = "" }

    if ($SkipUpdate) { return }

    Write-Host "  Checking for WSL updates..."
    $releases = Invoke-SafeApiRequest -Uri $config.ApiUrl
    $allowedReleases = @($releases) | Where-Object {
        -not $_.draft -and (-not $config.ProductionReleasesOnly -or (
            -not $_.prerelease -and (Test-IsProductionVersion $_.tag_name)
        ))
    }
    $versionedReleases = foreach ($release in $allowedReleases) {
        $versionText = "$($release.tag_name)" -replace '^v', ''
        $semanticVersion = $null
        if ([version]::TryParse($versionText, [ref]$semanticVersion)) {
            [PSCustomObject]@{
                Release         = $release
                SemanticVersion = $semanticVersion
                VersionText     = $versionText
            }
        }
    }
    # Prefer the highest version, not the most recently published older servicing release.
    $latestVersionedRelease = $versionedReleases |
        Sort-Object -Property @(
            @{ Expression = { $_.SemanticVersion }; Descending = $true }
            @{ Expression = { [DateTimeOffset]$_.Release.published_at }; Descending = $true }
        ) |
        Select-Object -First 1

    if (-not $latestVersionedRelease) {
        Write-Warning "  Could not determine latest semantic WSL release"
        return
    }

    $latestRelease = $latestVersionedRelease.Release
    $latestVersion = ConvertTo-CanonicalSemanticVersion $latestVersionedRelease.VersionText
    $results.Tools["WSL"].Latest = $latestVersion

    if (Register-ToolUpdate -Name 'WSL' -InstalledVersion $installedVersion -LatestVersion $latestVersion -Command $config.UpdateCommand -Type $config.UpdateType) {
        $releaseType = if ($latestRelease.prerelease) { "prerelease" } else { "release" }
        Write-Warning "  WSL $releaseType available: $installedVersion -> $latestVersion"
    } else {
        Write-Success "WSL is up to date"
    }
}
#endregion

#region Private helpers

#endregion
