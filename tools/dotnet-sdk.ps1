#Requires -Version 7.0

# .NET SDK inventory and channel-aware update plans. All installed SDKs remain
# visible; private per-version state and row coverage are owned by this tool.
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
    # A newer installed SDK can cover older rows in the same major; compute that
    # once here so the generic renderer does not need .NET-specific comparisons.
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
        $sorted = @(Sort-SemanticVersions $byMajor[$major])
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
            $tools[".NET SDK $version"] = @{ ToolId = 'dotnet-sdk'; ItemId = $version; Installed = $version; Latest = $latest; HighestInstalled = $highest; Covered = $latest -and (Compare-SemanticVersions $highest $latest) -ge 0 }
        }
    }

    [PSCustomObject]@{ DotNetSDKs = $dotNetSDKs; Tools = $tools; ByMajor = $byMajor }
}

function Test-DotNetChannelEligible {
    # A go-live channel is Microsoft-supported for production even though its SDK
    # still carries an rc suffix, so it is eligible when only production releases are wanted.
    param([Parameter(Mandatory)]$Channel, [bool]$ProductionReleasesOnly = $true)

    $phase = $Channel.'support-phase'
    -not $ProductionReleasesOnly -or $phase -eq 'go-live' -or (
        $phase -ne 'preview' -and (Test-IsProductionVersion $Channel.'latest-sdk')
    )
}

function Get-DotNetSDKWingetId {
    # WinGet publishes the pre-GA SDK under a single rolling "Preview" package and
    # only adds the numbered package (Microsoft.DotNet.SDK.<major>) at general availability.
    param([Parameter(Mandatory)][string]$Major, [string]$SupportPhase)

    if ($SupportPhase -in @('preview', 'go-live')) { 'Microsoft.DotNet.SDK.Preview' } else { "Microsoft.DotNet.SDK.$Major" }
}

function Get-DotNetSDKReleasePlan {
    # Separate servicing channels from newer-major announcements; do not promote
    # uninstalled preview channels into suggested new-major upgrades.
    param(
        [Parameter(Mandatory)][array]$InstalledVersions,
        [Parameter(Mandatory)]$ReleasesIndex,
        [bool]$ProductionReleasesOnly = $true
    )

    $latestSdkByChannel = @{}
    $wingetPackageIds = @{}
    foreach ($channel in $ReleasesIndex.'releases-index') {
        $channelMajor = ($channel.'channel-version' -split '\.')[0]
        if (-not $wingetPackageIds.ContainsKey($channelMajor)) {
            $wingetPackageIds[$channelMajor] = Get-DotNetSDKWingetId -Major $channelMajor -SupportPhase $channel.'support-phase'
        }
        if (-not (Test-DotNetChannelEligible -Channel $channel -ProductionReleasesOnly $ProductionReleasesOnly)) { continue }
        $latestSdkByChannel[$channel.'channel-version'] = @{
            LatestSdk = $channel.'latest-sdk'
            SupportPhase = $channel.'support-phase'
            PublishedAt = $channel.'latest-release-date'
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
        $releaseAllowed = Test-DotNetChannelEligible -Channel $channel -ProductionReleasesOnly $ProductionReleasesOnly
        if ($releaseAllowed -and $channel.'support-phase' -ne 'eol' -and ($channel.'support-phase' -ne 'preview' -or $major -in $installedMajors)) {
            if ($major -notin $availableMajors) { $availableMajors += $major }
        }
    }

    [PSCustomObject]@{
        LatestSdkByChannel = $latestSdkByChannel
        WingetPackageIds = $wingetPackageIds
        ByMajor = $byMajor
        InstalledMajors = $installedMajors
        MaxInstalledMajor = $maxInstalledMajor
        NewerMajors = @($availableMajors | Where-Object { $_ -gt $maxInstalledMajor } | Sort-Object -Descending)
    }
}

function Get-DotNetSDKPublishedAt {
    param([string]$Version, [hashtable]$LatestSdkByChannel)

    # Channel dates describe the channel's latest SDK, not a lagging WinGet package.
    $release = $LatestSdkByChannel.Values | Where-Object { $_.LatestSdk -eq $Version } | Select-Object -First 1
    if ($release) { $release.PublishedAt }
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
        foreach ($entry in $inventory.DotNetSDKs.GetEnumerator()) { (Get-ToolState 'dotnet-sdk')[$entry.Key] = $entry.Value }
        foreach ($entry in $inventory.Tools.GetEnumerator()) { $results.Tools[$entry.Key] = $entry.Value }

        if ($SkipUpdate) { return }

        Write-Host "  Checking for .NET SDK updates..."
        $releasesIndex = Invoke-SafeApiRequest -Uri $config.ApiUrl
        if (-not $releasesIndex) {
            Write-Host "    Manual check: https://dotnet.microsoft.com/en-us/download/dotnet"
            return
        }
        $releasePlan = Get-DotNetSDKReleasePlan -InstalledVersions @($sdkRecords.Version) -ReleasesIndex $releasesIndex -ProductionReleasesOnly $config.ProductionReleasesOnly
        $latestSdkByChannel = $releasePlan.LatestSdkByChannel
        $byMajor = $releasePlan.ByMajor
        $latestSdkByMajor = @{}
        $publishedAtByMajor = @{}

        Write-Host "`n  Version Summary:"
        $maxLen = ($byMajor.Keys | ForEach-Object { ".NET $_".Length } | Measure-Object -Maximum).Maximum
        foreach ($maj in ($byMajor.Keys | Sort-Object { [int]$_ } -Descending)) {
            $sorted  = @(Sort-SemanticVersions $byMajor[$maj])
            $highest = $sorted | Select-Object -Last 1
            Write-Host ("    {0,-$maxLen} : {1}" -f ".NET $maj", ($sorted -join ', '))

            $chVer = ($highest -split '\.')[0..1] -join '.'
            if ($latestSdkByChannel.ContainsKey($chVer)) {
                $wingetId = $releasePlan.WingetPackageIds[$maj]
                if (-not $wingetId) { $wingetId = "Microsoft.DotNet.SDK.$maj" }
                $latestSdk = if (Test-IsWindowsPlatform) {
                    Get-WingetLatestVersion -ToolName ".NET SDK $maj" -PackageId $wingetId
                } else {
                    $latestSdkByChannel[$chVer].LatestSdk
                }
                if (-not $latestSdk) { continue }
                $isGoLive = $latestSdkByChannel[$chVer].SupportPhase -eq 'go-live'
                if ($config.ProductionReleasesOnly -and -not $isGoLive -and -not (Test-IsProductionVersion $latestSdk)) { continue }
                $latestSdkByMajor[$maj] = $latestSdk
                if (Test-IsWindowsPlatform) {
                    $publishedAtByMajor[$maj] = Get-WingetReleaseDate -ToolName ".NET SDK $maj" -PackageId $wingetId -Version $latestSdk
                }
            }
        }

        $inventory = Get-DotNetSDKInventory -SdkRecords $sdkRecords -LatestSdkByChannel $latestSdkByChannel -LatestSdkByMajor $latestSdkByMajor
        foreach ($entry in $inventory.DotNetSDKs.GetEnumerator()) { (Get-ToolState 'dotnet-sdk')[$entry.Key] = $entry.Value }
        foreach ($entry in $inventory.Tools.GetEnumerator()) { $results.Tools[$entry.Key] = $entry.Value }
        $eligibleByMajor = @{}
        $hasBlockedRelease = $false
        foreach ($maj in $byMajor.Keys) {
            $highest = Sort-SemanticVersions $byMajor[$maj] | Select-Object -Last 1
            foreach ($version in $byMajor[$maj]) {
                $name = ".NET SDK $version"
                $latest = $results.Tools[$name].Latest
                if (-not $latest) { continue }
                $publishedAt = $publishedAtByMajor[$maj]
                if (-not $publishedAt) { $publishedAt = Get-DotNetSDKPublishedAt -Version $latest -LatestSdkByChannel $latestSdkByChannel }
                $eligible = Set-ToolReleaseInformation -ToolName $name -LatestVersion $latest -PublishedAt $publishedAt -CooldownDays $config.CooldownDays
                if (-not $eligible) { $hasBlockedRelease = $true }
                foreach ($property in @('Latest', 'LatestCooldown', 'LatestReleased', 'AgeDays', 'Installable', 'BlockReason')) {
                    if ($results.Tools[$name].ContainsKey($property)) {
                        (Get-ToolState 'dotnet-sdk')[$version][$property] = $results.Tools[$name][$property]
                    }
                }
                if ($version -eq $highest) { $eligibleByMajor[$maj] = $eligible -and $latestSdkByMajor.ContainsKey($maj) }
            }
            if ($eligibleByMajor[$maj] -and (Compare-SemanticVersions $latestSdkByMajor[$maj] $highest) -gt 0) {
                Write-Warning "    .NET $highest -> $($latestSdkByMajor[$maj]) (update available)"
                $results.Updates += ".NET SDK: $highest -> $($latestSdkByMajor[$maj])"
            }
        }

        # New-major suggestions on Windows require a version available in WinGet.
        $maxInstalledMajor = $releasePlan.MaxInstalledMajor
        $newerMajorVersions = @{}
        $newerMajors = @($releasePlan.NewerMajors)
        if (Test-IsWindowsPlatform) {
            $newerMajors = @($newerMajors | Where-Object {
                $newerWingetId = $releasePlan.WingetPackageIds["$_"]
                if (-not $newerWingetId) { $newerWingetId = "Microsoft.DotNet.SDK.$_" }
                $wingetVersion = Get-WingetLatestVersion -ToolName ".NET SDK $_" -PackageId $newerWingetId
                if ($wingetVersion) { $newerMajorVersions[$_] = $wingetVersion; $true } else { $false }
            })
        }
        $newerMajors = @($newerMajors | Where-Object {
            $major = $_
            $channel = $latestSdkByChannel.Keys | Where-Object { ($_ -split '\.')[0] -eq "$major" } |
                Sort-Object -Descending | Select-Object -First 1
            $candidate = if ($newerMajorVersions[$major]) { $newerMajorVersions[$major] } else { $latestSdkByChannel[$channel].LatestSdk }
            $name = ".NET SDK $major (new major version)"
            $results.Tools[$name] = @{ ToolId = 'dotnet-sdk'; ItemId = "$major"; Installed = ''; Latest = $candidate }
            $publishedAt = if (Test-IsWindowsPlatform) {
                $packageId = $releasePlan.WingetPackageIds["$major"]
                if (-not $packageId) { $packageId = "Microsoft.DotNet.SDK.$major" }
                Get-WingetReleaseDate -ToolName $name -PackageId $packageId -Version $candidate
            }
            if (-not $publishedAt) { $publishedAt = Get-DotNetSDKPublishedAt -Version $candidate -LatestSdkByChannel $latestSdkByChannel }
            $eligible = Set-ToolReleaseInformation -ToolName $name -LatestVersion $candidate -PublishedAt $publishedAt -CooldownDays $config.CooldownDays
            if (-not $eligible) { $hasBlockedRelease = $true }
            $eligible
        })
        foreach ($m in $newerMajors) {
            $versionLabel = if ($newerMajorVersions[$m]) { " (WinGet: $($newerMajorVersions[$m]))" } else { "" }
            Write-Warning "    Newer .NET major version available: $m$versionLabel (you have up to $maxInstalledMajor)"
            $results.Updates += ".NET SDK: Major version $m available"
        }

        if ($results.Updates -match '\.NET SDK') {
            foreach ($maj in $byMajor.Keys) {
                $highest = Sort-SemanticVersions $byMajor[$maj] | Select-Object -Last 1
                $latest  = (Get-ToolState 'dotnet-sdk')[$highest].Latest
                if ($eligibleByMajor[$maj] -and $latest -and $latest -ne "-" -and (Compare-SemanticVersions $latest $highest) -gt 0) {
                    $upgradeId = $releasePlan.WingetPackageIds[$maj]
                    if (-not $upgradeId) { $upgradeId = "Microsoft.DotNet.SDK.$maj" }
                    Add-AvailableUpdate -Name ".NET SDK $highest" -Command "winget upgrade $upgradeId --silent" -Type 'winget' -Details "$highest -> $latest" -Version $latest
                }
            }
            foreach ($m in $newerMajors) {
                $details = if ($newerMajorVersions[$m]) { "Latest in WinGet: $($newerMajorVersions[$m])" } else { 'New major version' }
                $installId = $releasePlan.WingetPackageIds["$m"]
                if (-not $installId) { $installId = "Microsoft.DotNet.SDK.$m" }
                Add-AvailableUpdate -Name ".NET SDK $m (new major version)" -Command "winget install $installId --silent" -Type 'winget-new' -Details $details -Version $results.Tools[".NET SDK $m (new major version)"].Latest
            }
        } elseif (-not $hasBlockedRelease) {
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

    # Keep the checked candidate and its release fields while replacing installed rows.
    $previousRows = @{}
    $staleKeys = @($results.Tools.Keys | Where-Object { $_ -like ".NET SDK*" })
    foreach ($k in $staleKeys) {
        $previousRows[$k] = $results.Tools[$k]
        $results.Tools.Remove($k) | Out-Null
    }
    $wingetReleases = (Get-ToolState 'dotnet-sdk').WingetReleases
    (Get-ToolState 'dotnet-sdk').Clear()
    if ($wingetReleases) { (Get-ToolState 'dotnet-sdk').WingetReleases = $wingetReleases }

    # Re-fetch latest-per-channel so Latest / HighestInstalled are accurate
    # in the summary table after an upgrade (fixes blank Latest column when
    # multiple minor versions of the same major are installed).
    $cfg = $toolsConfig[".NET SDK"]
    $releasePlan = $null
    $latestSdkByChannel = @{}
    if ($cfg -and $cfg.ApiUrl) {
        try {
            $releasesIndex = Invoke-RestMethod -Uri $cfg.ApiUrl -TimeoutSec $script:ApiRequestTimeout
            $releasePlan = Get-DotNetSDKReleasePlan -InstalledVersions @($sdkRecords.Version) -ReleasesIndex $releasesIndex -ProductionReleasesOnly $cfg.ProductionReleasesOnly
            $latestSdkByChannel = $releasePlan.LatestSdkByChannel
        } catch {
            # Network hiccups must not erase the previously checked release.
        }
    }

    $latestSdkByMajor = @{}
    foreach ($row in $previousRows.Values) {
        if ($row.Installed -and $row.Latest) {
            $major = ($row.Installed -split '\.')[0]
            $latestSdkByMajor[$major] = $row.Latest
        }
    }
    $inventory = Get-DotNetSDKInventory -SdkRecords $sdkRecords -LatestSdkByChannel $latestSdkByChannel -LatestSdkByMajor $latestSdkByMajor
    foreach ($entry in $inventory.DotNetSDKs.GetEnumerator()) { (Get-ToolState 'dotnet-sdk')[$entry.Key] = $entry.Value }
    foreach ($entry in $inventory.Tools.GetEnumerator()) { $results.Tools[$entry.Key] = $entry.Value }
    $byMajor = $inventory.ByMajor
    foreach ($entry in $inventory.Tools.GetEnumerator()) {
        $row = $entry.Value
        $major = ($row.Installed -split '\.')[0]
        $previous = $previousRows.Values | Where-Object {
            $_.Installed -and ($_.Installed -split '\.')[0] -eq $major -and $_.Latest -eq $row.Latest
        } | Select-Object -First 1
        foreach ($property in @('LatestCooldown', 'LatestReleased', 'AgeDays', 'Installable', 'BlockReason')) {
            if ($previous -and $previous.ContainsKey($property)) { $row[$property] = $previous[$property] }
        }
        $publishedAt = $null
        if (Test-IsWindowsPlatform) {
            $packageId = if ($releasePlan) { $releasePlan.WingetPackageIds[$major] }
            if (-not $packageId) { $packageId = "Microsoft.DotNet.SDK.$major" }
            $publishedAt = Get-WingetReleaseDate -ToolName $entry.Key -PackageId $packageId -Version $row.Latest
        }
        if (-not $publishedAt) { $publishedAt = Get-DotNetSDKPublishedAt -Version $row.Latest -LatestSdkByChannel $latestSdkByChannel }
        if ($row.Latest -and ($publishedAt -or -not $previous)) {
            $null = Set-ToolReleaseInformation -ToolName $entry.Key -LatestVersion $row.Latest -PublishedAt $publishedAt -CooldownDays $cfg.CooldownDays
        }
        foreach ($property in @('LatestCooldown', 'LatestReleased', 'AgeDays', 'Installable', 'BlockReason')) {
            if ($row.ContainsKey($property)) { (Get-ToolState 'dotnet-sdk')[$row.Installed][$property] = $row[$property] }
        }
    }
    foreach ($name in $previousRows.Keys | Where-Object { $_ -like '* (new major version)' }) {
        if (-not $byMajor.ContainsKey($previousRows[$name].ItemId)) { $results.Tools[$name] = $previousRows[$name] }
    }

    # Prune .NET items from Updates / AvailableUpdates that are now satisfied
    # (either the patch landed or an equal/higher SDK in the same channel is
    # already installed).
    $results.Updates = @($results.Updates | Where-Object {
        if ($_ -notmatch '^\.NET SDK:\s*(?<from>\d[\w.\-]*)\s*->\s*(?<to>\d[\w.\-]*)') { return $true }
        $from = $Matches.from; $to = $Matches.to
        $maj  = ($from -split '\.')[0]
        $hi   = if ($byMajor[$maj]) { Sort-SemanticVersions $byMajor[$maj] | Select-Object -Last 1 } else { $null }
        -not ($hi -and (Compare-SemanticVersions $hi $to) -ge 0)
    })
    $results.AvailableUpdates = @($results.AvailableUpdates | Where-Object {
        if ($_.Name -notmatch '^\.NET SDK\s+(?<from>\d[\w.\-]*)$') { return $true }
        $from = $Matches.from
        $maj  = ($from -split '\.')[0]
        if (-not $byMajor[$maj]) { return $true }
        $hi   = Sort-SemanticVersions $byMajor[$maj] | Select-Object -Last 1
        $lat  = (Get-ToolState 'dotnet-sdk')[$hi].Latest
        -not ($lat -and (Compare-SemanticVersions $hi $lat) -ge 0)
    })
}
#endregion