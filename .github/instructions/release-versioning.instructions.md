---
description: "Maintain the Tool Checker application version and Keep a Changelog release history. Use when bumping versions, preparing releases, or editing CHANGELOG.md."
applyTo: "tool-checker.ps1,CHANGELOG.md"
---

# Release versioning

- Treat `$script:ToolCheckerVersion` in `tool-checker.ps1` as the single source of
  truth for the application version. Do not duplicate it in the catalog or another
  file.
- Use a stable Semantic Versioning `MAJOR.MINOR.PATCH` value unless the release
  explicitly requires a prerelease version. Choose the increment from the shipped
  behavior: breaking changes increment `MAJOR`, backward-compatible features
  increment `MINOR`, and backward-compatible fixes increment `PATCH`.
- Keep a version bump and its changelog release entry in the same change. After
  validation, commit the release files with the exact message `Set V<version>`,
  preserving the uppercase `V`, then create the matching `<version>` Git tag on that
  commit. For example, version `2.2.0` uses commit message `Set V2.2.0` and tag
  `2.2.0`. Do not push the commit or tag or create a GitHub release unless explicitly
  requested.
- Maintain `CHANGELOG.md` in Keep a Changelog format. Record notable user-facing
  changes under `Unreleased` as they are introduced; omit formatting-only churn and
  test-only changes unless they materially affect contributors or release confidence.
- When preparing a release, rename the populated `Unreleased` section to the exact
  version and release date in `YYYY-MM-DD` format, then add a new empty `Unreleased`
  section above it. Use only applicable Keep a Changelog categories: `Added`,
  `Changed`, `Deprecated`, `Removed`, `Fixed`, and `Security`.
- Preserve existing release history. Write entries as concise outcomes for users or
  contributors rather than commit-message copies, and group related commits into one
  entry when they deliver one change.
- Update the reference links at the bottom of `CHANGELOG.md`: point `Unreleased` from
  the new version to `HEAD`, add the new version comparison from the previous version,
  and retain all older links.
- Validate a bump by running `./tool-checker.ps1 -Version` and confirming that it
  prints exactly the intended version without loading configuration. Run
  `git diff --check -- tool-checker.ps1 CHANGELOG.md` and check both files for editor
  diagnostics. Run focused Pester coverage when release work changes behavior in
  addition to metadata.