#Requires -Version 7.0
<#
.SYNOPSIS
    Checks installation status and available updates for development tools.
.DESCRIPTION
    Loads selected catalog tools and their explicit infrastructure dependencies.
.PARAMETER SkipUpdate
    Only check status; do not offer or execute updates. Alias: CheckOnly.
.PARAMETER Force
    Execute available tool updates automatically. Registry changes still require approval.
.PARAMETER Timeout
    Maximum seconds allowed for each tool check. Default: 60.
.PARAMETER CooldownDays
    Override the catalog release cooldown with a nonnegative number of full days.
.PARAMETER EnvFile
    Optional registry policy and tool-selection file. Defaults to the sibling .env.
.PARAMETER Version
    Print the application version without loading configuration or infrastructure.
.EXAMPLE
    .\tool-checker.ps1 -SkipUpdate
.EXAMPLE
    .\tool-checker.ps1 -Force -CooldownDays 8
#>
param(
    [Alias('CheckOnly')][switch]$SkipUpdate,
    [switch]$Force,
    [int]$Timeout = 60,
    [ValidateRange(0, 2147483647)][int]$CooldownDays,
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
    [switch]$Version
)

$script:ToolCheckerVersion = '2.0.0'
$script:ApiRequestTimeout = $Timeout
$script:IsDotSourced = $MyInvocation.InvocationName -eq '.'
if ($Version) {
    Write-Output $script:ToolCheckerVersion
    return
}

if (-not $script:IsDotSourced) {
    Clear-Host
}

# Load the fixed, definition-only infrastructure independently of tool selection.
foreach ($infrastructure in @('configuration','output','results','runtime','versions','checks','actions','parallel','package-managers','registry')) {
    $path = Join-Path $PSScriptRoot "Infra/$infrastructure.ps1"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $label = (Get-Culture).TextInfo.ToTitleCase($infrastructure)
        throw "$label infrastructure file not found: $path"
    }
    . $path
}

# Initialize shared state explicitly; dot-sourced use stops before running checks.
Initialize-ConsoleColors
$script:PlatformKey = Get-PlatformKey
$results = New-ToolCheckResults

$configPath = Join-Path $PSScriptRoot 'tool-checker.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Error "tool-checker.json not found at: $configPath"
    exit 1
}
# Readers return a snapshot; only bootstrap publishes it to the shared runtime scope.
$configuration = Read-ToolCheckerConfiguration -ConfigPath $configPath -EnvFile $EnvFile `
    -HasCooldownOverride $PSBoundParameters.ContainsKey('CooldownDays') -CooldownDays $CooldownDays
$toolsConfig = $configuration.ToolsConfiguration
$catalogToolIds = $configuration.CatalogToolIds
$resolvedEnvFile = $configuration.ResolvedEnvFile
$script:RegistryEnvironment = $configuration.RegistryEnvironment
$script:ReleaseCooldownDays = $configuration.CooldownDays

# Register selected dependencies, exposing helpers but keeping operation names local.
$script:ToolDefinitionFiles = @(Get-ToolDefinitionFiles -ToolsConfiguration $toolsConfig -Directory (Join-Path $PSScriptRoot 'Tools'))
$script:ToolDefinitions = Read-DefinitionRegistry -Files $script:ToolDefinitionFiles
$script:PackageManagerDefinitions = Read-DefinitionRegistry -Files @(Get-PackageManagerDefinitionFiles -ToolsConfiguration $toolsConfig -Directory (Join-Path $PSScriptRoot 'Infra/PackageManagers'))
foreach ($definitions in $script:PackageManagerDefinitions.Values) {
    $sharedDefinitions = @($definitions.Keys | Where-Object { $_ -notlike '*-PackageManager' } | ForEach-Object { $definitions[$_] })
    . ([scriptblock]::Create(($sharedDefinitions -join "`n`n")))
}
Initialize-RegistryContext -ResolveEndpoints:(-not $script:IsDotSourced)

function Main {
    # Checks produce inventory/action plans; rendering does not decide eligibility.
    Assert-ToolConfigurations
    Show-StartupInformation -IsElevated (Test-IsAdministrator)
    Test-RegistryConfiguration -EnvironmentConfig $script:RegistryEnvironment
    Show-RegistryMetadata

    $checks = @(Get-ConfiguredChecks)
    Show-CheckProgressHeader -Total $checks.Count -TimeoutSec $Timeout
    Invoke-ParallelChecks -Checks $checks -Total $checks.Count -TimeoutSec $Timeout
    $availableUpdateNames = @($results.Updates | Where-Object { $_ -notin $results.MaturityBlockedUpdates.Name })
    Show-ResultsSummary -AvailableUpdateNames $availableUpdateNames

    if (@(Get-AvailableActions).Count -eq 0) {
        Write-Host "`nNothing to do. Exiting.`n"
        return
    }

    # Automatic tool updates never imply approval to change package registries.
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

if (-not $script:IsDotSourced) {
    Main
    if ($results.Errors.Count -gt 0 -or $results.UpdateFailed.Count -gt 0) { exit 1 }
}