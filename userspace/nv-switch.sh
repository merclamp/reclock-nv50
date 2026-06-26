#!/usr/bin/env bash
# nv-switch.sh — switch the GeForce 9600 GT (G94 / Tesla) between the proprietary
# NVIDIA 340.108 driver and the open-source nouveau driver, BOTH directions.
#
#   nv-switch.sh status      # show installed packages + what's blacklisted + loaded
#   nv-switch.sh nvidia      # boot the proprietary 340.108 module on next reboot
#   nv-switch.sh nouveau     # boot nouveau on next reboot
#   nv-switch.sh             # same as 'status'
#
# How it works (and why it's reversible):
#   * It only flips WHICH driver the kernel is allowed to load at boot, via a small
#     set of modprobe.d files that nv-switch owns (each carries a "managed by
#     nv-switch" marker). It NEVER removes packages, so flipping back is instant.
#   * The 340xx package drops "blacklist nouveau" into /usr/lib/modprobe.d. You
#     cannot "un-blacklist" from another file, so to enable nouveau we SHADOW those
#     files with same-named empty files in /etc/modprobe.d (/etc wins over /usr/lib).
#   * It rebuilds the initramfs and asks you to reboot. It does NOT hot-swap the GPU
#     driver on a live system (that risks a black screen — reboot is the safe path).
#
# Run as your normal user; it calls sudo where needed.
set -euo pipefail

err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*"; }
hr()   { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# Run as a normal user (uses sudo) OR as root / under `sudo -A bash nv-switch.sh ...`.
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
command -v pacman >/dev/null || { err "Not an Arch-based system."; exit 1; }

MARKER="# managed by nv-switch — do not edit by hand"
SWITCH_CONF=/etc/modprobe.d/zz-nv-switch.conf       # our primary blacklist toggle
LEGACY_BL=/etc/modprobe.d/blacklist-nouveau.conf    # what install-cachyos.sh writes
KREL="$(uname -r)"

# modprobe.d files shipped by the proprietary packages that blacklist nouveau.
# We shadow these (same basename in /etc) to re-enable nouveau.
PKG_NOUVEAU_BLACKLISTS=(
  /usr/lib/modprobe.d/nvidia-340xx-dkms.conf
  /usr/lib/modprobe.d/nvidia-340xx.conf
  /usr/lib/modprobe.d/nvidia.conf
)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
nvidia_installed() {
  pacman -Qq nvidia-340xx-utils >/dev/null 2>&1 && \
  { pacman -Qq nvidia-340xx-dkms >/dev/null 2>&1 || pacman -Qq nvidia-340xx >/dev/null 2>&1; }
}

is_ours() { [[ -f "$1" ]] && head -n1 "$1" 2>/dev/null | grep -qF "$MARKER"; }

backup_aside() {
  # Move a non-nv-switch file aside with a timestamped .bak (only once).
  local f="$1"
  [[ -e "$f" ]] || return 0
  if is_ours "$f"; then return 0; fi
  local bak="${f}.nvswitch-bak-$(date +%Y%m%d%H%M%S)"
  $SUDO mv -f "$f" "$bak"
  warn "moved aside: $f -> $bak"
}

write_managed() {  # $1=path  $2=body
  printf '%s\n%s\n' "$MARKER" "$2" | $SUDO tee "$1" >/dev/null
  $SUDO chmod 0644 "$1"
}

remove_if_ours() { if is_ours "$1"; then $SUDO rm -f "$1"; info "removed: $1"; fi; }

rebuild_initramfs() {
  hr "Rebuilding initramfs"
  $SUDO mkinitcpio -P
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
cmd_status() {
  hr "nv-switch status"
  echo "kernel:            $KREL"
  printf "340xx packages:    "
  if nvidia_installed; then
    echo "installed ($(pacman -Q nvidia-340xx-utils 2>/dev/null | awk '{print $2}'))"
  else
    echo "NOT installed (run install-cachyos.sh to add the proprietary path)"
  fi

  printf "dkms module:       "
  dkms status 2>/dev/null | grep -i 'nvidia.*340\|^nvidia,' | head -1 || echo "—"

  printf "loaded now:        "
  _drv=$(lspci -k 2>/dev/null | grep -A3 -Ei 'vga|3d' | grep -i 'in use' | grep -oiE 'nvidia|nouveau' | head -1)
  [ -z "$_drv" ] && lsmod | grep -q '^nvidia' && _drv=nvidia
  [ -z "$_drv" ] && lsmod | grep -q '^nouveau' && _drv=nouveau
  echo "${_drv:-neither (headless / efifb?)}"

  printf "boot target:       "
  if is_ours "$SWITCH_CONF" && grep -q 'blacklist nvidia' "$SWITCH_CONF" 2>/dev/null; then
    echo "nouveau (nvidia modules blacklisted)"
  elif is_ours "$SWITCH_CONF" && grep -q 'blacklist nouveau' "$SWITCH_CONF" 2>/dev/null; then
    echo "nvidia (nouveau blacklisted)"
  else
    # no nv-switch state: infer from package blacklists
    if ls "${PKG_NOUVEAU_BLACKLISTS[@]}" >/dev/null 2>&1; then
      echo "nvidia (package default blacklists nouveau)"
    else
      echo "nouveau (no blacklist in place)"
    fi
  fi

  printf "nouveau shadows:   "
  local shadows=()
  for f in "${PKG_NOUVEAU_BLACKLISTS[@]}"; do
    local etc="/etc/modprobe.d/$(basename "$f")"
    is_ours "$etc" && shadows+=("$(basename "$etc")")
  done
  [[ ${#shadows[@]} -gt 0 ]] && echo "${shadows[*]}" || echo "none"

  echo
  echo "Driver paths are mutually exclusive. Use an X11 (not Wayland) session for nvidia."
}

# ---------------------------------------------------------------------------
# switch -> nvidia (proprietary 340.108)
# ---------------------------------------------------------------------------
cmd_nvidia() {
  hr "Switching to proprietary NVIDIA 340.108"
  if ! nvidia_installed; then
    err "nvidia-340xx-dkms / nvidia-340xx-utils are not installed."
    err "Install the proprietary path first:  ./install-cachyos.sh"
    exit 1
  fi

  # Re-enable the package nouveau blacklists by removing any shadows we created.
  for f in "${PKG_NOUVEAU_BLACKLISTS[@]}"; do
    remove_if_ours "/etc/modprobe.d/$(basename "$f")"
  done

  # Our own toggle: blacklist nouveau, do NOT blacklist nvidia.
  write_managed "$SWITCH_CONF" $'blacklist nouveau\noptions nouveau modeset=0'
  info "wrote $SWITCH_CONF (blacklist nouveau)"

  rebuild_initramfs

  cat <<EOF

$(printf '\033[1;32m[*]\033[0m') Set to PROPRIETARY 340.108. Reboot:  sudo reboot
After reboot:
  nvidia-smi                          # should report driver 340.108
  lspci -k | grep -A3 -Ei 'vga|3d'    # 'Kernel driver in use: nvidia'
Notes: log into a Plasma (X11) session — 340.xx has no Wayland. Secure Boot must
be OFF (or sign the module via MOK). If the dkms module isn't built, run:
  sudo dkms autoinstall
EOF
}

# ---------------------------------------------------------------------------
# switch -> nouveau (open source, in-tree)
# ---------------------------------------------------------------------------
cmd_nouveau() {
  hr "Switching to nouveau (open source)"

  # 1) Shadow every package file that blacklists nouveau (/etc wins over /usr/lib).
  for f in "${PKG_NOUVEAU_BLACKLISTS[@]}"; do
    [[ -e "$f" ]] || continue
    local etc="/etc/modprobe.d/$(basename "$f")"
    write_managed "$etc" "# shadow of $f — re-enables nouveau (nv-switch)"
    info "shadowed package blacklist: $etc"
  done

  # 2) Move aside any standalone nouveau blacklist that isn't ours.
  backup_aside "$LEGACY_BL"

  # 3) Our toggle: blacklist the proprietary modules so they don't grab the card.
  write_managed "$SWITCH_CONF" $'blacklist nvidia\nblacklist nvidia_uvm\nblacklist nvidia_drm\nblacklist nvidia_modeset'
  info "wrote $SWITCH_CONF (blacklist nvidia modules)"

  rebuild_initramfs

  cat <<EOF

$(printf '\033[1;32m[*]\033[0m') Set to NOUVEAU. Reboot:  sudo reboot
After reboot:
  lspci -k | grep -A3 -Ei 'vga|3d'    # 'Kernel driver in use: nouveau'
  glxinfo | grep "OpenGL renderer"    # should mention NV94 / GeForce 9600 GT
The proprietary packages stay installed but dormant; 'nv-switch.sh nvidia' flips
back. nouveau supports Wayland; reclocking it to full speed is a separate effort
(see nouveau-attic/ in this repo — kept for reference only).
EOF
}

case "${1:-status}" in
  status|"")        cmd_status ;;
  nvidia|prop|340)  cmd_nvidia ;;
  nouveau|open|nv)  cmd_nouveau ;;
  -h|--help|help)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) err "unknown command: $1"; echo "usage: $0 {status|nvidia|nouveau}"; exit 1 ;;
esac
