#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
nv9600gt — control panel for a GeForce 9600 GT (G94, Tesla) rig on CachyOS.

Free-people tooling: keyless, no vendor API, no telemetry. It just orchestrates
the shell scripts that live next to it and downloads the official NVIDIA 340.108
legacy .run directly from NVIDIA's public mirror (no account, no API key).

GUI (Tkinter) if a display is available; otherwise a plain text menu (TUI).
Pure Python standard library — nothing to pip install.

Actions:
  1. Install proprietary 340.108 (DKMS, Xorg-only)   -> install-cachyos.sh
  2. Optimize nouveau + Wayland (reclocking)         -> optimize-nouveau-cachyos.sh
  3. System optimization (weak rig)                  -> optimize-system-cachyos.sh
  4. Gaming setup (WineD3D, no DXVK)                 -> setup-gaming-9600gt.sh
  5. Build yserver (experimental X11 in Rust)        -> build-yserver.sh
  6. Download 340.108 .run only (no install)         -> direct NVIDIA download
  7. Show GPU / driver status

The proprietary driver and nouveau are mutually exclusive: picking #1 conflicts
with #2/#5. The app warns about that, but the final choice is yours.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
HERE = Path(__file__).resolve().parent

# Official NVIDIA 340.108 Linux x86_64 legacy driver (public, no account needed).
# This is the last release of the 340.xx branch that supports the 9600 GT (G94).
NV_340_VERSION = "340.108"
NV_340_RUNFILE = f"NVIDIA-Linux-x86_64-{NV_340_VERSION}.run"
# Primary + mirror download URLs (us./international). Both are NVIDIA-hosted.
NV_340_URLS = [
    f"https://us.download.nvidia.com/XFree86/Linux-x86_64/{NV_340_VERSION}/{NV_340_RUNFILE}",
    f"https://download.nvidia.com/XFree86/Linux-x86_64/{NV_340_VERSION}/{NV_340_RUNFILE}",
    f"https://international.download.nvidia.com/XFree86/Linux-x86_64/{NV_340_VERSION}/{NV_340_RUNFILE}",
]

SCRIPTS = {
    "install_proprietary": "install-cachyos.sh",
    "optimize_nouveau": "optimize-nouveau-cachyos.sh",
    "optimize_system": "optimize-system-cachyos.sh",
    "gaming": "setup-gaming-9600gt.sh",
    "yserver": "build-yserver.sh",
}


# ---------------------------------------------------------------------------
# Core helpers (UI-agnostic)
# ---------------------------------------------------------------------------
def script_path(key: str) -> Path:
    return HERE / SCRIPTS[key]


def run_script(key: str) -> int:
    """Run a sibling shell script in a terminal, return its exit code."""
    path = script_path(key)
    if not path.exists():
        print(f"[!] Missing script: {path}", file=sys.stderr)
        return 127
    os.chmod(path, 0o755)
    print(f"[*] Running {path.name} ...")
    try:
        return subprocess.call(["bash", str(path)])
    except KeyboardInterrupt:
        print("\n[~] Interrupted.")
        return 130


def gpu_status() -> str:
    """Best-effort GPU/driver status using only standard CLI tools."""
    lines = []

    def cmd(args):
        try:
            return subprocess.run(
                args, capture_output=True, text=True, timeout=10
            ).stdout.strip()
        except Exception as e:  # noqa: BLE001 - report, don't crash
            return f"(failed: {e})"

    lspci = cmd(["sh", "-c", "lspci -k | grep -A3 -Ei 'vga|3d' || true"])
    lines.append("== lspci (GPU + kernel driver in use) ==")
    lines.append(lspci or "(no GPU line found)")

    if shutil.which("nvidia-smi"):
        lines.append("\n== nvidia-smi ==")
        lines.append(cmd(["nvidia-smi", "--query-gpu=name,driver_version",
                           "--format=csv,noheader"]) or "(no output)")
    else:
        lines.append("\n== nvidia-smi == not installed (expected on nouveau)")

    if shutil.which("glxinfo"):
        lines.append("\n== OpenGL renderer ==")
        lines.append(cmd(["sh", "-c",
                          "glxinfo | grep -E 'OpenGL renderer|OpenGL version' || true"])
                     or "(no glxinfo output)")
    else:
        lines.append("\n== glxinfo == not installed (pacman -S mesa-utils)")

    # nouveau pstate (the reclocking win), if present
    pstate = cmd(["sh", "-c",
                  "cat /sys/kernel/debug/dri/*/pstate 2>/dev/null || true"])
    if pstate:
        lines.append("\n== nouveau pstate (reclocking; '*' should be on the highest) ==")
        lines.append(pstate)

    return "\n".join(lines)


def download_runfile(dest_dir: Path, progress=None) -> Path | None:
    """Download the official 340.108 .run from NVIDIA. Returns the saved path."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / NV_340_RUNFILE
    if dest.exists() and dest.stat().st_size > 1_000_000:
        if progress:
            progress(f"Already downloaded: {dest} ({dest.stat().st_size//1024} KiB)")
        return dest

    last_err = None
    for url in NV_340_URLS:
        try:
            if progress:
                progress(f"Trying {url} ...")

            def _hook(block, bsize, total):
                if progress and total > 0:
                    pct = min(100, block * bsize * 100 // total)
                    progress(f"Downloading {NV_340_RUNFILE}: {pct}%")

            tmp, _ = urllib.request.urlretrieve(url, dest, _hook)
            # sanity: the .run is several MB; reject tiny error pages
            if Path(tmp).stat().st_size < 1_000_000:
                raise OSError("downloaded file too small (likely an error page)")
            os.chmod(dest, 0o755)
            if progress:
                progress(f"Saved: {dest}")
            return dest
        except Exception as e:  # noqa: BLE001
            last_err = e
            if progress:
                progress(f"  failed: {e}")
            if dest.exists():
                dest.unlink(missing_ok=True)
    if progress:
        progress(f"[!] All mirrors failed. Last error: {last_err}")
    return None


# ---------------------------------------------------------------------------
# Text menu (TUI) — used when no display / Tkinter unavailable
# ---------------------------------------------------------------------------
MENU = [
    ("Install proprietary 340.108 (DKMS, Xorg-only)", "install_proprietary"),
    ("Optimize nouveau + Wayland (reclocking)", "optimize_nouveau"),
    ("System optimization (weak rig: i3-2120 + 8GB)", "optimize_system"),
    ("Gaming setup (WineD3D, DXVK disabled)", "gaming"),
    ("Build yserver (experimental Rust X11)", "yserver"),
    ("Download 340.108 .run only (no install)", "download"),
    ("Show GPU / driver status", "status"),
    ("Quit", "quit"),
]


def run_tui() -> int:
    while True:
        print("\n=== nv9600gt control panel (TUI) ===")
        for i, (label, _) in enumerate(MENU, 1):
            print(f"  {i}. {label}")
        choice = input("Select: ").strip()
        if not choice.isdigit() or not (1 <= int(choice) <= len(MENU)):
            print("Invalid choice.")
            continue
        action = MENU[int(choice) - 1][1]
        if action == "quit":
            return 0
        elif action == "status":
            print("\n" + gpu_status())
        elif action == "download":
            download_runfile(HERE / "downloads", progress=print)
        else:
            if action in ("optimize_nouveau", "yserver"):
                print("[~] Note: this path uses NOUVEAU. Do not combine with the "
                      "proprietary 340 driver.")
            elif action == "install_proprietary":
                print("[~] Note: proprietary 340 is Xorg-only and conflicts with "
                      "nouveau/yserver/Wayland.")
            run_script(action)


# ---------------------------------------------------------------------------
# GUI (Tkinter) — used when a display is available
# ---------------------------------------------------------------------------
def run_gui() -> int:
    import tkinter as tk
    from tkinter import messagebox, scrolledtext

    root = tk.Tk()
    root.title("nv9600gt — GeForce 9600 GT control panel")
    root.geometry("640x520")

    tk.Label(root, text="GeForce 9600 GT (G94 / Tesla) — CachyOS control panel",
             font=("sans", 12, "bold")).pack(pady=8)
    tk.Label(root, text="Made in Ingria by Free People · keyless · no vendor API",
             font=("sans", 8)).pack()

    out = scrolledtext.ScrolledText(root, height=14, wrap="word")
    out.pack(fill="both", expand=True, padx=8, pady=8)

    def log(msg: str):
        out.insert("end", msg + "\n")
        out.see("end")
        root.update_idletasks()

    def do_script(key: str, warn: str | None = None):
        if warn and not messagebox.askyesno("Confirm", warn):
            return
        log(f"[*] Launching {SCRIPTS[key]} in a terminal...")
        # Run in a real terminal so interactive prompts work; fall back to inline.
        term = next((t for t in ("konsole", "alacritty", "kitty", "xterm")
                     if shutil.which(t)), None)
        path = str(script_path(key))
        os.chmod(path, 0o755)
        if term:
            flag = "-e" if term != "konsole" else "--noclose -e"
            subprocess.Popen([*term.split(), *flag.split(), "bash", path])
            log(f"    started in {term}.")
        else:
            log("    no terminal emulator found; running inline (output below).")
            rc = subprocess.call(["bash", path])
            log(f"    exit code {rc}")

    def do_status():
        log("\n" + gpu_status())

    def do_download():
        log("[*] Downloading official NVIDIA 340.108 .run ...")
        p = download_runfile(HERE / "downloads", progress=log)
        if p:
            log(f"[*] Done: {p}")
        else:
            messagebox.showerror("Download failed",
                                 "All NVIDIA mirrors failed. Check connection.")

    buttons = [
        ("Install proprietary 340.108 (Xorg-only)", lambda: do_script(
            "install_proprietary",
            "Proprietary 340 is Xorg-ONLY and conflicts with nouveau/Wayland/yserver.\nContinue?")),
        ("Optimize nouveau + Wayland (reclocking)", lambda: do_script("optimize_nouveau")),
        ("System optimization (weak rig)", lambda: do_script("optimize_system")),
        ("Gaming setup (WineD3D, no DXVK)", lambda: do_script("gaming")),
        ("Build yserver (experimental Rust X11)", lambda: do_script(
            "yserver",
            "yserver is EXPERIMENTAL and needs nouveau (NEVER works on proprietary 340).\nBuild it?")),
        ("Download 340.108 .run only", do_download),
        ("Show GPU / driver status", do_status),
    ]
    btnframe = tk.Frame(root)
    btnframe.pack(fill="x", padx=8, pady=4)
    for i, (label, cb) in enumerate(buttons):
        tk.Button(btnframe, text=label, command=cb, anchor="w").grid(
            row=i // 2, column=i % 2, sticky="ew", padx=3, pady=3)
    btnframe.columnconfigure(0, weight=1)
    btnframe.columnconfigure(1, weight=1)

    tk.Button(root, text="Quit", command=root.destroy).pack(pady=6)

    log(gpu_status())
    root.mainloop()
    return 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> int:
    if "--tui" in sys.argv:
        return run_tui()
    # GUI only if a display is present and Tkinter imports.
    if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
        try:
            return run_gui()
        except Exception as e:  # noqa: BLE001 - fall back to text menu
            print(f"[~] GUI unavailable ({e}); falling back to text menu.")
    return run_tui()


if __name__ == "__main__":
    sys.exit(main())
