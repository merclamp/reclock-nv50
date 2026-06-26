#!/usr/bin/env bash
# install-cachyos.sh — NVIDIA 340.108 legacy driver (DKMS) for GeForce 9600 GT on CachyOS/Arch.
#
# GeForce 9600 GT = G94 (Tesla). Only the NVIDIA 340.xx legacy branch supports it.
# 340.108 is the final release of that branch — there is nothing newer for this card.
# On modern kernels (6.x/7.x) it needs community patches. The plain AUR
# `nvidia-340xx-dkms` is STALE (340.76, Linux 4.0) and will NOT build, so this script
# builds the kernel module from the VENDORED, PATCHED package in ../proprietary-340xx
# (which carries the 7.0/7.1 + clang/LTO fixes) and pulls only -utils from the AUR.
#
# This script:
#   1) verifies a 340-class NVIDIA GPU is present,
#   2) installs the matching kernel headers for the RUNNING kernel,
#   3) installs nvidia-340xx-utils (340.108) from the AUR, then builds + installs the
#      patched nvidia-340xx-dkms from ../proprietary-340xx,
#   4) blacklists nouveau and rebuilds the initramfs.
#
# Run as your normal user (NOT root) — makepkg/paru must build as non-root.
set -euo pipefail

err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] && { err "Run as a normal user, not root (paru builds unprivileged; it will sudo when needed)."; exit 1; }
command -v paru >/dev/null || { err "paru not found. Install an AUR helper first."; exit 1; }
command -v pacman >/dev/null || { err "Not an Arch-based system."; exit 1; }

# --- 1. Detect the GPU and confirm it's a 340-era card -----------------------
info "Detecting NVIDIA GPU..."
GPU_LINE="$(lspci -nn | grep -Ei 'vga|3d|display' | grep -i nvidia || true)"
if [[ -z "$GPU_LINE" ]]; then
  warn "No NVIDIA GPU detected via lspci. Continuing anyway (card may be disabled in BIOS / output via iGPU)."
else
  info "Found: $GPU_LINE"
  if ! grep -qi '9600\|G94\|\[10de:0622\]\|\[10de:0623\]\|\[10de:0625\]' <<<"$GPU_LINE"; then
    warn "This doesn't look like a 9600 GT / G94. The 340xx driver only supports Tesla-era cards."
    warn "Check https://www.nvidia.com/en-us/drivers/unix/legacy-gpu/ before continuing."
    read -rp "Continue anyway? [y/N] " a; [[ "${a,,}" == y ]] || exit 1
  fi
fi

# --- 2. Resolve kernel headers for the RUNNING kernel ------------------------
# CachyOS ships several kernels; headers MUST match the kernel currently booted,
# otherwise DKMS builds against the wrong tree and you get a black screen.
KREL="$(uname -r)"
info "Running kernel: $KREL"

detect_headers_pkg() {
  # Map the running kernel release suffix to its Arch/CachyOS kernel package name,
  # then return "<pkg>-headers".
  case "$KREL" in
    *-cachyos-rc)       echo "linux-cachyos-rc-headers" ;;
    *-cachyos-lts)      echo "linux-cachyos-lts-headers" ;;
    *-cachyos-hardened) echo "linux-cachyos-hardened-headers" ;;
    *-cachyos)          echo "linux-cachyos-headers" ;;
    *-zen*)             echo "linux-zen-headers" ;;
    *-lts)              echo "linux-lts-headers" ;;
    *-hardened)         echo "linux-hardened-headers" ;;
    *)                  echo "linux-headers" ;;
  esac
}
HDR_PKG="$(detect_headers_pkg)"
info "Matching headers package: $HDR_PKG"

if ! pacman -Si "$HDR_PKG" >/dev/null 2>&1 && ! paru -Si "$HDR_PKG" >/dev/null 2>&1; then
  warn "Couldn't confirm '$HDR_PKG' exists in repos. Installed kernels:"
  pacman -Q | grep -E '^linux' || true
  err  "Install the headers matching '$KREL' manually, then re-run."
  exit 1
fi

info "Installing kernel headers + DKMS prerequisites..."
sudo pacman -S --needed --noconfirm base-devel dkms "$HDR_PKG"

# --- 3. Install the legacy driver --------------------------------------------
# nvidia-340xx-utils (340.108) is current in the AUR, so take it from there. The
# kernel module, however, is built from our VENDORED + PATCHED package, NOT from the
# stale AUR `nvidia-340xx-dkms` (340.76) which cannot build on modern kernels.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKGDIR="$REPO_ROOT/proprietary-340xx"
[[ -f "$PKGDIR/PKGBUILD" ]] || { err "Vendored package missing at $PKGDIR"; exit 1; }

# clang/LTO kernels (CachyOS default) need the LLVM toolchain to build the module;
# the vendored dkms.conf auto-detects this and builds with CC=clang LLVM=1.
if grep -q '^CONFIG_CC_IS_CLANG=y' "/usr/lib/modules/$KREL/build/.config" 2>/dev/null; then
  info "Target kernel is clang/LTO-built — installing LLVM toolchain (clang llvm lld)."
  sudo pacman -S --needed --noconfirm clang llvm lld
fi

info "Installing nvidia-340xx-utils (340.108) from the AUR..."
paru -S --needed nvidia-340xx-utils

info "Building patched nvidia-340xx-dkms from $PKGDIR ..."
info "(Downloads the 340.108 .run, applies patches 0001-0020.)"
# NOTE: build with --nodeps. The PKGBUILD makedepends list 'linux'/'linux-headers',
# which a CachyOS kernel does NOT provide as those exact names; 'makepkg -s' would try
# to pull the STOCK linux kernel. The -dkms package only stages sources (no compile at
# build time), so skipping makedepends is safe.
( cd "$PKGDIR" && NVIDIA_340XX_DKMS_ONLY=1 makepkg -f --nodeps )
info "Installing the package (DKMS then builds the module against your kernel)..."
sudo pacman -U --noconfirm "$PKGDIR"/nvidia-340xx-dkms-*.pkg.tar.*

# --- 4. Blacklist nouveau & rebuild initramfs --------------------------------
info "Blacklisting nouveau..."
echo -e "blacklist nouveau\noptions nouveau modeset=0" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null

info "Rebuilding initramfs (mkinitcpio -P)..."
sudo mkinitcpio -P

# --- 5. Verify DKMS actually built -------------------------------------------
echo
info "DKMS status:"
dkms status || true
echo

if dkms status 2>/dev/null | grep -qi 'nvidia.*installed'; then
  info "DKMS module built successfully."
else
  warn "DKMS module not shown as installed. Check 'dkms status' and the build log in /var/lib/dkms/."
fi

cat <<'EOF'

============================================================
 Done. Reboot now:   sudo reboot
============================================================
After reboot, verify:
  nvidia-smi                         # should report driver 340.108
  lspci -k | grep -A3 -Ei 'vga|3d'   # 'Kernel driver in use: nvidia'

IMPORTANT for CachyOS:
  * Use an Xorg (X11) session, NOT Wayland. The 340.xx driver does not do Wayland.
    In SDDM/login screen pick a "Plasma (X11)" session.
  * Secure Boot must be OFF (unsigned module won't load), or sign the module via MOK.
  * Every time you switch/upgrade kernels, make sure the matching *-headers package
    is installed so DKMS can rebuild. (DKMS handles the rebuild automatically.)

If the screen is black after reboot: boot the other kernel / fallback entry,
check 'dkms status' and that headers match 'uname -r'. Fallback is nouveau
(remove /etc/modprobe.d/blacklist-nouveau.conf and rebuild initramfs).
EOF
