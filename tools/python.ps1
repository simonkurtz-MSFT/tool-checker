#Requires -Version 7.0

# Python runtime inventory, separate from the install-manager package itself.
# Prefer py-managed channels; fall back to python/python3 and platform release sources.
#region Public entry points
function Refresh-ToolStatus {
    param([string]$ToolName)
    if (-not (Test-CommandExists "py") -or -not $ToolName.StartsWith("Python")) { return }
    $major = ($results.Tools[$ToolName].Installed -split '\.')[0..1] -join '.'
    $out = py --list-paths 2>$null
    foreach ($line in $out) {
        if ($line.ToString().Trim() -match '^\s*(\d+\.\d+)\[?-?\d*\]?\s+.*Python\s+(\d+\.\d+\.\d+)') {
            if ($Matches[1] -eq $major) { $results.Tools[$ToolName].Installed = $Matches[2]; break }
        }
    }
}

function Test-Tool {
    param([string]$Progress)
    $config = Get-ToolConfiguration -ToolName 'Python' -RequiredProperties @('UpdateCommand', 'UpdateType')
    Write-Header "Checking Python" -Progress $Progress

    if (Test-CommandExists "py") {
        Write-Success "Python Installation Manager (py) found"
        try {
            $installed = py list 2>&1
            if ($installed) {
                $installedVersions = ConvertFrom-PythonLauncherList -OutputLines $installed
                Write-Host "  Installed Python versions:"
                foreach ($version in $installedVersions) {
                    $defaultLabel = if ($version.IsDefault) { ' (default)' } else { '' }
                    Write-Host "    - Python $($version.Version)$defaultLabel"
                    $results.Tools["Python $($version.Channel)"] = @{ Installed = $version.Version; Latest = "" }
                }
                if (-not $SkipUpdate) { Get-PythonUpdateViaPy -InstalledVersions $installedVersions }
            }
        } catch { Write-Warning "Unable to list Python versions via py: $_" }
        return
    }

    $command = @('python', 'python3') | Where-Object { Test-CommandExists $_ } | Select-Object -First 1
    if (-not $command) { Write-Error "Python not installed"; Add-NotInstalledTool "Python"; return }
    $ver = (Get-CommandVersion $command "--version") -replace 'Python ', '' | ForEach-Object { $_.Trim() }
    $label = if ($command -eq 'python3') { 'Python3' } else { 'Python' }
    Write-Success "$label installed: $ver"
    $maj = ($ver -split '\.')[0..1] -join '.'
    $results.Tools["Python $maj"] = @{ Installed = $ver; Latest = "" }
    if (-not $SkipUpdate) { Get-PythonUpdateConventional -InstalledVersion $ver }
}
#endregion

#region Private helpers
function ConvertFrom-PythonLauncherList {
    # Accept both descriptive manager rows and legacy -V: rows. Online suffixes
    # become comparable patch versions; installed suffixes are preserved for display.
    param(
        [Parameter(Mandatory)][array]$OutputLines,
        [switch]$Online
    )

    @($OutputLines | ForEach-Object {
        $line = $_.ToString()
        if ($line -match '^\s*(?<Channel>\d+\.\d+)\[?-?\d*\]?\s+(?<Default>\*)?\s*Python\s+(?<Version>\d+\.\d+\.\d+)') {
            [PSCustomObject]@{
                Channel = $Matches.Channel
                Version = $Matches.Version
                IsDefault = [bool]$Matches.Default
            }
        } elseif ($line -match '^\s*-V:(?<Channel>\d+\.\d+)(?<Suffix>-\d+)?\s*(?<Default>\*)?') {
            $version = if ($Online) {
                $patch = if ($Matches.Suffix) { $Matches.Suffix -replace '-', '.' } else { '.0' }
                "$($Matches.Channel)$patch"
            } else {
                "$($Matches.Channel)$($Matches.Suffix)"
            }
            [PSCustomObject]@{
                Channel = $Matches.Channel
                Version = $version
                IsDefault = [bool]$Matches.Default
            }
        }
    })
}

function Get-PythonLauncherUpdatePlan {
    # Patch installed channels independently; a newer channel is advisory, not an install.
    param(
        [Parameter(Mandatory)][array]$InstalledVersions,
        [Parameter(Mandatory)][array]$AvailableVersions
    )

    $installedByChannel = @{}
    foreach ($version in $InstalledVersions) {
        $installedByChannel[$version.Channel] = $version.Version
    }
    $latestByChannel = @{}
    foreach ($version in $AvailableVersions) {
        if (-not $latestByChannel.ContainsKey($version.Channel) -or (Compare-SemanticVersions $version.Version $latestByChannel[$version.Channel]) -gt 0) {
            $latestByChannel[$version.Channel] = $version.Version
        }
    }

    $updates = @()
    foreach ($channel in $installedByChannel.Keys) {
        $installed = $installedByChannel[$channel] -replace '-', '.'
        if ($installed -notmatch '^\d+\.\d+\.\d+$') { $installed = "$installed.0" }
        if ($latestByChannel.ContainsKey($channel) -and (Compare-SemanticVersions $latestByChannel[$channel] $installed) -gt 0) {
            $updates += [PSCustomObject]@{
                Channel = $channel
                Installed = $installedByChannel[$channel]
                Latest = $latestByChannel[$channel]
            }
        }
    }

    $highestInstalledChannel = @(Sort-SemanticVersions @($installedByChannel.Keys) | Select-Object -Last 1)
    $newerChannel = if ($highestInstalledChannel.Count -gt 0) {
        Sort-SemanticVersions -Descending @($latestByChannel.Keys | Where-Object { (Compare-SemanticVersions $_ $highestInstalledChannel[0]) -gt 0 }) |
            Select-Object -First 1
    } else {
        $null
    }

    [PSCustomObject]@{
        InstalledByChannel = $installedByChannel
        LatestByChannel = $latestByChannel
        Updates = $updates
        NewerChannel = $newerChannel
    }
}

function Get-PythonUpdateViaPy {
    param([Parameter(Mandatory)][array]$InstalledVersions)
    Write-Host "  Checking for Python updates via py --list-online..."
    try {
        $online = py list --online 2>&1
        if (-not $online) { return }
        $availableVersions = ConvertFrom-PythonLauncherList -OutputLines $online -Online
        $plan = Get-PythonLauncherUpdatePlan -InstalledVersions $InstalledVersions -AvailableVersions $availableVersions

        $found = $false
        foreach ($channel in $plan.InstalledByChannel.Keys) {
            if ($plan.LatestByChannel.ContainsKey($channel)) { $results.Tools["Python $channel"].Latest = $plan.LatestByChannel[$channel] }
        }
        foreach ($update in $plan.Updates) {
            Write-Warning "  Python $($update.Channel) has update available: $($update.Installed) -> $($update.Latest)"
            $results.Updates += "Python $($update.Channel)"; $found = $true
            Add-AvailableUpdate -Name "Python $($update.Channel)" -Command "py install $($update.Channel) --update --quiet" -Type 'py' -Details "$($update.Installed) -> $($update.Latest)"
        }
        if (-not $found) { Write-Success "All Python versions are up to date" }
        if ($plan.NewerChannel) {
            Write-Warning "  Newer Python major version available: $($plan.NewerChannel) (latest: $($plan.LatestByChannel[$plan.NewerChannel]))"
        }
    } catch { Write-Warning "  Could not check Python updates: $_" }
}

function Get-PythonUpdateConventional {
    param([string]$InstalledVersion)
    $config = $toolsConfig["Python"]
    Write-Host "  Checking for Python updates..."
    try {
        $major = ($InstalledVersion -split '\.')[0..1] -join '.'
        if (Test-IsWindowsPlatform) {
            $latest = Get-WingetLatestVersion -ToolName "Python $major" -PackageId "Python.Python.$major"
            if ($config.ProductionReleasesOnly -and -not (Test-IsProductionVersion $latest)) { $latest = $null }
            if ($latest) {
                $results.Tools["Python $major"].Latest = $latest
            }
        } else {
            $releases = Invoke-SafeApiRequest -Uri $config.ApiUrl
            $match = $releases | Where-Object { $_.cycle -eq $major } | Select-Object -First 1
            $latest = if ($match) { $match.latest } else { $null }
            if ($config.ProductionReleasesOnly -and -not (Test-IsProductionVersion $latest)) { $latest = $null }
            if ($latest) { $results.Tools["Python $major"].Latest = $latest }
        }
        if ($latest) {
            if ((Compare-SemanticVersions $latest $InstalledVersion) -gt 0) {
                $sourceLabel = if (Test-IsWindowsPlatform) { ' in WinGet' } else { '' }
                Write-Warning "  Python $major has update available${sourceLabel}: $InstalledVersion -> $latest"
                $results.Updates += "Python $major"
                if (!$SkipUpdate) {
                    Add-AvailableUpdate -Name "Python $major" -Command ($config.UpdateCommand -replace '\{version\}',$major) -Type $config.UpdateType -Details "$InstalledVersion -> $latest"
                }
            } else { Write-Success "Python $major is up to date" }
        }
        if (-not (Test-IsWindowsPlatform)) {
            # Cycles such as 3.9 and 3.14 must compare as versions, not decimals.
            $newerCycle = Sort-SemanticVersions -Descending @($releases | Where-Object { $_.eol -eq $false -and (Compare-SemanticVersions $_.cycle $major) -gt 0 } | ForEach-Object { $_.cycle }) | Select-Object -First 1
            $newerMajors = if ($newerCycle) { $releases | Where-Object { $_.cycle -eq $newerCycle } | Select-Object -First 1 }
            if ($newerMajors) { Write-Warning "  Newer Python major version available: $($newerMajors.cycle) (latest: $($newerMajors.latest))" }
        }
    } catch { Write-Warning "  Could not check Python updates: $_" }
}
#endregion
