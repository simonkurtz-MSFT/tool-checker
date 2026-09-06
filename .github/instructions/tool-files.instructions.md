---
description: "Maintain tool-specific PowerShell files, shared configuration, registry and output infrastructure, and their loading boundaries."
applyTo: "Tools/**/*.ps1,Infra/**/*.ps1,tool-checker.ps1,tool-checker.json,tests/**/*.ps1,CONTRIBUTING.md"
---

# Tool-specific files

- Keep only bootstrap and workflow orchestration in `tool-checker.ps1`. Extract tool-unique
  behavior into a flat `Tools/` file explicitly named by the catalog's `ToolFile`.
  Prefer `<catalog-id>.ps1` for clarity, but never infer filenames from IDs.
  Shared registry checks, repairs, and endpoint resolution belong in
  `Infra/registry.ps1`; shared console rendering belongs in `Infra/output.ps1`.
  Catalog/env parsing, selection, defaults, sorting, lookup, and validation belong
  in `Infra/configuration.ps1`.
  Generic dispatch, checking, actions, results, and workers belong in the explicit
  runtime/checks/actions/results/parallel infrastructure files. Do not introduce a
  public/private module hierarchy or tool-name switches in generic infrastructure.
- Prefer JSON-only standard entries. Create a tool file only for specialized
  behavior, using `Tools/_tool-template.ps1` as the starting point.
  Keep simple parser and platform-command differences in catalog properties.
  Cross-tool package-manager decisions and helpers belong in `Infra/PackageManagers/`.
  `Infra/package-managers.ps1` resolves only selected PackageManagerFiles and
  WindowsPackageManagerFiles. Accept filenames only, not paths or folder scans.
  Dispatch `*-PackageManager` operations locally; share only named helpers.
- Explicitly dot-source the fixed generic infrastructure list via `$PSScriptRoot`, independently
  of catalog selection; do not scan the folder or register it as a tool.
  Infrastructure files define functions only and reuse main-script state.
  Keep the missing-infrastructure test cases in tests/configuration.Tests.ps1 aligned
  with the fixed bootstrap list; verify each missing path and independent -Version output.
  Loading must not check or repair registries. Preserve explicit approval even
  with `-Force`, and never offer repairs with `-SkipUpdate`.
- Configuration reading returns a snapshot without assigning shared state or
  loading tool files. Main passes explicit catalog/env paths and cooldown override
  presence (including zero), assigns the snapshot, and registers selected tools.
  Validate catalog cooldown even with an override. Workers read configuration
  source explicitly but receive only the allowlisted lookup helper, never readers.
  Cover standalone loading and state preservation in configuration tests; copied
  application fixtures must include required infrastructure files.
- Output functions render existing state; keep checks, update eligibility, and
  action execution outside them. Preserve the host-only Write-Warning/Write-Error
  wrappers. Define the palette in Initialize-ConsoleColors; bootstrap calls it
  explicitly to set caller-scope variables, while definition-only loading preserves
  existing colors. Workers reuse color snapshots without running the initializer.
  Worker discovery explicitly reads the output file and includes only
  allowlisted helpers; keep its Write-Host capture override in worker setup.
  Test definition-only loading, rendering, and synthetic runspace output.
- Tool files define functions only. Preserve shared state and helper
  reuse, check-only behavior, result shapes, and action approval gates.
- Give scripts a concise purpose comment; explain non-obvious parsing, ownership,
  scope/serialization, eligibility, and side effects near the code. Keep comments
  accurate and avoid restating obvious statements; document strict JSON in Markdown.
- Keep cooldown defaults in catalog `settings.CooldownDays`. Reuse the resolved
  `$script:ReleaseCooldownDays` (runtime `-CooldownDays` takes precedence),
  including in workers; never hard-code cooldown periods in tool files.
- Exclude `_tool-template.ps1` from runtime loading and parallel function
  discovery. The template must remain safe to dot-source and must not silently
  report success when its unfinished checker is invoked.
- Resolve `ToolFile` only for selected, enabled catalog entries after selection
  and defaults. Omitted fields mean no file; invalid filenames or missing declared
  files fail startup. Accept only .ps1 filenames directly under Tools/, excluding
  the template. Load in catalog-ID order and key the registry by ID, not filename;
  never scan for undeclared files. Workers use the same registry, including private helpers.
- Follow the template's public entry-point names and Public entry points / Private
  helpers regions. Public names are tool-agnostic. Dispatch through
  Invoke-ToolEntryPoint by catalog ID, dot-sourcing definitions only in its local
  call scope so names do not collide or leak. Prefer tool-qualified private names;
  do not call another tool's helpers or assume an unselected file is loaded.
- A loaded `Refresh-ToolStatus` is selected automatically, with optional
  `[string]$ToolName`; it may refresh one row or the whole tool inventory.
  Do not reintroduce `RefreshMethod` fields or a named-handler switch.
- Shared version policy belongs in `Infra/versions.ps1`. Optional public
  `Compare-ToolVersions` accepts Version1, Version2, Version1Source, Version2Source
  strings and returns exactly one integer (-1/0/1). Keep overrides pure; use
  Compare-SemanticVersions for ordinary cases, avoiding recursive dispatch.
  Use Test-UpdateAvailable or Compare-OwnedToolVersions with ToolName for owned
  decisions, including table status. Standard checks persist source metadata in
  owner ToolState (command/api/package-manager filename); workers must retain it.
- Rows/actions carry ToolId and optional ItemId. Use Get-ToolState for owner-keyed
  inventory; never add product-specific fields to shared results. Preserve the
  latest known release during refresh and update detached visible rows explicitly.
- Resolve Executor, EntryPoint, Arguments, ExecutionMode, and OutcomePackageManager before
  returning action plans from checks. Catalog defaults support Windows overrides;
  explicit action metadata wins. Menu and Force paths use the same dispatcher.
  Generic executors return Output/ExitCode; optional Get-ToolOutcome interprets
  failures. Keep eligibility decisions in the owning tool or package manager, not rendering.
- Worker definitions come from explicit source files and selected registries,
  never live Get-Command bodies. Cover selected-only loading, colliding generic
  operation names, real synthetic jobs, and metadata preservation in architecture tests.
  Track check workers immediately after creation; protect pool opening, startup,
  and collection with guaranteed cleanup. Attempt every disposal without masking
  the original failure, and cover the lifecycle with synthetic real-runspace tests.
- Whenever tool-file conventions, helper contracts, loading, worker dependencies,
  or validation practices change, review and update the template and the relevant
  contribution guidance in the same change. Keep these instructions aligned and
  non-duplicative.
- Validate template syntax and definition-only loading after template changes.
  Cover explicit filenames differing from IDs and rejection of invalid/missing files.
  Cover identical entry-point names across tools and absence of caller-scope leaks.
  For integrated tool behavior, run focused Pester tests and real-runspace checks
  with synthetic inputs, each tool selected alone, and check-only coverage;
  never execute real installs or registry repairs in tests.