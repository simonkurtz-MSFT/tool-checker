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
6. Add or update focused Pester coverage. Custom checks must also add their
   implementation to [tool-checker.ps1](tool-checker.ps1).
7. Update the catalog ID list or other affected documentation in
   [README.md](README.md).

When proposing a tool, include sanitized examples of its installed-version
output and upstream release response. The configured parser must extract a
version that Tool Checker can compare consistently.

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
