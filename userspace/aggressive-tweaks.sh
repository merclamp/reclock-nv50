#!/usr/bin/env bash
# aggressive-tweaks.sh — squeeze-everything tweaks for the EXPERIMENT RIG
# (9600 GT / G94 / NV50 + Sandy Bridge i3 + 8GB + CachyOS).
#
# This is a PLAYGROUND box (kira + bf), so risk-of-brick is acceptable — but
# "experimental" still means "with a recovery path", per docs/05 §E. Every tweak
# is OPT-IN via a flag; nothing runs by default. Hardware-touching tweaks demand
# a recovery path (SSH from another machine / Magic SysRq).
#
# Usage:
#   ./aggressive-tweaks.sh --cpu --io --kde --zram        # safe-aggressive set
#   ./aggressive-tweaks.sh --all-safe                     # all of the above
#   ./aggressive-tweaks.sh --gpu-reclock                  # RISKY: hands off to nouveau-attic/userspace/reclock-full.sh §D
#   ./aggressive-tweaks.sh --help
#
# Reverts: every changed file gets a .bak-<timestamp>; kernel cmdline tweaks are
# one grub edit you can undo. GPU reclock is in-RAM (reboot reverts).
set -uo pipefail

err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*"; }
hr()   { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
backup(){ [[ -e "$1" ]] && sudo cp -a "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)" && info "backup $1"; }

[[ $EUID -eq 0 ]] && { err "Run as a normal user (sudo used where needed)."; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"

DO_CPU= DO_IO= DO_KDE= DO_ZRAM= DO_GPU=
for a in "$@"; do case "$a" in
  --cpu) DO_CPU=1 ;; --io) DO_IO=1 ;; --kde) DO_KDE=1 ;; --zram) DO_ZRAM=1 ;;
  --all-safe) DO_CPU=1; DO_IO=1; DO_KDE=1; DO_ZRAM=1 ;;
  --gpu-reclock) DO_GPU=1 ;;
  --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
  *) err "unknown flag: $a (see --help)"; exit 1 ;;
esac; done
[[ -z "$DO_CPU$DO_IO$DO_KDE$DO_ZRAM$DO_GPU" ]] && { err "Nothing selected. See --help."; exit 1; }

add_cmdline() {  # append a kernel param to GRUB_CMDLINE_LINUX_DEFAULT if missing
  local p="$1"
  grep -q "$p" /etc/default/grub && { info "cmdline already has: $p"; return; }
  backup /etc/default/grub
  sudo sed -i "s/\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 $p\"/" /etc/default/grub
  info "added cmdline: $p"
}

# ---------------------------------------------------------------------------
if [[ -n "$DO_CPU" ]]; then
  hr "CPU — aggressive (Sandy Bridge experiment box)"
  warn "Disabling CPU security mitigations. Fine on a playground box; LOWERS security."
  add_cmdline "mitigations=off"
  add_cmdline "mds=off"
  add_cmdline "tsx_async_abort=off"
  add_cmdline "nowatchdog"
  add_cmdline "nmi_watchdog=0"
  # pin performance governor hard (re-uses the service from optimize-system if present)
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
  sudo systemctl daemon-reload && sudo systemctl enable --now cpu-performance.service
  info "CPU tweaks staged (cmdline changes need grub-mkconfig + reboot, below)."
fi

if [[ -n "$DO_ZRAM" ]]; then
  hr "RAM/zram — aggressive (8GB box)"
  sudo pacman -S --needed --noconfirm zram-generator
  backup /etc/systemd/zram-generator.conf
  # lz4 = faster (lower ratio) than zstd; swappiness 200 = swap into RAM-zram eagerly.
  sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = lz4
EOF
  sudo tee /etc/sysctl.d/99-aggressive.conf >/dev/null <<'EOF'
vm.swappiness = 200
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.dirty_ratio = 8
vm.dirty_background_ratio = 4
EOF
  sudo systemctl daemon-reload
  sudo sysctl --system >/dev/null
  info "zram=lz4 (full RAM), swappiness=200."
fi

if [[ -n "$DO_IO" ]]; then
  hr "I/O — aggressive"
  backup /etc/udev/rules.d/60-ioscheduler.rules
  sudo tee /etc/udev/rules.d/60-ioscheduler.rules >/dev/null <<'EOF'
# NVMe -> none (lowest overhead); SSD -> mq-deadline; HDD -> bfq
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="2048"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF
  sudo udevadm control --reload && sudo udevadm trigger
  info "I/O schedulers + deeper queues applied."
fi

if [[ -n "$DO_KDE" ]]; then
  hr "KDE — kill compositor overhead (X11 gaming)"
  KW=$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)
  if [[ -n "$KW" ]]; then
    "$KW" --file kwinrc --group Compositing --key Enabled false
    "$KW" --file kwinrc --group Compositing --key AnimationSpeed 0
    "$KW" --file kdeglobals --group KDE --key AnimationDurationFactor 0
    info "KWin compositor disabled + animations off (re-login to apply). Re-enable: kwriteconfig ... Enabled true"
  else
    warn "kwriteconfig not found; run inside a Plasma session."
  fi
fi

# Apply kernel cmdline changes once at the end
if [[ -n "$DO_CPU" ]]; then
  hr "Applying GRUB cmdline"
  sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null \
    || warn "Update your bootloader config manually; reboot to apply cmdline."
fi

# ---------------------------------------------------------------------------
if [[ -n "$DO_GPU" ]]; then
  hr "GPU memory reclock — RISKY (can hang the GPU)"
  cat <<'NOTE'
HARD FACTS from this project's own recon (docs/03), so we don't chase impossible gains:
  * Voltage is ALREADY MAXED at 1.15 V — there is NO higher VID in the VBIOS.
    => overvolt is impossible; you cannot push memory past spec safely.
  * Target is the stock 0f pstate: core 650 / shader 1625 / MEMORY 900 MHz (499->900, x1.8).
  * Going ABOVE 900 MHz memory is NOT offered here: no voltage headroom + the open
    ENOMEM second front (docs/07) = near-certain freeze. That's vandalism, not tuning.
  * Even the stock 0f memory step is the risky part and must be tested live with recovery.
NOTE
  RECLOCK="$HERE/../nouveau-attic/userspace/reclock-full.sh"
  if [[ -x "$RECLOCK" ]]; then
    warn "Handing off to nouveau-attic/userspace/reclock-full.sh (archived; gates the live HW write)"
    warn "phrase and expects SSH/SysRq recovery ready (docs/05 §D/E)."
    read -rp "Launch the archived reclock-full.sh now? [y/N] " a
    [[ "${a,,}" == y ]] && exec bash "$RECLOCK"
  else
    err "reclock-full.sh not found (expected in nouveau-attic/userspace/)."
  fi
fi

cat <<'EOF'

============================================================
 Aggressive tweaks applied (selected sets). Reboot to apply
 kernel cmdline + zram changes:  sudo reboot
============================================================
Revert: each touched file has a .bak-<timestamp>. For GRUB, remove the added
params from /etc/default/grub and re-run grub-mkconfig. KWin compositor:
  kwriteconfig6 --file kwinrc --group Compositing --key Enabled true
GPU reclock is in-RAM only; a plain reboot reverts it.

What is deliberately NOT here (would brick / impossible on this card):
  * overvolt — already at 1.15 V ceiling, no higher VID exists.
  * memory > 900 MHz — no voltage headroom + open ENOMEM front => freeze.
  * persistent auto-reclock at boot without recovery — do that yourself, knowingly.
EOF
