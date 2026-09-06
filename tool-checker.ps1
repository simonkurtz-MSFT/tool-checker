#Requires -Version 7.0
<#
.SYNOPSIS
    Checks installation status and available updates for development tools.

.DESCRIPTION
    Tool configuration is loaded from tool-checker.json (sibling file).
    Standard tools are handled generically; complex tools use named custom functions.
    See tool-checker.json for the full tool inventory and per-tool settings.

.PARAMETER SkipUpdate
    Only check status; do not offer or execute updates.

.PARAMETER Force
    Execute all available updates without prompting.

.PARAMETER Timeout
    Maximum seconds to wait for each tool check before killing it. Default: 60.

.PARAMETER CooldownDays
    Override settings.CooldownDays from the catalog for npm release maturity.
    Use a nonnegative number of full days; zero removes the release-age delay.

.PARAMETER Version
    Print the tool checker version and exit.

.PARAMETER EnvFile
    Path to the optional registry policy file. Default: .env beside this script.

.EXAMPLE
    .\tool-checker.ps1
    .\tool-checker.ps1 -SkipUpdate
    .\tool-checker.ps1 -Force
    .\tool-checker.ps1 -Timeout 60
    .\tool-checker.ps1 -EnvFile C:\secure\tool-checker.env
    .\tool-checker.ps1 -Version
#>

param(
    [Alias('CheckOnly')]
    [switch]$SkipUpdate,
    [switch]$Force,
    [int]$Timeout = 60,
    [ValidateRange(0, 2147483647)]
    [int]$CooldownDays,
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
    [switch]$Version
)

$script:ToolCheckerVersion = '1.3.0'
$script:ApiRequestTimeout = $Timeout
$script:IsDotSourced = $MyInvocation.InvocationName -eq '.'

if ($Version) {
    Write-Output $script:ToolCheckerVersion
    return
}

# ─────────────────────────────────────────────
# 1. SETUP — colors, platform, results, config
# ─────────────────────────────────────────────

$ColorReset  = "`e[0m"
$ColorGreen  = "`e[32m"
$ColorYellow = "`e[33m"
$ColorRed    = "`e[31m"
$ColorCyan   = "`e[36m"
$ColorBlue   = "`e[34m"
$ColorOrange = "`e[38;5;208m"

# Detect platform for install-command lookup
$script:PlatformKey = & {
    $os   = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Windows' } else { 'Linux' }
    $cpu  = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $arch = if ($cpu -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'arm64' } else { 'amd64' }
    "$os ($arch)"
}

function New-ToolCheckResults {
    @{
        Tools                   = @{}
        DotNetSDKs              = @{}
        NotInstalled            = @()
        Updates                 = @()
        Errors                  = @()
        UpdateFailed            = @()
        AvailableUpdates        = @()
        MaturityBlockedUpdates  = @()
        GlobalNpmPackageUpdates = @()
        GlobalNpmUpdateCommand  = 'ncu -g -u --loglevel=error'
        RegistryChecks          = @()
    }
}

# Accumulates everything the script discovers
$results = New-ToolCheckResults

# --- Load tool-checker.json ------------------------------------------------

$configurationPath = Join-Path $PSScriptRoot 'Infra/configuration.ps1'
if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
    throw "Configuration infrastructure file not found: $configurationPath"
}
. $configurationPath

$configPath = Join-Path $PSScriptRoot "tool-checker.json"
if (-not (Test-Path $configPath)) {
    Write-Host "`e[31m✗ tool-checker.json not found at: $configPath`e[0m"
    exit 1
}

$configuration = Read-ToolCheckerConfiguration -ConfigPath $configPath -EnvFile $EnvFile `
    -HasCooldownOverride $PSBoundParameters.ContainsKey('CooldownDays') -CooldownDays $CooldownDays
$toolsConfig = $configuration.ToolsConfiguration
$catalogToolIds = $configuration.CatalogToolIds
$resolvedEnvFile = $configuration.ResolvedEnvFile
$script:RegistryEnvironment = $configuration.RegistryEnvironment
$script:NpmUpdateCooldownDays = $configuration.CooldownDays
$script:NpmRegistryResolution = @{
    Source = 'tool-checker.json'
    Url = $null
    Details = $null
}

function Get-ToolDefinitionFiles {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ToolsConfiguration,
        [Parameter(Mandatory)][string]$Directory
    )

    foreach ($config in $ToolsConfiguration.Values | Where-Object { $_.Enabled } | Sort-Object Id) {
        if (-not $config.Contains('ToolFile')) { continue }
        if ($config.ToolFile -isnot [string] -or $config.ToolFile -notmatch '^[a-z0-9][a-z0-9._-]*\.ps1$') {
            throw "Tool '$($config.Id)' requires ToolFile to be a .ps1 filename directly under Tools/."
        }
        $toolPath = Join-Path $Directory $config.ToolFile
        if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
            throw "Tool file '$($config.ToolFile)' configured for '$($config.Id)' was not found in Tools/."
        }
        $toolFile = Get-Item -LiteralPath $toolPath
        [PSCustomObject]@{ Id = $config.Id; Name = $toolFile.Name; FullName = $toolFile.FullName }
    }
}

$script:ToolDefinitionFiles = @(Get-ToolDefinitionFiles -ToolsConfiguration $toolsConfig -Directory (Join-Path $PSScriptRoot 'Tools'))
$script:ToolDefinitions = @{}
foreach ($toolDefinitionFile in $script:ToolDefinitionFiles) {
    $toolAst = [System.Management.Automation.Language.Parser]::ParseFile($toolDefinitionFile.FullName, [ref]$null, [ref]$null)
    $definitions = @{}
    foreach ($definition in $toolAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] }) {
        $definitions[$definition.Name] = $definition.Extent.Text
    }
    $script:ToolDefinitions[$toolDefinitionFile.Id] = $definitions
}

function Invoke-ToolEntryPoint {
    param(
        [Parameter(Mandatory)][string]$ToolId,
        [Parameter(Mandatory)][ValidateSet('Test-Tool', 'Refresh-ToolStatus', 'Invoke-ToolInstall', 'Invoke-ToolUpdate')][string]$EntryPoint,
        [hashtable]$Arguments = @{}
    )

    $definitions = $script:ToolDefinitions[$ToolId]
    if (-not $definitions -or -not $definitions.ContainsKey($EntryPoint)) {
        throw "Tool '$ToolId' does not define entry point '$EntryPoint'."
    }
    . ([scriptblock]::Create(($definitions.Values -join "`n`n")))
    & $EntryPoint @Arguments
}

# ─────────────────────────────────────────────
# 2. OUTPUT HELPERS
# ─────────────────────────────────────────────

$outputPath = Join-Path $PSScriptRoot 'Infra/output.ps1'
if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
    throw "Output infrastructure file not found: $outputPath"
}
. $outputPath

function Test-CommandExists {
    param([string]$Command)
    $null = Get-Command $Command -ErrorAction SilentlyContinue
    return $?
}

function Test-IsAdministrator {
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    try { return [int](& id -u) -eq 0 } catch { return $false }
}

function Get-DetailedErrorMessage {
    param([object]$ErrorRecord)

    if (-not $ErrorRecord) { return 'Unknown error' }
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("$ErrorRecord")
    if ($ErrorRecord.Exception) {
        $parts.Add("Exception: $($ErrorRecord.Exception.GetType().FullName)")
    }
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $parts.Add("Details: $($ErrorRecord.ErrorDetails.Message)")
    }
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        $parts.Add($ErrorRecord.InvocationInfo.PositionMessage.Trim())
    }
    $parts -join ' | '
}

$registryPath = Join-Path $PSScriptRoot 'Infra/registry.ps1'
if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    throw "Registry infrastructure file not found: $registryPath"
}
. $registryPath

if (-not $script:IsDotSourced) {
    Set-NpmRegistryApiUrls
}

function Get-CommandVersion {
    param([string]$Command, [string]$VersionFlag = "--version")
    if ([string]::IsNullOrWhiteSpace($VersionFlag)) { $VersionFlag = "--version" }
    try   { $output = & $Command $VersionFlag 2>&1; ($output -split "`n" | Select-Object -First 1).Trim() }
    catch { "Unable to retrieve version" }
}

# ─────────────────────────────────────────────
# 3. VERSION & UPDATE UTILITIES
# ─────────────────────────────────────────────

function ConvertTo-CanonicalSemanticVersion {
    param([string]$Version)
    if ($Version -match '^(\d+(?:\.\d+)+)-(\d+)$') {
        $Version = "$($Matches[1]).$($Matches[2])"
    }
    if ($Version -notmatch '^\d+(?:\.\d+)+$') { return $Version }

    $parts = [System.Collections.Generic.List[string]]@($Version -split '\.')
    while ($parts.Count -gt 3 -and $parts[$parts.Count - 1] -eq '0') {
        $parts.RemoveAt($parts.Count - 1)
    }
    $parts -join '.'
}

function Compare-SemanticVersions {
    param([string]$Version1, [string]$Version2)
    $Version1 = ConvertTo-CanonicalSemanticVersion $Version1
    $Version2 = ConvertTo-CanonicalSemanticVersion $Version2
    try {
        $v1 = [version]$Version1; $v2 = [version]$Version2
        if ($v1 -lt $v2) { -1 } elseif ($v1 -gt $v2) { 1 } else { 0 }
    } catch {
        if ($Version1 -lt $Version2) { -1 } elseif ($Version1 -gt $Version2) { 1 } else { 0 }
    }
}

function Test-UpdateAvailable {
    param([string]$InstalledVersion, [string]$LatestVersion)
    if ([string]::IsNullOrWhiteSpace($LatestVersion) -or $LatestVersion -eq $InstalledVersion) { return $false }
    (Compare-SemanticVersions $InstalledVersion $LatestVersion) -eq -1
}

function Test-IsProductionVersion {
    param([string]$Version)
    -not [string]::IsNullOrWhiteSpace($Version) -and $Version.Trim() -match '^v?\d+\.\d+\.\d+(?:\.0)?$'
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
            Installable = $age.TotalDays -ge $script:NpmUpdateCooldownDays
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
            if ($age.TotalDays -ge $script:NpmUpdateCooldownDays) {
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
    $results.NotInstalled += [PSCustomObject]@{ Name = $ToolName; InstallCommands = $cmds }
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
        [string]$Version
    )

    $entry = [ordered]@{
        Name = $Name
        Command = $Command
        Type = $Type
        Details = $Details
    }
    if ($PSBoundParameters.ContainsKey('RegistryKey')) { $entry.RegistryKey = $RegistryKey }
    if ($PSBoundParameters.ContainsKey('Version')) { $entry.Version = $Version }
    $results.AvailableUpdates += $entry
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

    if (-not (Test-UpdateAvailable -InstalledVersion $InstalledVersion -LatestVersion $LatestVersion)) {
        return $false
    }

    $results.Updates += $Name
    Add-AvailableUpdate -Name $Name -Command $Command -Type $Type -Details "$InstalledVersion -> $LatestVersion"
    $true
}

function Get-WingetInstalledVersion {
    param([string]$ToolName, [string]$PackageId)

    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT') -or
        [string]::IsNullOrWhiteSpace($PackageId) -or -not (Test-CommandExists 'winget')) {
        return $null
    }

    try {
        $metadata = @(& winget.exe list --id $PackageId -e --source winget --accept-source-agreements --disable-interactivity 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "winget list exited with code $LASTEXITCODE." }
        $packagePattern = '(?m)^[^\r\n]*[ \t]+' + [regex]::Escape($PackageId) + '[ \t]+(\d+(?:\.\d+)+)(?=[ \t]|\r?$)'
        $versionMatch = [regex]::Match(($metadata -join "`n"), $packagePattern)
        if (-not $versionMatch.Success) { throw 'Could not parse the installed package version from winget output.' }
        $versionMatch.Groups[1].Value
    } catch {
        Write-Warning "  Could not check installed $ToolName in WinGet: $_"
        $null
    }
}

function Get-WingetLatestVersion {
    param([string]$ToolName, [string]$PackageId)

    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT') -or [string]::IsNullOrWhiteSpace($PackageId)) {
        return $null
    }
    if (-not (Test-CommandExists 'winget')) {
        Write-Warning "  Could not check $ToolName in WinGet: winget not found"
        return $null
    }

    try {
        $metadata = @(& winget show --id $PackageId -e --source winget --accept-source-agreements --disable-interactivity 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "winget show exited with code $LASTEXITCODE. Output: $($metadata -join ' ')"
        }
        $metadataText = $metadata -join "`n"
        $versionMatch = [regex]::Match($metadataText, '(?m)^Version:\s*(\S+)\s*$')
        if (-not $versionMatch.Success) {
            throw 'Could not parse the package version from winget output.'
        }
        $versionMatch.Groups[1].Value
    } catch {
        $message = "Could not check $ToolName in WinGet. $(Get-DetailedErrorMessage $_)"
        Write-Warning "  $message"
        $results.Errors += $message
        $null
    }
}

# ─────────────────────────────────────────────
# 4. STANDARD TOOL FRAMEWORK
#    Handles any tool with CheckType = "standard"
#    in tool-checker.json. To add a simple tool,
#    just add its entry to the JSON file.
# ─────────────────────────────────────────────

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
        $results.Tools[$ToolName] = @{ Installed = "unknown"; Latest = "" }
        return
    }

    Write-Success "$ToolName installed: $version"
    $results.Tools[$ToolName] = @{ Installed = $version; Latest = "" }

    if (-not $SkipUpdate) {
        Get-StandardToolUpdates -ToolName $ToolName -InstalledVersion $version -RawOutput $raw
    }
}

# --- Version extraction (installed) -----------------------------------------

function Get-InstalledVersionFromOutput {
    param([string]$ToolName, [object]$Output)

    $config    = $toolsConfig[$ToolName]
    $extractor = $config.VersionExtractor
    if ($config.PreferWingetInstalledVersion) {
        $packageVersion = Get-WingetInstalledVersion -ToolName $ToolName -PackageId $config.WingetId
        if ($packageVersion) { return $packageVersion }
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
        # --- Add new VersionExtractor cases here ---
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

# --- Version extraction (latest from API) -----------------------------------

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

    switch ($extractor) {
        "npmDistTagLatest" {
            $latest = if ($ApiData.'dist-tags') { $ApiData.'dist-tags'.latest } else { $null }
            if ($config.ProductionReleasesOnly -and -not (Test-IsProductionVersion $latest)) {
                return Get-LatestProductionNpmVersion -ApiData $ApiData
            }
            $latest
        }
        # --- Add new API-version-extractor cases here ---
        default {
            # GitHub releases / generic fallback
            if ($ApiData.tag_name) { $ApiData.tag_name -replace '^v', '' }
            elseif ($ApiData.version) { $ApiData.version }
            elseif ($ApiData.release) { $ApiData.release }
            else { $null }
        }
    }
}

# --- Update check -----------------------------------------------------------

function Get-StandardToolUpdates {
    param([string]$ToolName, [string]$InstalledVersion, [object]$RawOutput = $null)

    $config = $toolsConfig[$ToolName]
    Write-Host "  Checking for $ToolName updates..."

    if (($IsWindows -or $env:OS -eq 'Windows_NT') -and $config.WingetId) {
        $latestVersion = Get-WingetLatestVersion -ToolName $ToolName -PackageId $config.WingetId
        if (-not (Set-LatestToolVersion -ToolNames $ToolName -LatestVersion $latestVersion -ProductionReleasesOnly $config.ProductionReleasesOnly -VersionLabel 'WinGet version')) { return }

        $updateCommand = Get-UpdateCommand -ToolName $ToolName -Installed $InstalledVersion -Latest $latestVersion
        if (Register-ToolUpdate -Name $ToolName -InstalledVersion $InstalledVersion -LatestVersion $latestVersion -Command $updateCommand -Type $config.UpdateType) {
            Write-Warning "  $ToolName has available updates in WinGet: $InstalledVersion -> $latestVersion"
            $url = $config.ReleaseNotesUrl; if ($url) { Write-Host "  Release notes: $url" }
        } else {
            Write-Success "$ToolName is up to date with WinGet"
        }
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

        $npmRelease = $null
        $isNpmPackage = $config.VersionExtractor -eq "npmDistTagLatest"
        if ($isNpmPackage) {
            $matureRelease = Get-LatestMatureNpmRelease -ApiData $apiData -MinimumVersion $InstalledVersion -MaximumVersion $latestVersion -ProductionReleasesOnly $config.ProductionReleasesOnly
            if ($matureRelease) {
                $latestVersion = $matureRelease.Version
                $npmRelease = $matureRelease
            } else {
                $npmRelease = Get-NpmVersionReleaseInfo -PackageName $config.NpmPackageName -Version $latestVersion
            }
            $results.Tools[$ToolName].AgeDays = if ($npmRelease) { $npmRelease.AgeDays } else { $null }
        }
        if (-not (Set-LatestToolVersion -ToolNames $ToolName -LatestVersion $latestVersion -ProductionReleasesOnly $config.ProductionReleasesOnly)) { return }

        if (Test-UpdateAvailable -InstalledVersion $InstalledVersion -LatestVersion $latestVersion) {
            $ageLabel = if ($npmRelease) { " ($($npmRelease.AgeDays) days old)" } elseif ($isNpmPackage) { " (age unknown)" } else { "" }
            Write-Warning "  $ToolName has available updates: $InstalledVersion -> $latestVersion$ageLabel"
            $results.Updates += $ToolName
            if ($isNpmPackage -and -not $npmRelease) {
                Write-Host "  FYI only: the release age could not be verified."
            } elseif ($npmRelease -and -not $npmRelease.Installable) {
                Write-Host "  FYI only: this release is not installable until it is $($script:NpmUpdateCooldownDays) days old."
                $results.MaturityBlockedUpdates += @{
                    Name = $ToolName
                    AgeDays = $npmRelease.AgeDays
                    RequiredAgeDays = $script:NpmUpdateCooldownDays
                }
            } elseif (-not $SkipUpdate) {
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

# ─────────────────────────────────────────────
# 5. POST-UPDATE VERSION REFRESH
# ─────────────────────────────────────────────

function Refresh-ToolVersion {
    param([string]$ToolName)
    try {
        if ($ToolName -eq "ncu global packages" -or $ToolName -like 'npm: *') {
            Invoke-ToolEntryPoint -ToolId 'npm-global-packages' -EntryPoint 'Refresh-ToolStatus'
            return $true
        }

        # Dynamic tool names don't have a direct config entry — route by pattern.
        # (e.g. ".NET SDK 10.0.201" maps to the ".NET SDK" config + dotnet refresh)
        if ($ToolName -match '^\.NET SDK\s') { Invoke-ToolEntryPoint -ToolId 'dotnet-sdk' -EntryPoint 'Refresh-ToolStatus'; return $true }
        if ($ToolName -match '^Python \d+\.\d+$') {
            Invoke-ToolEntryPoint -ToolId 'python' -EntryPoint 'Refresh-ToolStatus' -Arguments @{ ToolName = $ToolName }
            return $true
        }

        $config = $toolsConfig[$ToolName]
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

# ─────────────────────────────────────────────
# 7. SUMMARY TABLE & LOOKUP HELPERS
# ─────────────────────────────────────────────

function Get-UpdateCommand {
    param([string]$ToolName, [string]$Installed, [string]$Latest)
    if (-not $Latest -or $Latest -eq "-" -or (Compare-SemanticVersions $Installed $Latest) -ne -1) { return "" }
    if ($ToolName -in $results.MaturityBlockedUpdates.Name) { return "" }

    $availableUpdate = $results.AvailableUpdates | Where-Object { $_.Name -eq $ToolName } | Select-Object -First 1
    if ($availableUpdate) { return $availableUpdate.Command }

    # .NET SDK: higher SDK in same channel already covers it
    if ($ToolName -match "^\.NET SDK" -and $results.Tools.ContainsKey($ToolName)) {
        $hi = $results.Tools[$ToolName].HighestInstalled
        if ($hi -and [version]$hi -ge [version]$Latest) { return "" }
    }

    # Direct config match
    foreach ($k in $toolsConfig.Keys) {
        if ($ToolName -ne $k) { continue }
        $config = $toolsConfig[$k]
        if ($config.VersionExtractor -eq "npmDistTagLatest") {
            $ageDays = $results.Tools[$ToolName].AgeDays
            if ($null -eq $ageDays -or $ageDays -lt $script:NpmUpdateCooldownDays) { return "" }
            return $config.UpdateCommand.Replace("$($config.NpmPackageName)@latest", "$($config.NpmPackageName)@$Latest")
        }
        if ($config.WindowsUpdateCommand -and ($IsWindows -or $env:OS -eq 'Windows_NT')) {
            return $config.WindowsUpdateCommand
        }
        return $config.UpdateCommand
    }

    # Dynamic tool names
    if ($ToolName -match "^Python (\d+\.\d+)$") {
        if (Test-CommandExists "py") { return "py install $($Matches[1]) --update --quiet" }
        else { return $toolsConfig["Python"].UpdateCommand -replace '\{version\}', $Matches[1] }
    }
    if ($ToolName -match "^\.NET SDK")       { return $toolsConfig[".NET SDK"].UpdateCommand -replace '\{major\}', ($Installed -split '\.')[0] }
    if ($ToolName -eq "ncu global packages") { return $results.GlobalNpmUpdateCommand }
    if ($ToolName -match "^Azure Extension:") { return "az extension update --name $($ToolName -replace '^Azure Extension: ','' ) --only-show-errors" }
    ""
}

function Get-ReleaseNotesUrl {
    param([string]$ToolName)
    foreach ($k in $toolsConfig.Keys) { if ($ToolName -eq $k) { return $toolsConfig[$k].ReleaseNotesUrl } }
    if ($ToolName -match "^Python")           { return $toolsConfig["Python"].ReleaseNotesUrl }
    if ($ToolName -match "^\.NET SDK")        { return $toolsConfig[".NET SDK"].ReleaseNotesUrl }
    if ($ToolName -match "^Azure Extension:") { return $toolsConfig["Azure CLI Extensions"].ReleaseNotesUrl }
    ""
}

function Get-InstallCommand {
    param([pscustomobject]$NotInstalledEntry)
    if (-not $NotInstalledEntry -or -not $NotInstalledEntry.InstallCommands) { return "" }

    $commands = $NotInstalledEntry.InstallCommands
    if ($commands.Contains($script:PlatformKey)) { return $commands[$script:PlatformKey] }

    # Best-effort fallback to current OS if an exact arch match is missing.
    $osPrefix = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Windows (' } else { 'Linux (' }
    $fallbackKey = $commands.Keys | Where-Object { $_ -like "$osPrefix*" } | Select-Object -First 1
    if ($fallbackKey) { return $commands[$fallbackKey] }

    return ""
}

function Invoke-ToolCommand {
    param([string]$Command, [string]$Type)

    $isWinget = $Type -like 'winget*' -or $Command -match '^\s*winget(?:\.exe)?\s'
    if (-not $isWinget) {
        $output = Invoke-Expression "$Command 2>&1" | Out-String
        return @{ Output = $output; ExitCode = $LASTEXITCODE }
    }

    $parseErrors = $null
    $tokens = @([System.Management.Automation.PSParser]::Tokenize($Command, [ref]$parseErrors) | Where-Object {
        $_.Type -in @('Command', 'CommandArgument', 'CommandParameter', 'Number', 'String')
    })
    if ($parseErrors.Count -gt 0 -or $tokens.Count -lt 2 -or $tokens[0].Content -notmatch '^winget(?:\.exe)?$') {
        throw "Could not parse winget command: $Command"
    }

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $processArgs = @{
            FilePath               = $tokens[0].Content
            ArgumentList           = @($tokens[1..($tokens.Count - 1)].Content)
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError  = $stderrPath
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
        }
        $process = Start-Process @processArgs
        $output = @(
            Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue
            Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue
        ) -join "`n"
        return @{ Output = $output.Trim(); ExitCode = $process.ExitCode }
    } finally {
        Remove-Item -Path $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}



function Get-AvailableActions {
    param([switch]$RegistryOnly)

    $actions = @()
    foreach ($notInstalled in $results.NotInstalled | Where-Object { -not $RegistryOnly }) {
        $command = Get-InstallCommand -NotInstalledEntry $notInstalled
        $suffix = if ([string]::IsNullOrWhiteSpace($command)) { ' (no install command for this platform)' } else { '' }
        $actions += @{
            Name = $notInstalled.Name
            Label = "Install $($notInstalled.Name)$suffix"
            Type = 'install'
            Command = $command
        }
    }

    if (-not $SkipUpdate) {
        foreach ($update in $results.AvailableUpdates | Where-Object { -not $RegistryOnly -or $_.Type -eq 'registry' }) {
            $details = if ($update.Details) { " ($($update.Details))" } else { '' }
            $verb = if ($update.Type -eq 'registry') { 'Align' } else { 'Update' }
            $actions += @{
                Name = $update.Name
                Label = "$verb $($update.Name)$details"
                Type = $update.Type
                Command = $update.Command
                RegistryKey = $update.RegistryKey
                Version = $update.Version
            }
        }
    }

    $actions
}

function Invoke-ActionCommand {
    param([Parameter(Mandatory)][object]$Action)

    if ($Action.Type -eq 'registry') {
        return Set-RegistryConfiguration -RegistryKey $Action.RegistryKey -EnvironmentConfig $script:RegistryEnvironment
    }
    if ($Action.Name -eq 'uv' -and ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        return Invoke-ToolEntryPoint -ToolId 'uv' -EntryPoint 'Invoke-ToolInstall'
    }
    if ($Action.Type -eq 'node-direct') {
        return Invoke-ToolEntryPoint -ToolId 'nodejs' -EntryPoint 'Invoke-ToolUpdate' -Arguments @{ Version = $Action.Version }
    }
    Invoke-ToolCommand -Command $Action.Command -Type $Action.Type
}

function Test-WingetNoUpdateResult {
    param(
        [Parameter(Mandatory)][object]$Action,
        [int]$ExitCode,
        [string]$OutputText = ''
    )

    $wingetNoUpdateCodes = @(-1978335212, -1978335189, -1978335215)
    $isWingetCommand = $Action.Type -like 'winget*' -or $Action.Command -match '(^|\s)winget(\s|$)'
    $isWingetCommand -and (
        ($ExitCode -in $wingetNoUpdateCodes) -or
        $OutputText -match 'No applicable upgrade found' -or
        $OutputText -match 'No newer package version(s)? found' -or
        $OutputText -match 'No available upgrade found' -or
        $OutputText -match 'No installed package found matching'
    )
}

function Complete-UpdateExecution {
    param(
        [Parameter(Mandatory)][object]$Action,
        [Parameter(Mandatory)][object]$Execution,
        [switch]$Refresh
    )

    $exitCode = if ($null -ne $Execution.ExitCode) { [int]$Execution.ExitCode } else { 1 }
    $outputText = @($Execution.Output) -join "`n"
    if ($outputText) { Write-Host $outputText.TrimEnd() }

    if ($exitCode -eq 0) {
        Write-Success "Update completed: $($Action.Name)"
        $results.UpdateFailed = @($results.UpdateFailed | Where-Object { $_ -ne $Action.Name })
        if ($Refresh) {
            $refreshed = Refresh-ToolVersion -ToolName $Action.Name
            if ($refreshed -and $results.Tools.ContainsKey($Action.Name)) {
                Write-Host "  Verified version: $($results.Tools[$Action.Name].Installed)"
            } elseif ($Action.Name -eq 'ncu global packages') {
                Write-Host '  Verified global npm package versions refreshed'
            }
        }
        return $true
    }

    if (Test-WingetNoUpdateResult -Action $Action -ExitCode $exitCode -OutputText $outputText) {
        $message = "Skipped: $($Action.Name) - winget has no newer package yet | Command: $($Action.Command) | Exit code: $exitCode"
        Write-Warning $message
    } elseif ($outputText -match 'EALLOWREMOTE') {
        $message = "Failed: $($Action.Name) - npm rejected this package as a remote dependency; reinstall it from the configured registry before retrying | Command: $($Action.Command)"
        Write-Error $message
    } elseif ($Action.Command -match '^\s*uv\s+self\s+update\b' -and $outputText -match 'being used by another process|Access is denied|os error 32|failed to replace|failed to rename') {
        $message = "Failed: $($Action.Name) - uv.exe is in use | Command: $($Action.Command) | Exit code: $exitCode"
        Write-Error $message
    } elseif ($Action.Command -match '^\s*uv\s+self\s+update\b') {
        $message = "Failed: $($Action.Name) - 'uv self update' failed | Command: $($Action.Command) | Exit code: $exitCode"
        Write-Error $message
    } else {
        $message = "Failed: $($Action.Name) | Command: $($Action.Command) | Exit code: $exitCode"
        Write-Error $message
    }

    if ($Action.Name -notin $results.UpdateFailed) { $results.UpdateFailed += $Action.Name }
    $results.Errors += $message
    $false
}

function Complete-InstallExecution {
    param(
        [Parameter(Mandatory)][object]$Action,
        [Parameter(Mandatory)][object]$Execution
    )

    $outputText = @($Execution.Output) -join "`n"
    $exitCode = if ($null -ne $Execution.ExitCode) { [int]$Execution.ExitCode } else { 1 }
    if ($outputText) { Write-Host $outputText.TrimEnd() }

    $config = $toolsConfig[$Action.Name]
    $commandVerified = $config -and $config.Command -and (Test-CommandExists $config.Command)
    if ($commandVerified -or $exitCode -eq 0) {
        Write-Success "Install completed: $($Action.Name)"
        if ($commandVerified) {
            Write-Success "Verified command found: $($config.Command)"
        } else {
            Write-Warning "Command could not be verified yet for $($Action.Name) — you may need to restart your shell"
        }
        Refresh-ToolVersion -ToolName $Action.Name | Out-Null
        $results.NotInstalled = @($results.NotInstalled | Where-Object { $_.Name -ne $Action.Name })
        return $true
    }

    if (Test-WingetNoUpdateResult -Action $Action -ExitCode $exitCode -OutputText $outputText) {
        $message = "Install could not be verified for $($Action.Name). Command: $($Action.Command) | Exit code: $exitCode | The package manager reports no applicable package, but '$($config.Command)' is not available."
    } else {
        $message = "Install failed for $($Action.Name). Command: $($Action.Command) | Exit code: $exitCode"
    }
    Write-Error $message
    $results.Errors += $message
    $false
}

function Invoke-ActionMenu {
    param([switch]$RegistryOnly)

    $actions = @(Get-AvailableActions -RegistryOnly:$RegistryOnly)
    if ($actions.Count -eq 0) { return }

    $completedIdx = @()
    while ($true) {
        $remaining = @()
        for ($i = 0; $i -lt $actions.Count; $i++) {
            if ($i -notin $completedIdx) { $remaining += @{ Idx = $i; Action = $actions[$i] } }
        }
        if ($remaining.Count -eq 0) {
            Write-Host "All actions completed.`n"
            break
        }

        Write-Header "Actions"
        Write-Host ""
        Write-Host "  [0] Exit"
        Write-Host "  ----------------"
        for ($i = 0; $i -lt $remaining.Count; $i++) {
            if ($remaining[$i].Action.Name -in $results.UpdateFailed) {
                Write-Host "  $ColorOrange[$($i+1)] $($remaining[$i].Action.Label)$ColorReset"
            } else {
                Write-Host "  [$($i+1)] $($remaining[$i].Action.Label)"
            }
        }
        Write-Host ""

        $response = Read-Host "Select option"
        if ($response -eq "0" -or [string]::IsNullOrWhiteSpace($response)) { break }

        $selected = @()
        $response -split ',' | ForEach-Object {
            $t = $_.Trim()
            if ($t -match '^\d+$') {
                $n = [int]$t
                if ($n -ge 1 -and $n -le $remaining.Count) { $selected += $n }
            }
        }
        if ($selected.Count -eq 0) { Write-Host "No valid selection. Please try again.`n"; continue }

        foreach ($num in $selected) {
            $ri = $num - 1
            $a  = $remaining[$ri].Action

            if ($a.Type -ne 'registry' -and [string]::IsNullOrWhiteSpace($a.Command)) {
                Write-Warning "No command configured for $($a.Name) on $script:PlatformKey"
                continue
            }

            $isUvWindowsAction = $a.Name -eq 'uv' -and ($IsWindows -or $env:OS -eq 'Windows_NT')
            if ($a.Type -eq 'registry') {
                Write-Host "Executing approved registry alignment: $($a.Name)"
            } elseif ($isUvWindowsAction) {
                Write-Host 'Executing: standardize uv via winget (cleanup + install)'
            } else {
                Write-Host "Executing: $($a.Command)"
            }
            try {
                $execution = Invoke-ActionCommand -Action $a
                $outputText = $execution.Output
                $exitCode   = $execution.ExitCode

                if ($a.Type -eq 'registry') {
                    if (Complete-RegistryExecution -Action $a -Execution $execution) {
                        $completedIdx += $remaining[$ri].Idx
                    }
                } elseif ($a.Type -eq "install") {
                    if (Complete-InstallExecution -Action $a -Execution $execution) {
                        $completedIdx += $remaining[$ri].Idx
                    }
                } elseif (Complete-UpdateExecution -Action $a -Execution $execution -Refresh) {
                    $completedIdx += $remaining[$ri].Idx
                }
            } catch {
                $message = "$($a.Type) failed for $($a.Name). Command: $($a.Command) | $(Get-DetailedErrorMessage $_)"
                Write-Error $message
                if ($a.Name -notin $results.UpdateFailed) { $results.UpdateFailed += $a.Name }
                $results.Errors += $message
            }
            Write-Host ""
            Show-ResultsTable
        }
    }
}

# ─────────────────────────────────────────────
# 8. UPDATE EXECUTION (Force mode only)
# ─────────────────────────────────────────────

function Invoke-ForceUpdates {
    Write-Header "Available Updates (Force mode)"
    $automaticUpdates = @($results.AvailableUpdates | Where-Object { $_.Type -ne 'registry' })
    if ($automaticUpdates.Count -eq 0) { Write-Success "No automatic tool updates available"; return }

    Write-Host "Running all updates in parallel...`n"
    Invoke-ParallelUpdates -Updates $automaticUpdates
    foreach ($u in $automaticUpdates | Where-Object { $_.Name -notin $results.UpdateFailed }) {
        Refresh-ToolVersion -ToolName $u.Name | Out-Null
    }
    Show-ResultsTable
    if ($results.UpdateFailed.Count -gt 0) {
        Write-Error "$($results.UpdateFailed.Count) update(s) failed or were skipped: $($results.UpdateFailed -join ', ')"
    } else {
        Write-Success "All updates were installed successfully."
    }
    Write-Host ""
}

function Invoke-ParallelUpdates {
    param([array]$Updates)
    if ($Updates.Count -eq 0) { return }

    $jobs = @()
    foreach ($u in $Updates) {
        $requiresDirectExecution = $u.Type -eq 'node-direct' -or ($u.Name -eq 'uv' -and ($IsWindows -or $env:OS -eq 'Windows_NT'))
        if ($requiresDirectExecution) {
            Write-Host "Starting: $($u.Name)"
            $execution = Invoke-ActionCommand -Action $u
            Complete-UpdateExecution -Action $u -Execution $execution | Out-Null
            Write-Host ''
            continue
        }

        Write-Host "Starting: $($u.Name)"
        $jobs += @{
            Job = Start-Job -ScriptBlock {
                param($cmd)
                try {
                    $output = @(Invoke-Expression "$cmd 2>&1" | ForEach-Object { "$_" })
                    $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
                    [PSCustomObject]@{ Output = $output; ExitCode = $exitCode; Error = $null }
                } catch {
                    [PSCustomObject]@{
                        Output = @()
                        ExitCode = 1
                        Error = "$_ | Exception: $($_.Exception.GetType().FullName)"
                    }
                }
            } -ArgumentList $u.Command
            Update = $u
        }
    }
    Write-Host "`nWaiting for all updates to complete...`n"

    foreach ($j in $jobs) {
        $execution = Receive-Job -Job $j.Job -Wait
        $state = $j.Job.State
        $result = @()
        if ($state -eq "Completed") {
            $exitCode = if ($null -ne $execution.ExitCode) { [int]$execution.ExitCode } else { 1 }
            $result = @($execution.Output)
            if ($execution.Error) { $result += $execution.Error }
            $outputText = if ($result.Count -gt 0) { ($result | Out-String) } else { "" }
            Complete-UpdateExecution -Action $j.Update -Execution @{ Output = $outputText; ExitCode = $exitCode } | Out-Null
        } else {
            $message = "Failed: $($j.Update.Name) | Job state: $state | Command: $($j.Update.Command)"
            Write-Error $message
            if ($j.Update.Name -notin $results.UpdateFailed) { $results.UpdateFailed += $j.Update.Name }
            $results.Errors += $message
            if ($result) { $result | ForEach-Object { Write-Host "  $_" } }
        }
        Remove-Job -Job $j.Job; Write-Host ""
    }
    Write-Host "All parallel updates finished.`n"
}

# ─────────────────────────────────────────────
# 9. PARALLEL CHECK RUNNER
#    Runs all check scriptblocks concurrently
#    using runspaces. Each runspace captures
#    Write-Host output and returns a result
#    hashtable; results are merged in order.
# ─────────────────────────────────────────────

function Get-ParallelCheckFunctionBlock {
    param(
        [Parameter(Mandatory)][string]$ScriptContent,
        [Parameter(Mandatory)][hashtable]$ToolsConfiguration
    )

    $functionNames = @(
        'Invoke-ToolEntryPoint',
        'New-ToolCheckResults','Write-Header','Write-Success','Write-Warning','Write-Error',
        'Test-CommandExists','Get-DetailedErrorMessage','Get-ToolConfiguration','Get-CommandVersion',
        'ConvertTo-CanonicalSemanticVersion','Compare-SemanticVersions','Test-UpdateAvailable',
        'Test-IsProductionVersion','Set-LatestToolVersion','Get-LatestProductionNpmVersion','Get-LatestMatureNpmRelease',
        'Invoke-SafeApiRequest','Add-NotInstalledTool','Add-AvailableUpdate','Register-ToolUpdate','Get-WingetInstalledVersion','Get-WingetLatestVersion',
        'Test-StandardTool','Get-InstalledVersionFromOutput','Get-LatestVersionFromApi','Get-UpdateCommand','Get-StandardToolUpdates',
        'Get-GlobalNpmInstalledVersion','Get-NpmVersionReleaseInfo'
    )
    $functionNames += @($ToolsConfiguration.Values | Where-Object { $_.CheckType -eq 'custom' } | ForEach-Object { $_.CustomFunction })

    $outputContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Infra/output.ps1') -Raw
    $configurationContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Infra/configuration.ps1') -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput("$ScriptContent`n$outputContent`n$configurationContent", [ref]$null, [ref]$null)
    $functionDefinitions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    $definitions = @($functionDefinitions | Where-Object { $_.Name -in $functionNames } | ForEach-Object { $_.Extent.Text })
    $serializedDefinitions = (ConvertTo-Json -InputObject $script:ToolDefinitions -Depth 5 -Compress).Replace("'", "''")
    $definitions += "`$script:ToolDefinitions = ConvertFrom-Json -AsHashtable -InputObject '$serializedDefinitions'"
    $definitions -join "`n`n"
}

function New-ParallelCheckTimeoutResult {
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $timeoutResult = New-ToolCheckResults
    $timeoutResult.Index = $Index
    $timeoutResult.Output = @()
    $timeoutResult.Tools[$Name] = @{ Installed = 'unknown'; Latest = ''; CheckTimedOut = $true }
    $timeoutResult.Errors = @("$Name check timed out after ${TimeoutSec}s")
    $timeoutResult
}

function Merge-ParallelCheckResult {
    param([Parameter(Mandatory)][object]$CheckResult)

    foreach ($line in $CheckResult.Output) { Write-Host $line }
    foreach ($entry in $CheckResult.Tools.GetEnumerator()) { $results.Tools[$entry.Key] = $entry.Value }
    foreach ($entry in $CheckResult.DotNetSDKs.GetEnumerator()) { $results.DotNetSDKs[$entry.Key] = $entry.Value }
    $results.NotInstalled            += $CheckResult.NotInstalled
    $results.Updates                 += $CheckResult.Updates
    $results.Errors                  += $CheckResult.Errors
    $results.UpdateFailed            += $CheckResult.UpdateFailed
    $results.AvailableUpdates        += $CheckResult.AvailableUpdates
    $results.MaturityBlockedUpdates  += $CheckResult.MaturityBlockedUpdates
    $results.GlobalNpmPackageUpdates += $CheckResult.GlobalNpmPackageUpdates
    if ($CheckResult.GlobalNpmUpdateCommand -and $CheckResult.GlobalNpmUpdateCommand -ne 'ncu -g -u --loglevel=error') {
        $results.GlobalNpmUpdateCommand = $CheckResult.GlobalNpmUpdateCommand
    }
}

function Get-ParallelCheckWorkerScript {
    {
        param($fnBlock, $checkStr, $progress, $idx,
            $toolsConfig, $SkipUpdate, $PlatformKey, $NpmUpdateCooldownDays, $ApiRequestTimeout,
            $ColorReset, $ColorGreen, $ColorYellow, $ColorRed, $ColorCyan, $ColorBlue)

        $Global:__rs_outputLines = [System.Collections.Generic.List[string]]::new()
        $Global:toolsConfig = $toolsConfig
        $Global:SkipUpdate = $SkipUpdate
        $Global:PlatformKey = $PlatformKey
        $Global:NpmUpdateCooldownDays = $NpmUpdateCooldownDays
        $Global:ApiRequestTimeout = $ApiRequestTimeout
        $Global:ColorReset = $ColorReset
        $Global:ColorGreen = $ColorGreen
        $Global:ColorYellow = $ColorYellow
        $Global:ColorRed = $ColorRed
        $Global:ColorCyan = $ColorCyan
        $Global:ColorBlue = $ColorBlue

        $writeHostOverride = @'
function Write-Host {
    $Global:__rs_outputLines.Add(($args -join ' '))
}
$script:PlatformKey = $Global:PlatformKey
$script:NpmUpdateCooldownDays = $Global:NpmUpdateCooldownDays
$script:ApiRequestTimeout = $Global:ApiRequestTimeout
$results = $Global:results
$toolsConfig = $Global:toolsConfig
$SkipUpdate = $Global:SkipUpdate
$ColorReset = $Global:ColorReset
$ColorGreen = $Global:ColorGreen
$ColorYellow = $Global:ColorYellow
$ColorRed = $Global:ColorRed
$ColorCyan = $Global:ColorCyan
$ColorBlue = $Global:ColorBlue
'@
        $combinedBlock = $writeHostOverride + "`n`n" + $fnBlock
        . ([scriptblock]::Create($combinedBlock))
        $Global:results = New-ToolCheckResults
        $results = $Global:results

        try { Invoke-Expression ($checkStr -replace '\$args\[0\]', "'$progress'") }
        catch { $Global:__rs_outputLines.Add("  `e[31m✗ Check error: $_`e[0m") }

        @{
            Index                   = $idx
            Output                  = $Global:__rs_outputLines.ToArray()
            Tools                   = $Global:results.Tools
            DotNetSDKs              = $Global:results.DotNetSDKs
            NotInstalled            = $Global:results.NotInstalled
            Updates                 = $Global:results.Updates
            Errors                  = $Global:results.Errors
            AvailableUpdates        = $Global:results.AvailableUpdates
            MaturityBlockedUpdates  = $Global:results.MaturityBlockedUpdates
            UpdateFailed            = $Global:results.UpdateFailed
            GlobalNpmPackageUpdates = $Global:results.GlobalNpmPackageUpdates
            GlobalNpmUpdateCommand  = $Global:results.GlobalNpmUpdateCommand
        }
    }
}

function Invoke-ParallelChecks {
    param([array]$Checks, [int]$Total, [int]$TimeoutSec = 60)

    # Extract shared script helpers and the loaded tool-file functions for workers.
    $scriptContent = Get-Content $PSCommandPath -Raw
    $fnBlock = Get-ParallelCheckFunctionBlock -ScriptContent $scriptContent -ToolsConfiguration $toolsConfig

    # Thread-safe bag to collect per-check results keyed by index
    $resultBag = [System.Collections.Concurrent.ConcurrentDictionary[int, object]]::new()

    # Build runspace pool — cap at check count but no more than logical CPUs
    $maxThreads = [Math]::Min($Checks.Count, [System.Environment]::ProcessorCount)
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $maxThreads)
    $pool.Open()

    # Snapshot shared state for $using: injection
    $snap_toolsConfig  = $toolsConfig
    $snap_SkipUpdate   = $SkipUpdate
    $snap_PlatformKey  = $script:PlatformKey
    $snap_NpmUpdateCooldownDays = $script:NpmUpdateCooldownDays
    $snap_ColorReset   = $ColorReset
    $snap_ColorGreen   = $ColorGreen
    $snap_ColorYellow  = $ColorYellow
    $snap_ColorRed     = $ColorRed
    $snap_ColorCyan    = $ColorCyan
    $snap_ColorBlue    = $ColorBlue

    $padWidth    = $Total.ToString().Length
    $successIcon = [char]0x2713
    $threadStatusLines = [string[]]::new($Checks.Count)
    $parallelStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $supportsStatusUpdates = $false
    try {
        $supportsStatusUpdates = $Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected
    } catch { }
    $renderThreadStatuses = {
        if (-not $supportsStatusUpdates) { return }
        $elapsedSeconds = [Math]::Floor($parallelStopwatch.Elapsed.TotalSeconds)
        $Host.UI.Write("`e[s`e[$($threadStatusLines.Count + 2)A")
        $Host.UI.Write("`e[2K`r  Elapsed: ${elapsedSeconds}s`n")
        $Host.UI.Write("`e[2K`r`n")
        foreach ($line in $threadStatusLines) {
            $Host.UI.Write("`e[2K`r$line`n")
        }
        $Host.UI.Write("`e[u")
    }

    if ($supportsStatusUpdates) { $Host.UI.Write("`e[?25l") }
    Write-Host "  Elapsed: 0s"
    Write-Host ""
    $runningJobs = @()
    for ($i = 0; $i -lt $Checks.Count; $i++) {
        $idx      = $i
        $toolName = $Checks[$i].Name
        # Pass check as string so Invoke-Expression executes it in the runspace scope
        $checkStr = $Checks[$i].Block.ToString()
        $progress = "{0,$padWidth}/{1}" -f ($i + 1), $Total

        $threadStatusLines[$i] = "  $ColorCyan⟳ [$progress] Running: $toolName$ColorReset"
        Write-Host $threadStatusLines[$i]

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool

        [void]$ps.AddScript((Get-ParallelCheckWorkerScript))
        [void]$ps.AddArgument($fnBlock)
        [void]$ps.AddArgument($checkStr)
        [void]$ps.AddArgument($progress)
        [void]$ps.AddArgument($idx)
        [void]$ps.AddArgument($snap_toolsConfig)
        [void]$ps.AddArgument($snap_SkipUpdate)
        [void]$ps.AddArgument($snap_PlatformKey)
        [void]$ps.AddArgument($snap_NpmUpdateCooldownDays)
        [void]$ps.AddArgument($TimeoutSec)
        [void]$ps.AddArgument($snap_ColorReset)
        [void]$ps.AddArgument($snap_ColorGreen)
        [void]$ps.AddArgument($snap_ColorYellow)
        [void]$ps.AddArgument($snap_ColorRed)
        [void]$ps.AddArgument($snap_ColorCyan)
        [void]$ps.AddArgument($snap_ColorBlue)

        $runningJobs += @{ PS = $ps; Handle = $ps.BeginInvoke(); Index = $idx; StartTime = [System.Diagnostics.Stopwatch]::StartNew(); Name = $toolName }
    }

    $collectedResults = @{}
    try {
        while ($runningJobs.Count -gt 0) {
            $still = @()
            foreach ($job in $runningJobs) {
            if ($job.Handle.IsCompleted) {
                $elapsed = $job.StartTime.Elapsed
                $rawResult = $job.PS.EndInvoke($job.Handle)
                $hasErrors = $job.PS.Streams.Error.Count -gt 0
                if ($hasErrors) {
                    foreach ($err in $job.PS.Streams.Error) {
                        $results.Errors += "Parallel check error (job $($job.Index)): $err"
                    }
                }
                $job.PS.Dispose()
                if ($rawResult -and $rawResult.Count -gt 0) {
                    $hasErrors = $hasErrors -or $rawResult[0].Errors.Count -gt 0
                    $collectedResults[$job.Index] = $rawResult[0]
                }
                $progress = "{0,$padWidth}/{1}" -f ($job.Index + 1), $Total
                $elapsedLabel = '{0:N1}s' -f $elapsed.TotalSeconds
                if ($hasErrors) {
                    $threadStatusLines[$job.Index] = "  $ColorYellow! [$progress] Completed with errors: $($job.Name) ($elapsedLabel)$ColorReset"
                } else {
                    $threadStatusLines[$job.Index] = "  $ColorGreen$successIcon [$progress] Completed: $($job.Name) ($elapsedLabel)$ColorReset"
                }
                if ($supportsStatusUpdates) { & $renderThreadStatuses } else { Write-Host $threadStatusLines[$job.Index] }
            } elseif ($job.StartTime.Elapsed.TotalSeconds -ge $TimeoutSec) {
                # Kill the runspace that exceeded the timeout
                $job.PS.Stop()
                $job.PS.Dispose()
                # Provide a minimal result so the merge loop can handle it
                $progress = "{0,$padWidth}/{1}" -f ($job.Index + 1), $Total
                $threadStatusLines[$job.Index] = "  $ColorRed✗ [$progress] Timed out: $($job.Name) (${TimeoutSec}s)$ColorReset"
                if ($supportsStatusUpdates) { & $renderThreadStatuses } else { Write-Host $threadStatusLines[$job.Index] }
                $collectedResults[$job.Index] = New-ParallelCheckTimeoutResult -Index $job.Index -Name $job.Name -TimeoutSec $TimeoutSec
                } else {
                    $still += $job
                }
            }
            $runningJobs = $still
            if ($runningJobs.Count -gt 0) {
                if ($supportsStatusUpdates) { & $renderThreadStatuses }
                Start-Sleep -Milliseconds 250
            }
        }
    } finally {
        if ($supportsStatusUpdates) { $Host.UI.Write("`e[?25h") }
    }
    $parallelStopwatch.Stop()
    Write-Host ""
    $pool.Close()
    $pool.Dispose()

    # Print output and merge results in original order
    for ($i = 0; $i -lt $Checks.Count; $i++) {
        if (-not $collectedResults.ContainsKey($i)) { continue }
        Merge-ParallelCheckResult -CheckResult $collectedResults[$i]
    }
}

# ─────────────────────────────────────────────
# 10. MAIN — driven by sorted tool configuration
# ─────────────────────────────────────────────

function Main {
    Assert-ToolConfigurations

    $isElevated = Test-IsAdministrator
    Show-StartupInformation -IsElevated $isElevated
    Test-RegistryConfiguration -EnvironmentConfig $script:RegistryEnvironment
    Show-RegistryMetadata

    # Build check list from the sorted configuration order.
    $checks = @()
    foreach ($toolName in $toolsConfig.Keys) {
        $cfg = $toolsConfig[$toolName]
        if (-not $cfg.Enabled) { continue }
        $name = $toolName  # capture for closure
        if ($cfg.CheckType -eq "custom" -and $cfg.CustomFunction) {
            $fn = $cfg.CustomFunction
            $checkCommand = if ($script:ToolDefinitions.ContainsKey($cfg.Id)) {
                "Invoke-ToolEntryPoint -ToolId '$($cfg.Id)' -EntryPoint 'Test-Tool' -Arguments @{ Progress = `$args[0] }"
            } else {
                "$fn -Progress `$args[0]"
            }
            $checks += @{ Name = $name; Block = [scriptblock]::Create($checkCommand) }
        } elseif ($cfg.CheckType -eq "standard") {
            $checks += @{ Name = $name; Block = [scriptblock]::Create("Test-StandardTool -ToolName '$name' -Progress `$args[0]") }
        }
        # Tools with no CheckType (e.g. metadata-only entries) are skipped
    }

    $total = $checks.Count
    Show-CheckProgressHeader -Total $total -TimeoutSec $Timeout
    Invoke-ParallelChecks -Checks $checks -Total $total -TimeoutSec $Timeout

    $availableUpdateNames = @($results.Updates | Where-Object { $_ -notin $results.MaturityBlockedUpdates.Name })
    Show-ResultsSummary -AvailableUpdateNames $availableUpdateNames

    if ($Force) {
        Invoke-ForceUpdates
        if ($results.AvailableUpdates | Where-Object { $_.Type -eq 'registry' }) {
            Write-Warning 'Registry changes always require explicit approval, including in Force mode.'
            Invoke-ActionMenu -RegistryOnly
        }
    } else {
        Invoke-ActionMenu
    }
}

# Entry point
if (-not $script:IsDotSourced) {
    Main
    if ($results.Errors.Count -gt 0 -or $results.UpdateFailed.Count -gt 0) {
        exit 1
    }
}
