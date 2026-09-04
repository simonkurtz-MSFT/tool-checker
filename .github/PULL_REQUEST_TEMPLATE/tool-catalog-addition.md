# Tool Catalog Addition

## Summary

<!-- Name the tool and explain briefly why it belongs in the catalog. -->

## Catalog details

| Field | Value |
| --- | --- |
| Tool name | |
| Catalog ID | |
| Check type (`standard` or `custom`) | |
| Supported platforms | |
| Latest-release source | |
| Related issue | |

## Version evidence

<!-- Include sanitized installed-version output and the parsed version. -->

```text

```

<!-- Include a sanitized release response excerpt or its version field. -->

```text

```

## Validation

<!-- List the exact commands run and their results. -->

- [ ] `tool-checker.json` parses successfully.
- [ ] `Invoke-Pester ./tests` passes.
- [ ] A targeted `-SkipUpdate` inventory reports the expected versions.
- [ ] Install and update commands are non-interactive.
- [ ] Commands are verified on each claimed platform, or exceptions are noted.
- [ ] The README catalog ID list and affected configuration documentation are updated.
- [ ] No credentials, private registry URLs, or unrelated changes are included.

## Platform notes

<!-- Note unsupported or unverified platforms and elevation requirements. -->