# Steam gaming on the proprietary 340 driver (GeForce 9600 GT / Tesla)

How to get Steam games running **hardware-accelerated** on the legacy NVIDIA
340.108 driver, and the traps that waste an evening if you don't know them.

## TL;DR

```sh
./setup-steam-340.sh          # host GL + 32-bit deps + helper + env
# install GE-Proton11 -> ~/.steam/root/compatibilitytools.d/ and repoint to sniper:
sed -i 's/"require_tool_appid" *"4183110"/"require_tool_appid" "1628350"/' \
  ~/.steam/root/compatibilitytools.d/GE-Proton11-1/toolmanifest.vdf
steam -shutdown && steam-340-fix GE-Proton11-1
```

Per-game launch option that does the real work (set on every game by the helper):

```
PROTON_USE_WINED3D=1 __GL_SHADER_DISK_CACHE=1 __GL_SHADER_DISK_CACHE_SIZE=1000000000 STEAM_RUNTIME=0 %command%
```

## Why games render in software (1 FPS) by default

Steam launches everything inside the **pressure-vessel** container (the "Steam
Linux Runtime"). The 340 driver predates **glvnd**, so there is no
`libGLX_nvidia.so` for the container's GL dispatcher to find. It silently falls
back to Mesa's `libGLX_mesa` → `llvmpipe` (CPU software rasteriser). Result: the
GPU sits idle and you get ~1 FPS.

Evidence on a broken run: `/proc/<pid>/maps` shows
`libgallium-*.so` / `swrast`, VRAM usage stays at idle (~60 MiB), and every CPU
core is pegged by render threads.

## The fix

| Env (in launch options) | What it does |
|---|---|
| `STEAM_RUNTIME=0` | disables the scout LD overrides that force Mesa, so the container uses the **host** nvidia GL (`/run/host/.../nvidia/libGL.so.340.108` or `/usr/lib32/nvidia/...`) = hardware |
| `PROTON_USE_WINED3D=1` | Windows/Proton games only: forces Direct3D→OpenGL. The Tesla chip has **no Vulkan**, so DXVK/VKD3D/gamescope/Proton's default renderer cannot run. WineD3D (OpenGL) is the only path. (Ignored by native games.) |
| `__GL_SHADER_DISK_CACHE=1` (+ size) | persistent nvidia shader cache → removes WineD3D first-encounter compile **stutter/freezes** |

Native Linux games (Half-Life 2, …) also need their 32-bit host deps present,
because with `STEAM_RUNTIME=0` they link against the host, not the runtime:
`lib32-sdl2` (the usual culprit), plus `lib32-openal lib32-libvorbis lib32-libtheora`.
And the 32-bit nvidia GL itself: `lib32-nvidia-340xx-utils`.

Verified result (UT3 / Half-Life 2): `libGL.so.340.108` + `libnvidia-glcore` in
the process maps, VRAM jumps to 150–340 MiB, `LaunchApp ... Completed`.

## The SLR 4.0 trap (read this before picking a Proton)

A compat tool only works if the **Steam Linux Runtime it requires** is healthy.
As of mid-2026:

- `proton-cachyos`, `Proton Experimental`, **and even GE-Proton11** declare
  `require_tool_appid "4183110"` → **SLR 4.0 ("steamrt4")**.
- Steam **refuses to download** SLR 4.0 here: `Failed installing AppID 4183110
  (Invalid platform)`.
- Worse, even after copying a known-good SLR 4.0 tree in by hand, Steam
  re-validates it on the next start and bricks it to
  `Assertion Failed: Tool 4183110 "Steam Linux Runtime 4.0" unsupported version 0`
  → `LaunchApp failed with AppError_51` (the "Compatibility tool failed" dialog).

The runtime that **stays healthy** is **sniper** (SLR 3.0, appid `1628350`).

So:

- **Quickest:** use stock **Proton 9.0** — it requires sniper, works out of the box.
- **Best (modern Wine + fewer freezes):** install **GE-Proton11** (Wine 11) and
  **repoint it onto sniper** by editing its `toolmanifest.vdf`
  (`4183110` → `1628350`). Wine 11 brings the better WineD3D, a multithreaded
  command stream and fsync — noticeably smoother than Proton 9.0 for a CPU-bound
  dual-core box, and it actually launches.

## Hard limits (not bugs)

- **No Vulkan** → DXVK/VKD3D/gamescope/Proton-default never work. WineD3D only.
- **512 MB VRAM** → high-texture games will still stutter from VRAM swapping;
  lower texture detail in-game. The shader cache fixes compile stutter, not this.
- **No Wayland** — 340.xx is X11 only.

## Files

- `setup-steam-340.sh` — installs deps, the helper, and the global env.
- `steam-340-fix` — sets the universal launch option on every installed game and
  the default Steam Play compat tool. Run with Steam shut down.
