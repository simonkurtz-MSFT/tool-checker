#Requires -Version 7.0
<#
.SYNOPSIS
    Template for tool-specific behavior. Not a runtime tool file.

.DESCRIPTION
    Copy to Tools/<catalog-id>.ps1, using the exact key in tool-checker.json.
    Replace ExampleTool and Example CLI with the checker name and catalog Name.
    Set CustomFunction to the checker function name for a custom catalog entry.
    Standard entries need a file only when they have specialized behavior.

    Define functions only: dot-sourcing must not run checks, perform network
    requests, prompt, or modify the machine. Runtime loaders and parallel worker
    discovery must exclude _tool-template.ps1.

    Keep tool-specific parsers, release planning, checks, refresh handlers, and
    install/update routines together here. Keep shared functionality and dispatch
    in tool-checker.ps1. Do not duplicate shared helpers or create modules.

    Functions run in the main script or an isolated check worker. They use the
    existing toolsConfig, results, SkipUpdate, and script-scoped platform/timeout
    settings. Do not initialize shared state in this file.

    The Tools loader is not implemented yet. Creating a file alone does not
    register it with the current application or parallel workers.
#>

function Test-ExampleTool {
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

    Add only needed helpers below this function. Refresh and action routines are
    optional; preserve existing dispatch and approval gates in tool-checker.ps1.
    Add focused Pester coverage, including execution through a real check worker
    when this file is integrated. Keep this template aligned with that integration.
    #>
    throw [System.NotImplementedException]::new('Implement the tool-specific check before registering this file.')
}