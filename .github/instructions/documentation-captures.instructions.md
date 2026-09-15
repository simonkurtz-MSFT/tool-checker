---
description: "Maintain README documentation and authentic terminal captures. Use when refreshing README images or the documentation capture workflow."
applyTo: "README.md,docs/capture-readme.py,docs/capturing-readme-images.md,docs/assets/*.png"
---

# Documentation captures

- Use `docs/capture-readme.py` and the workflow in `docs/capturing-readme-images.md`
  to capture actual application output; never fabricate tool versions, timings,
  inventory rows, or action outcomes.
- Read the application version from `tool-checker.ps1`; align the README release,
  image captions, alt text, and capture provenance with the recorded run.
- Use an isolated temporary environment file, leave the user's `.env` untouched,
  omit `-Force`, and exit the action menu without installing, updating, or repairing
  registries. Do not execute machine-changing actions merely to obtain an image.
- Keep raw recordings local; inspect published images for credentials, private
  endpoints, clipping, and Unicode glyph rendering.
- Preserve the initial recorded banner before terminal scrolling; cropped stages
  may reuse that banner, but must not imply actions were performed when they were
  only offered. Document framing and terminal-cell rendering honestly.
- Validate capture-script syntax, editor diagnostics, local documentation links,
  image decoding, and `git diff --check`; no application version bump is needed
  for documentation-only refreshes.
