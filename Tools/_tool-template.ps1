#Requires -Version 7.0
<#
.SYNOPSIS
    Template for tool-specific behavior. Not a runtime tool file.

.DESCRIPTION
    Copy to a .ps1 file directly under Tools/ and set the catalog ToolFile to its
    filename (for example, "ToolFile": "example-sdk.ps1"). Prefer <catalog-id>.ps1
    for clarity, but the filename is explicitly configured, never inferred.
    Replace Example CLI with the catalog Name; keep public function names unchanged.
    Set CustomFunction to Test-Tool for a custom catalog entry.
    Standard entries need a file only when they have specialized behavior.

    Public entry points use the same tool-agnostic names in every file:
    - Test-Tool - checker; accepts [string]$Progress.
    - Refresh-ToolStatus - optional post-action inventory refresh.
    - Invoke-ToolInstall - optional specialized installer.
    - Invoke-ToolUpdate - optional specialized updater.
    Keep platform-specific details behind these names, not in public names.
    Action parameters and results must match the main script's dispatcher.

    Put public functions in '#region Public entry points' and private helpers in
    '#region Private helpers'. Private names may vary; prefer tool-qualified names
    for clarity. Only this tool's implementation and tests should call them.
    Invoke-ToolEntryPoint dispatches by catalog ID and dot-sources the registered
    definitions into its local call scope. Names can repeat across tool files
    without collisions or leaking into the caller. Regions document ownership.

    Define functions only: dot-sourcing must not run checks, perform network
    requests, prompt, or modify the machine. Runtime loaders and parallel worker
    discovery must exclude _tool-template.ps1.

    Keep tool-specific parsers, release planning, checks, refresh handlers, and
    install/update routines together here. Keep shared functionality and dispatch
    in tool-checker.ps1. Do not duplicate shared helpers or create modules.

    Functions run in the main script or an isolated check worker. They use the
    existing toolsConfig, results, SkipUpdate, and script-scoped platform/timeout
    settings. Do not initialize shared state in this file.

    After catalog selection, the main script loads only declared ToolFile files for
    selected, enabled tools in catalog-ID order into a per-tool definition registry.
    Omit ToolFile when no specialized file is needed. Invalid filenames and missing
    declared files fail startup. Registry keys remain catalog IDs, not filenames.
    This template and unrelated or disabled tool files are never loaded. Workers
    receive the same registry, including private helpers, and use the same dispatcher.
    Tool-local helpers need no dependency-list entry. Do not rely on file paths in
    tool functions. Shared worker helpers in the main script still require an
    entry in Get-ParallelCheckFunctionBlock. Keep files directly under Tools/.
#>

#region Public entry points
function Test-Tool {
    param([string]$Progress)

    $toolName = 'Example CLI'
    $config = Get-ToolConfiguration -ToolName $toolName -RequiredProperties @('Command')
    Write-Header "Checking $toolName" -Progress $Progress

    if (-not (Test-CommandExists $config.Command)) {
        Write-Error "$toolName not installed"
        Add-NotInstalledTool $toolName
        return
    }

    <#
    Replace the exception below with tool-specific inventory and update logic:
    - Read and parse the installed version; report an unparseable value as unknown.
    - Populate results.Tools using the existing Installed/Latest result shape.
    - Honor SkipUpdate before querying releases or registering available updates.
    - Reuse version comparison, release acceptance, and update-registration helpers.
    - Respect ProductionReleasesOnly and applicable npm maturity policy.
    - Detect and report only; never install, update, or repair during a check.

    Add needed helpers in the Private helpers region. Refresh and action routines are
    optional; preserve existing dispatch and approval gates in tool-checker.ps1.
    Add focused Pester coverage, including execution through a real check worker
    with synthetic inputs and no real installs, updates, or registry repairs.
    #>
    throw [System.NotImplementedException]::new('Implement the tool-specific check before registering this file.')
}
#endregion

#region Private helpers
#endregion