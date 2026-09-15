# Capturing README images

The README images are rendered from an actual Tool Checker terminal session, not
handwritten example output. [`capture-readme.py`](capture-readme.py) launches the
unchanged `tool-checker.ps1` in a Windows pseudoterminal, interprets its ANSI output,
and rasterizes the recorded terminal cells to PNG using Windows console fonts.
No browser or HTML mock terminal is involved.

## Prerequisites

- PowerShell 7 on `PATH` as `pwsh.exe`.
- Python with `venv` and pip.
- Windows Consolas and Segoe UI Symbol fonts.
- Internet access and the development tools you want inventoried.

The capture dependencies (`pywinpty`, `pyte`, and `Pillow`) are documentation-only;
Tool Checker itself does not require Python or these packages.

## Reproduce the captures

Run from the repository root in PowerShell:

```powershell
python -m venv "$env:TEMP\tool-checker-capture-venv"
& "$env:TEMP\tool-checker-capture-venv\Scripts\python.exe" -m pip install pywinpty pyte Pillow
& "$env:TEMP\tool-checker-capture-venv\Scripts\python.exe" ./docs/capture-readme.py
```

To review new images without replacing the checked-in assets, supply
`--output <directory>` to the capture script.

The helper:

1. Creates a temporary directory and passes a nonexistent `capture.env` path with
   `-EnvFile`, leaving the repository's `.env` untouched.
2. Records the version banner and actual first-run setup menu.
3. Sends Enter at the setup prompt to select all enabled catalog tools. The
   application itself creates the temporary environment file from `.env.example`.
4. Records a live progress frame after at least one check completes while another
   is still running.
5. Records the real inventory summary and action menu, then sends `0` to exit.
6. Renders the PNGs and removes the temporary environment directory.

It never passes `-Force` or selects install, update, or registry alignment actions.
Checks query real local tools and remote release sources. They are not mocked.
The capture expects an action menu; if no actions are available, it reports that
not all four stages were captured rather than manufacturing an action.

## Assets and framing

| Asset | Recorded stage |
| --- | --- |
| `assets/tool-checker-setup.png` | Version banner and first-run selection prompt. |
| `assets/tool-checker-execution.png` | Banner, startup diagnostics, registry metadata, and live parallel progress; the already pictured setup menu is omitted. |
| `assets/tool-checker-summary.png` | Banner, cooldown legend, inventory table, and summary notices. |
| `assets/tool-checker-post-execution-summary.png` | Banner and approval menu; the legacy filename is retained, but this image does **not** claim an update or repair was executed. |

The banner is copied from the same recorded screen for context in cropped views.
Text, tool versions, release ages, durations, and available commands are not edited.
ANSI colors are mapped to the terminal palette; font rasterization is not a
pixel-for-pixel screenshot of the VS Code terminal window.

The helper writes its raw ANSI recording to
`$env:TEMP\tool-checker-readme-recording.ansi` and prints the capture timestamp.
That recording stays local because it can include machine-specific paths and
registry diagnostics. Do not commit credentials or private registry endpoints.

The current images were captured from **2.2.0 on September 15, 2026**, selecting
19 enabled tools with registry policy left unset. The configured npm proxy was
used for metadata. An available uv update and pnpm's release cooldown were real
results of that run; they are examples, not assertions about today's releases.

## Before publishing

- [ ] Verify `./tool-checker.ps1 -Version` matches the release named in the README.
- [ ] Inspect every image for clipping, missing glyphs, credentials, and private URLs.
- [ ] Confirm versions, timings, and results originate from the recording.
- [ ] Update the README release, capture date, captions, and alt text as needed.
- [ ] Keep captions honest about whether any machine-changing actions occurred.
- [ ] Verify README image paths and documentation links resolve.
