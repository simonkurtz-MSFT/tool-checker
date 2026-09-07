#Requires -Version 7.0

# Node.js current-major servicing and LTS/current-major announcements. When WinGet
# lags upstream, an approved action can use the verified official Windows MSI.
#region Private helpers
function Get-NodeReleasePlan {
    param(
        [Parameter(Mandatory)][array]$DistributionIndex,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [bool]$ProductionReleasesOnly = $true
    )

    $allowedReleases = if ($ProductionReleasesOnly) {
        @($DistributionIndex | Where-Object { Test-IsProductionVersion $_.version })
    } else {
        @($DistributionIndex)
    }
    if ($allowedReleases.Count -eq 0) { return $null }

    $currentParts = $CurrentVersion -split '\.'
    $currentMajor = [int]$currentParts[0]
    $currentMinor = if ($currentParts.Count -gt 1) { [int]$currentParts[1] } else { 0 }
    $currentPatch = if ($currentParts.Count -gt 2) { [int]$currentParts[2] } else { 0 }
    # The distribution index is newest-first; retain separate current, LTS, and
    # installed-major targets rather than treating every newer major as a patch.
    $latestLTS = $allowedReleases | Where-Object { $_.lts } | Select-Object -First 1
    $latestCurrent = $allowedReleases | Select-Object -First 1
    $latestInCurrentMajor = $allowedReleases | Where-Object {
        [int](($_.version -replace '^v', '') -split '\.')[0] -eq $currentMajor
    } | Select-Object -First 1

    $latestCurrentVersion = $latestCurrent.version -replace '^v', ''
    $latestLTSVersion = if ($latestLTS) { $latestLTS.version -replace '^v', '' } else { $null }
    $latestInMajor = if ($latestInCurrentMajor) { $latestInCurrentMajor.version -replace '^v', '' } else { $null }
    $updateKind = $null
    if ($latestInMajor -and $latestInMajor -ne $CurrentVersion) {
        $latestParts = $latestInMajor -split '\.'
        $latestMinor = if ($latestParts.Count -gt 1) { [int]$latestParts[1] } else { 0 }
        $latestPatch = if ($latestParts.Count -gt 2) { [int]$latestParts[2] } else { 0 }
        if ($latestMinor -gt $currentMinor) { $updateKind = 'minor' }
        elseif ($latestPatch -gt $currentPatch) { $updateKind = 'patch' }
    }

    [PSCustomObject]@{
        CurrentMajor = $currentMajor
        LatestInMajor = $latestInMajor
        LatestCurrentVersion = $latestCurrentVersion
        LatestCurrentMajor = [int]($latestCurrentVersion -split '\.')[0]
        LatestLTS = $latestLTS
        LatestLTSVersion = $latestLTSVersion
        LatestLTSMajor = if ($latestLTSVersion) { [int]($latestLTSVersion -split '\.')[0] } else { $null }
        UpdateKind = $updateKind
    }
}

#endregion

#region Public entry points
function Test-Tool {
    param([string]$Progress)
    $config = Get-ToolConfiguration -ToolName 'NodeJS' -RequiredProperties @('Command', 'ApiUrl', 'UpdateCommand', 'UpdateType')
    Write-Header "Checking NodeJS" -Progress $Progress

    if (-not (Test-CommandExists $config.Command)) {
        Write-Error "NodeJS not installed"; Add-NotInstalledTool "NodeJS"; return
    }

    $versionOutput  = Get-CommandVersion $config.Command "--version"
    $currentVersion = $versionOutput -replace 'v', ''
    Write-Success "NodeJS installed: v$currentVersion"
    $results.Tools["NodeJS"] = @{ Installed = "v$currentVersion"; Latest = "" }

    if ($SkipUpdate) { return }

    Write-Host "  Checking for NodeJS updates..."
    $wingetLatestVersion = $null
    if (($IsWindows -or $env:OS -eq 'Windows_NT') -and $config.WingetId) {
        $wingetLatestVersion = Get-WingetLatestVersion -ToolName 'NodeJS' -PackageId $config.WingetId
        if ($wingetLatestVersion -and $config.ProductionReleasesOnly -and -not (Test-IsProductionVersion $wingetLatestVersion)) {
            Write-Warning "  Latest WinGet version '$wingetLatestVersion' is not a full production semantic version"
            $wingetLatestVersion = $null
        }
    }

    try {
        Write-Host "  Querying nodejs.org distribution API..."
        $distIndex = Invoke-RestMethod -Uri $config.ApiUrl -TimeoutSec $script:ApiRequestTimeout
        if (-not $distIndex) { return }

        $releasePlan = Get-NodeReleasePlan -DistributionIndex $distIndex -CurrentVersion $currentVersion -ProductionReleasesOnly $config.ProductionReleasesOnly
        if (-not $releasePlan) { return }
        $currentMajor = $releasePlan.CurrentMajor
        $latestInMajor = $releasePlan.LatestInMajor
        $latestLTS = $releasePlan.LatestLTS
        $latestLTSVersion = $releasePlan.LatestLTSVersion
        $latestLTSMajor = $releasePlan.LatestLTSMajor
        $latestCurrentVersion = $releasePlan.LatestCurrentVersion
        $latestCurrentMajor = $releasePlan.LatestCurrentMajor

        if ($latestInMajor) {
            $results.Tools['NodeJS'].Latest = "v$latestCurrentVersion"
            if ($releasePlan.UpdateKind) {
                Write-Warning "  $($releasePlan.UpdateKind.Substring(0, 1).ToUpper())$($releasePlan.UpdateKind.Substring(1)) update available in v${currentMajor}: v$currentVersion -> v$latestInMajor"
                $results.Updates += "NodeJS ($($releasePlan.UpdateKind))"
            } else {
                Write-Success "NodeJS v$currentMajor is up to date (latest patch)"
            }
        }

        if ($latestLTSMajor -gt $currentMajor) {
            Write-Warning "  Newer LTS major version available: v$currentMajor -> v$latestLTSMajor (LTS: $($latestLTS.lts))"
            $results.Updates += "NodeJS (major LTS)"
        }
        if ($latestCurrentMajor -gt $currentMajor) {
            Write-Warning "  Newer current major version available: v$currentMajor -> v$latestCurrentMajor"
            $results.Updates += "NodeJS (major current)"
        }

        Write-Host "`n  Summary:"
        Write-Host "  Current        : v$currentVersion (v$currentMajor series)"
        Write-Host "  Latest in v${currentMajor}  : v$latestInMajor"
        Write-Host "  Latest LTS     : v$latestLTSVersion (v$latestLTSMajor - $($latestLTS.lts))"
        Write-Host "  Latest Current : v$latestCurrentVersion (v$latestCurrentMajor)"

        if ($results.Updates -contains "NodeJS (patch)" -or $results.Updates -contains "NodeJS (minor)") {
            $wingetCanInstall = -not ($IsWindows -or $env:OS -eq 'Windows_NT') -or (
                $wingetLatestVersion -and (Compare-SemanticVersions $wingetLatestVersion $latestInMajor) -ge 0
            )
            if ($wingetCanInstall) {
                Write-Host "`n  Update options:"
                Write-Host "  - Using winget: $($config.UpdateCommand)"
                Write-Host "  - Download: https://nodejs.org/"
                Write-Host "  Release notes: $($config.ReleaseNotesUrl)"
                Add-AvailableUpdate -Name 'NodeJS' -Command $config.UpdateCommand -Type $config.UpdateType -Details "v$currentVersion -> v$latestInMajor"
            } else {
                $catalogVersion = if ($wingetLatestVersion) { "v$wingetLatestVersion" } else { 'unknown' }
                Write-Warning "  NodeJS v$latestInMajor is available upstream but not yet in WinGet (catalog: $catalogVersion); using the official installer."
                Add-AvailableUpdate -Name 'NodeJS' -Command "Official Node.js MSI v$latestInMajor (silent; UAC elevation)" -Type 'node-direct' -Version $latestInMajor -Details "v$currentVersion -> v$latestInMajor" -Executor 'tool' -ExecutionMode 'CurrentSession' -Arguments @{ Version = $latestInMajor }
            }
        }
    } catch {
        Write-Warning "  Could not check NodeJS updates: $_"
        $results.Errors += "NodeJS update check failed: $_"
    }
}

function Invoke-ToolUpdate {
    # Runs only through an approved CurrentSession action because MSI may need UAC.
    # Verify the published checksum before execution; retain logs on installer failure.
    param([string]$Version)

    $isAdministrator = Test-IsAdministrator

    $architecture = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'arm64' } else { 'x64' }
    $installerName = "node-v$Version-$architecture.msi"
    $installerPath = Join-Path ([System.IO.Path]::GetTempPath()) $installerName
    $installerLogPath = Join-Path ([System.IO.Path]::GetTempPath()) "node-v$Version-$architecture-install.log"
    $releaseUri    = "https://nodejs.org/dist/v$Version"
    $installerUri  = "$releaseUri/$installerName"

    try {
        Remove-Item -LiteralPath $installerPath, $installerLogPath -Force -ErrorAction SilentlyContinue
        $checksums = (Invoke-WebRequest -Uri "$releaseUri/SHASUMS256.txt" -TimeoutSec $script:ApiRequestTimeout -ErrorAction Stop).Content
        $checksumMatch = [regex]::Match($checksums, "(?m)^([a-fA-F0-9]{64})\s+$([regex]::Escape($installerName))$")
        if (-not $checksumMatch.Success) {
            throw "No published SHA-256 checksum was found for $installerName."
        }

        Invoke-WebRequest -Uri $installerUri -OutFile $installerPath -TimeoutSec $script:ApiRequestTimeout -ErrorAction Stop
        $expectedHash = $checksumMatch.Groups[1].Value
        $actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($actualHash -ne $expectedHash) {
            throw "SHA-256 verification failed for $installerName."
        }

        $processArgs = @{
            FilePath = 'msiexec.exe'
            ArgumentList = @('/i', "`"$installerPath`"", '/qn', '/norestart', '/L*V', "`"$installerLogPath`"")
            Wait = $true
            PassThru = $true
        }
        if (-not $isAdministrator) {
            $processArgs.Verb = 'RunAs'
        }
        $process = Start-Process @processArgs
        if ($process.ExitCode -in @(1641, 3010)) {
            Remove-Item -LiteralPath $installerLogPath -Force -ErrorAction SilentlyContinue
            return @{ Output = "Installed Node.js v$Version from $installerUri (restart required)"; ExitCode = 0 }
        }
        if ($process.ExitCode -eq 0) {
            Remove-Item -LiteralPath $installerLogPath -Force -ErrorAction SilentlyContinue
            return @{ Output = "Installed Node.js v$Version from $installerUri"; ExitCode = 0 }
        }
        return @{
            Output = "Node.js MSI failed with exit code $($process.ExitCode). Installer log: $installerLogPath"
            ExitCode = $process.ExitCode
        }
    } catch {
        if ($_.Exception.NativeErrorCode -eq 1223) {
            return @{ Output = 'Node.js update canceled at the administrator consent prompt.'; ExitCode = 1223 }
        }
        return @{ Output = "Node.js installer failed. $(Get-DetailedErrorMessage $_)"; ExitCode = 1 }
    } finally {
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
    }
}
#endregion
