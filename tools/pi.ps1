#Requires -Version 7.0

# Compare Pi's configured npm registry with upstream GitHub tags; build a tag when npm lags.
#region Public entry points
function Test-Tool {
    param([string]$Progress)

    $toolName = 'Pi'
    $config = Get-ToolConfiguration -ToolName $toolName -RequiredProperties @(
        'Command', 'ApiUrl', 'NpmPackageName', 'GitHubTagsApiUrl', 'GitHubCloneUrl'
    )
    Write-Header "Checking $toolName" -Progress $Progress

    if (-not (Test-CommandExists $config.Command)) {
        Write-Error "$toolName not installed"
        Add-NotInstalledTool $toolName
        return
    }

    $raw = Get-CommandVersion -Command $config.Command -VersionFlag $config.VersionFlag
    $installedVersion = Get-InstalledVersionFromOutput -ToolName $toolName -Output $raw
    if (-not $installedVersion) {
        Write-Warning "Could not parse $toolName version"
        $results.Tools[$toolName] = @{ ToolId = $config.Id; Installed = 'unknown'; Latest = '' }
        return
    }

    Write-Success "$toolName installed: $installedVersion"
    $results.Tools[$toolName] = @{
        ToolId = $config.Id
        Installed = $installedVersion
        Latest = ''
        ReleaseNotesUrl = $config.ReleaseNotesUrl
    }
    if ($SkipUpdate) { return }

    Write-Host "  Checking npm registry and GitHub tags for $toolName updates..."
    $release = Get-PiLatestRelease -ToolName $toolName
    if (-not $release) {
        Write-Warning "  Could not determine a latest $toolName release from npm or GitHub"
        return
    }

    $state = Get-ToolState -ToolId $config.Id
    $state.LatestVersionSource = $release.Source
    $results.Tools[$toolName].LatestReleased = $release.Version
    if (-not (Set-LatestToolVersion -ToolNames $toolName -LatestVersion $release.Version -ProductionReleasesOnly $config.ProductionReleasesOnly -VersionLabel "$($release.Source) version")) { return }

    if (Test-UpdateAvailable -InstalledVersion $installedVersion -LatestVersion $release.Version -ToolName $toolName) {
        $results.Updates += $toolName
        $sourceLabel = if ($release.Source -eq 'github') { "GitHub tag $($release.Tag)" } else { 'the configured npm registry' }
        $command = "Install Pi $($release.Version) from $sourceLabel"
        Add-AvailableUpdate -Name $toolName -Command $command -Type 'pi-upstream' `
            -Details "$installedVersion -> $($release.Version) ($sourceLabel)" -Version $release.Version `
            -Executor 'tool' -ExecutionMode 'CurrentSession' `
            -Arguments @{ Version = $release.Version; Source = $release.Source; Tag = $release.Tag }
        Write-Warning "  $toolName has available updates: $installedVersion -> $($release.Version) ($sourceLabel)"
        if ($config.ReleaseNotesUrl) { Write-Host "  Release notes: $($config.ReleaseNotesUrl)" }
    } else {
        Write-Success "$toolName is up to date with $($release.Source) version $($release.Version)"
    }
}

function Refresh-ToolStatus {
    param([string]$ToolName)
    $config = $toolsConfig[$ToolName]
    Refresh-StandardVersion -ToolName $ToolName -Config $config
}

function Invoke-ToolInstall {
    $release = Get-PiLatestRelease -ToolName 'Pi'
    if (-not $release) { return @{ Output = 'Could not determine the latest Pi release from npm or GitHub.'; ExitCode = 1 } }
    Install-PiRelease -Version $release.Version -Source $release.Source -Tag $release.Tag
}

function Invoke-ToolUpdate {
    param([string]$Version, [string]$Source, [string]$Tag)
    Install-PiRelease -Version $Version -Source $Source -Tag $Tag
}
#endregion

#region Private helpers
function Get-PiLatestRelease {
    param([string]$ToolName)
    $config = Get-ToolConfiguration -ToolName $ToolName
    $registryVersion = $null
    $npmData = Invoke-PiApiRequest -Uri $config.ApiUrl
    if ($npmData) {
        $registryVersion = Get-PiLatestNpmVersion -ApiData $npmData
        if (-not $registryVersion) { Write-Warning '  npm registry did not report a production Pi version' }
    }

    $github = Get-PiLatestGitHubTag -Uri $config.GitHubTagsApiUrl
    if ($registryVersion -and $github) {
        if ((Compare-SemanticVersions -Version1 $github.Version -Version2 $registryVersion) -gt 0) {
            Write-Host "  GitHub is ahead of the configured npm registry: $($github.Version) > $registryVersion"
            return @{ Version = $github.Version; Source = 'github'; Tag = $github.Tag }
        }
        return @{ Version = $registryVersion; Source = 'npm'; Tag = $null }
    }
    if ($github) { return @{ Version = $github.Version; Source = 'github'; Tag = $github.Tag } }
    if ($registryVersion) { return @{ Version = $registryVersion; Source = 'npm'; Tag = $null } }
    $null
}

function Get-PiLatestNpmVersion {
    param([object]$ApiData)
    $tagged = "$($ApiData.'dist-tags'.latest)".Trim()
    if (Test-IsProductionVersion $tagged) { return $tagged }

    # Match the shared npm policy when latest is absent or points to a prerelease.
    $versions = @()
    if ($ApiData.versions) {
        $versions = @($ApiData.versions.PSObject.Properties.Name | Where-Object {
            Test-IsProductionVersion $_
        } | Select-Object -Unique)
    }
    if ($versions.Count -eq 0) { return $null }
    $orderedVersions = @(Sort-SemanticVersions -Versions $versions -Descending)
    $orderedVersions | Select-Object -First 1
}

function Get-PiLatestGitHubTag {
    param([string]$Uri)
    $latest = $null
    # Tags are paged by GitHub; walk pages so an old high-numbered tag cannot hide later pages.
    for ($page = 1; $page -le 20; $page++) {
        $separator = if ($Uri.Contains('?')) { '&' } else { '?' }
        $pageUri = "$Uri${separator}per_page=100&page=$page"
        $tags = Invoke-PiApiRequest -Uri $pageUri
        if ($null -eq $tags) { break }
        $pageTags = @($tags)
        foreach ($entry in $pageTags) {
            $tag = "$($entry.name)"
            if ($tag -notmatch '^v?(\d+\.\d+\.\d+(?:\.0)?)$') { continue }
            $version = $Matches[1]
            if (-not $latest -or (Compare-SemanticVersions -Version1 $version -Version2 $latest.Version) -gt 0) {
                $latest = @{ Version = $version; Tag = $tag }
            }
        }
        if ($pageTags.Count -lt 100) { break }
    }
    $latest
}

function Invoke-PiApiRequest {
    param([string]$Uri)
    try {
        Invoke-RestMethod -Uri $Uri -TimeoutSec $script:ApiRequestTimeout -UserAgent 'ToolChecker' -ErrorAction Stop
    } catch {
        Write-Warning "  Release lookup failed for $Uri`: $(Get-DetailedErrorMessage $_)"
        $null
    }
}

function Install-PiRelease {
    param([string]$Version, [string]$Source, [string]$Tag)
    if (-not (Test-IsProductionVersion $Version)) {
        return @{ Output = "Refusing to install invalid Pi version '$Version'."; ExitCode = 1 }
    }

    if ($Source -eq 'npm') {
        $config = Get-ToolConfiguration -ToolName 'Pi'
        return Invoke-PiProcess -FilePath 'npm' -Arguments @('install', '--global', "$($config.NpmPackageName)@$Version", '--loglevel=error') `
            -NpmRegistryUrl (Get-PiConfiguredNpmRegistry)
    }
    if ($Source -ne 'github') {
        return @{ Output = "Refusing unknown Pi release source '$Source'."; ExitCode = 1 }
    }

    $config = Get-ToolConfiguration -ToolName 'Pi'
    $tagName = if ($Tag) { $Tag } else { "v$Version" }
    if ($tagName -notmatch '^v?\d+\.\d+\.\d+(?:\.0)?$') {
        return @{ Output = "Refusing invalid Pi GitHub tag '$tagName'."; ExitCode = 1 }
    }
    $installDirectory = Get-PiVersionDirectory -Version $Version
    $packageDirectory = Join-Path $installDirectory 'packages/coding-agent'
    $cliPath = Join-Path $packageDirectory 'dist/bundle/cli.js'

    if (Test-Path -LiteralPath $installDirectory) {
        $builtVersion = Get-PiBuiltVersion -CliPath $cliPath
        if ($builtVersion -ne $Version) {
            return @{ Output = "Pi install directory already exists but is not a valid $Version build: $installDirectory"; ExitCode = 1 }
        }
        $output = [System.Collections.Generic.List[string]]::new()
        $output.Add("Using existing Pi source build at $installDirectory")
    } else {
        $parent = Split-Path -Parent $installDirectory
        $null = New-Item -ItemType Directory -Path $parent -Force
        $clone = Invoke-PiProcess -FilePath 'git' -Arguments @('clone', '--depth', '1', '--branch', $tagName, '--', $config.GitHubCloneUrl, $installDirectory)
        if ($clone.Output) { $output = [System.Collections.Generic.List[string]]::new(); $output.Add($clone.Output.Trim()) }
        else { $output = [System.Collections.Generic.List[string]]::new() }
        if ($clone.ExitCode -ne 0) {
            Remove-Item -LiteralPath $installDirectory -Recurse -Force -ErrorAction SilentlyContinue
            return @{ Output = ($output -join "`n"); ExitCode = $clone.ExitCode }
        }

        $dependencies = Invoke-PiProcess -FilePath 'npm' -Arguments @('install', '--ignore-scripts', '--package-lock=false') `
            -WorkingDirectory $installDirectory -NpmRegistryUrl (Get-PiConfiguredNpmRegistry)
        if ($dependencies.Output) { $output.Add($dependencies.Output.Trim()) }
        if ($dependencies.ExitCode -ne 0) {
            Remove-Item -LiteralPath $installDirectory -Recurse -Force -ErrorAction SilentlyContinue
            return @{ Output = ($output -join "`n"); ExitCode = $dependencies.ExitCode }
        }

        # Git tags omit generated model JSON. The upstream build hydrates that data
        # before compiling; this is required for tags whose offline build inputs are absent.
        $build = Invoke-PiProcess -FilePath 'npm' -Arguments @('run', 'build') `
            -WorkingDirectory $installDirectory -NpmRegistryUrl (Get-PiConfiguredNpmRegistry)
        if ($build.Output) { $output.Add($build.Output.Trim()) }
        if ($build.ExitCode -ne 0 -or (Get-PiBuiltVersion -CliPath $cliPath) -ne $Version) {
            Remove-Item -LiteralPath $installDirectory -Recurse -Force -ErrorAction SilentlyContinue
            if ($build.ExitCode -eq 0) { $output.Add("Built Pi CLI did not report expected version $Version.") }
            return @{ Output = ($output -join "`n"); ExitCode = 1 }
        }
    }

    $codingAgentDirectory = Join-Path $installDirectory 'packages/coding-agent'
    $registryUrl = Get-PiConfiguredNpmRegistry
    $link = Invoke-PiProcess -FilePath 'npm' -Arguments @('link', '--global', '--workspaces=false') `
        -WorkingDirectory $codingAgentDirectory -NpmRegistryUrl $registryUrl
    if ($link.ExitCode -ne 0) {
        $output.Add('npm global link with workspace isolation failed; retrying npm link --local.')
        if ($link.Output) { $output.Add($link.Output.Trim()) }
        $link = Invoke-PiProcess -FilePath 'npm' -Arguments @('link', '--local') `
            -WorkingDirectory $codingAgentDirectory -NpmRegistryUrl $registryUrl
    }
    if ($link.Output) { $output.Add($link.Output.Trim()) }
    if ($link.ExitCode -ne 0) { return @{ Output = ($output -join "`n"); ExitCode = $link.ExitCode } }

    $verified = Invoke-PiProcess -FilePath $config.Command -Arguments @('--version')
    if ($verified.Output) { $output.Add($verified.Output.Trim()) }
    if ($verified.ExitCode -ne 0 -or ($verified.Output | Select-Object -First 1).ToString().Trim() -ne $Version) {
        $output.Add("Pi command did not verify at version $Version after linking.")
        return @{ Output = ($output -join "`n"); ExitCode = 1 }
    }
    $output.Add("Pi $Version installed from GitHub tag $tagName.")
    @{ Output = ($output -join "`n"); ExitCode = 0 }
}

function Get-PiVersionDirectory {
    param([string]$Version)
    if (Test-IsWindowsPlatform) {
        $programs = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs' } else { Join-Path $HOME 'AppData/Local/Programs' }
    } else {
        $programs = Join-Path $HOME '.local/share'
    }
    Join-Path $programs "pi-v$Version"
}

function Get-PiBuiltVersion {
    param([string]$CliPath)
    if (-not (Test-Path -LiteralPath $CliPath -PathType Leaf)) { return $null }
    $version = Invoke-PiProcess -FilePath 'node' -Arguments @($CliPath, '--version') -WorkingDirectory (Split-Path -Parent $CliPath)
    if ($version.ExitCode -ne 0) { return $null }
    ($version.Output | Select-Object -First 1).ToString().Trim()
}

function Get-PiConfiguredNpmRegistry {
    if ($script:NpmRegistryResolution.Source -eq 'npm machine/user configuration') {
        return $script:NpmRegistryResolution.Url
    }
    $null
}

function Invoke-PiProcess {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [string]$NpmRegistryUrl)
    $pushed = $false
    $previousRegistryValues = @{}
    try {
        if ($FilePath -ieq 'npm' -and $NpmRegistryUrl) {
            # Project .npmrc files must not silently send Pi's dependency installs
            # somewhere other than the registry already resolved by Tool Checker.
            $name = if (Test-IsWindowsPlatform) { 'NPM_CONFIG_REGISTRY' } else { 'npm_config_registry' }
            $previousRegistryValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $NpmRegistryUrl, 'Process')
        }
        if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory; $pushed = $true }
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
        return @{ Output = ($output | ForEach-Object { $_.ToString() }) -join "`n"; ExitCode = $exitCode }
    } catch {
        return @{ Output = (Get-DetailedErrorMessage $_); ExitCode = 1 }
    } finally {
        if ($pushed) { Pop-Location }
        foreach ($name in $previousRegistryValues.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousRegistryValues[$name], 'Process')
        }
    }
}
#endregion
