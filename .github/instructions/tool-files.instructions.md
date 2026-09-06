---
description: "Maintain tool-specific PowerShell files, shared registry infrastructure, and their loading boundaries."
applyTo: "Tools/**/*.ps1,Infra/**/*.ps1,tool-checker.ps1,tool-checker.json,tests/**/*.ps1,CONTRIBUTING.md"
---

# Tool-specific files

- Keep general functionality in `tool-checker.ps1`. Extract only tool-unique
  behavior into a flat `Tools/` file explicitly named by the catalog's `ToolFile`.
  Prefer `<catalog-id>.ps1` for clarity, but never infer filenames from IDs.
  Shared registry checks, repairs, and endpoint resolution belong in
  `Infra/registry.ps1`. Keep orchestration and other shared behavior in the main
  script; do not introduce a public/private module hierarchy.
- Prefer JSON-only standard entries. Create a tool file only for specialized
  behavior, using `Tools/_tool-template.ps1` as the starting point.
  Keep simple parser and platform-command differences in catalog properties.
  Cross-tool npm release metadata helpers stay shared in the main script.
- Explicitly dot-source `Infra/registry.ps1` via `$PSScriptRoot`, independently
  of catalog selection; do not scan the folder or register it as a tool.
  Infrastructure files define functions only and reuse main-script state.
  Loading must not check or repair registries. Preserve explicit approval even
  with `-Force`, and never offer repairs with `-SkipUpdate`.
- Tool files define functions only. Preserve shared state and helper
  reuse, check-only behavior, result shapes, and action approval gates.
- Keep cooldown defaults in catalog `settings.CooldownDays`. Reuse the resolved
  `$script:NpmUpdateCooldownDays` (runtime `-CooldownDays` takes precedence),
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