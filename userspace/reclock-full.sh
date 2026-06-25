#!/usr/bin/env bash
# reclock-full.sh — end-to-end pipeline that ties the reclock-nv50 KERNEL patch
# to the 9600gt-pack USERSPACE tuning, with the project's hardware-safety discipline.
#
# Stages (each gated, nothing destructive runs without explicit "go"):
#   0. assess (read-only)          -> scripts/assess.sh + assess-root.sh
#   1. build patched nouveau.ko    -> scripts/build-nouveau.sh           (docs/05 §A-B)
#   2. DRY-RUN  NvMemExec=0         -> load patched module, no HW write   (docs/05 §C)
#   3. LIVE memory reclock         -> NvMemExec=1, real pstate 0f         (docs/05 §D)  [RISKY]
#   4. userspace tuning            -> optimize-nouveau-cachyos.sh (pin pstate, mesa, Wayland)
#
# HARDWARE SAFETY (docs/05 §E): stages 2-3 unload nouveau and WILL kill your
# graphical session on this card. Run from a TTY, ideally with SSH from a second
# machine or Magic SysRq ready. The patch is in-RAM only; a reboot always reverts.
#
# This script writes to GPU hardware ONLY in stage 3, and ONLY after you type the
# confirmation phrase. Stages 0-2 are safe (read / build / dry-run).
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"   # reclock-nv50 repo root
PACK="$REPO/userspace"
SLOT="${NV_SLOT:-0000:01:00.0}"

err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*"; }
hr()   { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
ask()  { local p="$1" d="${2:-N}" a; read -rp "$p [$([[ $d == Y ]] && echo 'Y/n' || echo 'y/N')] " a; a="${a:-$d}"; [[ "${a,,}" == y ]]; }

[[ $EUID -eq 0 ]] && { err "Run as a normal user; it sudo's where needed (build must be unprivileged)."; exit 1; }
[[ -d "$REPO/scripts" && -f "$REPO/scripts/build-nouveau.sh" ]] || { err "Run from inside the reclock-nv50 checkout (userspace/)."; exit 1; }

PSTATE_NODE() { find /sys/kernel/debug/dri -name pstate 2>/dev/null | head -1; }

reclock_open() {
  # Probe (read-only) whether the loaded module accepts reclock (not -ENOSYS).
  local n; n="$(PSTATE_NODE)"
  [[ -n "$n" ]] && sudo grep -qiE '[0-9a-f]{2}:' "$n" 2>/dev/null
}

# ---------------------------------------------------------------------------
hr "Stage 0 — read-only assessment"
if [[ -x "$REPO/scripts/assess.sh" ]]; then
  bash "$REPO/scripts/assess.sh" || true
  info "Root probe (pstate/clk/dmesg):"
  sudo bash "$REPO/scripts/assess-root.sh" 2>/dev/null | grep -iE 'pstate|--- |reclock|ENOSYS|0f:' | head -30 || true
else
  warn "scripts/assess.sh not found — skipping read-only probe."
fi
ask "Proceed to build the patched nouveau module?" Y || { info "Stopped after assessment."; exit 0; }

# ---------------------------------------------------------------------------
hr "Stage 1 — build patched nouveau.ko"
KSRC="${NV_KSRC:-}"
if [[ -z "$KSRC" ]]; then
  warn "Kernel source dir not given. build-nouveau.sh will look in src/linux*, src/nouveau."
  warn "If it can't find sources, re-run with: NV_KSRC=/path/to/linux-7.0.11 $0"
fi
bash "$REPO/scripts/build-nouveau.sh" ${KSRC:+"$KSRC"} || { err "Build failed. Fix sources (docs/05 §A) and retry."; exit 1; }
KO="$(find "$REPO/build" -name 'nouveau.ko*' 2>/dev/null | head -1)"
[[ -n "$KO" ]] || { err "No nouveau.ko produced. Aborting."; exit 1; }
info "Built: $KO"

# ---------------------------------------------------------------------------
hr "Stage 2 — DRY-RUN (NvMemExec=0, no hardware write)"
warn "This unloads nouveau and reloads the patched module. Your GUI session will DIE."
warn "Be on a TTY (Ctrl+Alt+F3) with SSH/SysRq recovery ready (docs/05 §E)."
ask "Run the safe dry-run now?" || { info "Skipping dry-run/live. Built module is at: $KO"; exit 0; }

info "Unloading nouveau and loading patched module with NvMemExec=0..."
sudo modprobe -r nouveau 2>&1 || { err "Couldn't unload nouveau (still in use? exit X/Wayland first)."; exit 1; }
sudo insmod "$KO" config="NvMemExec=0" debug="clk=debug,fb=debug,bios=debug" || {
  err "insmod failed. Restoring stock module."; sudo modprobe nouveau; exit 1; }

info "Attempting pstate 0f (calc only, memory NOT written)..."
echo 0f | sudo tee "/sys/kernel/debug/dri/$SLOT/pstate" >/dev/null 2>&1 || \
  echo 0f | sudo tee "$(PSTATE_NODE)" >/dev/null 2>&1 || warn "pstate write path not found"
sudo dmesg | tail -40

if sudo dmesg | tail -60 | grep -qiE 'ENOSYS'; then
  err "Still -ENOSYS: the gate is NOT open. Patch didn't take. Restoring stock module."
  sudo rmmod nouveau 2>/dev/null || true; sudo modprobe nouveau; exit 1
fi
info "Dry-run looks good: reclock path is OPEN (no ENOSYS). Memory was not touched."

# ---------------------------------------------------------------------------
hr "Stage 3 — LIVE memory reclock (RISKY)"
warn "This writes real clocks to the GPU (pstate 0f: core 650 / shader 1625 / mem 900)."
warn "It CAN hang the GPU. Only continue with a recovery path ready (SSH/SysRq/reset)."
echo "Type exactly:  i have recovery ready"
read -r CONFIRM
if [[ "$CONFIRM" != "i have recovery ready" ]]; then
  info "Not confirmed. Reloading stock module and stopping (dry-run already proved the gate)."
  sudo rmmod nouveau 2>/dev/null || true; sudo modprobe nouveau
  exit 0
fi

info "Reloading patched module with NvMemExec=1 (live)..."
sudo rmmod nouveau 2>/dev/null || true
sudo insmod "$KO" || { err "insmod failed; restoring stock."; sudo modprobe nouveau; exit 1; }
echo 0f | sudo tee "/sys/kernel/debug/dri/$SLOT/pstate" >/dev/null 2>&1 || \
  echo 0f | sudo tee "$(PSTATE_NODE)" >/dev/null
sleep 2
info "Current pstate:"; sudo cat "$(PSTATE_NODE)"
sudo dmesg | tail -20
warn "If the screen/GPU is alive and clocks rose to ~900 MHz mem: SUCCESS."
warn "To make it boot-persistent you must install the patched module (DKMS/initramfs) yourself."

# ---------------------------------------------------------------------------
hr "Stage 4 — userspace tuning"
if ask "Run optimize-nouveau-cachyos.sh now (mesa + pin pstate service + Wayland)?" Y; then
  bash "$PACK/optimize-nouveau-cachyos.sh"
fi

cat <<EOF

============================================================
 Pipeline complete.
============================================================
 * Built module:        $KO
 * Reclock gate:        OPEN (dry-run passed)
 * Live reclock:        $([[ "$CONFIRM" == "i have recovery ready" ]] && echo "ATTEMPTED (verify dmesg/pstate above)" || echo "skipped")
 Persisting the patched module across reboots is a deliberate step — do it only
 after you trust stability (see docs/05 and reclock-nv50 README).
EOF
