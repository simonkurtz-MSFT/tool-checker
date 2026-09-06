---
description: "Maintain tool-specific PowerShell files and their template during tool additions and extraction."
applyTo: "Tools/**/*.ps1,tool-checker.ps1,tool-checker.json,tests/**/*.ps1,CONTRIBUTING.md"
---

# Tool-specific files

- Keep general functionality in `tool-checker.ps1`. Extract only tool-unique
  behavior into `Tools/<catalog-id>.ps1`, named exactly after its catalog key.
  Do not introduce infrastructure modules or a public/private module hierarchy.
- Prefer JSON-only standard entries. Create a tool file only for specialized
  behavior, using `Tools/_tool-template.ps1` as the starting point.
- Tool files define functions only. Preserve dot-sourced scope, shared helper
  reuse, check-only behavior, result shapes, and action approval gates.
- Exclude `_tool-template.ps1` from runtime loading and parallel function
  discovery. The template must remain safe to dot-source and must not silently
  report success when its unfinished checker is invoked.
- Whenever tool-file conventions, helper contracts, loading, worker dependencies,
  or validation practices change, review and update the template and the relevant
  contribution guidance in the same change. Remove transitional guidance once
  the loader is implemented. Keep these instructions aligned and non-duplicative.
- Validate template syntax and definition-only loading after template changes.
  For integrated tool behavior, run focused Pester tests and real-runspace checks
  with synthetic inputs; never execute real installs or registry repairs in tests.