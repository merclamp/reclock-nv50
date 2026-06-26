#!/usr/bin/env bash
# fix-display-cachyos.sh
# Get a BROKEN GeForce 9600 GT (G94/Tesla) CachyOS box back to a working graphical
# login. Strategy: force the most reliable combo for this old GPU —
#   nouveau driver  +  SDDM defaulting to an X11 (Xorg) Plasma session.
# Wayland on this card is possible but flaky; X11 is the safe recovery target.
#
# Run from a TTY (Ctrl+Alt+F3, log in), as a normal user (it will sudo):
#   bash fix-display-cachyos.sh
#
# It is conservative and idempotent: backs up every file, asks before big steps,
# and prints exactly how to revert. It does NOT delete user data.
#
# RECOMMENDED: run diagnose-display.sh first and read its hints. This script fixes
# the *common* causes; if the report shows something exotic, send it here first.
set -uo pipefail

err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*"; }
ask()  { local p="$1" d="${2:-N}" a; read -rp "$p [$([[ $d == Y ]] && echo 'Y/n' || echo 'y/N')] " a; a="${a:-$d}"; [[ "${a,,}" == y ]]; }
backup(){ [[ -e "$1" ]] && sudo cp -a "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)" && info "backed up $1"; }

[[ $EUID -eq 0 ]] && { err "Run as a normal user, not root."; exit 1; }
command -v pacman >/dev/null || { err "Not an Arch-based system."; exit 1; }

echo "=== fix-display: restore graphical login on 9600 GT (nouveau + X11) ==="

# --- 1. Remove proprietary nvidia leftovers (the #1 cause of black screen) ----
NV_PKGS=$(pacman -Qq 2>/dev/null | grep -Ei '^nvidia(-340xx)?(-utils|-dkms)?$' || true)
if [[ -n "$NV_PKGS" ]]; then
  warn "Proprietary NVIDIA packages found:"
  echo "$NV_PKGS"
  warn "On a 9600 GT these only work under Xorg and break Wayland/KMS easily."
  if ask "Remove them so nouveau can take over cleanly?" Y; then
    sudo pacman -Rns --noconfirm $NV_PKGS || warn "removal had issues; continuing"
  fi
else
  info "No proprietary nvidia packages installed — good."
fi

# --- 2. Un-blacklist nouveau (proprietary installers often blacklist it) ------
for f in /etc/modprobe.d/*.conf /usr/lib/modprobe.d/*.conf; do
  [[ -f "$f" ]] || continue
  if grep -qiE 'blacklist[[:space:]]+nouveau|nouveau[[:space:]]+modeset=0' "$f" 2>/dev/null; then
    warn "nouveau is blacklisted in $f"
    backup "$f"
    sudo sed -i '/blacklist[[:space:]]\+nouveau/Id; /nouveau[[:space:]]\+modeset=0/Id' "$f"
    info "removed nouveau blacklist from $f"
  fi
done

# --- 3. Make sure mesa + nouveau userspace is actually installed --------------
info "Ensuring open graphics stack is present..."
sudo pacman -S --needed --noconfirm mesa xorg-server xf86-video-nouveau 2>/dev/null \
  || sudo pacman -S --needed --noconfirm mesa xorg-server   # modesetting driver fallback

# --- 4. Remove a stale xorg.conf that pins a dead nvidia driver ---------------
if [[ -f /etc/X11/xorg.conf ]]; then
  if grep -qi 'nvidia' /etc/X11/xorg.conf 2>/dev/null; then
    warn "/etc/X11/xorg.conf references nvidia (now removed) — this breaks X startup."
    backup /etc/X11/xorg.conf
    sudo rm -f /etc/X11/xorg.conf
    info "removed stale xorg.conf (X will auto-detect nouveau)"
  fi
fi
for f in /etc/X11/xorg.conf.d/*nvidia*.conf; do
  [[ -f "$f" ]] || continue
  backup "$f"; sudo rm -f "$f"; info "removed $f"
done

# --- 5. Force SDDM to default to an X11 Plasma session (stable on old GPUs) ----
info "Configuring SDDM to use X11 by default..."
sudo mkdir -p /etc/sddm.conf.d
SDDM_DROP=/etc/sddm.conf.d/10-x11-recovery.conf
backup "$SDDM_DROP"
# DisplayServer=x11 keeps the greeter itself on Xorg too (most compatible).
sudo tee "$SDDM_DROP" >/dev/null <<'EOF'
[General]
DisplayServer=x11

[Wayland]
EnableHiDPI=false
EOF
info "wrote $SDDM_DROP (greeter + default session on X11)"

# Ensure the X11 Plasma session file exists (package: plasma-x11-session on some setups)
if ! ls /usr/share/xsessions/plasma*.desktop >/dev/null 2>&1; then
  warn "No X11 Plasma session file found."
  if ask "Install plasma-x11-session?" Y; then
    sudo pacman -S --needed --noconfirm plasma-x11-session 2>/dev/null \
      || warn "couldn't install plasma-x11-session; you may need plasma-workspace"
  fi
fi

# --- 6. Rebuild initramfs so the nouveau/KMS change takes effect --------------
info "Rebuilding initramfs..."
sudo mkinitcpio -P || warn "mkinitcpio reported issues; check output"

# --- 7. Make sure the display manager is enabled ------------------------------
if ! systemctl is-enabled sddm >/dev/null 2>&1; then
  if ask "Enable sddm.service?" Y; then sudo systemctl enable sddm; fi
fi

cat <<'EOF'

============================================================
 Done. Reboot to test the recovered login:
   sudo reboot
============================================================
After reboot you should land on the SDDM greeter. Log in to "Plasma (X11)".

If it works:
  * You're now on nouveau + X11. For performance, run nouveau-attic/userspace/optimize-nouveau-cachyos.sh
    (pins GPU clocks) — but you can stay on X11 for stability.
  * To try Wayland later: at the SDDM session picker choose "Plasma (Wayland)".

If it STILL fails, from a TTY run diagnose-display.sh again and send the report.
Emergency fallback to plain text boot (always works):
  sudo systemctl set-default multi-user.target   # boot to TTY, no graphics
  # ...fix things, then:
  sudo systemctl set-default graphical.target

Reverting this script: every changed file has a .bak-<timestamp> next to it.
EOF
