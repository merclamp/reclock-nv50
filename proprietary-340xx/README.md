# proprietary-340xx — patched NVIDIA 340.108 DKMS for GeForce 9600 GT

Self-contained, **vendored** Arch/CachyOS package that builds the NVIDIA 340.108
legacy kernel module (the last branch that supports G94 / Tesla, e.g. the 9600 GT)
on **modern kernels (Linux 7.0 / 7.1) and clang/ThinLTO kernels (CachyOS default)**.

It is the `nvidia-340xx` AUR package (Jerry Xiao, 340.108-39, patches up to kernel
6.15) **plus our own `0020-kernel-7.0-7.1.patch`**. We vendor it so the build does
not depend on AUR drift — the upstream `nvidia-340xx-dkms` AUR package is stale
(340.76 / Linux 4.0) and does **not** build.

## What `0020-kernel-7.0-7.1.patch` fixes

| # | Breakage on 7.0/7.1 | Fix |
|---|---|---|
| 1 | `static_assert(sizeof(struct filename) % 64 == 0)` in `linux/fs.h` fails inside every conftest (poisons vmap/acpi/pci_dma probes) | add `-fms-extensions` to conftest `BASE_CFLAGS` (kernel + uvm) — `struct filename` now uses an anonymous tagged member |
| 2 | `in_irq()` removed from the kernel | `in_irq()` → `in_hardirq()` |
| 3 | x86 boot `screen_info` global removed (sysfb refactor) and not exported to modules | new `screen_info` conftest → `NV_SCREEN_INFO_GLOBAL_PRESENT`; the two users fall back to "no boot framebuffer info" when absent |
| 4 | clang/LTO kernels embed clang-only CFLAGS; gcc build dies with `unrecognized command-line option '-mstack-alignment=8'` | `dkms.conf` auto-detects `CONFIG_CC_IS_CLANG=y` and builds with `CC=clang LD=ld.lld LLVM=1` |

Verified building clean against **both**:
- `7.0.13-zen` (gcc kernel) — proves the 7.0 + gcc path
- `7.1.0-rc7-cachyos-rc` (clang + ThinLTO) — proves the 7.1 + clang path

Both produce `nvidia.ko` + `nvidia-uvm.ko` with matching vermagic and no unresolved
symbols.

## Build + install

The easy way (from the repo, handles headers, AUR -utils, LLVM toolchain):

```
../userspace/install-cachyos.sh
```

By hand:

```
# kernel headers for the RUNNING kernel must be installed first
# clang/LTO kernel? also: sudo pacman -S --needed clang llvm lld
paru -S --needed nvidia-340xx-utils          # 340.108 utils from AUR (current)
NVIDIA_340XX_DKMS_ONLY=1 makepkg -si          # builds + installs the patched -dkms
```

`makepkg` downloads the official 340.108 `.run` from NVIDIA (verified by b2sum) and
applies patches `0001`–`0020`. DKMS then builds the module on install and on every
kernel update (clang detection happens at that point, per kernel).

## Notes

- Proprietary 340.xx is **Xorg/X11 only** — no Wayland. Use a Plasma (X11) session.
- Secure Boot must be OFF (unsigned module) or sign via MOK.
- Flip between this driver and nouveau with `../userspace/nv-switch.sh`.
- Build artifacts (`src/`, `pkg/`, `*.run`, `*.pkg.tar.*`) are gitignored.
