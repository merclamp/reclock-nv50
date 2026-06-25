#!/usr/bin/env bash
# target-machine.sh — sourceable guard. This pack is tuned for ONE specific machine
# (GeForce 9600 GT / G94 / NV50 + Sandy Bridge i3 + CachyOS). Running it elsewhere
# won't gain you anything and some tweaks (mitigations advice, zram sizing, DXVK-off)
# are actively wrong on other hardware.
#
# Usage inside a script:
#   source "$(dirname "$0")/target-machine.sh"
#   target_machine_check        # warns (and prompts) if hardware doesn't match
#
# It only WARNS + asks to continue — it never hard-blocks, because the user owns
# the box and may know what they're doing. Pure read-only probing.

_tm_warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*" >&2; }
_tm_ok()   { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }

# Expected target (the boyfriend's rig). See CLAUDE.md / docs.
TM_GPU_IDS="10de:0622 10de:0623 10de:0625"   # G94 family (9600 GT et al.)
TM_DISTRO_ID="cachyos"

target_machine_check() {
  local mismatch=0 reason=()

  # GPU: must be a G94/Tesla (9600 GT family)
  local gpu; gpu="$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | grep -i nvidia || true)"
  if [[ -n "$gpu" ]]; then
    local hit=0 id
    for id in $TM_GPU_IDS; do grep -qi "$id" <<<"$gpu" && hit=1; done
    grep -qiE 'G94|9600 ?GT' <<<"$gpu" && hit=1
    if [[ "$hit" -eq 0 ]]; then mismatch=1; reason+=("GPU is not a G94/9600 GT: ${gpu##*: }"); fi
  else
    mismatch=1; reason+=("no NVIDIA GPU detected via lspci")
  fi

  # Distro: expected CachyOS
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "$TM_DISTRO_ID" && "${ID_LIKE:-}" != *arch* ]]; then
      mismatch=1; reason+=("distro is '${ID:-unknown}', expected CachyOS/Arch")
    fi
  fi

  if [[ "$mismatch" -eq 0 ]]; then
    _tm_ok "Target machine matches (G94 / CachyOS). Proceeding."
    return 0
  fi

  _tm_warn "This pack is tuned for the 9600 GT / G94 + Sandy Bridge + CachyOS rig."
  for r in "${reason[@]}"; do _tm_warn "  - $r"; done
  _tm_warn "On different hardware some tweaks are useless or wrong (DXVK-off, zram sizing,"
  _tm_warn "CPU-mitigations advice, NV50 reclock). See CLAUDE.md."
  if [[ -n "${TM_ASSUME_YES:-}" ]]; then _tm_warn "TM_ASSUME_YES set — continuing."; return 0; fi
  local a; read -rp "Continue anyway? [y/N] " a
  [[ "${a,,}" == y ]]
}
