#Requires -Version 7.0

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
