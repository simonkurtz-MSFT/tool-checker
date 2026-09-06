# Contributing to Tool Checker

Thank you for improving Tool Checker. Contributions should keep checks safe,
predictable, and usable on the platforms they claim to support.

## Before you start

- Use PowerShell 7 or later.
- Install [Pester](https://pester.dev/) to run the test suite.
- Do not include credentials, private registry URLs, or other secrets in issues,
  tests, configuration, or command output.
- Open a Tool Catalog Addition issue before adding a new tool so its release
  source, platform support, and update behavior can be reviewed.

## Add a tool catalog entry

Prefer a `standard` entry in [tool-checker.json](tool-checker.json). Standard
entries use the shared command detection, version parsing, release lookup, and
update framework. Use a `custom` entry only when that framework cannot model
the tool, such as a tool that manages several installed release channels.

1. Choose a stable catalog ID made of lowercase letters, numbers, and hyphens.
2. Add a unique human-readable `Name` and the fields required for the selected
   check type. See the configuration reference in [README.md](README.md).
3. Use an authoritative release API or package registry for `ApiUrl` and link
   to official release notes when available.
4. Provide non-interactive install and update commands for each supported OS
   and architecture. Omit unsupported platform keys instead of adding commands
   that have not been verified.
5. Set `ProductionReleasesOnly` deliberately. Keep it enabled unless users are
   expected to track prerelease versions.
6. Add or update focused Pester coverage. Put new custom checks in
   a file directly under `Tools/` and declare its filename with `ToolFile`,
   starting from the tool-specific template below.
7. Update the catalog ID list or other affected documentation in
   [README.md](README.md).

When proposing a tool, include sanitized examples of its installed-version
output and upstream release response. The configured parser must extract a
version that Tool Checker can compare consistently.

## Tool-specific file template

Keep the npm cooldown default in catalog `settings.CooldownDays`, not in script
or tool-file constants. The runtime `-CooldownDays` override takes precedence;
reuse the resolved `$script:ReleaseCooldownDays` in tool and worker checks.
Cover catalog values, overrides (including zero), and worker propagation in tests.

Use [Tools/_tool-template.ps1](Tools/_tool-template.ps1) when extracting or adding
tool-unique behavior. Prefer `Tools/<catalog-id>.ps1` and explicitly set
`"ToolFile": "<catalog-id>.ps1"` in its catalog entry. Filenames may differ from
catalog IDs; the loader never infers them. Keep specialized checks, parsing, refresh handlers, and
action routines together; keep orchestration in
[tool-checker.ps1](tool-checker.ps1) and shared registry behavior in
[Infra/registry.ps1](Infra/registry.ps1). Shared console rendering belongs in
[Infra/output.ps1](Infra/output.ps1), and configuration handling belongs in
[Infra/configuration.ps1](Infra/configuration.ps1). Standard entries without specialized
behavior do not need a tool file.

Give each script a concise purpose comment. Explain non-obvious parsing assumptions,
state ownership, scope/worker boundaries, eligibility decisions, and action side
effects beside the relevant code. Avoid line-by-line narration and keep comments
current when behavior moves. Keep catalog field explanations in the configuration
reference rather than adding comments to strict JSON.

The template is scaffolding, not a registered tool. After catalog selection and
defaults, the main script registers functions only from declared `ToolFile` files
for selected, enabled entries, in catalog-ID order. `ToolFile` must be a .ps1
filename directly under `Tools/`, not a path or the template. Invalid filenames
and missing declared files fail startup. Registry keys remain catalog IDs.
Unselected, disabled, undeclared, and template files are not loaded. Omit
`ToolFile` when no specialized file is needed. Standard tools without a file
continue through the shared framework. Files must define functions only.
Parallel workers receive the same per-tool definition registry, so
tool-local helpers do not need separate dependency-list entries. Shared worker
helpers in the explicitly loaded infrastructure files still belong in the
`Get-ParallelCheckFunctionBlock` allowlist.

Use the same public names in every tool file: `Test-Tool`, `Refresh-ToolStatus`,
`Invoke-ToolInstall`, `Invoke-ToolUpdate`, `Get-ToolOutcome`, and `Compare-ToolVersions`. Implement only the entry points the
tool needs, in a `#region Public entry points` block. Set `CustomFunction` to
`Test-Tool` for extracted custom checkers. Keep private functions in
`#region Private helpers`; prefer tool-qualified names for clarity.

Call public functions through `Invoke-ToolEntryPoint`, specifying the catalog ID,
entry-point name, and an optional arguments hashtable. For example:

```powershell
Invoke-ToolEntryPoint -ToolId 'nodejs' -EntryPoint 'Test-Tool' -Arguments @{ Progress = '1/1' }
```

The dispatcher dot-sources only that tool's definitions into its local call scope,
then invokes the entry point. Repeated names cannot overwrite another tool or
leak into the caller. Helpers remain accessible within the tool call, but other
tools must not call them. Shared state is initialized by the entry point;
tool isolation does not require PowerShell modules.

Shared version rules live in [Infra/versions.ps1](Infra/versions.ps1). Use
`Test-UpdateAvailable -ToolName ...` or `Compare-OwnedToolVersions -ToolName ...`
for update decisions; these select the owner's optional `Compare-ToolVersions`
override before the default `Compare-SemanticVersions`. The public override accepts
string parameters `Version1`, `Version2`, `Version1Source`, and `Version2Source`
and must return exactly one integer: `-1` (older), `0` (equivalent), or `1` (newer).
Keep it pure: no API calls, state mutations, or actions. Delegate ordinary cases
to `Compare-SemanticVersions`, not back to the owner-aware dispatcher.
Standard checks record `InstalledVersionSource` and `LatestVersionSource` in
owner-keyed `ToolState`: `command`, `api`, or the package-manager filename.
Custom checks may supply the same metadata; sources can be empty. Planning,
update-command selection, and table status use the same comparison policy.
Raw package sorting may still call `Compare-SemanticVersions` directly.

All custom checks now live in their catalog-declared tool files: Node.js, .NET
SDK, Python, Python Install Manager, global npm packages, Azure CLI extensions,
PowerShell, and WSL. Azure CLI, Bicep, and pnpm have refresh-only files; uv has its
Windows installer. Azure Developer CLI has a source-aware version comparison file.
Tools handled entirely by catalog data need no file.

`Refresh-ToolVersion` calls a loaded `Refresh-ToolStatus` automatically, passing
the optional `[string]$ToolName` parameter. A handler may refresh one row or its
whole inventory. Dynamic SDK, Python, and npm rows route to their owning tool.
No `RefreshMethod` field or named-handler switch is needed. Specialized actions
remain behind the shared dispatcher and approval gates.

Keep cross-tool npm release metadata helpers in [Infra/PackageManagers/npm.ps1](Infra/PackageManagers/npm.ps1), declared through
`PackageManagerFiles`. In particular, a pnpm-only selection must not depend on the global npm tool file.
Use catalog JSON properties, regexes, and platform command overrides for simple
differences instead of adding tool-name branches to the standard framework.
Test changes with focused Pester coverage and synthetic real-runspace checks;
test each specialized checker selected alone and in check-only mode. Never execute
real installs, updates, or registry repairs in tests.

When conventions, helper contracts, loading, or validation practices change,
update the template and this guidance in the same change. The corresponding
[tool-file instructions](.github/instructions/tool-files.instructions.md) apply
to the implementation, catalog, and tests.

## Configuration infrastructure

[Infra/configuration.ps1](Infra/configuration.ps1) owns catalog and dotenv reading,
selection, sorting, optional defaults, cooldown resolution, configuration lookup,
and startup validation. `Get-ToolSortKey` is also shared with table rendering.
The main script explicitly dot-sources this function-only file via `$PSScriptRoot`
and calls `Read-ToolCheckerConfiguration` with catalog/env paths and explicit
cooldown override presence. The reader returns a snapshot; main assigns shared
state and registers selected tool definitions before validating them. Reading a
snapshot must not load tool files, modify process environment, or replace shared state.

Preserve relative env paths against the caller's working directory, optional
missing env files, selection normalization, ordered install commands, explicit
false values, and the catalog's cooldown validation even when overridden.
Keep the `-Version` early return independent of infrastructure and configuration.
Workers receive the resolved state and allowlisted `Get-ToolConfiguration` helper;
they must not reread configuration. Validate these boundaries with
[tests/configuration.Tests.ps1](tests/configuration.Tests.ps1) and the existing
selection, cooldown, tool-loading, and real-runspace tests.

## Registry infrastructure

[Infra/registry.ps1](Infra/registry.ps1) owns registry policy checks, approved
repairs for npm/pnpm/pip/uv/NuGet, npm metadata endpoint resolution, and repair
result reporting. It includes the supporting Python interpreter, uv configuration,
NuGet source, URL normalization, and credential-masking helpers.

The main script explicitly dot-sources this function-only file via `$PSScriptRoot`,
independently of selected tools, and fails startup if it is missing. Do not add
catalog entries, folder scanning, or tool-dispatch entry points for infrastructure.
Loading the file must not perform checks, requests, writes, or prompts.

Configuration reader invocation and shared state initialization remain in the entry point;
action menus and approval gates live in `Infra/actions.ps1`, with workers in `Infra/parallel.ps1`. Registry repairs still
require explicit approval with `-Force`; `-SkipUpdate` reports drift only.
Registry policy is independent of tool selection. Workers continue receiving
resolved tool configuration through the existing shared worker setup.

Validate changes with [tests/registry.Tests.ps1](tests/registry.Tests.ps1) and the
existing action/force-mode tests. Mock external commands and redirect uv writes
to `TestDrive`; never modify the developer's real package-manager configuration.

## Output infrastructure

[Infra/output.ps1](Infra/output.ps1) owns the shared message helpers, banner,
startup information, registry metadata display, progress heading, results table,
legend, and summary. It renders existing state without changing results or running
checks, updates, or prompts. Update eligibility and action approval remain in the
check/action infrastructure; the summary receives the already-filtered available update names.
Operation-specific messages remain with their checks and actions.

The main script explicitly dot-sources the function-only file via `$PSScriptRoot`
and fails startup if it is missing, independently of catalog selection. Preserve
the existing host-only `Write-Warning` and `Write-Error` wrappers, colors, and text.
The palette is defined by `Initialize-ConsoleColors` in the output file. Bootstrap
calls it explicitly to set the immediate caller's color variables; loading the file
alone must not initialize or overwrite them. Shared result state remains in bootstrap.

`Get-ParallelCheckFunctionBlock` explicitly reads the output and configuration files
alongside the main source and selects only allowlisted worker helpers. Do not scan `Infra/` or
send table/summary rendering to workers. The worker's `Write-Host` capture override
remains in worker setup, using a snapshot of initialized colors rather than calling
the initializer again. Validate with [tests/output.Tests.ps1](tests/output.Tests.ps1)
and the existing banner, legend, action, and parallel-check tests. Copied-application
fixtures must include all required infrastructure files.

## Runtime and package manager contracts

The entry point contains bootstrap and workflow orchestration only. Keep generic
definition loading and tool dispatch in `Infra/runtime.ps1`, result ownership in
`Infra/results.ps1`, checking and release-plan consumption in `Infra/checks.ps1`,
action planning/execution in `Infra/actions.ps1`, and check workers in
`Infra/parallel.ps1`. Infrastructure is loaded from an explicit list, never scanned.

Check-worker resources must be tracked as soon as they are created, before setup
or invocation can fail. Keep pool opening, worker startup, and result collection
inside guaranteed cleanup. Stop and dispose outstanding workers, close and dispose
the pool, and restore the cursor even on exceptions. A cleanup failure must not
skip remaining resources or replace the original operation error. Validate success,
timeout, startup, collection, and cleanup failures with synthetic workers in
[tests/parallel.Tests.ps1](tests/parallel.Tests.ps1).

Declare shared dependencies with `PackageManagerFiles` and `WindowsPackageManagerFiles`.
Use filenames such as `npm.ps1` and `winget.ps1`, resolved directly under
`Infra/PackageManagers/`; paths and directory scanning are not supported.
[Infra/package-managers.ps1](Infra/package-managers.ps1) loads only selected dependencies and dispatches local operation
names such as `Get-ReleasePlan-PackageManager`, `Invoke-Command-PackageManager`, and
`Get-ExecutionOutcome-PackageManager`. Package manager helpers are shared; operation entry points
stay local. Release plans carry the checked version, eligibility, blocking reason,
and exact installable command. Do not reconstruct package-specific decisions in
renderers, action menus, or background jobs.

Rows carry `ToolId` and optional `ItemId`; use `Get-ToolState -ToolId <id>` for
tool-private inventory. Dispatch stamps new unowned rows, but explicitly provide
ownership when rows or actions are built outside the tool entry point. Never infer
owners from display-name patterns. Refresh uses ownership and must not rely on
reference identity between visible rows and serialized tool state. Catalog
`RequiredProperties` and sort metadata replace tool-name switches in validation
and rendering.

`Add-AvailableUpdate` resolves execution metadata before a worker returns its plan.
An action carries `ToolId`, `ItemId`, `Operation`, `Command`, `Executor`,
`EntryPoint`, `Arguments`, `ExecutionMode`, and optional `OutcomePackageManager`.
Explicit action values override catalog defaults. Use `Executor = 'tool'` with
`ExecutionMode = 'CurrentSession'` for an installer that requires the current
process. Otherwise use `command` or a declared package manager filename. Install/update
catalog metadata supports `Windows` overrides. `Type` is not an executor selector.
WinGet package manager commands must be single commands; compound shell scripts use the
generic command executor. Specialized executors return `Output` and `ExitCode`.
Optional `Get-ToolOutcome(Action, ExitCode, OutputText)` returns a diagnostic
`Message` and `Status` without changing approval policy.

Interactive and Force paths share dispatch and completion. Jobs receive selected
definition registries and allowlisted helpers extracted from explicit source files,
not live `Get-Command` bodies that can contain mocks. Test contracts in
[tests/architecture.Tests.ps1](tests/architecture.Tests.ps1), including synthetic
background dispatch, selected dependency isolation, owned refresh, and menu metadata.

## Validate your change

Run the automated tests from the repository root:

```powershell
Invoke-Pester ./tests
```

Confirm that the catalog remains valid JSON:

```powershell
Get-Content ./tool-checker.json -Raw | ConvertFrom-Json | Out-Null
```

For a catalog addition, also run a targeted inventory against the new ID:

```powershell
$env:TOOL_CHECKER_TOOLS = 'example-cli'
./tool-checker.ps1 -SkipUpdate
Remove-Item Env:TOOL_CHECKER_TOOLS
```

Review the displayed name, installed version, latest version, release age,
release-notes link, and supported action. Do not apply an install or update
unless you intend to test that command on the current machine.

## Submit a pull request

Keep the pull request focused on one tool or one behavior change. Complete the
Tool Catalog Addition pull request template, describe any unsupported
platforms, and report the validation commands you ran. Screenshots are useful
when output formatting or interactive behavior changes, but are not required
for catalog-only additions.
