#!/usr/bin/env bash
# diagnose-display.sh
# Collect everything needed to diagnose "KDE won't start / Wayland or X won't come up"
# on a GeForce 9600 GT (G94, Tesla) CachyOS box. READ-ONLY: changes nothing.
#
# HOW TO USE (on the broken machine):
#   1. At the login screen, press Ctrl+Alt+F3 to get a text TTY.
#   2. Log in with username + password.
#   3. Run:   bash diagnose-display.sh
#   4. It writes a report to ./display-diag-<host>-<date>.txt
#   5. Send that file back here for an exact fix.
#
# It is safe to run repeatedly. It only reads logs and config.
set -uo pipefail   # no -e: we want it to finish even if a probe fails

OUT="display-diag-$(hostname 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

sec() { printf '\n========== %s ==========\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; eval "$* 2>&1" || printf '(command failed: %s)\n' "$*"; }

echo "display diagnostic report — $(date)"
echo "host: $(hostname 2>/dev/null)   user: $USER"

sec "SYSTEM / KERNEL"
run "uname -a"
run "cat /etc/os-release | grep -E 'PRETTY|NAME'"
run "cat /proc/cmdline"

sec "GPU HARDWARE + ACTIVE DRIVER"
run "lspci -nnk | grep -A3 -Ei 'vga|3d|display'"
run "lsmod | grep -E 'nouveau|nvidia|drm' "

sec "CONFLICT CHECK: proprietary nvidia vs nouveau"
run "pacman -Qq | grep -Ei 'nvidia' || echo '(no nvidia packages installed)'"
run "cat /etc/modprobe.d/*.conf 2>/dev/null | grep -Ei 'nouveau|nvidia' || echo '(no relevant modprobe entries)'"
run "ls -l /etc/X11/xorg.conf 2>/dev/null; ls -l /etc/X11/xorg.conf.d/ 2>/dev/null"

sec "DRM / KMS — did the kernel bring up a framebuffer?"
run "ls -l /dev/dri/ 2>/dev/null"
run "dmesg | grep -iE 'nouveau|drm|nvidia|fb0|modeset' | tail -n 40"

sec "DISPLAY MANAGER (SDDM) STATUS"
run "systemctl status display-manager.service --no-pager -l | tail -n 30"
run "systemctl status sddm --no-pager -l | tail -n 20"
# Which session type is SDDM defaulting to (Wayland vs X11)?
run "cat /etc/sddm.conf 2>/dev/null; cat /etc/sddm.conf.d/*.conf 2>/dev/null || echo '(no sddm.conf overrides)'"

sec "SDDM / GREETER LOGS"
run "journalctl -b -u sddm --no-pager | tail -n 60"
run "ls -lt /var/log/sddm* 2>/dev/null"

sec "KWIN / PLASMA SESSION ERRORS (this boot + previous boot)"
run "journalctl -b 0 --no-pager | grep -iE 'kwin|plasma|wayland|startplasma|drm|egl|gbm|nouveau' | tail -n 60"
run "journalctl -b -1 --no-pager | grep -iE 'kwin|plasma|wayland|startplasma|drm|egl|gbm|nouveau' | tail -n 40"

sec "XORG LOG (if an X session was attempted)"
run "cat ~/.local/share/xorg/Xorg.0.log 2>/dev/null | grep -iE '\(EE\)|\(WW\)|fatal|nouveau|nvidia|no screens|modeset' | tail -n 40 || echo '(no user Xorg log)'"
run "cat /var/log/Xorg.0.log 2>/dev/null | grep -iE '\(EE\)|\(WW\)|fatal|nouveau|nvidia|no screens' | tail -n 40 || echo '(no system Xorg log)'"

sec "MESA / GL USERSPACE"
run "pacman -Qq | grep -Ei 'mesa|libglvnd|vulkan' || echo '(mesa not found?!)'"

sec "DISK SPACE (full /  or /boot breaks login silently)"
run "df -h / /boot /home 2>/dev/null"

sec "RECENT FAILED SERVICES"
run "systemctl --failed --no-pager"

echo
echo "=================================================================="
echo "Report saved to: $OUT"
echo "Send that file back. Quick self-checks meanwhile:"
echo "  * 'in use: nouveau' in the GPU section  -> good"
echo "  * nvidia packages present + nouveau blacklisted -> likely the culprit"
echo "  * /dev/dri/ empty -> kernel modeset failed (KMS problem)"
echo "  * SDDM defaulting to a Wayland session on a half-removed nvidia -> common cause"
echo "=================================================================="
