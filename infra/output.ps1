# Console palette and rendering only. Loading this file defines helpers without
# changing caller state; bootstrap explicitly initializes colors before rendering.
function Initialize-ConsoleColors {
    # Target the immediate caller, whether bootstrap runs normally or is dot-sourced.
    # Workers receive a snapshot of these variables and do not initialize them again.
    $palette = @{
        ColorReset = "`e[0m"
        ColorGreen = "`e[32m"
        ColorYellow = "`e[33m"
        ColorRed = "`e[31m"
        ColorCyan = "`e[36m"
        ColorBlue = "`e[34m"
        ColorOrange = "`e[38;5;208m"
    }
    foreach ($color in $palette.GetEnumerator()) {
        Set-Variable -Name $color.Key -Value $color.Value -Scope 1
    }
}

# Warning/error helpers intentionally write to the host, not PowerShell error streams.
function Write-Header  { param([string]$Text, [string]$Progress = "")
    if ($Progress) { Write-Host "`n$ColorBlue► [$Progress] $Text$ColorReset" }
    else           { Write-Host "`n$ColorBlue► $Text$ColorReset" }
}
function Write-Success { param([string]$Text) Write-Host "  $ColorGreen✓ $Text$ColorReset" }
function Write-Warning { param([string]$Text) Write-Host "  $ColorYellow⚠ $Text$ColorReset" }
function Write-Error   { param([string]$Text) Write-Host "  $ColorRed✗ $Text$ColorReset" }

function Get-ApplicationBannerLines {
    param([Parameter(Mandatory)][string]$Version)

    $indent = '  '
    $padding = '   '
    $title = "Tool Checker V$Version"
    $border = '═' * ($title.Length + (2 * $padding.Length))
    @(
        "$indent╔$border╗"
        "$indent║$padding$title$padding║"
        "$indent╚$border╝"
    )
}

function Show-ApplicationBanner {
    Write-Host ''
    foreach ($line in Get-ApplicationBannerLines -Version $script:ToolCheckerVersion) {
        Write-Host "$ColorCyan$line$ColorReset"
    }
    Write-Host ''
}

function Show-UpdateLegend {
    if ($results.Updates.Count -eq 0 -and $results.Tools.Count -eq 0) { return }

    Write-Host "  npm release cooldown: $script:ReleaseCooldownDays full days"
    Write-Host ''
    Write-Host "  ${ColorCyan}Legend$ColorReset"
    Write-Host "    $ColorYellow■ Installable update / version unknown$ColorReset"
    Write-Host "    $ColorOrange■ No verified installable release$ColorReset"
    Write-Host "    ${ColorCyan}* Older than installed; informational only, no downgrade offered.$ColorReset"
    Write-Host ''
    Write-Host '  Latest Released is informational only.'
    Write-Host '  "-" means no verified cooldown-safe version or not checked.'
}

function Get-ResultsNameColumnWidth {
    $maxName = ($results.Tools.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    if (-not $maxName -or $maxName -lt 4) { return 4 }
    return $maxName
}

function Show-ResultsTable {
    # Older/non-cooldown checks supply Latest only; explicit null means no verified safe release.
    $rows = @($results.Tools.GetEnumerator() | ForEach-Object {
        $row = $_.Value
        $latest = if ($row.Latest) { $row.Latest } elseif ($SkipUpdate) { '-' } else { 'unknown' }
        $cooldown = if ($row.ContainsKey('LatestCooldown')) {
            if ($row.LatestCooldown) { $row.LatestCooldown } else { '-' }
        } elseif ($_.Key -in $results.MaturityBlockedUpdates.Name -or ($row.ContainsKey('Installable') -and -not $row.Installable)) {
            '-'
        } else { $latest }
        $released = if ($row.LatestReleased) { $row.LatestReleased } else { $latest }
        $comparisons = @{}
        foreach ($column in @{ Cooldown = $cooldown; Released = $released }.GetEnumerator()) {
            $comparisons[$column.Key] = if (
                -not [string]::IsNullOrWhiteSpace($row.Installed) -and
                $row.Installed -notin @('-', '?', 'unknown', 'Unable to retrieve version') -and
                $column.Value -notin @('-', '?', 'unknown', 'Unable to retrieve version')) {
                Compare-OwnedToolVersions -Version1 $row.Installed -Version2 $column.Value -ToolName $_.Key
            } else { $null }
        }
        $age = '-'
        if ($null -ne $row.AgeDays -and
            (Compare-OwnedToolVersions -Version1 $row.Installed -Version2 $row.Latest -ToolName $_.Key) -lt 0) {
            $age = "$($row.AgeDays)d"
        }
        [pscustomobject]@{
            Name = $_.Key
            Row = $row
            Cooldown = $cooldown
            CooldownComparison = $comparisons.Cooldown
            CooldownDisplay = if ($comparisons.Cooldown -gt 0) { "$cooldown*" } else { $cooldown }
            Age = $age
            ReleasedComparison = $comparisons.Released
            ReleasedDisplay = if ($comparisons.Released -gt 0) { "$released*" } else { $released }
        }
    } | Sort-Object {
        $config = Get-OwnedConfiguration -ToolId (Get-ResultToolId -Name $_.Name)
        Get-ToolSortKey -ToolName $_.Name -Configuration $config -Row $_.Row
    })
    $maxName = Get-ResultsNameColumnWidth
    $maxInst = [Math]::Max(9, ($rows | ForEach-Object { "$($_.Row.Installed)".Length } | Measure-Object -Maximum).Maximum)
    $maxCooldown = [Math]::Max(15, ($rows.CooldownDisplay | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum)
    $maxAge = [Math]::Max(3, ($rows.Age | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum)
    $maxReleased = [Math]::Max(15, ($rows.ReleasedDisplay | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum)

    Write-Host ""
    $hdr = "  {0,-$maxName}   {1,-$maxInst}   {2,-$maxCooldown}   {3,$maxAge}   {4,-$maxReleased}" -f "Name","Installed","Latest Cooldown","Age","Latest Released"
    Write-Host "$ColorCyan$hdr$ColorReset"
    Write-Host ("  {0}   {1}   {2}   {3}   {4}" -f ("-"*$maxName),("-"*$maxInst),("-"*$maxCooldown),("-"*$maxAge),("-"*$maxReleased))

    $rows | ForEach-Object {
        $inst = $_.Row.Installed
        $installedUnknown = [string]::IsNullOrWhiteSpace($inst) -or $inst -in @('unknown', 'Unable to retrieve version')
        $latestUnknown = $_.Cooldown -eq 'unknown'
        $currentOrNewer = $null -ne $_.CooldownComparison -and $_.CooldownComparison -ge 0
        $noSafeRelease = $_.Cooldown -eq '-' -and ($_.Row.ContainsKey('LatestCooldown') -or $_.Name -in $results.MaturityBlockedUpdates.Name -or ($_.Row.ContainsKey('Installable') -and -not $_.Row.Installable))
        $clr  = if ($_.Name -in $results.UpdateFailed) { $ColorRed }
            elseif ($_.Row.CheckTimedOut) { $ColorRed }
            elseif ($installedUnknown -or $latestUnknown) { $ColorYellow }
            elseif ($currentOrNewer -or $_.Row.Covered) { $ColorGreen }
            elseif ($noSafeRelease) { $ColorOrange }
            elseif ($_.Cooldown -eq '-') { $ColorGreen }
                else { $ColorYellow }
        $cooldownCell = "{0,-$maxCooldown}" -f $_.CooldownDisplay
        if ($_.CooldownComparison -gt 0) { $cooldownCell = "$ColorCyan$cooldownCell$ColorReset$clr" }
        $row = "  {0,-$maxName}   {1,-$maxInst}   {2}   {3,$maxAge}" -f $_.Name,$inst,$cooldownCell,$_.Age
        $releasedColor = if ($_.ReleasedComparison -gt 0) { $ColorCyan }
            elseif ($null -ne $_.ReleasedComparison -and $_.ReleasedComparison -eq 0) { $ColorGreen } else { '' }
        Write-Host "$clr$row$ColorReset   $releasedColor$($_.ReleasedDisplay)$ColorReset"
    }
    $installationOwners = @($results.ToolState.Keys | Where-Object {
        $results.ToolState[$_].ContainsKey('Installations') -and
        @($results.ToolState[$_].Installations | Where-Object Status -eq 'Found').Count -gt 1
    } | Sort-Object)
    if ($installationOwners.Count -gt 0) {
        Write-Host ""
        Write-Host "${ColorCyan}  Package installations (global inventories)$ColorReset"
        Write-Host ""
        foreach ($owner in $installationOwners) {
            $state = $results.ToolState[$owner]
            $config = Get-OwnedConfiguration -ToolId $owner
            $name = if ($config.Name) { $config.Name } else { $owner }
            $found = @($state.Installations | Where-Object Status -eq 'Found')
            $duplicate = $found.Count -gt 1
            $label = if ($duplicate) { "$name [multiple installations]" } else { $name }
            $color = if ($duplicate) { $ColorYellow } else { $ColorCyan }
            Write-Host "$color  $label$ColorReset"
            foreach ($installation in $found) {
                Write-Host "    $($installation.PackageManager): $($installation.PackageName)@$($installation.Version)"
                if ($installation.Path) { Write-Host "      $($installation.Path -replace '^\\\\\?\\', '')" }
            }
            $cleanup = @(Get-DuplicateInstallationActions | Where-Object ToolId -eq $owner | Select-Object -First 1)
            if ($cleanup.Count -gt 0) { Write-Host "$ColorYellow    Recommended removal: $($cleanup[0].Command)$ColorReset" }
            if ($state.ResolvedCommandPath) {
                Write-Host ""
                Write-Host "    Command resolves to: $($state.ResolvedCommandPath -replace '^\\\\\?\\', '')"
                Write-Host ""
            }
        }
    }
    Write-Host ""
}

function Show-ToolDetails {
    Write-Header 'Update / Install commands and Release Notes'
    $names = @(@($results.Tools.Keys) + @($results.NotInstalled.Name) | Sort-Object -Unique)
    if ($names.Count -eq 0) { Write-Host '  No tool details available.' }
    foreach ($name in $names) {
        $missing = $results.NotInstalled | Where-Object Name -eq $name | Select-Object -First 1
        $row = $results.Tools[$name]
        $command = if ($missing) { Get-InstallCommand -NotInstalledEntry $missing }
            elseif ($row) { Get-UpdateCommand -ToolName $name -Installed $row.Installed -Latest $row.Latest }
        $url = Get-ReleaseNotesUrl -ToolName $name
        Write-Host "`n  $ColorCyan$name$ColorReset"
        if ($command) { Write-Host "    Update / Install: $command" }
        elseif ($missing) { Write-Host '    Update / Install: No install command for this platform' }
        Write-Host "    Release Notes: $(if ($url) { $url } else { 'Not configured' })"
    }
    Write-Host ''
}

function Show-StartupInformation {
    param([bool]$IsElevated)

    Write-Host "  Process elevated     : $(if ($IsElevated) { 'Yes' } else { 'No' })"

    if ($SkipUpdate) { Write-Warning "Running in check-only mode (updates disabled)" }
    if ($Force)      { Write-Warning "Running with automatic update (no prompts)" }

    Write-Host "  Registry policy file : $resolvedEnvFile"
    Write-Host "  Selected tool count  : $($toolsConfig.Count)/$($catalogToolIds.Count)"
}

function Show-RegistryMetadata {
    $registryMetadataRows = @($toolsConfig.Keys |
        Where-Object { $toolsConfig[$_].VersionExtractor -eq 'npmDistTagLatest' } |
        Sort-Object |
        ForEach-Object {
            $label = if ($_ -eq 'GitHub Copilot CLI') { 'GHCP CLI metadata URL' } else { "$_ metadata URL" }
            [PSCustomObject]@{ Label = $label; Url = $toolsConfig[$_].ApiUrl }
        })
    $registryLabels = @('npm registry source', 'npm registry URL') + @($registryMetadataRows.Label)
    $registryLabelWidth = (($registryLabels | Measure-Object -Property Length -Maximum).Maximum + 1)
    Write-Host ""
    Write-Host ("  {0,-$registryLabelWidth}: {1}" -f 'npm registry source', $script:NpmRegistryResolution.Source)
    Write-Host ("  {0,-$registryLabelWidth}: {1}" -f 'npm registry URL', $script:NpmRegistryResolution.Url)
    if ($script:NpmRegistryResolution.Details) {
        Write-Warning "Registry resolution detail: $($script:NpmRegistryResolution.Details)"
    }
    foreach ($row in $registryMetadataRows) {
        Write-Host ("  {0,-$registryLabelWidth}: {1}" -f $row.Label, $row.Url)
    }
    Write-Host ""
}

function Show-CheckProgressHeader {
    param([int]$Total, [int]$TimeoutSec)

    Write-Host "  -----------------------------------"
    Write-Host ""
    Write-Host "  Running $Total checks in parallel (${TimeoutSec}s timeout)...`n"
}

function Show-ResultsSummary {
    param([string[]]$AvailableUpdateNames)

    Write-Host ""
    Write-Host ""
    Show-UpdateLegend
    Write-Header "Summary"
    Show-ResultsTable

    if ($results.NotInstalled.Count -gt 0) {
        Write-Host "`n$ColorRed✗ Not Installed ($($results.NotInstalled.Count)):$ColorReset"
        $results.NotInstalled | ForEach-Object {
            Write-Host "  - $($_.Name)"
        }
    }
    if ($AvailableUpdateNames.Count -gt 0) {
        Write-Host "`n$ColorYellow⚠  Updates Available ($($AvailableUpdateNames.Count)):$ColorReset"
        $AvailableUpdateNames | ForEach-Object { Write-Host "  - $_" }
    }
    if ($results.MaturityBlockedUpdates.Count -gt 0) {
        Write-Host "`n$ColorOrange⚠  Updates Not Yet Available ($($results.MaturityBlockedUpdates.Count)):$ColorReset"
        $nameWidth = Get-ResultsNameColumnWidth
        $blockedNameWidth = ($results.MaturityBlockedUpdates.Name | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
        if ($blockedNameWidth -gt $nameWidth) { $nameWidth = $blockedNameWidth }
        $labelWidth = $nameWidth + 1
        $results.MaturityBlockedUpdates | ForEach-Object {
            $ageUnit = if ($_.AgeDays -eq 1) { 'day' } else { 'days' }
            $requiredAgeUnit = if ($_.RequiredAgeDays -eq 1) { 'day' } else { 'days' }
            Write-Host ("  - {0,-$labelWidth}: release is {1} {2} old; available at {3} {4}" -f
                $_.Name, $_.AgeDays, $ageUnit, $_.RequiredAgeDays, $requiredAgeUnit)
        }
    }
    if ($results.Errors.Count -gt 0) {
        Write-Host "`n$ColorRed⚠  Errors ($($results.Errors.Count)):$ColorReset"
        $results.Errors | ForEach-Object { Write-Host "  - $_" }
    }
    Write-Host "`n$ColorCyan═══════════════════════════════════════$ColorReset`n"
}