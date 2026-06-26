#!/usr/bin/env bash
# Сборка пропатченного nouveau.ko out-of-tree против установленных headers.
# Ядро собрано clang+LTO ⇒ строго LLVM=1. MODVERSIONS off ⇒ важен только vermagic.
#
# Использование:
#   scripts/build-nouveau.sh [ПУТЬ_К_ИСХОДНИКАМ]
# ПУТЬ_К_ИСХОДНИКАМ — либо полное дерево ядра (содержит drivers/gpu/drm/nouveau),
# либо сам каталог nouveau. Если не задан, ищет в src/linux*, src/nouveau.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
KB=/usr/lib/modules/$(uname -r)/build
PATCH="$ROOT/patches/0001-nvkm-clk-nv50-enable-reclocking.patch"
WORK="$ROOT/build/nouveau-src"

# 1. найти исходники
SRC="${1:-}"
if [ -z "$SRC" ]; then
  # ловим и фиксированные имена, и версионированные (src/linux-7.0.11, src/linux-cachyos-*)
  for c in "$ROOT"/src/linux* "$ROOT"/src/linux-source "$ROOT"/src/nouveau "$ROOT"/src/linux-nouveau; do
    [ -d "$c/drivers/gpu/drm/nouveau" ] && SRC="$c" && break
    [ -d "$c" ] && [ -z "$SRC" ] && SRC="$c"
  done
fi
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "НЕ НАЙДЕН исходник. Укажи путь аргументом."; exit 1; }

# 2. локализовать каталог nouveau
if [ -d "$SRC/drivers/gpu/drm/nouveau" ]; then
  NVSRC="$SRC/drivers/gpu/drm/nouveau"
elif [ -f "$SRC/nouveau_drv.h" ] || [ -d "$SRC/nvkm" ]; then
  NVSRC="$SRC"
else
  echo "В '$SRC' не видно nouveau (ни drivers/gpu/drm/nouveau, ни nvkm/)."; exit 1
fi
echo "nouveau source: $NVSRC"

# 3. копия в рабочий каталог (чтобы не пачкать исходник)
rm -rf "$WORK"; mkdir -p "$WORK"
cp -a "$NVSRC/." "$WORK/"

# 4. применить патч (подбираем -p автоматически)
cd "$WORK"
applied=
for p in 5 4 1; do
  if patch --dry-run -p$p < "$PATCH" >/dev/null 2>&1; then
    patch -p$p < "$PATCH"; applied=$p; break
  fi
done
[ -n "$applied" ] || { echo "Патч не применился (проверь контекст nv50.c)."; exit 1; }
echo "Патч применён (-p$applied). Проверка:"
grep -n "nv50_clk_new_(&nv50_clk" nvkm/subdev/clk/nv50.c || true

# 5. сборка тем же тулчейном, что ядро
JOBS=$(nproc)
echo "Сборка (LLVM=1, -j$JOBS) против $KB ..."
make -C "$KB" M="$WORK" LLVM=1 -j"$JOBS" modules

echo
KO=$(find "$WORK" -name 'nouveau.ko*' | head -1)
echo "ГОТОВО: $KO"
echo "vermagic собранного модуля:"; modinfo "$KO" 2>/dev/null | grep -E '^vermagic|^filename'
echo "vermagic текущего ядра:    $(cat /usr/lib/modules/$(uname -r)/build/include/config/kernel.release 2>/dev/null)"
