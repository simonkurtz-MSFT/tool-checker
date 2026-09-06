#Requires -Version 7.0

#region Private helpers
function ConvertFrom-DotNetSDKList {
    param([Parameter(Mandatory)][array]$OutputLines)

    @($OutputLines | ForEach-Object {
        if ($_ -match '^\s*(?<Version>\S+)\s+\[(?<Path>.*)\]\s*$') {
            [PSCustomObject]@{ Version = $Matches.Version; Path = $Matches.Path }
        }
    })
}

function Get-DotNetSDKInventory {
    param(
        [Parameter(Mandatory)][array]$SdkRecords,
        [hashtable]$LatestSdkByChannel = @{},
        [hashtable]$LatestSdkByMajor = @{}
    )

    $byMajor = @{}
    foreach ($record in $SdkRecords) {
        $major = ($record.Version -split '\.')[0]
        if (-not $byMajor[$major]) { $byMajor[$major] = @() }
        $byMajor[$major] += $record.Version
    }

    $dotNetSDKs = @{}
    $tools = @{}
    foreach ($major in $byMajor.Keys) {
        $sorted = @($byMajor[$major] | Sort-Object { [version]$_ })
        $highest = $sorted | Select-Object -Last 1
        $channel = ($highest -split '\.')[0..1] -join '.'
        $channelRelease = $latestSdkByChannel[$channel]
        $latest = if ($LatestSdkByMajor.ContainsKey($major)) {
            $LatestSdkByMajor[$major]
        } elseif ($channelRelease -is [string]) {
            $channelRelease
        } elseif ($channelRelease) {
            $channelRelease.LatestSdk
        } else {
            ''
        }

        foreach ($version in $sorted) {
            $record = $SdkRecords | Where-Object Version -eq $version | Select-Object -First 1
            $dotNetSDKs[$version] = @{ Installed = $version; Latest = $latest; Path = $record.Path; HighestInstalled = $highest }
            $tools[".NET SDK $version"] = @{ Installed = $version; Latest = $latest; HighestInstalled = $highest }
        }
    }

    [PSCustomObject]@{ DotNetSDKs = $dotNetSDKs; Tools = $tools; ByMajor = $byMajor }
}

function Get-DotNetSDKReleasePlan {
    param(
        [Parameter(Mandatory)][array]$InstalledVersions,
        [Parameter(Mandatory)]$ReleasesIndex,
        [bool]$ProductionReleasesOnly = $true
    )

    $latestSdkByChannel = @{}
    foreach ($channel in $ReleasesIndex.'releases-index') {
        if ($ProductionReleasesOnly -and $channel.'support-phase' -eq 'preview') { continue }
        if ($ProductionReleasesOnly -and -not (Test-IsProductionVersion $channel.'latest-sdk')) { continue }
        $latestSdkByChannel[$channel.'channel-version'] = @{
            LatestSdk = $channel.'latest-sdk'
            SupportPhase = $channel.'support-phase'
        }
    }

    $byMajor = @{}
    foreach ($version in $InstalledVersions) {
        $major = ($version -split '\.')[0]
        if (-not $byMajor[$major]) { $byMajor[$major] = @() }
        $byMajor[$major] += $version
    }
    $installedMajors = @($byMajor.Keys | ForEach-Object { [int]$_ })
    $maxInstalledMajor = ($installedMajors | Measure-Object -Maximum).Maximum
    $availableMajors = @()
    foreach ($channel in $ReleasesIndex.'releases-index') {
        $major = [int]($channel.'channel-version' -split '\.')[0]
        $releaseAllowed = -not $ProductionReleasesOnly -or (
            $channel.'support-phase' -ne 'preview' -and (Test-IsProductionVersion $channel.'latest-sdk')
        )
        if ($releaseAllowed -and $channel.'support-phase' -ne 'eol' -and ($channel.'support-phase' -ne 'preview' -or $major -in $installedMajors)) {
            if ($major -notin $availableMajors) { $availableMajors += $major }
        }
    }

    [PSCustomObject]@{
        LatestSdkByChannel = $latestSdkByChannel
        ByMajor = $byMajor
        InstalledMajors = $installedMajors
        MaxInstalledMajor = $maxInstalledMajor
        NewerMajors = @($availableMajors | Where-Object { $_ -gt $maxInstalledMajor } | Sort-Object -Descending)
    }
}
#endregion

#region Public entry points
function Test-Tool {
    param([string]$Progress)
    $config = Get-ToolConfiguration -ToolName '.NET SDK' -RequiredProperties @('Command', 'ApiUrl', 'UpdateCommand')
    Write-Header "Checking .NET SDKs" -Progress $Progress

    if (-not (Test-CommandExists $config.Command)) {
        Write-Error ".NET SDK not installed"; Add-NotInstalledTool ".NET SDK"; return
    }

    try {
        $sdkList = dotnet --list-sdks 2>$null
        if (-not $sdkList -or $sdkList.Count -eq 0) { Write-Warning "No .NET SDKs found"; return }
        $sdkRecords = ConvertFrom-DotNetSDKList -OutputLines $sdkList
        if ($sdkRecords.Count -eq 0) { Write-Warning "No .NET SDKs found"; return }

        Write-Success "Installed .NET SDKs:"
        foreach ($record in $sdkRecords) { Write-Host "  - $($record.Version)" }
        $inventory = Get-DotNetSDKInventory -SdkRecords $sdkRecords
        foreach ($entry in $inventory.DotNetSDKs.GetEnumerator()) { $results.DotNetSDKs[$entry.Key] = $entry.Value }
        foreach ($entry in $inventory.Tools.GetEnumerator()) { $results.Tools[$entry.Key] = $entry.Value }

        if ($SkipUpdate) { return }

        Write-Host "  Checking for .NET SDK updates..."
        $releasesIndex = Invoke-RestMethod -Uri $config.ApiUrl -TimeoutSec $script:ApiRequestTimeout
        $releasePlan = Get-DotNetSDKReleasePlan -InstalledVersions @($sdkRecords.Version) -ReleasesIndex $releasesIndex -ProductionReleasesOnly $config.ProductionReleasesOnly
        $latestSdkByChannel = $releasePlan.LatestSdkByChannel
        $byMajor = $releasePlan.ByMajor
        $latestSdkByMajor = @{}

        Write-Host "`n  Version Summary:"
        $maxLen = ($byMajor.Keys | ForEach-Object { ".NET $_".Length } | Measure-Object -Maximum).Maximum
        foreach ($maj in ($byMajor.Keys | Sort-Object { [int]$_ } -Descending)) {
            $sorted  = $byMajor[$maj] | Sort-Object { [version]$_ }
            $highest = $sorted | Select-Object -Last 1
            Write-Host ("    {0,-$maxLen} : {1}" -f ".NET $maj", ($sorted -join ', '))

            $chVer = ($highest -split '\.')[0..1] -join '.'
            if ($latestSdkByChannel.ContainsKey($chVer)) {
                $latestSdk = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                    Get-WingetLatestVersion -ToolName ".NET SDK $maj" -PackageId "Microsoft.DotNet.SDK.$maj"
                } else {
                    $latestSdkByChannel[$chVer].LatestSdk
                }
                if (-not $latestSdk) { continue }
                if ($config.ProductionReleasesOnly -and -not (Test-IsProductionVersion $latestSdk)) { continue }
                $latestSdkByMajor[$maj] = $latestSdk
                if ([version]$latestSdk -gt [version]$highest) {
                    Write-Warning "    .NET $highest -> $latestSdk (update available)"
                    $results.Updates += ".NET SDK: $highest -> $latestSdk"
                }
            }
        }

        $inventory = Get-DotNetSDKInventory -SdkRecords $sdkRecords -LatestSdkByChannel $latestSdkByChannel -LatestSdkByMajor $latestSdkByMajor
        foreach ($entry in $inventory.DotNetSDKs.GetEnumerator()) { $results.DotNetSDKs[$entry.Key] = $entry.Value }
        foreach ($entry in $inventory.Tools.GetEnumerator()) { $results.Tools[$entry.Key] = $entry.Value }

        # Newer major versions
        $maxInstalledMajor = $releasePlan.MaxInstalledMajor
        $newerMajorVersions = @{}
        $newerMajors = @($releasePlan.NewerMajors)
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            $newerMajors = @($newerMajors | Where-Object {
                $wingetVersion = Get-WingetLatestVersion -ToolName ".NET SDK $_" -PackageId "Microsoft.DotNet.SDK.$_"
                if ($wingetVersion) { $newerMajorVersions[$_] = $wingetVersion; $true } else { $false }
            })
        }
        foreach ($m in $newerMajors) {
            $versionLabel = if ($newerMajorVersions[$m]) { " (WinGet: $($newerMajorVersions[$m]))" } else { "" }
            Write-Warning "    Newer .NET major version available: $m$versionLabel (you have up to $maxInstalledMajor)"
            $results.Updates += ".NET SDK: Major version $m available"
        }

        if ($results.Updates -match '\.NET SDK') {
            foreach ($maj in $byMajor.Keys) {
                $highest = $byMajor[$maj] | Sort-Object { [version]$_ } | Select-Object -Last 1
                $latest  = $results.DotNetSDKs[$highest].Latest
                if ($latest -and $latest -ne "-" -and [version]$latest -gt [version]$highest) {
                    Add-AvailableUpdate -Name ".NET SDK $highest" -Command "winget upgrade Microsoft.DotNet.SDK.$maj --silent" -Type 'winget' -Details "$highest -> $latest"
                }
            }
            foreach ($m in $newerMajors) {
                $details = if ($newerMajorVersions[$m]) { "Latest in WinGet: $($newerMajorVersions[$m])" } else { 'New major version' }
                Add-AvailableUpdate -Name ".NET SDK $m (new major version)" -Command "winget install Microsoft.DotNet.SDK.$m --silent" -Type 'winget-new' -Details $details
            }
        } else {
            Write-Success "All .NET SDKs are up to date with their latest patches"
        }
    } catch {
        Write-Warning "  Could not check .NET SDK updates: $_"
        Write-Host "    Manual check: https://dotnet.microsoft.com/en-us/download/dotnet"
    }
}

function Refresh-ToolStatus {
    param([string]$ToolName)

    if (-not (Test-CommandExists "dotnet")) { return }
    $sdkList = dotnet --list-sdks 2>$null
    if (-not $sdkList) { return }
    $sdkRecords = ConvertFrom-DotNetSDKList -OutputLines $sdkList
    if ($sdkRecords.Count -eq 0) { return }

    # Rebuild installed-SDK inventory from scratch so stale versions disappear
    # and newly-installed patch releases show up.
    $staleKeys = @($results.Tools.Keys | Where-Object { $_ -like ".NET SDK*" })
    foreach ($k in $staleKeys) { $results.Tools.Remove($k) | Out-Null }
    $results.DotNetSDKs.Clear()

    # Re-fetch latest-per-channel so Latest / HighestInstalled are accurate
    # in the summary table after an upgrade (fixes blank Latest column when
    # multiple minor versions of the same major are installed).
    $cfg = $toolsConfig[".NET SDK"]
    $latestSdkByChannel = @{}
    if ($cfg -and $cfg.ApiUrl) {
        try {
            $releasesIndex = Invoke-RestMethod -Uri $cfg.ApiUrl -TimeoutSec $script:ApiRequestTimeout
            $releasePlan = Get-DotNetSDKReleasePlan -InstalledVersions @($sdkRecords.Version) -ReleasesIndex $releasesIndex -ProductionReleasesOnly $cfg.ProductionReleasesOnly
            $latestSdkByChannel = $releasePlan.LatestSdkByChannel
        } catch {
            # Network hiccup on refresh is non-fatal; leave Latest blank.
        }
    }

    $inventory = Get-DotNetSDKInventory -SdkRecords $sdkRecords -LatestSdkByChannel $latestSdkByChannel
    foreach ($entry in $inventory.DotNetSDKs.GetEnumerator()) { $results.DotNetSDKs[$entry.Key] = $entry.Value }
    foreach ($entry in $inventory.Tools.GetEnumerator()) { $results.Tools[$entry.Key] = $entry.Value }
    $byMajor = $inventory.ByMajor

    # Prune .NET items from Updates / AvailableUpdates that are now satisfied
    # (either the patch landed or an equal/higher SDK in the same channel is
    # already installed).
    $results.Updates = @($results.Updates | Where-Object {
        if ($_ -notmatch '^\.NET SDK:\s*(?<from>[\d.]+)\s*->\s*(?<to>[\d.]+)') { return $true }
        $from = $Matches.from; $to = $Matches.to
        $maj  = ($from -split '\.')[0]
        $hi   = if ($byMajor[$maj]) { ($byMajor[$maj] | Sort-Object { [version]$_ } | Select-Object -Last 1) } else { $null }
        -not ($hi -and [version]$hi -ge [version]$to)
    })
    $results.AvailableUpdates = @($results.AvailableUpdates | Where-Object {
        if ($_.Name -notmatch '^\.NET SDK\s+(?<from>[\d.]+)$') { return $true }
        $from = $Matches.from
        $maj  = ($from -split '\.')[0]
        if (-not $byMajor[$maj]) { return $true }
        $hi   = $byMajor[$maj] | Sort-Object { [version]$_ } | Select-Object -Last 1
        $lat  = $results.DotNetSDKs[$hi].Latest
        -not ($lat -and [version]$hi -ge [version]$lat)
    })
}
#endregion