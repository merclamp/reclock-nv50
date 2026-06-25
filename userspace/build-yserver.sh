#!/usr/bin/env bash
# build-yserver.sh
# Build & install joske/yserver — a modern X11 server written from scratch in Rust —
# on CachyOS/Arch. EXPERIMENTAL on a GeForce 9600 GT.
#
# READ THIS FIRST (hard facts from upstream README):
#   * yserver's GLX_EXT_texture_from_pixmap (needed for compositing) "can NOT (read: NEVER)
#     work on the nvidia PROPRIETARY driver". => Do NOT combine with install-cachyos.sh (340.108).
#   * On nouveau it is "untested"; on the author's GTX 1050 nouveau couldn't even bring up Xorg.
#     The 9600 GT (G94) is older/simpler, so it MIGHT work — zero guarantees.
#   * Therefore this is an OPT-IN experiment. It does NOT replace your working Xorg/Wayland.
#     You keep your normal session and launch yserver manually from a TTY to try it.
#
# This script only builds + installs the binary and (optionally) wires a separate
# xinitrc. It never touches your display manager unless you explicitly opt in.
set -euo pipefail

err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*"; }
ask()  { local p="$1" d="${2:-N}" a; read -rp "$p [$([[ $d == Y ]] && echo 'Y/n' || echo 'y/N')] " a; a="${a:-$d}"; [[ "${a,,}" == y ]]; }

[[ $EUID -eq 0 ]] && { err "Run as a normal user, not root."; exit 1; }
command -v pacman >/dev/null || { err "Not an Arch-based system."; exit 1; }

REPO_URL="https://github.com/joske/yserver.git"
SRC_DIR="${YSERVER_SRC:-$HOME/.local/src/yserver}"

# --- Safety gate: refuse if the proprietary 340 driver is installed ----------
if pacman -Qq nvidia-340xx nvidia-340xx-dkms 2>/dev/null | grep -q .; then
  err "Proprietary nvidia-340xx is installed. yserver's TFP can NEVER work on it."
  err "yserver needs nouveau. Switch to nouveau first (optimize-nouveau-cachyos.sh), then retry."
  exit 1
fi

# --- Confirm nouveau is the active driver ------------------------------------
if lspci -k 2>/dev/null | grep -A3 -Ei 'vga|3d' | grep -qi 'in use: nouveau'; then
  info "nouveau is the active driver — good."
else
  warn "nouveau does not appear to be the active GPU driver."
  warn "yserver will almost certainly fail without nouveau. Run optimize-nouveau-cachyos.sh first."
  ask "Continue anyway (experiment)?" || exit 1
fi

# --- 1. Dependencies (exact list from upstream README, Arch) -----------------
info "Installing build dependencies..."
sudo pacman -S --needed --noconfirm \
  just gcc seatd libxshmfence libxkbcommon libinput shaderc systemd-libs fontconfig git

# Rust toolchain (rustup preferred; repo pins a toolchain via rust-toolchain.toml)
if ! command -v cargo >/dev/null 2>&1; then
  info "Installing Rust toolchain (rustup)..."
  sudo pacman -S --needed --noconfirm rustup
  rustup default stable
fi

# seatd is used for seat management; enable it so a normal user can drive KMS/input.
if ! systemctl is-enabled seatd >/dev/null 2>&1; then
  if ask "Enable seatd.service (recommended for running yserver as your user)?" Y; then
    sudo systemctl enable --now seatd
    sudo usermod -aG seat "$USER" && info "Added $USER to 'seat' group (re-login required)."
  fi
fi

# --- 2. Clone / update source ------------------------------------------------
if [[ -d "$SRC_DIR/.git" ]]; then
  info "Updating existing checkout in $SRC_DIR..."
  git -C "$SRC_DIR" pull --ff-only || warn "git pull failed; building current checkout."
else
  info "Cloning yserver into $SRC_DIR..."
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone "$REPO_URL" "$SRC_DIR"
fi

# --- 3. Build + install ------------------------------------------------------
info "Building yserver (release)... this can take a while on a slow CPU."
cd "$SRC_DIR"
# 'just install' builds release and installs to /usr/local/bin/yserver (needs sudo).
just install

if command -v yserver >/dev/null 2>&1; then
  info "Installed: $(command -v yserver)"
else
  warn "yserver binary not found on PATH after install. Check 'just install' output above."
fi

# --- 4. Optional: a dedicated xinitrc to try it from a TTY -------------------
if ask "Create a test ~/.xinitrc.yserver (launches a minimal session to try it)?" Y; then
  cat > "$HOME/.xinitrc.yserver" <<'XINIT'
#!/bin/sh
# Minimal session for testing yserver. Replace 'startplasma-x11' with a lighter WM
# if Plasma is too heavy on this rig (e.g. 'openbox-session' or 'startxfce4').
exec dbus-run-session startplasma-x11
XINIT
  chmod +x "$HOME/.xinitrc.yserver"
  info "Wrote ~/.xinitrc.yserver"
fi

cat <<EOF

============================================================
 yserver built. It is EXPERIMENTAL — your normal session is untouched.
============================================================
Try it from a FREE TTY (Ctrl+Alt+F3), logged in as your user:

  cd "$SRC_DIR"
  # uses ~/.xinitrc (or copy ~/.xinitrc.yserver to ~/.xinitrc first):
  just startx

Useful keybinds inside yserver:
  Ctrl+Alt+Backspace  -> kill server, back to console
  Ctrl+Alt+Enter      -> screenshot of framebuffer to CWD
  Ctrl+Alt+F12        -> dump drawables as PPM

If it works and you want it at login (lightdm only — gdm/sddm can't):
  sudo pacman -S lightdm lightdm-gtk-greeter
  echo -e '[Seat:*]\nxserver-command=/usr/local/bin/yserver' | \\
    sudo tee /etc/lightdm/lightdm.conf.d/99-yserver.conf
  sudo systemctl disable --now sddm 2>/dev/null || true
  sudo systemctl enable lightdm

If it DOESN'T work (likely on this old nouveau card):
  Just don't use it. Your Xorg/Wayland session is unchanged. Remove the binary with:
  sudo rm -f /usr/local/bin/yserver
EOF
