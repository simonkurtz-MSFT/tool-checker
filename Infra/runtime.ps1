# Runtime discovery and tool dispatch. Definitions are loaded by bootstrap; tool
# code runs only through the selected catalog ID, never through a folder scan.
function Get-PlatformKey {
    $os = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Windows' } else { 'Linux' }
    $cpu = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $arch = if ($cpu -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'arm64' } else { 'amd64' }
    "$os ($arch)"
}

function Get-ConfiguredChecks {
    # Store runnable text rather than closures so workers use their own state snapshot.
    foreach ($toolName in $toolsConfig.Keys) {
        $config = $toolsConfig[$toolName]
        if (-not $config.Enabled) { continue }
        $escapedName = $toolName.Replace("'", "''")
        if ($config.CheckType -eq 'custom' -and $config.CustomFunction) {
            $command = if ($script:ToolDefinitions.ContainsKey($config.Id)) {
                "Invoke-ToolEntryPoint -ToolId '$($config.Id)' -EntryPoint 'Test-Tool' -Arguments @{ Progress = `$args[0] }"
            } else { "$($config.CustomFunction) -Progress `$args[0]" }
            @{ Name = $toolName; ToolId = $config.Id; Block = [scriptblock]::Create($command) }
        } elseif ($config.CheckType -eq 'standard') {
            @{ Name = $toolName; ToolId = $config.Id; Block = [scriptblock]::Create("Test-StandardTool -ToolName '$escapedName' -Progress `$args[0]") }
        }
    }
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

function Invoke-ToolEntryPoint {
    param(
        [Parameter(Mandatory)][string]$ToolId,
        [Parameter(Mandatory)][ValidateSet('Test-Tool', 'Refresh-ToolStatus', 'Invoke-ToolInstall', 'Invoke-ToolUpdate', 'Get-ToolOutcome', 'Compare-ToolVersions')][string]$EntryPoint,
        [hashtable]$Arguments = @{}
    )

    $definitions = $script:ToolDefinitions[$ToolId]
    if (-not $definitions -or -not $definitions.ContainsKey($EntryPoint)) {
        throw "Tool '$ToolId' does not define entry point '$EntryPoint'."
    }
    # Local dot-sourcing lets tools reuse public names without leaking into the caller.
    . ([scriptblock]::Create(($definitions.Values -join "`n`n")))
    $previousRows = $results.Tools.Clone()
    # Even a partially failed check may have created rows that need an owner.
    try { & $EntryPoint @Arguments }
    finally { Set-ToolResultOwnership -ToolId $ToolId -PreviousRows $previousRows }
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
