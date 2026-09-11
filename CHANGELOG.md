# Changelog

<!-- markdownlint-disable MD024 -->

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add an interactive first-run setup that creates the environment file and records
  the selected catalog tools.

### Changed

- Consolidate test files under the infrastructure and tool-specific test directories.
- Expand setup documentation and test coverage.

## [2.1.0] - 2026-09-09

### Added

- Add a JSON Schema for the tool catalog and schema validation tests.
- Add dedicated test suites for infrastructure and individual tool integrations.

### Changed

- Reorganize tests by infrastructure and tool ownership.

### Fixed

- Correct the Azure Bicep CLI update command.

## [2.0.0] - 2026-09-07

### Added

- Add Azure Developer CLI checks and update support.
- Add contribution guidance, issue templates, and a tool-catalog pull request template.
- Add a template for implementing specialized tool checkers.

### Changed

- Modularize the application into shared infrastructure, package-manager adapters,
  and tool-specific files.
- Move tool metadata and behavior selection into the catalog configuration.
- Expand architecture, configuration, output, parallelism, registry, and version tests.

### Fixed

- Refresh summary rows after actions complete.
- Correct Azure Developer CLI version comparison.

## [1.2.5] - 2026-09-04

### Changed

- Replace display-name-based tool selection with stable catalog IDs.
- Sort and validate selected tools through the catalog configuration.
- Expand selection and configuration test coverage.

## [1.2.4] - 2026-09-04

### Added

- Add Pester coverage for version comparison, update availability, parallel checks,
  and shared functions.

### Changed

- Set the default per-check timeout to 60 seconds.
- Centralize version comparison, latest-version lookup, update availability, and
  update-command planning.
- Run tool checks in parallel and refactor the main workflow into reusable functions.

## [1.2.3] - 2026-09-02

### Added

- Add GitHub Copilot CLI inventory and update support.

### Changed

- Highlight tool versions whose installed or latest state cannot be determined.

## [1.2.2] - 2026-09-01

### Changed

- Run Azure CLI installation silently.
- Handle npm and pnpm update paths independently.
- Fall back to an alternate Node.js installation path when needed.
- Elevate privileges for Node.js installation on Windows.

## [1.2.1] - 2026-08-31

### Added

- Select the newest mature npm package release after a release-age cooldown.
- Allow configured tools such as Git to track non-production releases.

### Changed

- Accept supported semantic-version variants while tightening prerelease detection.
- Update the documentation and screenshots for the `1.2` release line.

## [1.2.0] - 2026-08-17

### Changed

- Improve HTTP timeout handling for release checks.
- Refresh tool status after updates.
- Update execution and summary screenshots.

## [1.1.1] - 2026-08-07

### Added

- Add uv registry policy checks and alignment support.

## [1.1.0] - 2026-08-07

### Added

- Add optional registry policy checks and repair actions for npm, pnpm, pip, and
  NuGet sources.
- Query WinGet for the latest installable package version.
- Add detailed npm error reporting.

### Changed

- Sort and process configured tools alphabetically.

## [1.0.4] - 2026-08-07

### Fixed

- Correct Node.js installation behavior.
- Correct uv installation behavior.

## [1.0.3] - 2026-08-06

### Changed

- Report version checks with indeterminate results instead of treating them as
  successful comparisons.

## [1.0.2] - 2026-08-05

### Added

- Add Python Install Manager inventory and update support.

## [1.0.1] - 2026-08-04

### Added

- Display the npm and pnpm registry used for package metadata queries.
- Add more detailed error output for failed checks.

## [1.0.0] - 2026-08-03

### Added

- Add the initial PowerShell tool inventory, version checking, and update workflow.
- Add configuration for development tools, package managers, SDKs, and runtimes.

[Unreleased]: https://github.com/simonkurtz-MSFT/tool-checker/compare/2.1.0...HEAD
[2.1.0]: https://github.com/simonkurtz-MSFT/tool-checker/compare/2.0.0...2.1.0
[2.0.0]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.2.5...2.0.0
[1.2.5]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.2.4...1.2.5
[1.2.4]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.2.3...1.2.4
[1.2.3]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.2.2...1.2.3
[1.2.2]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.2.1...1.2.2
[1.2.1]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.2.0...1.2.1
[1.2.0]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.1.1...1.2.0
[1.1.1]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.1.0...1.1.1
[1.1.0]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.0.4...1.1.0
[1.0.4]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.0.3...1.0.4
[1.0.3]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.0.2...1.0.3
[1.0.2]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/simonkurtz-MSFT/tool-checker/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/simonkurtz-MSFT/tool-checker/releases/tag/1.0.0
