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
        - Refresh-ToolStatus - optional post-action inventory refresh; accepts
            optional [string]$ToolName and may refresh one row or the whole inventory.
    - Invoke-ToolInstall - optional specialized installer.
    - Invoke-ToolUpdate - optional specialized updater.
    - Compare-ToolVersions - optional pure version comparison; accepts strings
        Version1, Version2, Version1Source, and Version2Source; returns one integer
        (-1 for older, 0 for equivalent, 1 for newer). Sources may be empty.
        Delegate ordinary cases to Compare-SemanticVersions, not the dispatcher.
        - Get-ToolOutcome - optional failure diagnostic; accepts Action, ExitCode,
            and OutputText and returns a Message/Status object or nothing.
    Keep platform-specific details behind these names, not in public names.
    Action parameters and results must match Infra/actions.ps1's dispatcher.
    A loaded Refresh-ToolStatus is used automatically; do not add a RefreshMethod
    catalog field or a tool-specific refresh switch in the main script.

    Put public functions in '#region Public entry points' and private helpers in
    '#region Private helpers'. Private names may vary; prefer tool-qualified names
    for clarity. Only this tool's implementation and tests should call them.
    Invoke-ToolEntryPoint dispatches by catalog ID and dot-sources the registered
    definitions into its local call scope. Names can repeat across tool files
    without collisions or leaking into the caller. Regions document ownership.

    Add a concise file-purpose comment and explain non-obvious parser assumptions,
    release eligibility, state ownership, and action side effects near the code.
    Keep comments about intent/contracts rather than narrating individual statements.

    Define functions only: dot-sourcing must not run checks, perform network
    requests, prompt, or modify the machine. Runtime loaders and parallel worker
    discovery must exclude _tool-template.ps1.

    Keep tool-specific parsers, release planning, checks, refresh handlers, and
    install/update routines together here. Keep dispatch in Infra/runtime.ps1;
    shared registry checks, repairs, and endpoint resolution live in
    Infra/registry.ps1, loaded independently of tool selection.
    Shared console rendering and Initialize-ConsoleColors live in Infra/output.ps1.
    Main explicitly initializes the caller's palette; workers receive color snapshots.
    Configuration parsing, defaults, selection, and lookup live in
    Infra/configuration.ps1. Main assigns resolved state and registers tool files.
    Do not duplicate shared helpers or create modules.
    Shared version rules live in Infra/versions.ps1. Use Test-UpdateAvailable with
    ToolName (or Compare-OwnedToolVersions) for owner-aware update decisions.
    Standard checks record InstalledVersionSource/LatestVersionSource in ToolState:
    command, api, or a package-manager filename. Overrides must not fetch data,
    mutate state, or execute actions; the same rule drives planning and rendering.
    Cross-tool npm release metadata helpers live in Infra/PackageManagers/npm.ps1.
    Declare PackageManagerFiles and WindowsPackageManagerFiles explicitly;
    Infra/package-managers.ps1 resolves only selected dependencies. Prefer catalog
    JSON properties, regexes, and platform command overrides for simple differences.

    Functions run in the main script or an isolated check worker. They use the
    existing toolsConfig, results, SkipUpdate, and script-scoped platform/timeout
    settings. Do not initialize shared state in this file.
    For npm maturity checks, reuse script:ReleaseCooldownDays, resolved from
    catalog settings.CooldownDays or the runtime -CooldownDays override. Do not
    hard-code a cooldown in tool files; workers receive the same resolved value.

    After catalog selection, the main script loads only declared ToolFile files for
    selected, enabled tools in catalog-ID order into a per-tool definition registry.
    Omit ToolFile when no specialized file is needed. Invalid filenames and missing
    declared files fail startup. Registry keys remain catalog IDs, not filenames.
    This template and unrelated or disabled tool files are never loaded. Workers
    receive the same registry, including private helpers, and use the same dispatcher.
    Tool-local helpers need no dependency-list entry. Do not rely on file paths in
    tool functions. Shared worker helpers in explicit infrastructure sources
    still require an entry in Get-ParallelCheckFunctionBlock, which explicitly
    reads these sources. Workers reuse resolved configuration, not its readers.
    Keep files directly under Tools/.

    Store private inventory with Get-ToolState -ToolId '<catalog-id>'. Rows carry
    ToolId and optional ItemId; dispatch stamps newly created unowned rows.
    Do not infer ownership from display names. Refresh visible rows explicitly
    instead of relying on shared references to tool state across worker boundaries.
    Add-AvailableUpdate resolves catalog executor metadata into an action plan.
    For specialized actions, supply -Executor tool -Arguments @{ ... } and
    -ExecutionMode CurrentSession when required. The default entry point is
    Invoke-ToolUpdate. Return @{ Output = '...'; ExitCode = 0 } from executors.
    Catalog Install/UpdateExecutor, EntryPoint, ExecutionMode, and OutcomePackageManager
    settings support Windows overrides. Explicit action values take precedence.
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
    optional; preserve existing dispatch and approval gates in Infra/actions.ps1.
    Add focused Pester coverage, including execution through a real check worker
    with synthetic inputs, this tool selected alone, and check-only coverage.
    Never execute real installs, updates, or registry repairs in tests.
    #>
    throw [System.NotImplementedException]::new('Implement the tool-specific check before registering this file.')
}
#endregion

#region Private helpers
#endregion