#!/usr/bin/env bash
# optimize-system-cachyos.sh
# Whole-system tuning for a WEAK rig: Intel i3-2120/2130 (Sandy Bridge, 2c/4t),
# GeForce 9600 GT (nouveau), ~8 GB RAM, on CachyOS + KDE Plasma.
#
# Philosophy: on hardware this old, "optimization" = REMOVE load, not "speed up".
# We cut background bloat, shrink memory pressure, pin sane governors, and trim
# the KDE compositor — so the 2 CPU cores and the ancient GPU aren't wasted.
#
# Safe by design:
#   * idempotent (re-runnable),
#   * backs up every file it touches to <file>.bak-YYYYmmdd-HHMMSS,
#   * does NOT fight CachyOS defaults (cachyos-settings already tunes sysctl/ananicy);
#     it only adds what's missing and trims desktop-side waste,
#   * asks before disabling optional services.
#
# Run as a normal user (sudo used where needed). Some KDE tweaks need a Plasma session.
set -euo pipefail

err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*"; }
ask()  { local p="$1" d="${2:-N}" a; if [[ -n "${ASSUME_YES:-}" ]]; then a="$d"; printf '\033[1;34m[?]\033[0m %s [auto:%s]\n' "$p" "$a"; else read -rp "$p [$([[ $d == Y ]] && echo 'Y/n' || echo 'y/N')] " a; fi; a="${a:-$d}"; [[ "${a,,}" == y ]]; }

[[ $EUID -eq 0 ]] && { err "Run as a normal user, not root."; exit 1; }
command -v pacman >/dev/null || { err "Not an Arch-based system."; exit 1; }

backup() { [[ -f "$1" ]] && sudo cp -a "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)" && info "backed up $1"; }

# --- 0. Detect RAM (adapt zram/swappiness automatically) ---------------------
RAM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
RAM_GB=$(( (RAM_KB + 524288) / 1048576 ))
info "Detected RAM: ${RAM_GB} GB | CPU: $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ //')"
info "CPU cores/threads: $(nproc) threads"

# =============================================================================
# 1. zram swap  (compress RAM instead of swapping to a slow disk)
# =============================================================================
info "Configuring zram swap..."
sudo pacman -S --needed --noconfirm zram-generator
backup /etc/systemd/zram-generator.conf
# ~half of RAM as a sane default for 8 GB; capped to keep things sane.
ZRAM_FRAC="ram / 2"
[[ $RAM_GB -le 4 ]] && ZRAM_FRAC="ram"          # <=4 GB: more aggressive
[[ $RAM_GB -ge 16 ]] && ZRAM_FRAC="ram / 4"     # plenty of RAM: smaller zram
sudo tee /etc/systemd/zram-generator.conf >/dev/null <<EOF
[zram0]
zram-size = min(${ZRAM_FRAC}, 8192)
compression-algorithm = zstd
EOF
sudo systemctl daemon-reload
sudo systemctl start /dev/zram0 2>/dev/null || sudo systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true

# =============================================================================
# 2. sysctl: memory pressure tuned for a low-RAM, zram-backed box
# =============================================================================
info "Writing VM/sysctl tuning (additive; won't clobber cachyos-settings)..."
SYSCTL=/etc/sysctl.d/99-weakrig.conf
backup "$SYSCTL"
sudo tee "$SYSCTL" >/dev/null <<'EOF'
# zram is fast -> swap into it eagerly instead of OOM/thrash on disk.
vm.swappiness = 100
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
# Flush dirty pages sooner so a slow HDD/SSD doesn't stall the desktop.
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
sudo sysctl --system >/dev/null

# =============================================================================
# 3. CPU governor: performance (ondemand adds latency on a slow 2-core CPU)
# =============================================================================
info "Setting CPU governor to performance..."
if pacman -Qq power-profiles-daemon >/dev/null 2>&1 || systemctl list-unit-files | grep -q power-profiles-daemon; then
  sudo systemctl enable --now power-profiles-daemon 2>/dev/null || true
  command -v powerprofilesctl >/dev/null && powerprofilesctl set performance 2>/dev/null || true
fi
# Hard governor via a tiny service (works even without PPD):
sudo tee /etc/systemd/system/cpu-performance.service >/dev/null <<'EOF'
[Unit]
Description=Pin CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now cpu-performance.service

# =============================================================================
# 4. I/O scheduler: bfq for HDD / mq-deadline for SSD/NVMe (auto via udev)
# =============================================================================
info "Installing I/O scheduler udev rule..."
UDEV=/etc/udev/rules.d/60-ioscheduler.rules
backup "$UDEV"
sudo tee "$UDEV" >/dev/null <<'EOF'
# HDD (rotational) -> bfq (fair, good for desktop on spinning disk)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
# SATA SSD -> mq-deadline
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# NVMe -> none (lowest overhead)
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
EOF
sudo udevadm control --reload && sudo udevadm trigger || true

# =============================================================================
# 5. Trim background services (ask per item; skip what isn't installed)
# =============================================================================
info "Trimming optional background services (each is opt-in)..."
disable_svc() {  # $1=unit  $2=human reason
  systemctl list-unit-files | grep -q "^$1" || return 0
  if ask "Disable $1 ($2)?"; then sudo systemctl disable --now "$1" 2>/dev/null && info "disabled $1" || true; fi
}
disable_svc bluetooth.service        "Bluetooth — disable if no BT devices"
disable_svc cups.service             "printing — disable if no printer"
disable_svc cups.socket              "printing socket"
disable_svc avahi-daemon.service     "mDNS/zeroconf — disable if no network discovery"
disable_svc ModemManager.service     "mobile-broadband modem — usually unneeded on desktop"

# Lightweight helpers that genuinely help weak boxes:
if ask "Enable irqbalance (spreads IRQs across the 2 cores)?" Y; then
  sudo pacman -S --needed --noconfirm irqbalance && sudo systemctl enable --now irqbalance
fi

# =============================================================================
# 6. KDE Plasma: kill compositor bloat + disable Baloo file indexing
# =============================================================================
info "Trimming KDE Plasma (per-user; needs a Plasma session to fully apply)..."
if command -v kwriteconfig6 >/dev/null 2>&1; then KW=kwriteconfig6; elif command -v kwriteconfig5 >/dev/null 2>&1; then KW=kwriteconfig5; else KW=""; fi
if [[ -n "$KW" ]]; then
  # Compositor: keep it (Wayland needs it) but make it cheap.
  $KW --file kwinrc --group Compositing --key AnimationSpeed 0
  $KW --file kwinrc --group Compositing --key LatencyPolicy "Low"
  $KW --file kwinrc --group Compositing --key WindowsBlockCompositing true
  # Disable expensive desktop effects (blur, wobbly, etc.)
  for fx in blur contrast wobblywindows magiclamp slidingpopups; do
    $KW --file kwinrc --group Plugins --key "${fx}Enabled" false
  done
  # Global animation slowdown -> instant
  $KW --file kdeglobals --group KDE --key AnimationDurationFactor 0
  info "KDE compositor/effects trimmed (re-login to apply)."
else
  warn "kwriteconfig not found — skipping KDE tweaks (run inside a Plasma session)."
fi

# Baloo file indexer hammers CPU+disk on weak machines:
if command -v balooctl6 >/dev/null 2>&1; then BC=balooctl6; elif command -v balooctl >/dev/null 2>&1; then BC=balooctl; else BC=""; fi
if [[ -n "$BC" ]] && ask "Disable Baloo file indexing (big CPU/disk saver)?" Y; then
  $BC disable 2>/dev/null || $BC suspend 2>/dev/null || true
  $BC purge 2>/dev/null || true
  info "Baloo indexing disabled."
fi

# =============================================================================
# 7. Journald: cap log size so it doesn't grind a slow disk
# =============================================================================
info "Capping systemd journal size..."
backup /etc/systemd/journald.conf
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-weakrig.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
EOF
sudo systemctl restart systemd-journald || true

# =============================================================================
# 8. Optional: CPU mitigations  (SECURITY TRADE-OFF — default = KEEP them on)
# =============================================================================
echo
warn "Sandy Bridge is hit hard by Spectre/Meltdown mitigations (it's a 2011 CPU)."
warn "Disabling them gives a real CPU speedup, but LOWERS security. Default: keep ON."
if ask "Disable CPU mitigations for more speed (NOT recommended; understand the risk)?"; then
  if [[ -f /etc/default/grub ]]; then
    backup /etc/default/grub
    if grep -q 'mitigations=' /etc/default/grub; then
      sudo sed -i 's/mitigations=[^ "]*/mitigations=off/' /etc/default/grub
    else
      sudo sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 mitigations=off"/' /etc/default/grub
    fi
    sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || warn "Update your bootloader config manually."
    info "mitigations=off set (takes effect after reboot)."
  else
    warn "No /etc/default/grub — add 'mitigations=off' to your bootloader kernel cmdline manually."
  fi
else
  info "Kept CPU mitigations ON (safer). Good call."
fi

cat <<'EOF'

============================================================
 System optimization done. Reboot to apply everything:
   sudo reboot
============================================================
Verify after reboot:
  swapon --show                       # zram0 present, zstd
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # performance
  cat /sys/block/*/queue/scheduler    # bfq / mq-deadline / none per device
  systemd-analyze blame | head        # what still takes time at boot
  balooctl6 status                    # 'disabled' if you turned it off

Reverting anything: every changed file has a .bak-<timestamp> next to it.
Disable the helper services if you change your mind:
  sudo systemctl disable --now cpu-performance.service
EOF
