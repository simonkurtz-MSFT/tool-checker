"""Record the real Windows PowerShell terminal; render its ANSI cells to README PNGs.

Requires pywinpty, pyte, and Pillow in an isolated Python environment.
Never selects an install, update, or registry-repair action.
"""
from __future__ import annotations

import argparse
import json
import queue
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path

import pyte
from PIL import Image, ImageDraw, ImageFont
from winpty import PtyProcess


COLORS = {
    "default": "#cccccc", "black": "#0c0c0c", "red": "#c50f1f",
    "green": "#13a10e", "brown": "#c19c00", "blue": "#3b78ff",
    "magenta": "#881798", "cyan": "#3a96dd", "white": "#cccccc",
    "brightblack": "#767676", "brightred": "#e74856",
    "brightgreen": "#16c60c", "brightbrown": "#f9f1a5",
    "brightblue": "#3b78ff", "brightmagenta": "#b4009e",
    "brightcyan": "#61d6d6", "brightwhite": "#f2f2f2",
}


def render(lines: list, destination: Path) -> None:
    """Rasterize recorded terminal cells, preserving text, positions, and ANSI colors."""
    font = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 18)
    bold = ImageFont.truetype("C:/Windows/Fonts/consolab.ttf", 18)
    symbols = ImageFont.truetype("C:/Windows/Fonts/seguisym.ttf", 18)
    cell_width = font.getlength("M")
    row_height = 24
    used_width = max((max((x + 1 for x, c in line.items() if c.data.strip()), default=0)
                      for line in lines), default=80)
    image = Image.new("RGB", (round(used_width * cell_width) + 48,
                               len(lines) * row_height + 48), "#0c0c0c")
    draw = ImageDraw.Draw(image)
    for y, line in enumerate(lines):
        for x, cell in line.items():
            if not cell.data.strip():
                continue
            color = COLORS.get(cell.fg, f"#{cell.fg}")
            draw.text((24 + x * cell_width, 24 + y * row_height), cell.data,
                      font=symbols if any(ord(c) > 0x25FF for c in cell.data) else (bold if cell.bold else font), fill=color)
    image.save(destination)


def snapshot(screen: pyte.Screen) -> list:
    # Copies preserve the exact recorded state while the terminal continues running.
    return [dict(screen.buffer[y]) for y in range(screen.lines)]


def trim(lines: list) -> list:
    while lines and not any(cell.data.strip() for cell in lines[-1].values()):
        lines.pop()
    while lines and not any(cell.data.strip() for cell in lines[0].values()):
        lines.pop(0)
    return lines


def text(line: dict) -> str:
    return "".join(line.get(x, pyte.screens.Char(data=" ")).data
                   for x in range(max(line, default=0) + 1))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "assets")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    args.output.mkdir(parents=True, exist_ok=True)
    screen = pyte.Screen(300, 220)
    stream = pyte.Stream(screen)
    events: queue.Queue = queue.Queue()
    captures = {}
    banner = []
    chunks = []
    setup_answered = False
    menu_answered = False
    with tempfile.TemporaryDirectory(prefix="tool-checker-readme-") as temporary:
        environment = Path(temporary) / "capture.env"
        command = ["pwsh.exe", "-NoLogo", "-NoProfile", "-Command",
                   f"& './tool-checker.ps1' -EnvFile '{environment}'"]
        process = PtyProcess.spawn(command, cwd=str(root), dimensions=(220, 300))

        def read_terminal() -> None:
            try:
                while True:
                    chunk = process.read(65536)
                    if chunk:
                        events.put(chunk)
                    else:
                        break
            except EOFError:
                pass
            except Exception as error:  # noqa: BLE001 -- propagate reader-thread failures to the main thread
                events.put(error)
            finally:
                events.put(None)

        threading.Thread(target=read_terminal, daemon=True).start()
        try:
            while True:
                chunk = events.get(timeout=180)
                if chunk is None:
                    break
                if isinstance(chunk, Exception):
                    raise chunk
                chunks.append(chunk)
                stream.feed(chunk)
                display = "\n".join(screen.display)
                if not setup_answered and "Tools:" in display:
                    captures["tool-checker-setup.png"] = trim(snapshot(screen))
                    banner = captures["tool-checker-setup.png"][:3]
                    # Accept all enabled tools in the isolated first-run environment.
                    process.write("\r")
                    setup_answered = True
                if ("Elapsed:" in display and "Completed:" in display and "Running:" in display
                        and "tool-checker-execution.png" not in captures):
                    lines = trim(snapshot(screen))
                    startup_index = next(i for i, line in enumerate(lines)
                                         if "Process elevated" in text(line))
                    # Omit the setup section already shown in its own image.
                    captures["tool-checker-execution.png"] = banner + [{}] + trim(lines[startup_index:])
                if not menu_answered and "Select option:" in display:
                    lines = trim(snapshot(screen))
                    summary_index = next(i for i, line in enumerate(lines)
                                         if "npm release cooldown:" in text(line) or "► Summary" in text(line))
                    actions_index = next(i for i, line in enumerate(lines)
                                         if "► Actions" in text(line))
                    captures["tool-checker-summary.png"] = banner + [{}] + trim(lines[summary_index:actions_index])
                    captures["tool-checker-post-execution-summary.png"] = banner + [{}] + trim(lines[actions_index:])
                    # Exit without ever selecting a machine-changing action.
                    process.write("0\r")
                    menu_answered = True
            if "tool-checker-summary.png" not in captures:
                lines = trim(snapshot(screen))
                summary_index = next(i for i, line in enumerate(lines)
                                     if "npm release cooldown:" in text(line) or "► Summary" in text(line))
                captures["tool-checker-summary.png"] = trim(lines[summary_index:])
        finally:
            if process.isalive():
                process.terminate(force=True)
    for name, lines in captures.items():
        render(lines, args.output / name)
        print(f"Saved {name}: {len(lines)} recorded rows")
    # Keep the raw recording local: it can contain machine-specific paths and diagnostics.
    recording = Path(tempfile.gettempdir()) / "tool-checker-readme-recording.ansi"
    recording.write_text("".join(chunks), encoding="utf-8")
    print(json.dumps({"captured_at": datetime.now(timezone.utc).isoformat(),
                      "recording": str(recording), "images": list(captures)}, indent=2))
    if not all(name in captures for name in ("tool-checker-setup.png",
                                            "tool-checker-execution.png",
                                            "tool-checker-summary.png",
                                            "tool-checker-post-execution-summary.png")):
        raise RuntimeError("Run did not produce all four capture stages; inspect the recording.")


if __name__ == "__main__":
    main()
