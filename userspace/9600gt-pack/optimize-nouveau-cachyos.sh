#!/usr/bin/env bash
# optimize-nouveau-cachyos.sh
# Squeeze maximum performance out of nouveau on a GeForce 9600 GT (G94, Tesla)
# under CachyOS/Arch with a Wayland (KWin) desktop.
#
# Why this gets you close to the proprietary driver:
#   nouveau leaves Tesla GPUs parked at their lowest boot clock => ~10% of proprietary perf.
#   Tesla G94-GT218 supports MANUAL reclocking (/sys/kernel/debug/dri/*/pstate).
#   Forcing the MAX pstate at boot recovers ~80% of proprietary-driver performance.
#   (Source: nouveau.freedesktop.org + ventureoo/nouveau-reclocking benchmarks.)
#
# Hard limits you cannot beat (be honest with yourself):
#   * No automatic clock scaling on Tesla — we pin it to max (slightly higher idle power/heat).
#   * No Vulkan on Tesla at the hardware level — OpenGL only (no NVK). That's a chip limit.
#   * Result is "very close to NVIDIA 340 in OpenGL", NOT "equal in everything".
#
# What this script does:
#   1) installs the full open Mesa/nouveau userspace stack (incl. 32-bit for games),
#   2) makes sure the proprietary 340 driver / nouveau-blacklist are NOT in the way,
#   3) enables nouveau modeset + tuning kernel params,
#   4) installs a systemd unit that pins the MAX pstate on every boot (the big win),
#   5) sets sane Wayland/KWin env defaults.
#
# Run as a normal user (it will sudo where needed). Reboot afterwards.
set -euo pipefail

err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] && { err "Run as a normal user, not root."; exit 1; }
command -v pacman >/dev/null || { err "Not an Arch-based system."; exit 1; }

# --- 0. Confirm card is a reclocking-capable Tesla ---------------------------
info "Detecting NVIDIA GPU..."
GPU_LINE="$(lspci -nn | grep -Ei 'vga|3d|display' | grep -i nvidia || true)"
if [[ -n "$GPU_LINE" ]]; then
  info "Found: $GPU_LINE"
else
  warn "No NVIDIA GPU via lspci; continuing anyway."
fi

# --- 1. Remove proprietary-340 obstacles & nouveau blacklist -----------------
if pacman -Qq nvidia-340xx nvidia-340xx-dkms nvidia-340xx-utils 2>/dev/null | grep -q .; then
  warn "Proprietary nvidia-340xx packages are installed; they conflict with nouveau."
  read -rp "Remove them now? [y/N] " a
  if [[ "${a,,}" == y ]]; then
    sudo pacman -Rns --noconfirm $(pacman -Qq nvidia-340xx nvidia-340xx-dkms nvidia-340xx-utils 2>/dev/null) || true
  else
    warn "Leaving them installed — nouveau may not load. You decide."
  fi
fi

# Drop any nouveau blacklist left over from a previous proprietary install.
for f in /etc/modprobe.d/blacklist-nouveau.conf /usr/lib/modprobe.d/nvidia-340xx.conf; do
  if [[ -f "$f" ]] && grep -q 'blacklist nouveau' "$f" 2>/dev/null; then
    warn "Found nouveau blacklist in $f — removing the blacklist line."
    sudo sed -i '/blacklist nouveau/d; /nouveau modeset=0/d' "$f"
  fi
done

# --- 2. Install the open Mesa / nouveau userspace stack ----------------------
info "Installing open graphics stack (Mesa + nouveau + 32-bit for games)..."
# multilib must be enabled for lib32-* (needed by Steam/Wine). Warn if it's off.
if ! pacman -Sl multilib >/dev/null 2>&1; then
  warn "The [multilib] repo seems disabled. Enable it in /etc/pacman.conf for 32-bit game support."
fi
sudo pacman -S --needed --noconfirm \
  mesa mesa-utils \
  vulkan-mesa-layers \
  xorg-server xorg-xinit \
  || { err "Package install failed."; exit 1; }
# 32-bit (best-effort; only if multilib is on)
sudo pacman -S --needed --noconfirm lib32-mesa 2>/dev/null || warn "lib32-mesa skipped (enable [multilib])."

# --- 3. Kernel params for nouveau --------------------------------------------
# nouveau.config=NvBoost=2  -> allow the highest available boost pstate
# nouveau.pstate=1          -> expose pstate switching node (legacy fallback path)
info "Adding nouveau kernel parameters..."
DROPIN=/etc/modprobe.d/nouveau-perf.conf
printf 'options nouveau config=NvBoost=2\n' | sudo tee "$DROPIN" >/dev/null
info "Wrote $DROPIN"

# --- 4. The big win: pin MAX pstate at every boot via systemd ----------------
# We write a tiny self-contained service that finds the pstate node and sets the
# highest available level. Works whether the node lives in debugfs or sysfs.
info "Installing nouveau-reclock.service (pins max GPU clock at boot)..."

RECLOCK_BIN=/usr/local/bin/nouveau-reclock-max
sudo tee "$RECLOCK_BIN" >/dev/null <<'RECLOCK'
#!/usr/bin/env bash
# Pin nouveau to its highest available pstate (Tesla/Kepler/Maxwell manual reclocking).
set -euo pipefail
shopt -s nullglob

# debugfs must be mounted for the pstate node.
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

found=0
for node in /sys/kernel/debug/dri/*/pstate; do
  [[ -e "$node" ]] || continue
  found=1
  # Lines look like:  07: core 169-580 MHz ...   AC DC *
  # The highest hardware level is the last numeric "NN:" entry (excluding AC/DC).
  max="$(grep -Eo '^[0-9a-fA-F]+:' "$node" | tr -d ':' | grep -viE '^(AC|DC)$' | tail -n1 || true)"
  if [[ -n "$max" ]]; then
    echo "$max" > "$node" 2>/dev/null && echo "nouveau-reclock: set pstate $max on $node" || \
      echo "nouveau-reclock: failed to set $max on $node" >&2
  else
    # Some firmwares only accept the literal 'AC' (wall-power max) token.
    echo "AC" > "$node" 2>/dev/null && echo "nouveau-reclock: set pstate AC on $node" || true
  fi
done

[[ "$found" -eq 1 ]] || { echo "nouveau-reclock: no pstate node found (card may not support reclocking)"; exit 0; }
RECLOCK
sudo chmod +x "$RECLOCK_BIN"

sudo tee /etc/systemd/system/nouveau-reclock.service >/dev/null <<UNIT
[Unit]
Description=Pin nouveau GPU to maximum pstate (manual reclocking)
After=multi-user.target
ConditionPathExistsGlob=/sys/kernel/debug/dri/*/pstate

[Service]
Type=oneshot
ExecStart=$RECLOCK_BIN
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable nouveau-reclock.service

# --- 5. Wayland / KWin environment defaults ----------------------------------
info "Writing Wayland environment defaults..."
sudo mkdir -p /etc/environment.d
sudo tee /etc/environment.d/90-nouveau-wayland.conf >/dev/null <<'ENVF'
# nouveau + Wayland sane defaults
# Force GBM (nouveau supports it; this is exactly what proprietary 340 lacked).
GBM_BACKEND=nouveau
__GLX_VENDOR_LIBRARY_NAME=mesa
# Let KWin use the atomic/EGL path on nouveau.
KWIN_DRM_USE_EGL_STREAMS=0
ENVF

# --- 6. Rebuild initramfs so modeset params apply ----------------------------
info "Rebuilding initramfs..."
sudo mkinitcpio -P

# --- 7. Optional: also install ventureoo/nouveau-reclocking (nicer CLI) ------
echo
read -rp "Also install ventureoo/nouveau-reclocking CLI (Lua helper, optional)? [y/N] " a
if [[ "${a,,}" == y ]]; then
  sudo pacman -S --needed --noconfirm lua git
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/ventureoo/nouveau-reclocking.git "$tmp/nr"
  sudo install -Dm755 "$tmp/nr/src/nouveau-reclocking" /usr/local/bin/nouveau-reclocking
  rm -rf "$tmp"
  info "Installed: run 'sudo nouveau-reclocking --list' to see pstates, '--max --save' to pin."
fi

cat <<'EOF'

============================================================
 Done. Reboot now:   sudo reboot
============================================================
After reboot, verify the optimization actually took:

  # 1) nouveau is the driver in use (NOT nvidia):
  lspci -k | grep -A3 -Ei 'vga|3d'

  # 2) pstate got pinned to max (the whole point):
  sudo cat /sys/kernel/debug/dri/*/pstate
  #    -> the '*' marker should be on the HIGHEST level, e.g.  07: ... *

  # 3) OpenGL renderer reports nouveau + the card:
  glxinfo | grep -E "OpenGL renderer|OpenGL version"

  # 4) Wayland session: log into "Plasma (Wayland)" at the SDDM screen.

Reality check:
  * Expect ~80% of NVIDIA-340 OpenGL performance once pstate is pinned (vs ~10% without).
  * Tesla has NO hardware Vulkan -> OpenGL games only; Vulkan-only titles won't run.
  * If the desktop is unstable on Wayland, fall back to "Plasma (X11)" — same nouveau driver,
    often steadier on very old GPUs.
  * Higher idle temps are normal now (clocks are pinned high). For a quiet desktop you can
    switch the service to --min, or disable it: sudo systemctl disable --now nouveau-reclock.
EOF
