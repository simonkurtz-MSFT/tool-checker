#Requires -Version 7.0

#region Public entry points
function Test-Tool {
    param([string]$Progress)
    $config = Get-ToolConfiguration -ToolName 'Azure CLI Extensions' -RequiredProperties @('UpdateType')
    Write-Header "Checking Azure CLI Extensions" -Progress $Progress

    if (-not (Test-CommandExists "az")) {
        Write-Error "Azure CLI not installed, skipping extensions check"; return
    }

    try {
        $jsonOutput = az extension list --output json 2>$null
        if (-not $jsonOutput -or $jsonOutput -notmatch '^\s*\[') {
            Write-Host "  No Azure CLI extensions installed or unable to retrieve list"; return
        }
        $extensions = @($jsonOutput | ConvertFrom-Json)
        if ($null -eq $extensions -or $extensions.Count -eq 0) {
            Write-Host "  No Azure CLI extensions installed"; return
        }

        Write-Success "Installed extensions:"
        foreach ($ext in $extensions) {
            Write-Host "  - $($ext.name): $($ext.version)"
            $results.Tools["  az ext: $($ext.name)"] = @{ Installed = $ext.version; Latest = "" }
        }
        if ($SkipUpdate) { return }

        Write-Host "  Checking for Azure CLI extension updates..."
        $updatesAvailable = $false
        foreach ($ext in $extensions) {
            $versions = az extension list-versions --name $ext.name 2>$null | ConvertFrom-Json
            $stable = $versions | ForEach-Object {
                $cv = ($_.version -split '\s+')[0]
                [PSCustomObject]@{ version = $cv }
            } | Where-Object { Test-IsProductionVersion $_.version }
            $latest = if ($config.ProductionReleasesOnly) {
                $stable | Select-Object -Last 1
            } else {
                $versions | Select-Object -Last 1 | ForEach-Object { @{ version = ($_.version -split '\s+')[0] } }
            }
            if (-not $latest) { continue }

            $results.Tools["  az ext: $($ext.name)"].Latest = $latest.version
            $updateName = "Azure Extension: $($ext.name)"
            $updateCommand = "az extension update --name $($ext.name) --only-show-errors"
            if (Register-ToolUpdate -Name $updateName -InstalledVersion $ext.version -LatestVersion $latest.version -Command $updateCommand -Type 'az-extension') {
                Write-Warning "  Extension '$($ext.name)' has update available: $($ext.version) -> $($latest.version)"
                $updatesAvailable = $true
            }
        }
        if (-not $updatesAvailable) { Write-Success "All Azure CLI extensions are up to date" }
    } catch {
        Write-Error "Failed to list Azure CLI extensions: $_"
        $results.Errors += "Azure extensions check failed: $_"
    }
}
#endregion

#region Private helpers

#endregion
