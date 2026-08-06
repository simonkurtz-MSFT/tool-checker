# Tool Checker

Tool Checker is a PowerShell 7 script that inventories development tools, compares installed versions with upstream releases, and optionally installs missing tools or applies updates. Checks run in parallel and are driven by [`tool-checker.json`](tool-checker.json).

The included configuration checks:

- Node.js and global npm packages
- npm-check-updates (`ncu`), pnpm, Deno, and uv
- Azure CLI, Azure CLI extensions, and Bicep
- .NET SDKs, Python Install Manager (`py`), and Python installations
- Git, GitHub CLI, and ripgrep
- WSL and PowerShell

Tool Checker supports Windows and Linux on AMD64 and ARM64. Some configured tools or update commands are platform-specific; for example, WSL is checked only on Windows and several Windows updates use WinGet.

## See it in action

The following screenshots show Tool Checker `1.0.0` starting in check-only mode, reporting a consolidated inventory, and refreshing the summary after a selected update completes.

![Tool Checker starting parallel checks and reporting detected tools](docs/assets/tool-checker-execution.png)

![Tool Checker completed inventory summary](docs/assets/tool-checker-summary.png)

![Tool Checker post-execution summary after a completed update](docs/assets/tool-checker-post-execution-summary.png)

## Requirements

- [PowerShell 7 or later](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
- Internet access to query release APIs and package registries
- The package managers used by your configured install and update commands, such as WinGet, npm, or `apt`
- `tool-checker.ps1` and `tool-checker.json` in the same directory

The script does not require installation or additional PowerShell modules.

## Usage

From PowerShell, run:

```powershell
./tool-checker.ps1
```

Checks run concurrently, followed by a summary showing installed and latest versions, release age, available commands, and release-note links. If actions are available, an interactive menu lets you select one or more comma-separated action numbers. Press Enter or select `0` to exit without making further changes.

### Options

| Option               | Description                                                                                                                                       |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-SkipUpdate`        | Check which tools are installed without querying for or applying updates. Alias: `-CheckOnly`. Missing tools can still appear in the action menu. |
| `-Force`             | Apply every actionable update without prompting. Updates run in parallel. This does not automatically install missing tools.                      |
| `-Timeout <seconds>` | Set the maximum time for each individual check. The default is 30 seconds.                                                                        |
| `-Version`           | Print the Tool Checker version and exit.                                                                                                          |

Examples:

```powershell
# Run checks and choose actions interactively
./tool-checker.ps1

# Inventory installed and missing tools only
./tool-checker.ps1 -SkipUpdate

# Apply all available updates without prompts
./tool-checker.ps1 -Force

# Allow slower checks up to 60 seconds each
./tool-checker.ps1 -Timeout 60

# Print the script version
./tool-checker.ps1 -Version
```

Tool Checker executes the commands shown in the summary or action menu. Review [`tool-checker.json`](tool-checker.json) before using interactive actions or `-Force`, especially on a shared or managed machine.

## Configuration

Tools are defined under the top-level `tools` object in [`tool-checker.json`](tool-checker.json). Object order controls display order.

There are two kinds of checks:

- `standard`: Uses the generic command, version parser, release API, and update-command framework. Most new command-line tools should use this type.
- `custom`: Calls a named function in `tool-checker.ps1` for tools requiring specialized behavior, such as multiple installed SDK channels.

### Add a standard tool

Add an entry like this:

```json
{
  "tools": {
    "Example CLI": {
      "enabled": true,
      "CheckType": "standard",
      "ProductionReleasesOnly": true,
      "Command": "example",
      "VersionFlag": "--version",
      "VersionParseRegex": "example ([0-9]+(?:\\.[0-9]+){1,3})",
      "UpdateType": "winget",
      "UpdateCommand": "winget upgrade Vendor.Example --silent --disable-interactivity",
      "ReleaseNotesUrl": "https://github.com/vendor/example/releases",
      "ApiUrl": "https://api.github.com/repos/vendor/example/releases/latest",
      "InstallCommands": {
        "Windows (amd64)": "winget install Vendor.Example --silent --disable-interactivity",
        "Windows (arm64)": "winget install Vendor.Example --silent --disable-interactivity",
        "Linux (amd64)": "sudo apt-get install -y example",
        "Linux (arm64)": "sudo apt-get install -y example"
      }
    }
  }
}
```

The generic API parser recognizes common `tag_name`, `version`, or `release` properties. GitHub's latest-release API works without a custom extractor. A leading `v` is removed before version comparison.

### Standard fields

| Field                    | Required              | Purpose                                                                                                                |
| ------------------------ | --------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `enabled`                | No                    | Set to `false` to skip this checker. Defaults to `true` when omitted.                                                  |
| `CheckType`              | Yes                   | Set to `standard` or `custom`.                                                                                         |
| `Command`                | Yes                   | Executable name used to detect whether the tool is installed.                                                          |
| `VersionFlag`            | Usually               | Argument passed to `Command`; defaults to `--version`.                                                                 |
| `VersionCommand`         | No                    | Full command used instead of `Command` plus `VersionFlag`.                                                             |
| `VersionParseRegex`      | Recommended           | Regex whose first capture group is the installed version.                                                              |
| `VersionExtractor`       | No                    | Named parser for special installed/API output. Built-in values include `npmDistTagLatest`, `azCliJson`, and `azBicep`. |
| `ApiUrl`                 | Yes for update checks | Endpoint used to determine the latest release.                                                                         |
| `ProductionReleasesOnly` | No                    | Excludes alpha, beta, preview, RC, canary, and similar versions. Defaults to `true`.                                   |
| `UpdateParseRegex`       | No                    | Extracts an available version from a self-reporting version command instead of the API result.                         |
| `UpdateType`             | Recommended           | Identifies the command family for execution and error handling, such as `winget`, `direct`, or `npm-global`.           |
| `UpdateCommand`          | Yes for updates       | PowerShell command executed to update the tool.                                                                        |
| `InstallCommands`        | No                    | Platform-specific commands offered when the tool is missing.                                                           |
| `ReleaseNotesUrl`        | No                    | Link displayed when an update is actionable.                                                                           |
| `RefreshMethod`          | No                    | Named post-update version refresh handler. Without one, the standard version check is reused.                          |

`InstallCommands` supports these platform keys:

```text
Windows (amd64)
Windows (arm64)
Linux (amd64)
Linux (arm64)
```

If the exact architecture is absent, Tool Checker falls back to the first command for the current operating system. If no matching command exists, the missing tool is reported but cannot be installed from the menu.

### npm packages

For an npm-hosted CLI, set `VersionExtractor` to `npmDistTagLatest` and provide `NpmPackageName`. Tool Checker uses the user's configured npm registry when possible and pins updates to the version it checked.

The script enforces a seven-full-day cooldown before newly published npm package versions become actionable. Younger releases remain visible as informational updates but are not installed.

### Add a custom tool

Use a custom entry only when the standard framework cannot model the check:

```json
{
  "tools": {
    "Example SDK": {
      "enabled": true,
      "CheckType": "custom",
      "CustomFunction": "Test-ExampleSDK",
      "Command": "example"
    }
  }
}
```

Then add the corresponding function to `tool-checker.ps1`:

```powershell
function Test-ExampleSDK {
    param([string]$Progress)

    Write-Header "Checking Example SDK" -Progress $Progress
    # Populate the shared $results collections here.
}
```

Custom checker functions must accept a `Progress` string and must be included in the function list inside `Invoke-ParallelChecks` so they are available in worker runspaces. If the custom tool can be updated, add entries to `$results.AvailableUpdates` with `Name`, `Command`, `Type`, and `Details` values.

## Output and behavior

- Green rows are installed and current, or were run in check-only mode without an update lookup.
- Yellow rows have an actionable install or update, or the latest version could not be determined.
- Orange rows identify npm releases still in cooldown.
- Red rows identify failed updates, missing tools, or checks that timed out before inventory completed.
- A timed-out check is stopped and reported without preventing other checks from completing. A whole-check timeout shows `unknown` in red; an installed tool whose latest-version lookup did not complete shows `unknown` in yellow rather than appearing current.
- After an interactive action, Tool Checker refreshes the displayed version when a refresh handler is available.

Release APIs and package catalogs can disagree temporarily. In particular, WinGet may publish a release later than the upstream project. Tool Checker treats known "no applicable upgrade" responses as a retry-later condition rather than a successful update.

## License

Licensed under the terms in [`LICENSE`](LICENSE).
