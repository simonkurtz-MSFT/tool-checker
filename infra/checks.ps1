# Generic inventory, version comparison, and update planning. Catalog data or a
# selected package manager owns package-specific parsing and eligibility; checks never install.
function Get-CommandVersion {
    param([string]$Command, [string]$VersionFlag = "--version")
    if ([string]::IsNullOrWhiteSpace($VersionFlag)) { $VersionFlag = "--version" }
    try   { $output = & $Command $VersionFlag 2>&1; ($output -split "`n" | Select-Object -First 1).Trim() }
    catch { "Unable to retrieve version" }
}

function Set-LatestToolVersion {
    param(
        [Parameter(Mandatory)]
        [string[]]$ToolNames,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LatestVersion,
        [bool]$ProductionReleasesOnly = $true,
        [string]$VersionLabel = 'version'
    )

    if ([string]::IsNullOrWhiteSpace($LatestVersion)) { return $false }
    if ($ProductionReleasesOnly -and -not (Test-IsProductionVersion $LatestVersion)) {
        Write-Warning "  Latest $VersionLabel '$LatestVersion' is not a full production semantic version"
        return $false
    }

    foreach ($toolName in $ToolNames) {
        if (-not $results.Tools.ContainsKey($toolName)) {
            throw "Cannot set latest version for unregistered tool '$toolName'."
        }
        $results.Tools[$toolName].Latest = $LatestVersion
    }
    $true
}

function Invoke-SafeApiRequest {
    param([string]$Uri, [int]$Timeout = $script:ApiRequestTimeout)
    try   { Invoke-RestMethod -Uri $Uri -TimeoutSec $Timeout -ErrorAction Stop }
    catch {
        $details = Get-DetailedErrorMessage $_
        $message = "API request failed for $Uri. $details"
        Write-Error "  $message"
        $results.Errors += $message
        $null
    }
}

function Add-NotInstalledTool {
    param([string]$ToolName)
    if ($results.NotInstalled | Where-Object { $_.Name -eq $ToolName }) { return }
    $cfg = $toolsConfig[$ToolName]
    $cmds = if ($cfg -and $cfg.ContainsKey('InstallCommands')) { $cfg.InstallCommands } else { [ordered]@{} }
    $results.NotInstalled += [PSCustomObject]@{ Name = $ToolName; ToolId = $cfg.Id; InstallCommands = $cmds }
}

function Add-AvailableUpdate {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Command,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Type,
        [string]$Details = '',
        [string]$RegistryKey,
        [string]$Version,
        [string]$OwnerId = (Get-ResultToolId -Name $Name),
        [string]$ItemId = $Name,
        [string]$Executor,
        [hashtable]$Arguments = @{},
        [string]$ExecutionMode
    )

    $entry = [ordered]@{
        Name = $Name
        Command = $Command
        Type = $Type
        Details = $Details
        ToolId = $OwnerId
        ItemId = $ItemId
        Operation = 'Update'
        Executor = $Executor
        EntryPoint = if ($Executor -eq 'tool') { 'Invoke-ToolUpdate' } else { $null }
        Arguments = $Arguments
        ExecutionMode = $ExecutionMode
        ReleaseNotesUrl = (Get-OwnedConfiguration -ToolId $OwnerId).ReleaseNotesUrl
    }
    if ($PSBoundParameters.ContainsKey('RegistryKey')) { $entry.RegistryKey = $RegistryKey }
    if ($PSBoundParameters.ContainsKey('Version')) { $entry.Version = $Version }
    # Plans leave workers fully resolved; later UI/job code must not guess their executor.
    $results.AvailableUpdates += (Resolve-ActionMetadata -Action $entry)
}

function Register-ToolUpdate {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$InstalledVersion,
        [Parameter(Mandatory)]
        [string]$LatestVersion,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Command,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Type
    )

    if (-not (Test-UpdateAvailable -InstalledVersion $InstalledVersion -LatestVersion $LatestVersion -ToolName $Name)) {
        return $false
    }

    $results.Updates += $Name
    Add-AvailableUpdate -Name $Name -Command $Command -Type $Type -Details "$InstalledVersion -> $LatestVersion"
    $true
}

function Test-StandardTool {
    param([string]$ToolName, [string]$Progress)

    $config = $toolsConfig[$ToolName]
    Write-Header "Checking $ToolName" -Progress $Progress

    if (-not (Test-CommandExists $config.Command)) {
        Write-Error "$ToolName not installed"
        Add-NotInstalledTool $ToolName
        return
    }

    # Obtain raw version output
    if ($config.VersionCommand) {
        try   { $raw = Invoke-Expression "$($config.VersionCommand) 2>&1" }
        catch { $raw = "Unable to retrieve version" }
    } else {
        $raw = Get-CommandVersion $config.Command $config.VersionFlag
    }

    # Extract installed version
    $version = Get-InstalledVersionFromOutput -ToolName $ToolName -Output $raw
    if (-not $version) {
        Write-Warning "Could not parse $ToolName version"
        $results.Tools[$ToolName] = @{ ToolId = $config.Id; Installed = "unknown"; Latest = "" }
        return
    }

    Write-Success "$ToolName installed: $version"
    $results.Tools[$ToolName] = @{ ToolId = $config.Id; Installed = $version; Latest = ""; ReleaseNotesUrl = $config.ReleaseNotesUrl }

    if (-not $SkipUpdate) {
        Get-StandardToolUpdates -ToolName $ToolName -InstalledVersion $version -RawOutput $raw
    }
}

function Get-InstalledVersionFromOutput {
    param([string]$ToolName, [object]$Output)

    $config    = $toolsConfig[$ToolName]
    $extractor = $config.VersionExtractor
    $versionState = Get-ToolState -ToolId $config.Id
    $versionState.InstalledVersionSource = 'command'
    $packageManager = Get-ConfiguredPackageManager -Configuration $config -Operation 'InstalledVersion'
    if ($packageManager) {
        $packageVersion = Invoke-PackageManagerOperation -PackageManager $packageManager -Operation 'Get-InstalledVersion' -Arguments @{ ToolName = $ToolName }
        if ($packageVersion) {
            $versionState.InstalledVersionSource = $packageManager
            return $packageVersion
        }
    }
    $outputStr = if ($Output -is [array]) { $Output -join "`n" } else { "$Output" }
    if ([string]::IsNullOrWhiteSpace($outputStr) -or $outputStr.Trim() -eq 'Unable to retrieve version') {
        return $null
    }

    switch ($extractor) {
        "jsonProperty" {
            try   { ($outputStr | ConvertFrom-Json).($config.VersionProperty) }
            catch { $null }
        }
        # Simple parser variations belong in catalog properties, not product-name cases.
        default {
            # Use VersionParseRegex from JSON; fall back to stripping a leading 'v'
            $firstLine = if ($config.ParseEntireVersionOutput) { $outputStr } else { ($outputStr -split "`n" | Select-Object -First 1).Trim() }
            if ($config.VersionParseRegex -and $firstLine -match $config.VersionParseRegex) {
                $Matches[1]
            } elseif ($config.ParseEntireVersionOutput) {
                $null
            } else {
                $firstLine -replace '^v', ''
            }
        }
    }
}

function Get-LatestVersionFromApi {
    param([object]$ApiData, [string]$ToolName)

    $config = $toolsConfig[$ToolName]
    $extractor = $config.VersionExtractor

    if ($config.ApiVersionProperty) {
        $value = $ApiData
        foreach ($property in ($config.ApiVersionProperty -split '\.')) {
            if ($null -eq $value) { return $null }
            $value = $value.$property
        }
        return $value
    }
    if ($config.ApiVersionRegex) {
        if ($ApiData.tag_name -match $config.ApiVersionRegex) { return $Matches[1] }
        return $null
    }

    $packageManager = Get-ConfiguredPackageManager -Configuration $config -Operation 'ApiVersion'
    if ($packageManager) { return Invoke-PackageManagerOperation -PackageManager $packageManager -Operation 'Get-LatestVersion' -Arguments @{ ToolName = $ToolName; ApiData = $ApiData } }
    if ($ApiData.tag_name) { $ApiData.tag_name -replace '^v', '' }
    elseif ($ApiData.version) { $ApiData.version }
    elseif ($ApiData.release) { $ApiData.release }
    else { $null }
}

function Get-StandardToolUpdates {
    param([string]$ToolName, [string]$InstalledVersion, [object]$RawOutput = $null)

    $config = $toolsConfig[$ToolName]
    Write-Host "  Checking for $ToolName updates..."

    $packageManager = Get-ConfiguredPackageManager -Configuration $config -Operation 'Release'
    $versionState = Get-ToolState -ToolId $config.Id
    $versionState.LatestVersionSource = if ($packageManager) { $packageManager } elseif ($config.UpdateParseRegex) { 'command' } else { 'api' }
    if ($packageManager) {
        $plan = Invoke-PackageManagerOperation -PackageManager $packageManager -Operation 'Get-ReleasePlan' -Arguments @{ ToolName = $ToolName; InstalledVersion = $InstalledVersion }
        if ($plan) { Register-ReleasePlan -ToolName $ToolName -InstalledVersion $InstalledVersion -Plan $plan }
        return
    }

    # Self-reporting tools: the version command itself reveals available updates
    if ($config.UpdateParseRegex) {
        $outputStr = if ($RawOutput -is [array]) { $RawOutput -join ' ' } else { "$RawOutput" }
        if ($outputStr -match $config.UpdateParseRegex) {
            $latestVersion = $Matches[1]
            if ($null -ne $latestVersion) {
                $latestVersion = "$latestVersion".Trim().TrimEnd('.')
            }
            if (-not (Set-LatestToolVersion -ToolNames $ToolName -LatestVersion $latestVersion -ProductionReleasesOnly $config.ProductionReleasesOnly -VersionLabel 'reported version')) { return }
            $updateCommand = Get-UpdateCommand -ToolName $ToolName -Installed $InstalledVersion -Latest $latestVersion
            if (Register-ToolUpdate -Name $ToolName -InstalledVersion $InstalledVersion -LatestVersion $latestVersion -Command $updateCommand -Type $config.UpdateType) {
                Write-Warning "  $ToolName has available updates: $InstalledVersion -> $latestVersion"
                $url = $config.ReleaseNotesUrl; if ($url) { Write-Host "  Release notes: $url" }
            } else {
                Write-Success "$ToolName is up to date"
            }
        } else {
            $results.Tools[$ToolName].Latest = $InstalledVersion
            Write-Success "$ToolName is up to date"
        }
        return
    }

    # API-based update check
    try {
        if (-not $config.ApiUrl) { Write-Warning "  No API endpoint configured for $ToolName"; return }

        $apiData = Invoke-SafeApiRequest -Uri $config.ApiUrl
        if (-not $apiData) { return }

        $latestVersion = Get-LatestVersionFromApi -ToolName $ToolName -ApiData $apiData
        if (-not $latestVersion) { Write-Warning "  Could not determine latest version"; return }

        if (-not (Set-LatestToolVersion -ToolNames $ToolName -LatestVersion $latestVersion -ProductionReleasesOnly $config.ProductionReleasesOnly)) { return }

        if (Test-UpdateAvailable -InstalledVersion $InstalledVersion -LatestVersion $latestVersion -ToolName $ToolName) {
            Write-Warning "  $ToolName has available updates: $InstalledVersion -> $latestVersion"
            $results.Updates += $ToolName
            if (-not $SkipUpdate) {
                $url = $config.ReleaseNotesUrl; if ($url) { Write-Host "  Release notes: $url" }
                $updateCommand = Get-UpdateCommand -ToolName $ToolName -Installed $InstalledVersion -Latest $latestVersion
                Add-AvailableUpdate -Name $ToolName -Command $updateCommand -Type $config.UpdateType -Details "$InstalledVersion -> $latestVersion"
            }
        } else {
            Write-Success "$ToolName is up to date"
        }
    } catch {
        Write-Warning "  Could not check $ToolName updates: $_"
    }
}

function Register-ReleasePlan {
    # Consume the package manager's eligibility and exact command, including blocked releases
    # that remain visible for information but must not enter the executable action list.
    param([string]$ToolName, [string]$InstalledVersion, [hashtable]$Plan)
    $config = Get-ToolConfiguration -ToolName $ToolName
    $latest = $Plan.Latest
    if (-not (Set-LatestToolVersion -ToolNames $ToolName -LatestVersion $latest -ProductionReleasesOnly $config.ProductionReleasesOnly -VersionLabel $Plan.VersionLabel)) { return }
    $row = $results.Tools[$ToolName]
    $row.AgeDays = $Plan.AgeDays
    $row.Installable = $Plan.Installable
    $row.BlockReason = $Plan.BlockReason
    if (Test-UpdateAvailable -InstalledVersion $InstalledVersion -LatestVersion $latest -ToolName $ToolName) {
        $results.Updates += $ToolName
        Write-Warning "  $ToolName has available updates$($Plan.SourceLabel): $InstalledVersion -> $latest$($Plan.AgeLabel)"
        if (-not $Plan.Installable) {
            Write-Host "  FYI only: $($Plan.BlockReason)"
            if ($Plan.MaturityBlocked) { $results.MaturityBlockedUpdates += @{ Name = $ToolName; AgeDays = $Plan.AgeDays; RequiredAgeDays = $Plan.RequiredAgeDays } }
        } elseif (-not $SkipUpdate) {
            if ($config.ReleaseNotesUrl) { Write-Host "  Release notes: $($config.ReleaseNotesUrl)" }
            Add-AvailableUpdate -Name $ToolName -Command $Plan.Command -Type $Plan.Type -Details "$InstalledVersion -> $latest"
        }
    } else { Write-Success "$ToolName is up to date$($Plan.CurrentLabel)" }
}

function Refresh-ToolVersion {
    # Dynamic rows route by owner ID; a tool may refresh its entire managed inventory.
    param([string]$ToolName)
    try {
        $owner = Get-ResultToolId -Name $ToolName
        $config = Get-OwnedConfiguration -ToolId $owner
        if (-not $config) { Write-Warning "  Tool configuration not found: $ToolName"; return $false }

        if ($config.Id -and $script:ToolDefinitions.ContainsKey($config.Id) -and $script:ToolDefinitions[$config.Id].ContainsKey('Refresh-ToolStatus')) {
            Invoke-ToolEntryPoint -ToolId $config.Id -EntryPoint 'Refresh-ToolStatus' -Arguments @{ ToolName = $ToolName }
        } else {
            Refresh-StandardVersion -ToolName $ToolName -Config $config
        }
        return $true
    } catch {
        Write-Warning "  Error refreshing version for ${ToolName}: $_"
        return $false
    }
}

function Refresh-StandardVersion {
    param([string]$ToolName, [hashtable]$Config)
    if (-not (Test-CommandExists $Config.Command)) { return }
    $version = Get-CommandVersion $Config.Command $Config.VersionFlag
    if ($version -and $version -notmatch "Unable to retrieve") {
        $installedVersion = Get-InstalledVersionFromOutput -ToolName $ToolName -Output $version
        if ($installedVersion) { $results.Tools[$ToolName].Installed = $installedVersion }
    }
}

function Get-UpdateCommand {
    param([string]$ToolName, [string]$Installed, [string]$Latest)
    if (-not $Latest -or $Latest -eq "-" -or -not (Test-UpdateAvailable -InstalledVersion $Installed -LatestVersion $Latest -ToolName $ToolName)) { return "" }
    if ($ToolName -in $results.MaturityBlockedUpdates.Name) { return "" }

    # A planned command can pin a verified release; never replace it with a moving tag.
    $availableUpdate = $results.AvailableUpdates | Where-Object { $_.Name -eq $ToolName } | Select-Object -First 1
    if ($availableUpdate) { return $availableUpdate.Command }

    if ($results.Tools.ContainsKey($ToolName) -and $results.Tools[$ToolName].Covered) { return '' }

    # Direct config match
    foreach ($k in $toolsConfig.Keys) {
        if ($ToolName -ne $k) { continue }
        $config = $toolsConfig[$k]
        if ($config.ReleasePackageManager) { return '' }
        if ($config.WindowsUpdateCommand -and ($IsWindows -or $env:OS -eq 'Windows_NT')) {
            return $config.WindowsUpdateCommand
        }
        return $config.UpdateCommand
    }

    ""
}

function Get-ReleaseNotesUrl {
    param([string]$ToolName)
    $config = Get-OwnedConfiguration -ToolId (Get-ResultToolId -Name $ToolName)
    if ($config) { return $config.ReleaseNotesUrl }
    ''
}
