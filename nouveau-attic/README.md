# nouveau-attic — ARCHIVED nouveau reclocking effort (reference only)

This is the original goal of the repo: getting **nouveau reclocking** on the
GeForce 9600 GT (G94 / NV50 / Tesla) up to full clocks by patching
`nvkm/subdev/clk/nv50.c` (`allow_reclock=false` → `true`).

It is **archived**. The working driver path for this card is now the proprietary
NVIDIA **340.108** DKMS in `../proprietary-340xx/` (see the repo root README). The
nouveau reclock path is kept here for reference and in case someone wants to pick it
back up — it is not maintained and its cross-references to repo-root paths are
historical (they assume the old layout where this content lived at the top level).

## What's here

| Path | What it was |
|---|---|
| `patches/0001-...patch` | flips `allow_reclock` for nv50 in nouveau |
| `src/nvkm-clk/`, `src/nvkm-fb/` | nouveau clk/fb subdev reference sources |
| `scripts/build-nouveau.sh` | out-of-tree build of the patched `nouveau.ko` |
| `scripts/assess*.sh` | read-only nouveau/pstate diagnostics |
| `docs/00-07` | reclocking findings, rnndb cross-ref, build/dry-run notes |
| `traces/` | vbios dump + voltage/perf-level traces for this card |
| `установить-всё.sh` | old nouveau-path "install everything" one-shot |
| `userspace/optimize-nouveau-cachyos.sh` | nouveau + Mesa + pinned-pstate service |
| `userspace/reclock-full.sh` | live memory reclock (writes pstate 0f to HW) |
| `userspace/build-yserver.sh` | experimental Rust X11 server (nouveau-only) |
| `userspace/README-nouveau-wayland.md`, `userspace/INTEGRATION.md` | the old guides |

## To actually run nouveau today

You don't need any of this to *use* nouveau — it's in-tree. Just switch:

```
../userspace/nv-switch.sh nouveau
```

That flips the boot driver to nouveau (and back with `nv-switch.sh nvidia`).
Reclocking it to full speed is the unfinished part that lives in this attic.
