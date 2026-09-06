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
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
    [switch]$Version
)

$script:ToolCheckerVersion = '1.2.5'
$script:NpmUpdateCooldownDays = 7
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

function Get-ToolSortKey {
    param([string]$ToolName)

    if ($ToolName -eq "Azure CLI") { return "Azure CLI|0|0" }
    if ($ToolName -eq "Azure CLI Extensions") { return "Azure CLI|1|Azure CLI Extensions" }
    if ($ToolName -match "^\s*az ext:") { return "Azure CLI|1|$ToolName" }
    if ($ToolName -match "^\.NET SDK ([\d.]+)") {
        $version = [version]$Matches[1]
        return ".NET SDK|0|{0:D10}.{1:D10}.{2:D10}" -f (
            [int]::MaxValue - $version.Major
        ), (
            [int]::MaxValue - $version.Minor
        ), (
            [int]::MaxValue - $version.Build
        )
    }
    if ($ToolName -match "^Python ([\d.]+)") {
        $parts = $Matches[1] -split '\.'
        $major = if ($parts.Count -gt 0) { [int]$parts[0] } else { 0 }
        $minor = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
        return "Python|0|{0:D10}.{1:D10}" -f (
            [int]::MaxValue - $major
        ), (
            [int]::MaxValue - $minor
        )
    }
    "$ToolName|0|0"
}

function Get-ToolCatalogSelection {
    param(
        [Parameter(Mandatory)][object]$Tools,
        [string[]]$RequestedToolIds = @()
    )

    $catalogToolIds = @()
    $catalogToolNames = @()
    $catalogEntries = @($Tools.PSObject.Properties | ForEach-Object {
        if ($_.Name -notmatch '^[a-z][a-z0-9-]*$') {
            throw "Tool catalog ID '$($_.Name)' must use lowercase letters, numbers, and hyphens."
        }
        if ([string]::IsNullOrWhiteSpace("$($_.Value.Name)")) {
            throw "Tool catalog entry '$($_.Name)' requires a display Name."
        }
        if ($_.Value.Name -in $catalogToolNames) {
            throw "Tool catalog display Name '$($_.Value.Name)' must be unique."
        }
        $catalogToolIds += $_.Name
        $catalogToolNames += $_.Value.Name
        [PSCustomObject]@{ Id = $_.Name; Name = $_.Value.Name; Configuration = $_.Value }
    } | Sort-Object { Get-ToolSortKey $_.Name })

    $unknownToolIds = @($RequestedToolIds | Where-Object { $_ -notin $catalogToolIds })
    if ($unknownToolIds) {
        throw "TOOL_CHECKER_TOOLS contains unknown catalog ID(s): $($unknownToolIds -join ', ')"
    }

    [PSCustomObject]@{
        CatalogToolIds = $catalogToolIds
        SelectedEntries = @($catalogEntries | Where-Object { -not $RequestedToolIds -or $_.Id -in $RequestedToolIds })
    }
}

function Read-DotEnvFile {
    param([string]$Path)

    $values = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $values }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed.StartsWith('export ')) { $trimmed = $trimmed.Substring(7).TrimStart() }
        if ($trimmed -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { continue }

        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))
        )) {
            $value = $value.Substring(1, $value.Length - 2)
        } else {
            $value = ($value -replace '\s+#.*$', '').Trim()
        }
        $values[$key] = $value
    }
    $values
}

$configPath = Join-Path $PSScriptRoot "tool-checker.json"
if (-not (Test-Path $configPath)) {
    Write-Host "`e[31m✗ tool-checker.json not found at: $configPath`e[0m"
    exit 1
}

$toolsConfig = [ordered]@{}
$toolsJson   = Get-Content $configPath -Raw | ConvertFrom-Json
$resolvedEnvFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile)
$script:RegistryEnvironment = Read-DotEnvFile -Path $resolvedEnvFile
$requestedToolIds = @()
if ($script:RegistryEnvironment.Contains('TOOL_CHECKER_TOOLS') -and $script:RegistryEnvironment.TOOL_CHECKER_TOOLS) {
    $requestedToolIds = @($script:RegistryEnvironment.TOOL_CHECKER_TOOLS -split ',' |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ } |
        Select-Object -Unique)
}
$script:NpmRegistryResolution = @{
    Source = 'tool-checker.json'
    Url = $null
    Details = $null
}

$catalogSelection = Get-ToolCatalogSelection -Tools $toolsJson.tools -RequestedToolIds $requestedToolIds
$catalogToolIds = $catalogSelection.CatalogToolIds
$catalogEntries = $catalogSelection.SelectedEntries

foreach ($catalogEntry in $catalogEntries) {
    if ($requestedToolIds -and $catalogEntry.Id -notin $requestedToolIds) { continue }
    $toolName = "$($catalogEntry.Name)"
    $jsonTool = $catalogEntry.Configuration
    $toolEntry = @{}
    foreach ($prop in $jsonTool.PSObject.Properties) {
        if ($prop.Name -eq "InstallCommands") {
            $ordered = [ordered]@{}
            foreach ($p in $prop.Value.PSObject.Properties) { $ordered[$p.Name] = $p.Value }
            $toolEntry["InstallCommands"] = $ordered
        } else {
            $toolEntry[$prop.Name] = $prop.Value
        }
    }
    $toolEntry['Id'] = $catalogEntry.Id
    if (-not $toolEntry.ContainsKey('ProductionReleasesOnly')) {
        $toolEntry['ProductionReleasesOnly'] = $true
    }
    if (-not $toolEntry.ContainsKey('Enabled')) {
        $toolEntry['Enabled'] = $true
    }
    $toolsConfig[$toolName] = $toolEntry
}

function Get-ToolDefinitionFiles {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ToolsConfiguration,
        [Parameter(Mandatory)][string]$Directory
    )

    foreach ($config in $ToolsConfiguration.Values | Where-Object { $_.Enabled } | Sort-Object Id) {
        $toolPath = Join-Path $Directory "$($config.Id).ps1"
        if (Test-Path -LiteralPath $toolPath -PathType Leaf) {
            Get-Item -LiteralPath $toolPath
        }
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
    $script:ToolDefinitions[$toolDefinitionFile.BaseName] = $definitions
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

function Get-ToolConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$ToolName,
        [string[]]$RequiredProperties = @()
    )

    if (-not $toolsConfig.Contains($ToolName)) {
        throw "Tool configuration not found: $ToolName"
    }

    $config = $toolsConfig[$ToolName]
    foreach ($propertyName in $RequiredProperties) {
        if (-not $config.ContainsKey($propertyName) -or [string]::IsNullOrWhiteSpace("$($config[$propertyName])")) {
            throw "Tool '$ToolName' requires configuration property '$propertyName'."
        }
    }
    $config
}

function Assert-ToolConfigurations {
    $customRequiredProperties = @{
        'NodeJS' = @('Command', 'ApiUrl')
        'Global npm packages' = @()
        'Azure CLI Extensions' = @('Command')
        '.NET SDK' = @('Command', 'ApiUrl')
        'Python Install Manager (py)' = @('Command', 'PackageName', 'WingetId')
        'Python' = @('Command', 'ApiUrl')
        'PowerShell' = @('Command', 'ApiUrl')
        'WSL' = @('Command', 'VersionCommand', 'VersionParseRegex', 'ApiUrl')
    }

    foreach ($toolName in $toolsConfig.Keys) {
        $config = $toolsConfig[$toolName]
        if (-not $config.Enabled) { continue }
        if ($config.CheckType -notin @('standard', 'custom')) {
            throw "Tool '$toolName' has unsupported CheckType '$($config.CheckType)'."
        }

        $requiredProperties = @('UpdateType', 'UpdateCommand')
        if ($config.CheckType -eq 'standard') {
            $requiredProperties += @('Command', 'ApiUrl')
            if ([string]::IsNullOrWhiteSpace("$($config.VersionFlag)") -and [string]::IsNullOrWhiteSpace("$($config.VersionCommand)")) {
                throw "Standard tool '$toolName' requires either 'VersionFlag' or 'VersionCommand'."
            }
        } else {
            $requiredProperties += @('CustomFunction')
            if ($customRequiredProperties.ContainsKey($toolName)) {
                $requiredProperties += $customRequiredProperties[$toolName]
            }
        }

        $config = Get-ToolConfiguration -ToolName $toolName -RequiredProperties $requiredProperties
        if ($config.CheckType -ne 'custom') { continue }

        $functionName = "$($config.CustomFunction)"
        $checkerExists = if ($config.Id -and $script:ToolDefinitions.ContainsKey($config.Id)) {
            $functionName -eq 'Test-Tool' -and $script:ToolDefinitions[$config.Id].ContainsKey($functionName)
        } else {
            [bool](Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue)
        }
        if (-not $checkerExists) {
            throw "Custom checker '$functionName' configured for '$toolName' was not found."
        }
    }
}

# ─────────────────────────────────────────────
# 2. OUTPUT HELPERS
# ─────────────────────────────────────────────

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

function ConvertTo-NormalizedRegistryUrl {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $Value.Trim().TrimEnd('/')
}

function Protect-RegistryUrl {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '(not configured)' }
    try {
        $uri = [Uri]$Value
        if (-not $uri.UserInfo) { return $Value }
        $builder = [UriBuilder]$uri
        $builder.UserName = '***'
        $builder.Password = '***'
        $builder.Uri.AbsoluteUri.TrimEnd('/')
    } catch {
        if ($Value -match '://[^/@]+@') { return ($Value -replace '://[^/@]+@', '://***@') }
        $Value
    }
}

function Invoke-RegistryCommand {
    param([string]$Command, [string[]]$Arguments)

    try {
        $output = @(& $Command @Arguments 2>&1)
        [PSCustomObject]@{ Output = ($output -join "`n").Trim(); ExitCode = $LASTEXITCODE }
    } catch {
        [PSCustomObject]@{ Output = Get-DetailedErrorMessage $_; ExitCode = 1 }
    }
}

function Get-PythonCommand {
    $candidates = @()
    if (Test-CommandExists 'py') {
        $candidates += [PSCustomObject]@{ Command = 'py'; Prefix = @('-V:3', '-m', 'pip') }
        $candidates += [PSCustomObject]@{ Command = 'py'; Prefix = @('-m', 'pip') }
    }
    if (Test-CommandExists 'python') {
        $candidates += [PSCustomObject]@{ Command = 'python'; Prefix = @('-m', 'pip') }
    }
    if (Test-CommandExists 'python3') {
        $candidates += [PSCustomObject]@{ Command = 'python3'; Prefix = @('-m', 'pip') }
    }

    foreach ($candidate in $candidates) {
        $probe = Invoke-RegistryCommand -Command $candidate.Command -Arguments (@($candidate.Prefix) + @('--version'))
        if ($probe.ExitCode -eq 0) { return $candidate }
    }
    $null
}

function Get-UvUserConfigPath {
    if ($IsWindows) {
        return Join-Path $env:APPDATA 'uv\uv.toml'
    }
    $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    Join-Path $configHome 'uv/uv.toml'
}

function Get-UvDefaultIndex {
    $configPath = Get-UvUserConfigPath
    if (-not (Test-Path -LiteralPath $configPath)) { return '' }

    foreach ($line in Get-Content -LiteralPath $configPath) {
        if ($line -match '^\s*(?:index-url|default-index)\s*=\s*["''](.*)["'']\s*(?:#.*)?$') {
            return $Matches[1]
        }
    }
    ''
}

function Set-UvDefaultIndex {
    param([string]$IndexUrl)

    try {
        $configPath = Get-UvUserConfigPath
        $configDirectory = Split-Path -Parent $configPath
        if (-not (Test-Path -LiteralPath $configDirectory)) {
            New-Item -ItemType Directory -Path $configDirectory -Force -ErrorAction Stop | Out-Null
        }

        $setting = "index-url = $($IndexUrl | ConvertTo-Json -Compress)"
        $lines = if (Test-Path -LiteralPath $configPath) { @(Get-Content -LiteralPath $configPath) } else { @() }
        $settingWritten = $false
        $updatedLines = foreach ($line in $lines) {
            if ($line -match '^\s*(?:index-url|default-index)\s*=') {
                if (-not $settingWritten) {
                    $setting
                    $settingWritten = $true
                }
                continue
            }
            $line
        }
        if (-not $settingWritten) { $updatedLines = @($setting) + @($updatedLines) }
        Set-Content -LiteralPath $configPath -Value $updatedLines -Encoding utf8 -ErrorAction Stop
        [PSCustomObject]@{ Output = "Configured uv index URL in $configPath"; ExitCode = 0 }
    } catch {
        [PSCustomObject]@{ Output = Get-DetailedErrorMessage $_; ExitCode = 1 }
    }
}

function Get-NuGetSource {
    param([string]$SourceName)
    if (-not (Test-CommandExists 'dotnet')) { return $null }

    $result = Invoke-RegistryCommand -Command 'dotnet' -Arguments @('nuget', 'list', 'source', '--format', 'Detailed')
    if ($result.ExitCode -ne 0) { return $null }
    $lines = $result.Output -split "`r?`n"
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\d+\.\s+(.+?)\s+\[(Enabled|Disabled)\]\s*$' -and $Matches[1].Trim() -eq $SourceName) {
            if ($index + 1 -lt $lines.Count) {
                return [PSCustomObject]@{
                    Url = $lines[$index + 1].Trim()
                    Enabled = $Matches[2] -eq 'Enabled'
                }
            }
        }
    }
    $null
}

function Add-RegistryCheck {
    param(
        [string]$Key,
        [string]$Name,
        [string]$Current,
        [string]$Expected,
        [string]$Details = '',
        [switch]$ForceMisaligned
    )

    $currentNormalized = ConvertTo-NormalizedRegistryUrl $Current
    $expectedNormalized = ConvertTo-NormalizedRegistryUrl $Expected
    $status = if ($ForceMisaligned) { 'Misaligned' }
        elseif (-not $Details -and $currentNormalized -eq $expectedNormalized) { 'Aligned' }
        elseif ($Details) { 'Unavailable' }
        else { 'Misaligned' }
    $results.RegistryChecks += [PSCustomObject]@{
        Key = $Key
        Name = $Name
        Current = $Current
        Expected = $Expected
        Status = $status
        Details = $Details
    }
    if ($status -eq 'Misaligned' -and -not $SkipUpdate) {
        $actionDetails = "$(Protect-RegistryUrl $Current) -> $(Protect-RegistryUrl $Expected)"
        if ($Details) { $actionDetails = "$Details; $actionDetails" }
        Add-AvailableUpdate -Name "$Name registry" -Command '' -Type 'registry' -Details $actionDetails -RegistryKey $Key
    }
}

function Test-RegistryConfiguration {
    param([System.Collections.IDictionary]$EnvironmentConfig)

    Write-Header 'Registry Configuration'
    Write-Host ""

    $registryPolicyKeys = @('NPM_CONFIG_REGISTRY', 'PNPM_CONFIG_REGISTRY', 'PIP_INDEX_URL', 'UV_DEFAULT_INDEX', 'NUGET_SOURCE_URL')
    if (-not @($registryPolicyKeys | Where-Object { $EnvironmentConfig.Contains($_) })) {
        Write-Host "  No registry policy loaded from $EnvFile"
        Write-Host '  Copy .env.example to .env and uncomment the registries you want to enforce.'
        return
    }

    if ($EnvironmentConfig.Contains('NPM_CONFIG_REGISTRY')) {
        if (Test-CommandExists 'npm') {
            $current = (Invoke-RegistryCommand -Command 'npm' -Arguments @('config', 'get', 'registry')).Output
            Add-RegistryCheck -Key 'npm' -Name 'npm' -Current $current -Expected $EnvironmentConfig.NPM_CONFIG_REGISTRY
        } else {
            Add-RegistryCheck -Key 'npm' -Name 'npm' -Expected $EnvironmentConfig.NPM_CONFIG_REGISTRY -Details 'npm is not installed'
        }
    }
    if ($EnvironmentConfig.Contains('PNPM_CONFIG_REGISTRY')) {
        if (Test-CommandExists 'pnpm') {
            $current = (Invoke-RegistryCommand -Command 'pnpm' -Arguments @('config', 'get', 'registry', '--location=global')).Output
            Add-RegistryCheck -Key 'pnpm' -Name 'pnpm' -Current $current -Expected $EnvironmentConfig.PNPM_CONFIG_REGISTRY
        } else {
            Add-RegistryCheck -Key 'pnpm' -Name 'pnpm' -Expected $EnvironmentConfig.PNPM_CONFIG_REGISTRY -Details 'pnpm is not installed'
        }
    }
    if ($EnvironmentConfig.Contains('PIP_INDEX_URL')) {
        $python = Get-PythonCommand
        if ($python) {
            $query = Invoke-RegistryCommand -Command $python.Command -Arguments (@($python.Prefix) + @('config', 'get', 'global.index-url'))
            $current = if ($query.ExitCode -eq 0) { $query.Output } else { '' }
            Add-RegistryCheck -Key 'pip' -Name 'pip' -Current $current -Expected $EnvironmentConfig.PIP_INDEX_URL
        } else {
            Add-RegistryCheck -Key 'pip' -Name 'pip' -Expected $EnvironmentConfig.PIP_INDEX_URL -Details 'No installed Python interpreter provides pip'
        }
    }
    if ($EnvironmentConfig.Contains('UV_DEFAULT_INDEX')) {
        if (Test-CommandExists 'uv') {
            Add-RegistryCheck -Key 'uv' -Name 'uv' -Current (Get-UvDefaultIndex) -Expected $EnvironmentConfig.UV_DEFAULT_INDEX
        } else {
            Add-RegistryCheck -Key 'uv' -Name 'uv' -Expected $EnvironmentConfig.UV_DEFAULT_INDEX -Details 'uv is not installed'
        }
    }
    if ($EnvironmentConfig.Contains('NUGET_SOURCE_URL')) {
        $sourceName = if ($EnvironmentConfig.Contains('NUGET_SOURCE_NAME') -and $EnvironmentConfig.NUGET_SOURCE_NAME) {
            $EnvironmentConfig.NUGET_SOURCE_NAME
        } else { 'nuget.org' }
        if (Test-CommandExists 'dotnet') {
            $source = Get-NuGetSource $sourceName
            $details = if ($source -and -not $source.Enabled) { 'source is disabled' } else { '' }
            Add-RegistryCheck -Key 'nuget' -Name "NuGet ($sourceName)" -Current $source.Url -Expected $EnvironmentConfig.NUGET_SOURCE_URL -Details $details -ForceMisaligned:($source -and -not $source.Enabled)
        } else {
            Add-RegistryCheck -Key 'nuget' -Name "NuGet ($sourceName)" -Expected $EnvironmentConfig.NUGET_SOURCE_URL -Details '.NET SDK is not installed'
        }
    }

    foreach ($check in $results.RegistryChecks) {
        $color = if ($check.Status -eq 'Aligned') { $ColorGreen } elseif ($check.Status -eq 'Misaligned') { $ColorYellow } else { $ColorRed }
        Write-Host "  $color$($check.Name): $($check.Status)$ColorReset"
        Write-Host "    Current  : $(Protect-RegistryUrl $check.Current)"
        Write-Host "    Expected : $(Protect-RegistryUrl $check.Expected)"
        if ($check.Details) { Write-Host "    Detail  : $($check.Details)" }
    }
}

function Set-RegistryConfiguration {
    param([string]$RegistryKey, [System.Collections.IDictionary]$EnvironmentConfig)

    switch ($RegistryKey) {
        'npm' {
            Invoke-RegistryCommand -Command 'npm' -Arguments @('config', 'set', 'registry', $EnvironmentConfig.NPM_CONFIG_REGISTRY, '--location=user')
        }
        'pnpm' {
            Invoke-RegistryCommand -Command 'pnpm' -Arguments @('config', 'set', 'registry', $EnvironmentConfig.PNPM_CONFIG_REGISTRY, '--location=global')
        }
        'pip' {
            $python = Get-PythonCommand
            if (-not $python) { return [PSCustomObject]@{ Output = 'No installed Python interpreter provides pip'; ExitCode = 1 } }
            Invoke-RegistryCommand -Command $python.Command -Arguments (@($python.Prefix) + @('config', '--user', 'set', 'global.index-url', $EnvironmentConfig.PIP_INDEX_URL))
        }
        'uv' {
            Set-UvDefaultIndex -IndexUrl $EnvironmentConfig.UV_DEFAULT_INDEX
        }
        'nuget' {
            $sourceName = if ($EnvironmentConfig.NUGET_SOURCE_NAME) { $EnvironmentConfig.NUGET_SOURCE_NAME } else { 'nuget.org' }
            $source = Get-NuGetSource $sourceName
            $write = if ($source) {
                Invoke-RegistryCommand -Command 'dotnet' -Arguments @('nuget', 'update', 'source', $sourceName, '--source', $EnvironmentConfig.NUGET_SOURCE_URL)
            } else {
                Invoke-RegistryCommand -Command 'dotnet' -Arguments @('nuget', 'add', 'source', $EnvironmentConfig.NUGET_SOURCE_URL, '--name', $sourceName)
            }
            if ($write.ExitCode -ne 0) { return $write }
            $enable = Invoke-RegistryCommand -Command 'dotnet' -Arguments @('nuget', 'enable', 'source', $sourceName)
            [PSCustomObject]@{
                Output = @($write.Output, $enable.Output) | Where-Object { $_ } | Join-String -Separator "`n"
                ExitCode = $enable.ExitCode
            }
        }
        default { [PSCustomObject]@{ Output = "Unknown registry key: $RegistryKey"; ExitCode = 1 } }
    }
}

function Set-NpmRegistryApiUrls {
    $npmConfigs = @($toolsConfig.GetEnumerator() | Where-Object {
        $_.Value.VersionExtractor -eq 'npmDistTagLatest' -and $_.Value.NpmPackageName -and $_.Value.ApiUrl
    })
    if ($npmConfigs.Count -gt 0) {
        $fallbackConfig = $npmConfigs[0].Value
        $packageSuffix = [Uri]::EscapeDataString($fallbackConfig.NpmPackageName)
        $script:NpmRegistryResolution.Url = $fallbackConfig.ApiUrl.Substring(
            0,
            $fallbackConfig.ApiUrl.Length - $packageSuffix.Length
        ).TrimEnd('/')
    }
    if (-not (Test-CommandExists "npm")) {
        $script:NpmRegistryResolution.Details = 'npm was not found; using configured package endpoints.'
        return
    }

    try {
        $registryOutput = @(& npm config get registry 2>&1)
        $registryExitCode = $LASTEXITCODE
        if ($registryExitCode -ne 0) {
            throw "npm config get registry exited with code $registryExitCode. Output: $($registryOutput -join ' ')"
        }
        $registryValue = ($registryOutput | Select-Object -First 1).ToString().Trim()
        $registryUri = $null
        if (-not [Uri]::TryCreate($registryValue, [UriKind]::Absolute, [ref]$registryUri) -or
            $registryUri.Scheme -notin @('http', 'https')) {
            throw "npm returned an invalid registry URL: '$registryValue'"
        }

        $registryBaseUrl = $registryUri.AbsoluteUri.TrimEnd('/')
        $script:NpmRegistryResolution.Source = 'npm machine/user configuration'
        $script:NpmRegistryResolution.Url = $registryBaseUrl
        foreach ($toolName in $toolsConfig.Keys) {
            $config = $toolsConfig[$toolName]
            if ($config.VersionExtractor -eq "npmDistTagLatest" -and $config.NpmPackageName) {
                $packagePath = [Uri]::EscapeDataString($config.NpmPackageName)
                $config.ApiUrl = "$registryBaseUrl/$packagePath"
            }
        }
    } catch {
        $script:NpmRegistryResolution.Details = Get-DetailedErrorMessage $_
    }
}

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
    if ($extractor -eq 'azdGitHubTag') {
        $packageVersion = Get-WingetInstalledVersion -ToolName $ToolName -PackageId $config.WingetId
        if ($packageVersion) { return $packageVersion }
    }
    $outputStr = if ($Output -is [array]) { $Output -join "`n" } else { "$Output" }
    if ([string]::IsNullOrWhiteSpace($outputStr) -or $outputStr.Trim() -eq 'Unable to retrieve version') {
        return $null
    }

    switch ($extractor) {
        "azCliJson" {
            try   { ($outputStr | ConvertFrom-Json).'azure-cli' }
            catch { $null }
        }
        "azBicep" {
            # VersionParseRegex should be "Bicep CLI version\s+(\S+)"
            if ($config.VersionParseRegex -and $outputStr -match $config.VersionParseRegex) { $Matches[1] }
            else { $null }
        }
        # --- Add new VersionExtractor cases here ---
        default {
            # Use VersionParseRegex from JSON; fall back to stripping a leading 'v'
            $firstLine = ($outputStr -split "`n" | Select-Object -First 1).Trim()
            if ($config.VersionParseRegex -and $firstLine -match $config.VersionParseRegex) {
                $Matches[1]
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

    switch ($extractor) {
        "npmDistTagLatest" {
            $latest = if ($ApiData.'dist-tags') { $ApiData.'dist-tags'.latest } else { $null }
            if ($config.ProductionReleasesOnly -and -not (Test-IsProductionVersion $latest)) {
                return Get-LatestProductionNpmVersion -ApiData $ApiData
            }
            $latest
        }
        "azCliJson" {
            if ($ApiData.info -and $ApiData.info.version) { $ApiData.info.version } else { $null }
        }
        "azdGitHubTag" {
            if ($ApiData.tag_name -match '^azure-dev-cli_(.+)$') { $Matches[1] } else { $null }
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
#    RefreshMethod in JSON drives dispatch.
#    Add new refresh handlers in the switch.
# ─────────────────────────────────────────────

function Refresh-ToolVersion {
    param([string]$ToolName)
    try {
        if ($ToolName -eq "ncu global packages" -or $ToolName -like 'npm: *') {
            Refresh-NcuGlobalPackagesStatus
            return $true
        }

        # Dynamic tool names don't have a direct config entry — route by pattern.
        # (e.g. ".NET SDK 10.0.201" maps to the ".NET SDK" config + dotnet refresh)
        if ($ToolName -match '^\.NET SDK\s') { Refresh-DotNetVersion; return $true }

        $config = $toolsConfig[$ToolName]
        if (-not $config) { Write-Warning "  Tool configuration not found: $ToolName"; return $false }

        switch ($config.RefreshMethod) {
            "azure-cli" { Refresh-AzureCliVersion -ToolName $ToolName }
            "bicep"     { Refresh-BicepVersion    -ToolName $ToolName }
            "dotnet"    { Refresh-DotNetVersion }
            "pnpm"      { Refresh-PnpmVersion -ToolName $ToolName }
            "python"    { Refresh-PythonVersion   -ToolName $ToolName }
            # --- Add new refresh handlers here ---
            default     { Refresh-StandardVersion -ToolName $ToolName -Config $config }
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

function Refresh-AzureCliVersion {
    param([string]$ToolName)
    if (Test-CommandExists "az") {
        $json = az version --output json 2>$null | ConvertFrom-Json
        if ($json.'azure-cli') { $results.Tools[$ToolName].Installed = $json.'azure-cli' }
    }
}

function Refresh-BicepVersion {
    param([string]$ToolName)
    if (Test-CommandExists "az") {
        $out = az bicep version 2>$null
        $regex = $toolsConfig["Azure Bicep CLI"].VersionParseRegex
        $line = $out | Where-Object { $_ -match 'Bicep CLI' } | Select-Object -First 1
        if ($regex -and $line -match $regex) { $results.Tools[$ToolName].Installed = $Matches[1] }
    }
}

function Refresh-PnpmVersion {
    param([string]$ToolName)
    $config = $toolsConfig[$ToolName]
    $version = Get-GlobalNpmInstalledVersion -PackageName $config.NpmPackageName
    if ($version) {
        $results.Tools[$ToolName].Installed = $version
    } else {
        Refresh-StandardVersion -ToolName $ToolName -Config $config
    }
}

function Refresh-DotNetVersion {
    if (-not (Test-CommandExists "dotnet")) { return }
    $sdkList = dotnet --list-sdks 2>$null
    if (-not $sdkList) { return }
    $sdkRecords = ConvertFrom-DotNetSDKList -OutputLines $sdkList
    if ($sdkRecords.Count -eq 0) { return }

    # Rebuild installed-SDK inventory from scratch so stale versions disappear
    # and newly-installed patch releases show up.
    $staleKeys = @($results.Tools.Keys | Where-Object { $_ -like ".NET SDK*" })
    foreach ($k in $staleKeys) { $results.Tools.Remove($k) | Out-Null }
    $results.DotNetSDKs.Clear()

    # Re-fetch latest-per-channel so Latest / HighestInstalled are accurate
    # in the summary table after an upgrade (fixes blank Latest column when
    # multiple minor versions of the same major are installed).
    $cfg = $toolsConfig[".NET SDK"]
    $latestSdkByChannel = @{}
    if ($cfg -and $cfg.ApiUrl) {
        try {
            $releasesIndex = Invoke-RestMethod -Uri $cfg.ApiUrl -TimeoutSec $script:ApiRequestTimeout
            $releasePlan = Get-DotNetSDKReleasePlan -InstalledVersions @($sdkRecords.Version) -ReleasesIndex $releasesIndex -ProductionReleasesOnly $cfg.ProductionReleasesOnly
            $latestSdkByChannel = $releasePlan.LatestSdkByChannel
        } catch {
            # Network hiccup on refresh is non-fatal; leave Latest blank.
        }
    }

    $inventory = Get-DotNetSDKInventory -SdkRecords $sdkRecords -LatestSdkByChannel $latestSdkByChannel
    foreach ($entry in $inventory.DotNetSDKs.GetEnumerator()) { $results.DotNetSDKs[$entry.Key] = $entry.Value }
    foreach ($entry in $inventory.Tools.GetEnumerator()) { $results.Tools[$entry.Key] = $entry.Value }
    $byMajor = $inventory.ByMajor

    # Prune .NET items from Updates / AvailableUpdates that are now satisfied
    # (either the patch landed or an equal/higher SDK in the same channel is
    # already installed).
    $results.Updates = @($results.Updates | Where-Object {
        if ($_ -notmatch '^\.NET SDK:\s*(?<from>[\d.]+)\s*->\s*(?<to>[\d.]+)') { return $true }
        $from = $Matches.from; $to = $Matches.to
        $maj  = ($from -split '\.')[0]
        $hi   = if ($byMajor[$maj]) { ($byMajor[$maj] | Sort-Object { [version]$_ } | Select-Object -Last 1) } else { $null }
        -not ($hi -and [version]$hi -ge [version]$to)
    })
    $results.AvailableUpdates = @($results.AvailableUpdates | Where-Object {
        if ($_.Name -notmatch '^\.NET SDK\s+(?<from>[\d.]+)$') { return $true }
        $from = $Matches.from
        $maj  = ($from -split '\.')[0]
        if (-not $byMajor[$maj]) { return $true }
        $hi   = $byMajor[$maj] | Sort-Object { [version]$_ } | Select-Object -Last 1
        $lat  = $results.DotNetSDKs[$hi].Latest
        -not ($lat -and [version]$hi -ge [version]$lat)
    })
}

function Refresh-PythonVersion {
    param([string]$ToolName)
    if (-not (Test-CommandExists "py") -or -not $ToolName.StartsWith("Python")) { return }
    $major = ($results.Tools[$ToolName].Installed -split '\.')[0..1] -join '.'
    $out = py --list-paths 2>$null
    foreach ($line in $out) {
        if ($line.ToString().Trim() -match '^\s*(\d+\.\d+)\[?-?\d*\]?\s+.*Python\s+(\d+\.\d+\.\d+)') {
            if ($Matches[1] -eq $major) { $results.Tools[$ToolName].Installed = $Matches[2]; break }
        }
    }
}

function Refresh-NcuGlobalPackagesStatus {
    if ($results.GlobalNpmPackageUpdates.Count -eq 0) { return }
    foreach ($pkg in $results.GlobalNpmPackageUpdates) {
        $v = Get-GlobalNpmInstalledVersion -PackageName $pkg.Name
        if ($v) { $pkg.Current = $v; $pkg.Installed = $v; $pkg.Latest = $v }
    }
    $results.Updates = @($results.Updates | Where-Object { $_ -ne "ncu global packages" })
}

# ─────────────────────────────────────────────
# 6. CUSTOM TOOL CHECKERS
#    These handle tools whose check/update logic
#    is too complex for the standard framework.
#    To add a custom checker:
#      1. Add Tools/<catalog-id>.ps1 with a function
#         matching the JSON CustomFunction field.
#      2. Accept param([string]$Progress).
# ─────────────────────────────────────────────

# --- NCU Global npm packages -----------------------------------------------

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

function Test-NCUGlobal {
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

# --- Azure CLI Extensions ---------------------------------------------------

function Test-AzureExtensions {
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

# --- .NET SDK: multiple installed SDKs, channel grouping -------------------

function ConvertFrom-DotNetSDKList {
    param([Parameter(Mandatory)][array]$OutputLines)

    @($OutputLines | ForEach-Object {
        if ($_ -match '^\s*(?<Version>\S+)\s+\[(?<Path>.*)\]\s*$') {
            [PSCustomObject]@{ Version = $Matches.Version; Path = $Matches.Path }
        }
    })
}

function Get-DotNetSDKInventory {
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
        $sorted = @($byMajor[$major] | Sort-Object { [version]$_ })
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
            $tools[".NET SDK $version"] = @{ Installed = $version; Latest = $latest; HighestInstalled = $highest }
        }
    }

    [PSCustomObject]@{ DotNetSDKs = $dotNetSDKs; Tools = $tools; ByMajor = $byMajor }
}

function Get-DotNetSDKReleasePlan {
    param(
        [Parameter(Mandatory)][array]$InstalledVersions,
        [Parameter(Mandatory)]$ReleasesIndex,
        [bool]$ProductionReleasesOnly = $true
    )

    $latestSdkByChannel = @{}
    foreach ($channel in $ReleasesIndex.'releases-index') {
        if ($ProductionReleasesOnly -and $channel.'support-phase' -eq 'preview') { continue }
        if ($ProductionReleasesOnly -and -not (Test-IsProductionVersion $channel.'latest-sdk')) { continue }
        $latestSdkByChannel[$channel.'channel-version'] = @{
            LatestSdk = $channel.'latest-sdk'
            SupportPhase = $channel.'support-phase'
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
        $releaseAllowed = -not $ProductionReleasesOnly -or (
            $channel.'support-phase' -ne 'preview' -and (Test-IsProductionVersion $channel.'latest-sdk')
        )
        if ($releaseAllowed -and $channel.'support-phase' -ne 'eol' -and ($channel.'support-phase' -ne 'preview' -or $major -in $installedMajors)) {
            if ($major -notin $availableMajors) { $availableMajors += $major }
        }
    }

    [PSCustomObject]@{
        LatestSdkByChannel = $latestSdkByChannel
        ByMajor = $byMajor
        InstalledMajors = $installedMajors
        MaxInstalledMajor = $maxInstalledMajor
        NewerMajors = @($availableMajors | Where-Object { $_ -gt $maxInstalledMajor } | Sort-Object -Descending)
    }
}

function Test-DotNetSDKs {
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
        foreach ($entry in $inventory.DotNetSDKs.GetEnumerator()) { $results.DotNetSDKs[$entry.Key] = $entry.Value }
        foreach ($entry in $inventory.Tools.GetEnumerator()) { $results.Tools[$entry.Key] = $entry.Value }

        if ($SkipUpdate) { return }

        Write-Host "  Checking for .NET SDK updates..."
        $releasesIndex = Invoke-RestMethod -Uri $config.ApiUrl -TimeoutSec $script:ApiRequestTimeout
        $releasePlan = Get-DotNetSDKReleasePlan -InstalledVersions @($sdkRecords.Version) -ReleasesIndex $releasesIndex -ProductionReleasesOnly $config.ProductionReleasesOnly
        $latestSdkByChannel = $releasePlan.LatestSdkByChannel
        $byMajor = $releasePlan.ByMajor
        $latestSdkByMajor = @{}

        Write-Host "`n  Version Summary:"
        $maxLen = ($byMajor.Keys | ForEach-Object { ".NET $_".Length } | Measure-Object -Maximum).Maximum
        foreach ($maj in ($byMajor.Keys | Sort-Object { [int]$_ } -Descending)) {
            $sorted  = $byMajor[$maj] | Sort-Object { [version]$_ }
            $highest = $sorted | Select-Object -Last 1
            Write-Host ("    {0,-$maxLen} : {1}" -f ".NET $maj", ($sorted -join ', '))

            $chVer = ($highest -split '\.')[0..1] -join '.'
            if ($latestSdkByChannel.ContainsKey($chVer)) {
                $latestSdk = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                    Get-WingetLatestVersion -ToolName ".NET SDK $maj" -PackageId "Microsoft.DotNet.SDK.$maj"
                } else {
                    $latestSdkByChannel[$chVer].LatestSdk
                }
                if (-not $latestSdk) { continue }
                if ($config.ProductionReleasesOnly -and -not (Test-IsProductionVersion $latestSdk)) { continue }
                $latestSdkByMajor[$maj] = $latestSdk
                if ([version]$latestSdk -gt [version]$highest) {
                    Write-Warning "    .NET $highest -> $latestSdk (update available)"
                    $results.Updates += ".NET SDK: $highest -> $latestSdk"
                }
            }
        }

        $inventory = Get-DotNetSDKInventory -SdkRecords $sdkRecords -LatestSdkByChannel $latestSdkByChannel -LatestSdkByMajor $latestSdkByMajor
        foreach ($entry in $inventory.DotNetSDKs.GetEnumerator()) { $results.DotNetSDKs[$entry.Key] = $entry.Value }
        foreach ($entry in $inventory.Tools.GetEnumerator()) { $results.Tools[$entry.Key] = $entry.Value }

        # Newer major versions
        $maxInstalledMajor = $releasePlan.MaxInstalledMajor
        $newerMajorVersions = @{}
        $newerMajors = @($releasePlan.NewerMajors)
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            $newerMajors = @($newerMajors | Where-Object {
                $wingetVersion = Get-WingetLatestVersion -ToolName ".NET SDK $_" -PackageId "Microsoft.DotNet.SDK.$_"
                if ($wingetVersion) { $newerMajorVersions[$_] = $wingetVersion; $true } else { $false }
            })
        }
        foreach ($m in $newerMajors) {
            $versionLabel = if ($newerMajorVersions[$m]) { " (WinGet: $($newerMajorVersions[$m]))" } else { "" }
            Write-Warning "    Newer .NET major version available: $m$versionLabel (you have up to $maxInstalledMajor)"
            $results.Updates += ".NET SDK: Major version $m available"
        }

        if ($results.Updates -match '\.NET SDK') {
            foreach ($maj in $byMajor.Keys) {
                $highest = $byMajor[$maj] | Sort-Object { [version]$_ } | Select-Object -Last 1
                $latest  = $results.DotNetSDKs[$highest].Latest
                if ($latest -and $latest -ne "-" -and [version]$latest -gt [version]$highest) {
                    Add-AvailableUpdate -Name ".NET SDK $highest" -Command "winget upgrade Microsoft.DotNet.SDK.$maj --silent" -Type 'winget' -Details "$highest -> $latest"
                }
            }
            foreach ($m in $newerMajors) {
                $details = if ($newerMajorVersions[$m]) { "Latest in WinGet: $($newerMajorVersions[$m])" } else { 'New major version' }
                Add-AvailableUpdate -Name ".NET SDK $m (new major version)" -Command "winget install Microsoft.DotNet.SDK.$m --silent" -Type 'winget-new' -Details $details
            }
        } else {
            Write-Success "All .NET SDKs are up to date with their latest patches"
        }
    } catch {
        Write-Warning "  Could not check .NET SDK updates: $_"
        Write-Host "    Manual check: https://dotnet.microsoft.com/en-us/download/dotnet"
    }
}

# --- Python Install Manager: Windows AppX package behind py -----------------

function Test-PythonInstallManager {
    param([string]$Progress)
    $toolName = "Python Install Manager (py)"
    $config = Get-ToolConfiguration -ToolName $toolName -RequiredProperties @('PackageName', 'WingetId', 'UpdateCommand', 'UpdateType')
    Write-Header "Checking $toolName" -Progress $Progress

    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        Write-Warning "$toolName check skipped: Windows only"
        return
    }

    $package = Get-AppxPackage -Name $config.PackageName -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) {
        Write-Error "$toolName not installed"
        Add-NotInstalledTool $toolName
        return
    }

    $installedVersion = $package.Version.ToString()
    Write-Success "$toolName installed: $installedVersion"
    $results.Tools[$toolName] = @{ Installed = $installedVersion; Latest = "" }

    if ($SkipUpdate) { return }

    Write-Host "  Checking for $toolName updates..."
    $latestVersion = Get-WingetLatestVersion -ToolName $toolName -PackageId $config.WingetId
    if (-not (Set-LatestToolVersion -ToolNames $toolName -LatestVersion $latestVersion -ProductionReleasesOnly $config.ProductionReleasesOnly -VersionLabel 'WinGet version')) { return }

    if (Register-ToolUpdate -Name $toolName -InstalledVersion $installedVersion -LatestVersion $latestVersion -Command $config.UpdateCommand -Type $config.UpdateType) {
        Write-Warning "  $toolName has available updates in WinGet: $installedVersion -> $latestVersion"
        Write-Host "  Release notes: $($config.ReleaseNotesUrl)"
    } else {
        Write-Success "$toolName is up to date with WinGet"
    }
}

# --- Python: multiple installed versions via py launcher --------------------

function Test-Python {
    param([string]$Progress)
    $config = Get-ToolConfiguration -ToolName 'Python' -RequiredProperties @('UpdateCommand', 'UpdateType')
    Write-Header "Checking Python" -Progress $Progress

    if (Test-CommandExists "py") {
        Write-Success "Python Installation Manager (py) found"
        try {
            $installed = py list 2>&1
            if ($installed) {
                $installedVersions = ConvertFrom-PythonLauncherList -OutputLines $installed
                Write-Host "  Installed Python versions:"
                foreach ($version in $installedVersions) {
                    $defaultLabel = if ($version.IsDefault) { ' (default)' } else { '' }
                    Write-Host "    - Python $($version.Version)$defaultLabel"
                    $results.Tools["Python $($version.Channel)"] = @{ Installed = $version.Version; Latest = "" }
                }
                if (-not $SkipUpdate) { Get-PythonUpdateViaPy -InstalledVersions $installedVersions }
            }
        } catch { Write-Warning "Unable to list Python versions via py: $_" }
    } elseif (Test-CommandExists "python") {
        $ver = (Get-CommandVersion "python" "--version") -replace 'Python ', '' | ForEach-Object { $_.Trim() }
        Write-Success "Python installed: $ver"
        $maj = ($ver -split '\.')[0..1] -join '.'
        $results.Tools["Python $maj"] = @{ Installed = $ver; Latest = "" }
        if (-not $SkipUpdate) { Get-PythonUpdateConventional -InstalledVersion $ver }
    } elseif (Test-CommandExists "python3") {
        $ver = (Get-CommandVersion "python3" "--version") -replace 'Python ', '' | ForEach-Object { $_.Trim() }
        Write-Success "Python3 installed: $ver"
        $maj = ($ver -split '\.')[0..1] -join '.'
        $results.Tools["Python $maj"] = @{ Installed = $ver; Latest = "" }
        if (-not $SkipUpdate) { Get-PythonUpdateConventional -InstalledVersion $ver }
    } else {
        Write-Error "Python not installed"; Add-NotInstalledTool "Python"
    }
}

function ConvertFrom-PythonLauncherList {
    param(
        [Parameter(Mandatory)][array]$OutputLines,
        [switch]$Online
    )

    @($OutputLines | ForEach-Object {
        $line = $_.ToString()
        if ($line -match '^\s*(?<Channel>\d+\.\d+)\[?-?\d*\]?\s+(?<Default>\*)?\s*Python\s+(?<Version>\d+\.\d+\.\d+)') {
            [PSCustomObject]@{
                Channel = $Matches.Channel
                Version = $Matches.Version
                IsDefault = [bool]$Matches.Default
            }
        } elseif ($line -match '^\s*-V:(?<Channel>\d+\.\d+)(?<Suffix>-\d+)?\s*(?<Default>\*)?') {
            $version = if ($Online) {
                $patch = if ($Matches.Suffix) { $Matches.Suffix -replace '-', '.' } else { '.0' }
                "$($Matches.Channel)$patch"
            } else {
                "$($Matches.Channel)$($Matches.Suffix)"
            }
            [PSCustomObject]@{
                Channel = $Matches.Channel
                Version = $version
                IsDefault = [bool]$Matches.Default
            }
        }
    })
}

function Get-PythonLauncherUpdatePlan {
    param(
        [Parameter(Mandatory)][array]$InstalledVersions,
        [Parameter(Mandatory)][array]$AvailableVersions
    )

    $installedByChannel = @{}
    foreach ($version in $InstalledVersions) {
        $installedByChannel[$version.Channel] = $version.Version
    }
    $latestByChannel = @{}
    foreach ($version in $AvailableVersions) {
        if (-not $latestByChannel.ContainsKey($version.Channel) -or [version]$version.Version -gt [version]$latestByChannel[$version.Channel]) {
            $latestByChannel[$version.Channel] = $version.Version
        }
    }

    $updates = @()
    foreach ($channel in $installedByChannel.Keys) {
        $installed = $installedByChannel[$channel] -replace '-', '.'
        if ($installed -notmatch '^\d+\.\d+\.\d+$') { $installed = "$installed.0" }
        if ($latestByChannel.ContainsKey($channel) -and [version]$latestByChannel[$channel] -gt [version]$installed) {
            $updates += [PSCustomObject]@{
                Channel = $channel
                Installed = $installedByChannel[$channel]
                Latest = $latestByChannel[$channel]
            }
        }
    }

    $highestInstalledChannel = @($installedByChannel.Keys | Sort-Object { [version]$_ } | Select-Object -Last 1)
    $newerChannel = if ($highestInstalledChannel.Count -gt 0) {
        $latestByChannel.Keys |
            Where-Object { [version]$_ -gt [version]$highestInstalledChannel[0] } |
            Sort-Object { [version]$_ } -Descending |
            Select-Object -First 1
    } else {
        $null
    }

    [PSCustomObject]@{
        InstalledByChannel = $installedByChannel
        LatestByChannel = $latestByChannel
        Updates = $updates
        NewerChannel = $newerChannel
    }
}

function Get-PythonUpdateViaPy {
    param([Parameter(Mandatory)][array]$InstalledVersions)
    Write-Host "  Checking for Python updates via py --list-online..."
    try {
        $online = py list --online 2>&1
        if (-not $online) { return }
        $availableVersions = ConvertFrom-PythonLauncherList -OutputLines $online -Online
        $plan = Get-PythonLauncherUpdatePlan -InstalledVersions $InstalledVersions -AvailableVersions $availableVersions

        $found = $false
        foreach ($channel in $plan.InstalledByChannel.Keys) {
            if ($plan.LatestByChannel.ContainsKey($channel)) { $results.Tools["Python $channel"].Latest = $plan.LatestByChannel[$channel] }
        }
        foreach ($update in $plan.Updates) {
            Write-Warning "  Python $($update.Channel) has update available: $($update.Installed) -> $($update.Latest)"
            $results.Updates += "Python $($update.Channel)"; $found = $true
            Add-AvailableUpdate -Name "Python $($update.Channel)" -Command "py install $($update.Channel) --update --quiet" -Type 'py' -Details "$($update.Installed) -> $($update.Latest)"
        }
        if (-not $found) { Write-Success "All Python versions are up to date" }
        if ($plan.NewerChannel) {
            Write-Warning "  Newer Python major version available: $($plan.NewerChannel) (latest: $($plan.LatestByChannel[$plan.NewerChannel]))"
        }
    } catch { Write-Warning "  Could not check Python updates: $_" }
}

function Get-PythonUpdateConventional {
    param([string]$InstalledVersion)
    $config = $toolsConfig["Python"]
    Write-Host "  Checking for Python updates..."
    try {
        $major = ($InstalledVersion -split '\.')[0..1] -join '.'
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            $latest = Get-WingetLatestVersion -ToolName "Python $major" -PackageId "Python.Python.$major"
            if ($config.ProductionReleasesOnly -and -not (Test-IsProductionVersion $latest)) { $latest = $null }
            if ($latest) {
                $results.Tools["Python $major"].Latest = $latest
            }
        } else {
            $releases = Invoke-RestMethod -Uri $config.ApiUrl -TimeoutSec $script:ApiRequestTimeout
            $match = $releases | Where-Object { $_.cycle -eq $major } | Select-Object -First 1
            $latest = if ($match) { $match.latest } else { $null }
            if ($config.ProductionReleasesOnly -and -not (Test-IsProductionVersion $latest)) { $latest = $null }
            if ($latest) { $results.Tools["Python $major"].Latest = $latest }
        }
        if ($latest) {
            if ([version]$latest -gt [version]$InstalledVersion) {
                $sourceLabel = if ($IsWindows -or $env:OS -eq 'Windows_NT') { ' in WinGet' } else { '' }
                Write-Warning "  Python $major has update available${sourceLabel}: $InstalledVersion -> $latest"
                $results.Updates += "Python $major"
                if (!$SkipUpdate) {
                    Add-AvailableUpdate -Name "Python $major" -Command ($config.UpdateCommand -replace '\{version\}',$major) -Type $config.UpdateType -Details "$InstalledVersion -> $latest"
                }
            } else { Write-Success "Python $major is up to date" }
        }
        if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
            $newerMajors = $releases | Where-Object { $_.eol -eq $false -and [double]$_.cycle -gt [double]$major } | Sort-Object { [double]$_.cycle } -Descending | Select-Object -First 1
            if ($newerMajors) { Write-Warning "  Newer Python major version available: $($newerMajors.cycle) (latest: $($newerMajors.latest))" }
        }
    } catch { Write-Warning "  Could not check Python updates: $_" }
}

# --- PowerShell: reports both Windows PS and Core ---------------------------

function Test-PowerShell {
    param([string]$Progress)
    $config = Get-ToolConfiguration -ToolName 'PowerShell' -RequiredProperties @('Command', 'ApiUrl', 'UpdateCommand', 'UpdateType')
    Write-Header "Checking PowerShell" -Progress $Progress

    $currentVersion = $PSVersionTable.PSVersion
    Write-Success "Current PowerShell: $currentVersion"
    $results.Tools["PowerShell"] = @{ Installed = $currentVersion.ToString(); Latest = "" }

    if (Test-CommandExists "pwsh") {
        $pwshVersion = (Get-CommandVersion "pwsh" "--version") -replace 'PowerShell ', ''
        Write-Success "PowerShell Core installed: $pwshVersion"
        $results.Tools["PowerShell Core"] = @{ Installed = $pwshVersion; Latest = "" }
        if ($SkipUpdate) { return }

        Write-Host "  Checking for PowerShell updates..."
        try {
            $latestVersion = if (($IsWindows -or $env:OS -eq 'Windows_NT') -and $config.WingetId) {
                Get-WingetLatestVersion -ToolName 'PowerShell' -PackageId $config.WingetId
            } else {
                $releases = Invoke-RestMethod -Uri $config.ApiUrl -TimeoutSec $script:ApiRequestTimeout
                $releases.tag_name -replace 'v', ''
            }
            $latestToolNames = @('PowerShell')
            if ($results.Tools['PowerShell Core']) { $latestToolNames += 'PowerShell Core' }
            if (-not (Set-LatestToolVersion -ToolNames $latestToolNames -LatestVersion $latestVersion -ProductionReleasesOnly $config.ProductionReleasesOnly)) { return }

            if (Register-ToolUpdate -Name 'PowerShell' -InstalledVersion $pwshVersion -LatestVersion $latestVersion -Command $config.UpdateCommand -Type $config.UpdateType) {
                $sourceLabel = if ($IsWindows -or $env:OS -eq 'Windows_NT') { ' in WinGet' } else { '' }
                Write-Warning "  PowerShell has available updates${sourceLabel}: $pwshVersion -> $latestVersion"
                Write-Host "  Release notes: $($config.ReleaseNotesUrl)"
            } else { Write-Success "PowerShell is up to date" }
        } catch { Write-Warning "  Could not fetch latest PowerShell version: $_" }
    } else {
        Write-Warning "PowerShell Core (pwsh) not installed"
    }
}

# --- WSL: installed package vs latest allowed release -----------------------

function Test-WSL {
    param([string]$Progress)
    $config = Get-ToolConfiguration -ToolName 'WSL' -RequiredProperties @('Command', 'VersionCommand', 'VersionParseRegex', 'ApiUrl', 'UpdateCommand', 'UpdateType')
    Write-Header "Checking WSL" -Progress $Progress

    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        Write-Warning "WSL check skipped: Windows only"
        return
    }

    if (-not (Test-CommandExists $config.Command)) {
        Write-Error "WSL not installed"
        Add-NotInstalledTool "WSL"
        return
    }

    try { $versionOutput = Invoke-Expression "$($config.VersionCommand) 2>&1" | Out-String }
    catch { $versionOutput = "" }

    if (-not ($versionOutput -match $config.VersionParseRegex)) {
        Write-Warning "Could not parse WSL version from wslc -v"
        $results.Tools["WSL"] = @{ Installed = "unknown"; Latest = "" }
        return
    }

    $installedVersion = ConvertTo-CanonicalSemanticVersion $Matches[1]
    Write-Success "WSL installed: $installedVersion"
    $results.Tools["WSL"] = @{ Installed = $installedVersion; Latest = "" }

    if ($SkipUpdate) { return }

    Write-Host "  Checking for WSL updates..."
    $releases = Invoke-SafeApiRequest -Uri $config.ApiUrl
    $allowedReleases = @($releases) | Where-Object {
        -not $_.draft -and (-not $config.ProductionReleasesOnly -or (
            -not $_.prerelease -and (Test-IsProductionVersion $_.tag_name)
        ))
    }
    $versionedReleases = foreach ($release in $allowedReleases) {
        $versionText = "$($release.tag_name)" -replace '^v', ''
        $semanticVersion = $null
        if ([version]::TryParse($versionText, [ref]$semanticVersion)) {
            [PSCustomObject]@{
                Release         = $release
                SemanticVersion = $semanticVersion
                VersionText     = $versionText
            }
        }
    }
    $latestVersionedRelease = $versionedReleases |
        Sort-Object -Property @(
            @{ Expression = { $_.SemanticVersion }; Descending = $true }
            @{ Expression = { [DateTimeOffset]$_.Release.published_at }; Descending = $true }
        ) |
        Select-Object -First 1

    if (-not $latestVersionedRelease) {
        Write-Warning "  Could not determine latest semantic WSL release"
        return
    }

    $latestRelease = $latestVersionedRelease.Release
    $latestVersion = ConvertTo-CanonicalSemanticVersion $latestVersionedRelease.VersionText
    $results.Tools["WSL"].Latest = $latestVersion

    if (Register-ToolUpdate -Name 'WSL' -InstalledVersion $installedVersion -LatestVersion $latestVersion -Command $config.UpdateCommand -Type $config.UpdateType) {
        $releaseType = if ($latestRelease.prerelease) { "prerelease" } else { "release" }
        Write-Warning "  WSL $releaseType available: $installedVersion -> $latestVersion"
    } else {
        Write-Success "WSL is up to date"
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
        if ($ToolName -eq 'uv' -and ($IsWindows -or $env:OS -eq 'Windows_NT')) {
            return 'winget install --id astral-sh.uv -e --source winget --silent --disable-interactivity --force'
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

function Invoke-UvWindowsInstall {
    $output = [System.Collections.Generic.List[string]]::new()

    try {
        if (-not (Test-CommandExists 'winget')) {
            return @{ Output = 'winget is required to install uv on Windows.'; ExitCode = 1 }
        }

        $uvCommands = @(Get-Command uv -All -ErrorAction SilentlyContinue)
        $uvPaths = @($uvCommands | ForEach-Object Source | Where-Object { $_ } | Select-Object -Unique)

        if ($uvPaths -match '\\pipx\\' -and (Test-CommandExists 'pipx')) {
            $pipxOutput = pipx uninstall uv 2>&1 | Out-String
            if ($pipxOutput) { $output.Add($pipxOutput.Trim()) }
        }
        if ($uvPaths -match '\\.cargo\\bin\\' -and (Test-CommandExists 'cargo')) {
            $cargoOutput = cargo uninstall uv 2>&1 | Out-String
            if ($cargoOutput) { $output.Add($cargoOutput.Trim()) }
        }

        $uninstall = Invoke-ToolCommand -Command 'winget uninstall --id astral-sh.uv -e --silent --disable-interactivity' -Type 'winget'
        if ($uninstall.Output) { $output.Add($uninstall.Output) }

        foreach ($binDirectory in @(
            (Join-Path $env:USERPROFILE '.local\bin'),
            (Join-Path $env:USERPROFILE '.cargo\bin')
        )) {
            foreach ($binary in @('uv.exe', 'uvx.exe', 'uvw.exe')) {
                $binaryPath = Join-Path $binDirectory $binary
                if (Test-Path -LiteralPath $binaryPath) {
                    Remove-Item -LiteralPath $binaryPath -Force -ErrorAction Stop
                    $output.Add("Removed $binaryPath")
                }
            }
        }

        $install = Invoke-ToolCommand -Command 'winget install --id astral-sh.uv -e --source winget --silent --disable-interactivity --force' -Type 'winget'
        if ($install.Output) { $output.Add($install.Output) }
        return @{ Output = ($output -join "`n"); ExitCode = $install.ExitCode }
    } catch {
        $output.Add((Get-DetailedErrorMessage $_))
        return @{ Output = ($output -join "`n"); ExitCode = 1 }
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
        return Invoke-UvWindowsInstall
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

function Complete-RegistryExecution {
    param(
        [Parameter(Mandatory)][object]$Action,
        [Parameter(Mandatory)][object]$Execution
    )

    $outputText = @($Execution.Output) -join "`n"
    $exitCode = if ($null -ne $Execution.ExitCode) { [int]$Execution.ExitCode } else { 1 }
    if ($outputText) { Write-Host $outputText.TrimEnd() }
    if ($exitCode -eq 0) {
        Write-Success "Registry aligned: $($Action.Name)"
        return $true
    }

    $message = "Registry alignment failed for $($Action.Name). $outputText"
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
        'Test-IsProductionVersion','Set-LatestToolVersion','Get-LatestProductionNpmVersion','Get-LatestMatureNpmRelease','ConvertFrom-DotNetSDKList','Get-DotNetSDKInventory','Get-DotNetSDKReleasePlan',
        'Invoke-SafeApiRequest','Add-NotInstalledTool','Add-AvailableUpdate','Register-ToolUpdate','Get-WingetInstalledVersion','Get-WingetLatestVersion',
        'Test-StandardTool','Get-InstalledVersionFromOutput','Get-LatestVersionFromApi','Get-UpdateCommand','Get-StandardToolUpdates',
        'Parse-NpmInstallCommand','ConvertFrom-NcuGlobalOutput','Get-GlobalNpmInstalledVersion','Get-NpmVersionReleaseInfo',
        'ConvertFrom-PythonLauncherList','Get-PythonLauncherUpdatePlan','Get-PythonUpdateViaPy','Get-PythonUpdateConventional'
    )
    $functionNames += @($ToolsConfiguration.Values | Where-Object { $_.CheckType -eq 'custom' } | ForEach-Object { $_.CustomFunction })

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($ScriptContent, [ref]$null, [ref]$null)
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

    Write-Host ""
    foreach ($line in Get-ApplicationBannerLines -Version $script:ToolCheckerVersion) {
        Write-Host "$ColorCyan$line$ColorReset"
    }
    Write-Host ""

    $isElevated = Test-IsAdministrator
    Write-Host "  Process elevated     : $(if ($isElevated) { 'Yes' } else { 'No' })"

    if ($SkipUpdate) { Write-Warning "Running in check-only mode (updates disabled)" }
    if ($Force)      { Write-Warning "Running with automatic update (no prompts)" }

    Write-Host "  Registry policy file : $resolvedEnvFile"
    Write-Host "  Selected tool count  : $($toolsConfig.Count)/$($catalogToolIds.Count)"
    Test-RegistryConfiguration -EnvironmentConfig $script:RegistryEnvironment

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

    Write-Host "  -----------------------------------"
    Write-Host ""

    $total = $checks.Count
    Write-Host "  Running $total checks in parallel (${Timeout}s timeout)...`n"
    Invoke-ParallelChecks -Checks $checks -Total $total -TimeoutSec $Timeout

    # Summary
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
    $availableUpdateNames = @($results.Updates | Where-Object { $_ -notin $results.MaturityBlockedUpdates.Name })
    if ($availableUpdateNames.Count -gt 0) {
        Write-Host "`n$ColorYellow⚠ Updates Available ($($availableUpdateNames.Count)):$ColorReset"
        $availableUpdateNames | ForEach-Object { Write-Host "  - $_" }
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
