#!/usr/bin/env bash
# setup-steam-340.sh
# Make Steam games run HARDWARE-accelerated on a legacy NVIDIA 340.xx GPU
# (GeForce 9600 GT / G94 / Tesla) on CachyOS/Arch.
#
# The problem (and the fix) in one paragraph:
#   Steam runs games inside the pressure-vessel container. The 340 driver is
#   pre-glvnd (no libGLX_nvidia.so), so the container falls back to Mesa's
#   llvmpipe SOFTWARE renderer => ~1 FPS. The fix is per-game launch options:
#       PROTON_USE_WINED3D=1 __GL_SHADER_DISK_CACHE=1 STEAM_RUNTIME=0 %command%
#   STEAM_RUNTIME=0 makes the container use the HOST nvidia GL (hardware);
#   PROTON_USE_WINED3D forces the OpenGL path for Windows games (Tesla has no
#   Vulkan, so DXVK/VKD3D/gamescope are impossible); the shader disk cache kills
#   WineD3D first-encounter compile stutter (freezes).
#
# This installs the host GL + 32-bit deps, the steam-340-fix helper, and
# (optionally) GE-Proton11 repointed onto the stable 'sniper' runtime — see
# userspace/STEAM-GAMING.md for the full story incl. the SLR 4.0 trap.
set -euo pipefail
err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] && { err "Run as your normal user, not root."; exit 1; }
command -v pacman >/dev/null || { err "Not an Arch-based system."; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! grep -qzoP '\[multilib\]\s*\n\s*Include' /etc/pacman.conf 2>/dev/null; then
  warn "[multilib] looks disabled in /etc/pacman.conf — 32-bit Steam games need it."
  warn "Enable it, run 'sudo pacman -Syu', then re-run this script."
fi

info "Installing host nvidia GL (64+32-bit) and common 32-bit game deps..."
# nvidia-340xx-utils / lib32-nvidia-340xx-utils come from the AUR (paru/yay).
AUR=""
for h in paru yay; do command -v "$h" >/dev/null && AUR="$h" && break; done
if [[ -n "$AUR" ]]; then
  "$AUR" -S --needed --noconfirm nvidia-340xx-utils lib32-nvidia-340xx-utils || \
    warn "Install nvidia-340xx-utils + lib32-nvidia-340xx-utils from the AUR manually."
else
  warn "No AUR helper found — install nvidia-340xx-utils + lib32-nvidia-340xx-utils from the AUR."
fi
# These resolve the 'libSDL2 not found' etc. that break native Source games
# launched outside the runtime (STEAM_RUNTIME=0).
sudo pacman -S --needed --noconfirm \
  lib32-sdl2 lib32-openal lib32-libvorbis lib32-libtheora || \
  warn "Could not install all 32-bit game deps; install lib32-sdl2 at minimum."

info "Installing steam-340-fix helper -> ~/.local/bin/steam-340-fix"
mkdir -p ~/.local/bin
install -m755 "$HERE/steam-340-fix" ~/.local/bin/steam-340-fix

info "Making PROTON_USE_WINED3D global (env.d)..."
mkdir -p ~/.config/environment.d
conf=~/.config/environment.d/90-tesla-gaming.conf
grep -q PROTON_USE_WINED3D "$conf" 2>/dev/null || cat >>"$conf" <<'E'
# GeForce 9600 GT (Tesla) has NO Vulkan -> force Proton's WineD3D (OpenGL) path.
PROTON_USE_WINED3D=1
# Persistent nvidia shader cache -> fewer WineD3D compile freezes.
__GL_SHADER_DISK_CACHE=1
__GL_SHADER_DISK_CACHE_SIZE=1000000000
E
mkdir -p ~/.nv/GLCache

cat <<'NEXT'

[*] Base install done. To finish:

  1. (Recommended) Install a MODERN Wine on the stable runtime:
       latest GE-Proton11 -> ~/.steam/root/compatibilitytools.d/GE-Proton11-1
       then repoint it onto 'sniper' (SLR 4.0 is broken on this box):
         sed -i 's/"require_tool_appid" *"4183110"/"require_tool_appid" "1628350"/' \
           ~/.steam/root/compatibilitytools.d/GE-Proton11-1/toolmanifest.vdf

  2. Open Steam once (so config.vdf has a CompatToolMapping), then:
       steam -shutdown
       steam-340-fix GE-Proton11-1     # or 'proton_9' if you skipped step 1
       # ^ sets the universal launch option on every installed game and the
       #   default Steam Play tool for new Windows games.

  3. Start Steam, hit Play. Native + Proton games now run on the GPU.

  See userspace/STEAM-GAMING.md for why, and for the SLR 4.0 trap.
NEXT
info "Done."
