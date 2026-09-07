# Catalog/env parsing, selection, defaults, and validation. Readers return snapshots
# without loading tools or publishing shared state; bootstrap owns those later steps.
function Get-ToolSortKey {
    param([string]$ToolName, [object]$Configuration, [object]$Row)
    $group = if ($Configuration.SortGroup) { $Configuration.SortGroup } else { $ToolName }
    $order = if ($Configuration.SortOrder) { $Configuration.SortOrder } else { 0 }
    $version = $null
    # Invert padded numeric components to sort versions descending within a text key.
    if ($Configuration.SortVersionsDescending -and [version]::TryParse("$($Row.Installed)", [ref]$version)) {
        return "$group|$order|{0:D10}.{1:D10}.{2:D10}" -f (
            [int]::MaxValue - $version.Major
        ), ([int]::MaxValue - $version.Minor), ([int]::MaxValue - [Math]::Max(0, $version.Build))
    }
    "$group|$order|$ToolName"
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
    } | Sort-Object { Get-ToolSortKey -ToolName $_.Name -Configuration $_.Configuration })

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
    # Parse optional assignments as data; never evaluate shell expressions or set env vars.
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

function Read-ToolCheckerConfiguration {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$EnvFile,
        [bool]$HasCooldownOverride = $false,
        [ValidateRange(0, 2147483647)][int]$CooldownDays
    )

    $toolsConfig = [ordered]@{}
    $toolsJson = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $catalogCooldownDays = $toolsJson.settings.CooldownDays
    # Validate the catalog even with an override; explicit presence makes zero meaningful.
    if (($catalogCooldownDays -isnot [int] -and $catalogCooldownDays -isnot [long]) -or
        $catalogCooldownDays -lt 0 -or $catalogCooldownDays -gt [int]::MaxValue) {
        throw 'Catalog settings.CooldownDays must be a nonnegative integer no greater than 2147483647.'
    }
    $resolvedCooldownDays = if ($HasCooldownOverride) { $CooldownDays } else { [int]$catalogCooldownDays }
    $resolvedEnvFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile)
    $registryEnvironment = Read-DotEnvFile -Path $resolvedEnvFile
    $requestedToolIds = @()
    if ($registryEnvironment.Contains('TOOL_CHECKER_TOOLS') -and $registryEnvironment.TOOL_CHECKER_TOOLS) {
        $requestedToolIds = @($registryEnvironment.TOOL_CHECKER_TOOLS -split ',' |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Where-Object { $_ } |
            Select-Object -Unique)
    }

    $catalogSelection = Get-ToolCatalogSelection -Tools $toolsJson.tools -RequestedToolIds $requestedToolIds
    foreach ($catalogEntry in $catalogSelection.SelectedEntries) {
        $toolName = "$($catalogEntry.Name)"
        $jsonTool = $catalogEntry.Configuration
        $toolEntry = @{}
        foreach ($prop in $jsonTool.PSObject.Properties) {
            if ($prop.Name -eq "InstallCommands") {
                $ordered = [ordered]@{}
                foreach ($property in $prop.Value.PSObject.Properties) { $ordered[$property.Name] = $property.Value }
                $toolEntry["InstallCommands"] = $ordered
            } else {
                $toolEntry[$prop.Name] = $prop.Value
            }
        }
        $toolEntry['Id'] = $catalogEntry.Id
        # Default only missing keys so an explicit false value survives configuration loading.
        if (-not $toolEntry.ContainsKey('ProductionReleasesOnly')) {
            $toolEntry['ProductionReleasesOnly'] = $true
        }
        if (-not $toolEntry.ContainsKey('Enabled')) {
            $toolEntry['Enabled'] = $true
        }
        $toolsConfig[$toolName] = $toolEntry
    }

    [PSCustomObject]@{
        ToolsConfiguration = $toolsConfig
        CatalogToolIds = $catalogSelection.CatalogToolIds
        ResolvedEnvFile = $resolvedEnvFile
        RegistryEnvironment = $registryEnvironment
        CooldownDays = $resolvedCooldownDays
    }
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
    # Run after selected definitions are registered so custom entry points can be verified.
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
            $requiredProperties += @($config.RequiredProperties | Where-Object { $_ })
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