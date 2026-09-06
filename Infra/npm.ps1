# Shared npm metadata and cooldown policy, loaded only by selected dependencies.
# *-PackageManager operations are locally dispatched; named npm helpers are shared with tools.
function Get-ExecutionOutcome-PackageManager {
    param([object]$Action, [int]$ExitCode, [string]$OutputText)
    if ($OutputText -match 'EALLOWREMOTE') {
        @{ Status = 'Failed'; Message = "Failed: $($Action.Name) - npm rejected this package as a remote dependency; reinstall it from the configured registry before retrying | Command: $($Action.Command)" }
    }
}

function Get-LatestVersion-PackageManager {
    param([object]$ApiData, [string]$ToolName)
    $config = Get-ToolConfiguration -ToolName $ToolName
    $latest = if ($ApiData.'dist-tags') { $ApiData.'dist-tags'.latest } else { $null }
    if ($config.ProductionReleasesOnly -and -not (Test-IsProductionVersion $latest)) {
        return Get-LatestProductionNpmVersion -ApiData $ApiData
    }
    $latest
}

function Get-ReleasePlan-PackageManager {
    param([string]$ToolName, [string]$InstalledVersion)
    $config = Get-ToolConfiguration -ToolName $ToolName
    $apiData = Invoke-SafeApiRequest -Uri $config.ApiUrl
    if (-not $apiData) { return }
    $latest = Get-LatestVersion-PackageManager -ApiData $apiData -ToolName $ToolName
    if (-not $latest) { return }
    # Prefer the newest mature upgrade, even when the latest tag is still cooling down.
    $release = Get-LatestMatureNpmRelease -ApiData $apiData -MinimumVersion $InstalledVersion -MaximumVersion $latest -ProductionReleasesOnly $config.ProductionReleasesOnly
    if ($release) { $latest = $release.Version }
    else { $release = Get-NpmVersionReleaseInfo -PackageName $config.NpmPackageName -Version $latest }
    $ageDays = if ($release) { $release.AgeDays } else { $null }
    $installable = $release -and $release.Installable
    $reason = if (-not $release) { 'the release age could not be verified.' }
        elseif (-not $installable) { "this release is not installable until it is $($script:ReleaseCooldownDays) days old." }
    @{
        Latest = $latest
        Installable = [bool]$installable
        AgeDays = $ageDays
        AgeLabel = if ($release) { " ($ageDays days old)" } else { ' (age unknown)' }
        BlockReason = $reason
        MaturityBlocked = $release -and -not $installable
        RequiredAgeDays = $script:ReleaseCooldownDays
        # Pin the release whose age was checked so execution cannot follow a newer tag.
        Command = $config.UpdateCommand.Replace("$($config.NpmPackageName)@latest", "$($config.NpmPackageName)@$latest")
        Type = $config.UpdateType
        VersionLabel = 'latest version'
    }
}

function Get-GlobalNpmInstalledVersion {
    param([string]$PackageName)
    try {
        $json = npm list -g $PackageName --depth=0 --json --silent 2>$null
        if (-not $json) { return $null }
        $parsed = $json | ConvertFrom-Json
        $dep = $parsed.dependencies.PSObject.Properties | Where-Object { $_.Name -eq $PackageName } | Select-Object -First 1
        if ($dep -and $dep.Value.version) { $dep.Value.version } else { $null }
    } catch { $null }
}

function Get-NpmVersionReleaseInfo {
    param([string]$PackageName, [string]$Version)

    try {
        $json = npm view "$PackageName@$Version" time --json 2>$null
        if (-not $json) { return $null }
        $time = $json | ConvertFrom-Json
        $publishedAt = [DateTimeOffset]::Parse($time.$Version).ToUniversalTime()
        $age = [DateTimeOffset]::UtcNow - $publishedAt
        [PSCustomObject]@{
            PublishedAt = $publishedAt
            AgeDays     = [Math]::Max(0, [Math]::Floor($age.TotalDays))
            Installable = $age.TotalDays -ge $script:ReleaseCooldownDays
        }
    } catch {
        Write-Warning "Could not determine publish time for $PackageName@$Version"
        $null
    }
}

function Get-LatestProductionNpmVersion {
    param([object]$ApiData)

    if (-not $ApiData -or -not $ApiData.versions) { return $null }
    $versions = @($ApiData.versions.PSObject.Properties.Name | Where-Object { Test-IsProductionVersion $_ })
    $versions |
        ForEach-Object { $_ -replace '^v', '' } |
        Sort-Object { [version]$_ } -Descending |
        Select-Object -First 1
}

function Get-LatestMatureNpmRelease {
    # Search the installed-to-latest window descending; missing/invalid dates are ineligible.
    param(
        [object]$ApiData,
        [string]$MinimumVersion,
        [string]$MaximumVersion,
        [bool]$ProductionReleasesOnly = $true
    )

    if (-not $ApiData -or -not $ApiData.versions -or -not $ApiData.time) { return $null }
    $versions = @($ApiData.versions.PSObject.Properties.Name | Where-Object {
        -not $ProductionReleasesOnly -or (Test-IsProductionVersion $_)
    }) | ForEach-Object { $_ -replace '^v', '' } | Sort-Object { [version](ConvertTo-CanonicalSemanticVersion $_) } -Descending

    foreach ($version in $versions) {
        if ($MinimumVersion -and (Compare-SemanticVersions $MinimumVersion $version) -ne -1) { continue }
        if ($MaximumVersion -and (Compare-SemanticVersions $version $MaximumVersion) -eq 1) { continue }
        $publishedProperty = $ApiData.time.PSObject.Properties[$version]
        if (-not $publishedProperty) { continue }
        try {
            $publishedAt = [DateTimeOffset]::Parse("$($publishedProperty.Value)").ToUniversalTime()
            $age = [DateTimeOffset]::UtcNow - $publishedAt
            if ($age.TotalDays -ge $script:ReleaseCooldownDays) {
                return [PSCustomObject]@{
                    Version     = $version
                    PublishedAt = $publishedAt
                    AgeDays     = [Math]::Max(0, [Math]::Floor($age.TotalDays))
                    Installable = $true
                }
            }
        } catch { continue }
    }
    $null
}
