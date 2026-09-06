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
   `Tools/<catalog-id>.ps1`, starting from the tool-specific template below.
7. Update the catalog ID list or other affected documentation in
   [README.md](README.md).

When proposing a tool, include sanitized examples of its installed-version
output and upstream release response. The configured parser must extract a
version that Tool Checker can compare consistently.

## Tool-specific file template

Use [Tools/_tool-template.ps1](Tools/_tool-template.ps1) when extracting or adding
tool-unique behavior. Name the implementation `Tools/<catalog-id>.ps1`, matching
the exact catalog key. Keep specialized checks, parsing, refresh handlers, and
action routines together; keep general functionality in
[tool-checker.ps1](tool-checker.ps1). Standard entries without specialized
behavior do not need a tool file.

The template is scaffolding, not a registered tool. After catalog selection and
defaults, the main script registers functions from existing `Tools/<catalog-id>.ps1` files
for selected, enabled entries, in catalog-ID order. Unselected, disabled,
uncatalogued, and template files are not loaded. Standard tools without a file
continue through the shared framework. Files must define functions only.
Parallel workers receive the same per-tool definition registry, so
tool-local helpers do not need separate dependency-list entries. Shared worker
helpers in the main script still belong in `Get-ParallelCheckFunctionBlock`.

Use the same public names in every tool file: `Test-Tool`, `Refresh-ToolStatus`,
`Invoke-ToolInstall`, and `Invoke-ToolUpdate`. Implement only the entry points the
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
tools must not call them. Shared state and helpers remain in the main script;
this does not introduce PowerShell modules or a new directory hierarchy.

[Tools/nodejs.ps1](Tools/nodejs.ps1) is the first extracted implementation.
Existing custom checks for other tools remain in the main script until extracted.
Test changes with focused Pester coverage and synthetic real-runspace checks;
never execute real installs, updates, or registry repairs in tests.

When conventions, helper contracts, loading, or validation practices change,
update the template and this guidance in the same change. The corresponding
[tool-file instructions](.github/instructions/tool-files.instructions.md) apply
to the implementation, catalog, and tests.

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
