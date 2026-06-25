#!/usr/bin/env bash
# setup-gaming-9600gt.sh
# Wine gaming setup for a GeForce 9600 GT (G94, Tesla) on CachyOS + nouveau.
#
# Why NO DXVK here:
#   DXVK translates Direct3D 9/10/11 -> Vulkan. The Tesla chip in the 9600 GT has
#   NO hardware Vulkan at all (neither nouveau/NVK nor the proprietary 340 driver
#   expose a Vulkan device). So DXVK cannot run on the GPU. The only way to "run"
#   DXVK would be a CPU software-Vulkan (lavapipe), which is slower than just using
#   WineD3D's hardware OpenGL path on this DX9/DX10-era card.
#
#   => This script forces WineD3D (Direct3D -> OpenGL, hardware-accelerated by nouveau)
#      and explicitly DISABLES DXVK so Wine never tries the dead Vulkan path.
#
# Prerequisite: run optimize-nouveau-cachyos.sh first (open Mesa stack + pinned pstate).
set -euo pipefail

err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] && { err "Run as a normal user, not root."; exit 1; }
command -v pacman >/dev/null || { err "Not an Arch-based system."; exit 1; }

# multilib is required for 32-bit Wine deps (most old DX9 games are 32-bit).
if ! grep -qzoP '\[multilib\]\s*\n\s*Include' /etc/pacman.conf 2>/dev/null; then
  warn "[multilib] repo may be disabled in /etc/pacman.conf — 32-bit games need it."
  warn "Enable it (uncomment [multilib] + Include line), run 'sudo pacman -Syu', then re-run."
fi

# --- 1. Install Wine + helpers (NO dxvk package) -----------------------------
info "Installing Wine (staging) + winetricks + 32-bit GL/audio libs..."
sudo pacman -S --needed --noconfirm \
  wine-staging winetricks \
  mesa lib32-mesa mesa-utils \
  lib32-gnutls lib32-libpulse \
  || { err "Package install failed (check [multilib])."; exit 1; }

# --- 2. Create a clean WINEPREFIX configured for WineD3D ----------------------
PFX="${WINEPREFIX:-$HOME/.wine-9600gt}"
info "Creating Wine prefix at: $PFX"
export WINEPREFIX="$PFX"
export WINEARCH=win32       # DX9-era titles are overwhelmingly 32-bit
export WINEDLLOVERRIDES="dxgi,d3d9,d3d10core,d3d11=b"   # force builtin WineD3D, never DXVK
wineboot --init >/dev/null 2>&1 || true
info "Prefix initialized (WINEARCH=win32)."

# --- 3. Force the WineD3D (OpenGL) renderer in the registry ------------------
# renderer=gl  -> WineD3D uses OpenGL (hardware on nouveau). 'vulkan' would need DXVK.
info "Forcing WineD3D OpenGL renderer in the prefix registry..."
cat > /tmp/wined3d-9600gt.reg <<'REG'
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Wine\Direct3D]
"renderer"="gl"
"VideoMemorySize"="512"
"csmt"=dword:00000001
REG
wine regedit /tmp/wined3d-9600gt.reg >/dev/null 2>&1 || warn "regedit import failed (run after a desktop session)."
rm -f /tmp/wined3d-9600gt.reg

# --- 4. A launcher wrapper that always disables DXVK -------------------------
LAUNCHER="$HOME/.local/bin/wine9600"
mkdir -p "$HOME/.local/bin"
cat > "$LAUNCHER" <<LAUNCH
#!/usr/bin/env bash
# Launch a Windows game on the 9600 GT via WineD3D (hardware OpenGL), DXVK disabled.
# Tuned for a WEAK CPU (Intel i3-2120/2130 = Sandy Bridge, 2 cores / 4 threads).
export WINEPREFIX="$PFX"
# Builtin (WineD3D) for all D3D DLLs -> never load DXVK even if present:
export WINEDLLOVERRIDES="dxgi,d3d9,d3d10core,d3d11=b"

# --- CPU-offload sync primitives (matter a LOT on a 2-core Sandy Bridge) ---
# fsync cuts kernel/sync overhead the most; needs a CachyOS/fsync-patched kernel
# (CachyOS kernels ship it). esync is the fallback if fsync is unsupported.
export WINEFSYNC=1
export WINEESYNC=1

# --- Mesa/nouveau OpenGL tuning ---
export __GL_SHADER_DISK_CACHE=1
export MESA_SHADER_CACHE_DISABLE=false

# mesa_glthread: helps GPUs with spare CPU headroom, but on a 2c/4t Sandy Bridge
# it can REGRESS because there are few free threads. Default OFF.
# Try it per-game: 'WINE9600_GLTHREAD=1 wine9600 game.exe' and compare FPS.
if [[ "\${WINE9600_GLTHREAD:-0}" == "1" ]]; then
  export mesa_glthread=true
fi

# --- Virtual desktop = the gamescope replacement on this rig ---------------
# Runs the game inside a fixed-resolution Wine "desktop" window. This is what you
# actually want gamescope for (locked resolution, no tearing, contained window),
# but with ZERO extra compositor/Vulkan layer — gamescope needs Vulkan, which the
# Tesla GPU lacks, and would only burn the weak CPU via software-Vulkan.
#   Lower the resolution here to gain FPS on the old GPU. Examples:
#     WINE9600_RES=1280x720  wine9600 game.exe
#     WINE9600_RES=1024x768  wine9600 game.exe   (4:3 titles)
#   Unset/empty => game runs in its own native mode (no virtual desktop).
WINE9600_DESKTOP_ARGS=()
if [[ -n "\${WINE9600_RES:-}" ]]; then
  WINE9600_DESKTOP_ARGS=(explorer "/desktop=game,\${WINE9600_RES}")
fi

exec wine "\${WINE9600_DESKTOP_ARGS[@]}" "\$@"
LAUNCH
chmod +x "$LAUNCHER"

cat <<EOF

============================================================
 Done. Wine is set up for WineD3D (OpenGL), DXVK disabled.
============================================================
Prefix:   $PFX   (WINEARCH=win32)
Launcher: $LAUNCHER   (make sure ~/.local/bin is in PATH)

Run a game:
  wine9600 /path/to/game.exe
  # or directly:
  WINEPREFIX="$PFX" WINEDLLOVERRIDES="dxgi,d3d9,d3d10core,d3d11=b" wine game.exe

Verify the GPU is actually doing the work (not llvmpipe/CPU):
  glxinfo | grep "OpenGL renderer"     # must say NVxx / NV94 / nouveau, NOT 'llvmpipe'

Tips for this rig (9600 GT + i3-2120/2130 Sandy Bridge, 2c/4t):
  * Old DX9/DX10 games only: WineD3D -> OpenGL is the fast, correct path here.
  * Run optimize-nouveau-cachyos.sh FIRST so the GPU pstate is pinned to max,
    otherwise everything runs at ~10% GPU speed. On a weak CPU you can't afford that too.
  * fsync/esync are enabled to offload sync work from the slow CPU. If a game misbehaves,
    disable per-run: 'WINEFSYNC=0 WINEESYNC=0 wine9600 game.exe'.
  * glthread is OFF by default (can hurt on 2 cores). Test it: 'WINE9600_GLTHREAD=1 wine9600 game.exe'.
  * The CPU is the bottleneck as much as the GPU. Lower in-game resolution/effects helps both.
  * 64-bit-only games: make a separate WINEARCH=win64 prefix; still WineD3D, still no DXVK.
  * D3D11+/D3D12/Vulkan games CANNOT run: Tesla has no hardware Vulkan. Hardware limit, not config.
    DXVK is pointless on this GPU for the same reason (it needs Vulkan).
EOF
