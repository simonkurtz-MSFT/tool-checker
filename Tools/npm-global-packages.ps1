#Requires -Version 7.0

#region Public entry points
function Refresh-ToolStatus {
    param([string]$ToolName)

    if ($results.GlobalNpmPackageUpdates.Count -eq 0) { return }
    foreach ($pkg in $results.GlobalNpmPackageUpdates) {
        $v = Get-GlobalNpmInstalledVersion -PackageName $pkg.Name
        if ($v) { $pkg.Current = $v; $pkg.Installed = $v; $pkg.Latest = $v }
    }
    $results.Updates = @($results.Updates | Where-Object { $_ -ne "ncu global packages" })
}

function Test-Tool {
    param([string]$Progress)
    $config = Get-ToolConfiguration -ToolName 'Global npm packages'
    Write-Header "Checking ncu -g (global npm packages updates)" -Progress $Progress

    if (-not (Test-CommandExists "ncu")) {
        Write-Error "ncu not installed (required for global package check)"
        Add-NotInstalledTool "ncu"; return
    }

    try {
        Write-Host "  Running ncu -g to check all global package updates..."
        $output       = ncu -g 2>&1
        $outputString = $output -join "`n"
        $results.GlobalNpmPackageUpdates = @()

        if ($LASTEXITCODE -ne 0 -and $outputString -match 'EALLOWREMOTE') {
            $message = 'ncu could not inspect a global package installed from a remote source. Reinstall that package by registry name, then retry.'
            Write-Warning $message
            $results.Errors += $message
            return
        }

        $parsedOutput = ConvertFrom-NcuGlobalOutput -OutputLines @($output)
        $results.GlobalNpmPackageUpdates = @($parsedOutput.Packages)
        if ($parsedOutput.InstallCommand) {
            $results.GlobalNpmUpdateCommand = $parsedOutput.InstallCommand
            $extracted = Parse-NpmInstallCommand $results.GlobalNpmUpdateCommand
            if ($extracted.Count -gt 0 -and $results.GlobalNpmPackageUpdates.Count -eq 0) {
                foreach ($pkg in $extracted) {
                    $iv = Get-GlobalNpmInstalledVersion -PackageName $pkg.Name
                    $results.GlobalNpmPackageUpdates += @{
                        Name = $pkg.Name; Current = $(if ($iv) { $iv } else { "?" }); Latest = $pkg.Version
                    }
                }
            }
        }

        # Dedicated npm-hosted tool checks own these packages; exclude duplicate ncu rows and actions.
        $managedNpmPackageNames = @($toolsConfig.Values | Where-Object {
            $_.VersionExtractor -eq 'npmDistTagLatest' -and $_.NpmPackageName
        } | ForEach-Object { $_.NpmPackageName })
        $results.GlobalNpmPackageUpdates = @($results.GlobalNpmPackageUpdates | Where-Object {
            $_.Name -notin $managedNpmPackageNames
        })

        foreach ($pkg in $results.GlobalNpmPackageUpdates) {
            $productionReleasesOnly = $config.ProductionReleasesOnly
            $metadata = Invoke-SafeApiRequest -Uri "$((npm config get registry).TrimEnd('/'))/$([Uri]::EscapeDataString($pkg.Name))"
            if ($productionReleasesOnly -and -not (Test-IsProductionVersion $pkg.Latest)) {
                $pkg.Latest = Get-LatestProductionNpmVersion -ApiData $metadata
            }
            if (-not $pkg.Latest) { continue }
            $minimumVersion = if ($pkg.Current -and $pkg.Current -ne '?') { $pkg.Current } else { $null }
            $release = Get-LatestMatureNpmRelease -ApiData $metadata -MinimumVersion $minimumVersion -MaximumVersion $pkg.Latest -ProductionReleasesOnly $productionReleasesOnly
            if ($release) {
                $pkg.Latest = $release.Version
            } else {
                $release = Get-NpmVersionReleaseInfo -PackageName $pkg.Name -Version $pkg.Latest
            }
            $pkg.PublishedAt = $release.PublishedAt
            $pkg.AgeDays = $release.AgeDays
            $pkg.Installable = $release -and $release.Installable
            if ($release -and -not $release.Installable) {
                $results.MaturityBlockedUpdates += @{
                    Name = $pkg.Name
                    AgeDays = $release.AgeDays
                    RequiredAgeDays = $script:NpmUpdateCooldownDays
                }
            }
        }

        $installablePackages = @($results.GlobalNpmPackageUpdates | Where-Object {
            $_.Latest -and $_.Latest -ne "-" -and $_.Current -ne $_.Latest -and $_.Installable
        })
        $actionable = $installablePackages.Count -gt 0

        if ($outputString -match "All global packages are up-to-date") {
            Write-Success "All global npm packages are up to date"
        } elseif ($results.GlobalNpmPackageUpdates.Count -gt 0) {
            Write-Warning "Global package updates available:"
            foreach ($pkg in $results.GlobalNpmPackageUpdates) {
                $status = if ($pkg.Installable) { "installable" } else { "FYI; $($script:NpmUpdateCooldownDays)-day cooldown" }
                $age = if ($null -ne $pkg.AgeDays) { "$($pkg.AgeDays) days old" } else { "age unknown" }
                Write-Host "    $($pkg.Name)  Installed: $($pkg.Current)  Latest: $($pkg.Latest)  ($age; $status)"
            }

            if ($actionable) {
                $results.Updates += "ncu global packages"
                $specs = $installablePackages | ForEach-Object { "$($_.Name)@$($_.Latest)" }
                $results.GlobalNpmUpdateCommand = "npm install -g $($specs -join ' ') --loglevel=error"
                if (!$SkipUpdate) {
                    foreach ($pkg in $installablePackages) {
                        Add-AvailableUpdate -Name "npm: $($pkg.Name)" -Command "npm install -g $($pkg.Name)@$($pkg.Latest) --loglevel=error" -Type 'npm-global-package' -Details "$($pkg.Current) -> $($pkg.Latest)"
                    }
                }
            }
        }
    } catch {
        Write-Warning "Unable to run ncu -g: $_"
    }
}
#endregion

#region Private helpers
function Parse-NpmInstallCommand {
    param([string]$Command)
    $packages = @()
    if ($Command -match 'install\s+(.+?)(?:\s+--loglevel|$)') {
        foreach ($part in ($Matches[1].Trim() -split '\s+')) {
            if ($part -match '^(@?[^@]+)@(.+)$' -and $Matches[1] -ne 'npm-check-updates') {
                $packages += @{ Name = $Matches[1]; Version = $Matches[2] }
            }
        }
    }
    $packages
}

function ConvertFrom-NcuGlobalOutput {
    param([Parameter(Mandatory)][array]$OutputLines)

    $packages = @()
    $installCommand = $null
    foreach ($line in $OutputLines) {
        $text = $line.ToString().Trim()
        if ($text -match '^(@?[a-zA-Z0-9._/-]+)\s+([0-9a-zA-Z._-]+)\s+→\s+([0-9a-zA-Z._-]+)\s*$') {
            $packages += @{ Name = $Matches[1]; Current = $Matches[2]; Latest = $Matches[3] }
        } elseif (-not $installCommand -and $text -match '^npm\s+-g\s+install\s+') {
            $installCommand = if ($text -match '--loglevel=') { $text } else { "$text --loglevel=error" }
        }
    }

    [PSCustomObject]@{
        Packages = $packages
        InstallCommand = $installCommand
    }
}

#endregion
