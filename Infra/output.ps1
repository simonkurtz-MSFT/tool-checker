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

function Show-UpdateLegend {
    if ($results.Updates.Count -eq 0) { return }

    Write-Host "  npm release cooldown: $script:NpmUpdateCooldownDays full days"
    Write-Host "  $ColorYellow■ Installable update / version unknown$ColorReset  $ColorOrange■ Cooldown / not yet installable$ColorReset"
}

function Show-ResultsTable {
    # Column widths
    $maxName = ($results.Tools.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $maxInst = ($results.Tools.Values | ForEach-Object { $_.Installed.Length } | Measure-Object -Maximum).Maximum
    $maxLat  = ($results.Tools.Values | ForEach-Object {
        if (-not $SkipUpdate -and [string]::IsNullOrWhiteSpace($_.Latest)) { "unknown".Length }
        else { $_.Latest.Length }
    } | Measure-Object -Maximum).Maximum
    $ageLabels = @($results.Tools.Values | Where-Object { $null -ne $_.AgeDays } | ForEach-Object { "$($_.AgeDays)d" })
    $ageLabels += @($results.GlobalNpmPackageUpdates | Where-Object { $null -ne $_.AgeDays } | ForEach-Object { "$($_.AgeDays)d" })
    $maxAge = if ($ageLabels.Count -gt 0) { ($ageLabels | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum } else { 0 }
    if ($maxAge -lt 3) { $maxAge = 3 }

    if ($results.GlobalNpmPackageUpdates.Count -gt 0) {
        $pn = ($results.GlobalNpmPackageUpdates | ForEach-Object { ("  "+$_.Name).Length } | Measure-Object -Maximum).Maximum
        $pi = ($results.GlobalNpmPackageUpdates | ForEach-Object { $(if ($_.Installed) { $_.Installed } elseif ($_.Current) { $_.Current } else { "-" }).Length } | Measure-Object -Maximum).Maximum
        $pl = ($results.GlobalNpmPackageUpdates | ForEach-Object { $(if ($_.Latest) { $_.Latest } else { "-" }).Length } | Measure-Object -Maximum).Maximum
        if ($pn -gt $maxName) { $maxName = $pn }; if ($pi -gt $maxInst) { $maxInst = $pi }; if ($pl -gt $maxLat) { $maxLat = $pl }
    }

    $cmds   = $results.Tools.GetEnumerator() | ForEach-Object { Get-UpdateCommand -ToolName $_.Key -Installed $_.Value.Installed -Latest $_.Value.Latest }
    $maxUpd = ($cmds | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    # Only measure release-notes width from tools that have an update or install pending
    $actionableNames = @()
    $actionableNames += $results.NotInstalled | ForEach-Object { $_.Name }
    $actionableNames += $results.Tools.GetEnumerator() | Where-Object {
        $cmd = Get-UpdateCommand -ToolName $_.Key -Installed $_.Value.Installed -Latest $(if ($_.Value.Latest) { $_.Value.Latest } else { "-" })
        $cmd -ne ""
    } | ForEach-Object { $_.Key }
    $urls   = $actionableNames | ForEach-Object { Get-ReleaseNotesUrl -ToolName $_ } | Where-Object { $_ }
    $maxUrl = if ($urls) { ($urls | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum } else { 0 }
    if ($maxName -lt 4)   { $maxName = 4 };  if ($maxInst -lt 9) { $maxInst = 9 }
    if ($maxLat  -lt 6)   { $maxLat  = 6 };  if (-not $maxUpd -or $maxUpd -lt 16) { $maxUpd = 16 }
    if ($maxUrl -lt 13)   { $maxUrl = 13 }

    Write-Host ""
    $hdr = "  {0,-$maxName}  {1,-$maxInst}  {2,-$maxLat}  {3,$maxAge}  {4,-$maxUpd}  {5,-$maxUrl}" -f "Name","Installed","Latest","Age","Update / Install","Release Notes"
    Write-Host "$ColorCyan$hdr$ColorReset"
    Write-Host ("  {0}  {1}  {2}  {3}  {4}  {5}" -f ("-"*$maxName),("-"*$maxInst),("-"*$maxLat),("-"*$maxAge),("-"*$maxUpd),("-"*$maxUrl))

    # Sort: Azure CLI + extensions grouped, .NET SDKs descending, Python descending
    $sorted = $results.Tools.GetEnumerator() | Sort-Object { Get-ToolSortKey $_.Key }

    $sorted | ForEach-Object {
        $inst = $_.Value.Installed
        $installedUnknown = [string]::IsNullOrWhiteSpace($inst) -or $inst -in @('unknown', 'Unable to retrieve version')
        $latestUnknown = -not $SkipUpdate -and [string]::IsNullOrWhiteSpace($_.Value.Latest)
        $lat = if ($latestUnknown) { "unknown" } elseif ($_.Value.Latest) { $_.Value.Latest } else { "-" }
        $currentOrNewer = -not $latestUnknown -and $lat -ne "-" -and (Compare-SemanticVersions $inst $lat) -ge 0
        $age  = if (-not $currentOrNewer -and $null -ne $_.Value.AgeDays) { "$($_.Value.AgeDays)d" } else { "-" }
        $cmd  = Get-UpdateCommand -ToolName $_.Key -Installed $inst -Latest $_.Value.Latest
        # Only show release notes for tools with a pending update/install
        $url  = if ($cmd -or $_.Key -in $actionableNames) { Get-ReleaseNotesUrl -ToolName $_.Key } else { "" }
        $hi   = $_.Value.HighestInstalled
        $covered = -not $latestUnknown -and $hi -and [version]$hi -ge [version]$lat
        $clr  = if ($_.Key -in $results.UpdateFailed) { $ColorRed }
            elseif ($_.Value.CheckTimedOut) { $ColorRed }
            elseif ($installedUnknown -or $latestUnknown) { $ColorYellow }
            elseif ($lat -eq "-" -or $currentOrNewer -or $covered) { $ColorGreen }
            elseif ($_.Key -in $results.MaturityBlockedUpdates.Name) { $ColorOrange }
                else { $ColorYellow }
        $row  = ("  {0,-$maxName}  {1,-$maxInst}  {2,-$maxLat}  {3,$maxAge}  {4,-$maxUpd}  {5,-$maxUrl}" -f $_.Key,$inst,$lat,$age,$cmd,$url).TrimEnd()
        Write-Host "$clr$row$ColorReset"

        # Inline ncu global package sub-rows
        if ($_.Key -eq "ncu" -and $results.GlobalNpmPackageUpdates.Count -gt 0) {
            foreach ($pkg in $results.GlobalNpmPackageUpdates) {
                $pn = "  $($pkg.Name)"
                $pi = if ($pkg.Installed) { $pkg.Installed } elseif ($pkg.Current) { $pkg.Current } else { "-" }
                $pl = if ($pkg.Latest) { $pkg.Latest } else { "-" }
                $packageCurrentOrNewer = $pl -ne "-" -and $pi -ne "?" -and (Compare-SemanticVersions $pi $pl) -ge 0
                $pa = if (-not $packageCurrentOrNewer -and $null -ne $pkg.AgeDays) { "$($pkg.AgeDays)d" } else { "-" }
                    $pc = if ($pi -eq $pl) { $ColorGreen }
                        elseif (-not $pkg.Installable) { $ColorOrange }
                        else { $ColorYellow }
                $row = ("  {0,-$maxName}  {1,-$maxInst}  {2,-$maxLat}  {3,$maxAge}  {4,-$maxUpd}  {5,-$maxUrl}" -f $pn,$pi,$pl,$pa,"","").TrimEnd()
                Write-Host "$pc$row$ColorReset"
            }
        }
    }
    Write-Host ""
}

function Show-StartupInformation {
    param([bool]$IsElevated)

    Write-Host ""
    foreach ($line in Get-ApplicationBannerLines -Version $script:ToolCheckerVersion) {
        Write-Host "$ColorCyan$line$ColorReset"
    }
    Write-Host ""
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
    $registryLabelWidth = ($registryLabels | Measure-Object -Property Length -Maximum).Maximum
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
        Write-Host "`n$ColorYellow⚠ Updates Available ($($AvailableUpdateNames.Count)):$ColorReset"
        $AvailableUpdateNames | ForEach-Object { Write-Host "  - $_" }
    }
    if ($results.MaturityBlockedUpdates.Count -gt 0) {
        Write-Host "`n$ColorOrange⚠ Updates Not Yet Available ($($results.MaturityBlockedUpdates.Count)):$ColorReset"
        $results.MaturityBlockedUpdates | ForEach-Object {
            Write-Host "  - $($_.Name): release is $($_.AgeDays)d old; available at $($_.RequiredAgeDays)d"
        }
    }
    if ($results.Errors.Count -gt 0) {
        Write-Host "`n$ColorRed⚠ Errors ($($results.Errors.Count)):$ColorReset"
        $results.Errors | ForEach-Object { Write-Host "  - $_" }
    }
    Write-Host "`n$ColorCyan═══════════════════════════════════════$ColorReset`n"
}