# Runtime discovery and tool dispatch. Definitions are loaded by bootstrap; tool
# code runs only through the selected catalog ID, never through a folder scan.
function Test-IsWindowsPlatform { $IsWindows -or $env:OS -eq 'Windows_NT' }

function Get-PlatformConfigurationValue {
    # A Windows<Property> override wins on Windows; otherwise the base property applies.
    param([object]$Configuration, [string]$Property)
    if ((Test-IsWindowsPlatform) -and $Configuration["Windows$Property"]) { return $Configuration["Windows$Property"] }
    $Configuration[$Property]
}

function Get-PlatformKey {
    $os = if (Test-IsWindowsPlatform) { 'Windows' } else { 'Linux' }
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
        if ($config.CheckType -eq 'custom') {
            $command = "Invoke-ToolEntryPoint -ToolId '$($config.Id)' -EntryPoint 'Test-Tool' -Arguments @{ Progress = `$args[0] }"
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
            throw "Tool '$($config.Id)' requires ToolFile to be a .ps1 filename directly under tools/."
        }
        $toolPath = Join-Path $Directory $config.ToolFile
        if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
            throw "Tool file '$($config.ToolFile)' configured for '$($config.Id)' was not found in tools/."
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

function Get-InfrastructureDefinitions {
    # Read source text, not live Get-Command bodies that tests may have mocked.
    param([Parameter(Mandatory)][string[]]$Names)
    $files = @('configuration','output','results','runtime','versions','checks','actions','parallel','package-managers','registry')
    $source = ($files | ForEach-Object { Get-Content -LiteralPath (Join-Path $PSScriptRoot "$_.ps1") -Raw }) -join "`n"
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    $definitions = @{}
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $definitions[$statement.Name] = $statement.Extent.Text }
    }
    # A renamed or removed helper must fail startup, not silently break a worker.
    $missing = @($Names | Where-Object { -not $definitions.ContainsKey($_) })
    if ($missing.Count -gt 0) { throw "Worker infrastructure function(s) not found: $($missing -join ', ')" }
    $Names | ForEach-Object { $definitions[$_] }
}

function Test-CommandExists {
    param([string]$Command)
    $null = Get-Command $Command -ErrorAction SilentlyContinue
    return $?
}

function Test-IsAdministrator {
    if (Test-IsWindowsPlatform) {
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
