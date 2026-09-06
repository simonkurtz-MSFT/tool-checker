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