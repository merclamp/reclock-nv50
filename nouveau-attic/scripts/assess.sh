#!/usr/bin/env bash
# Read-only диагностика nouveau NV50 (без root). Воспроизводит разведку проекта.
set -u
SLOT="0000:01:00.0"
echo "===== GPU / драйвер ====="
lspci -nn | grep -iE "vga|3d|nvidia"
readlink -f /sys/bus/pci/devices/$SLOT/driver
echo "===== ядро / модуль ====="
uname -r; lsmod | grep -i nouveau | head -1
echo "===== сессия ====="
echo "session=$XDG_SESSION_TYPE wayland=$WAYLAND_DISPLAY display=$DISPLAY"
echo "===== OpenGL / GLES ====="
glxinfo -B 2>/dev/null | grep -iE "renderer|OpenGL (core|version|ES)|direct rendering"
echo "===== Vulkan ====="
vulkaninfo --summary 2>/dev/null | grep -iE "deviceName|driverName" || echo "(нет Vulkan — ожидаемо)"
echo "===== KMS коннекторы ====="
modetest -M nouveau -c 2>/dev/null | grep -iE "connected|disconnected" | head
echo "===== hwmon (temp/volt) ====="
for h in /sys/class/drm/card0/device/hwmon/hwmon*; do
  for f in "$h"/temp1_input "$h"/in0_input "$h"/fan1_input; do
    [ -e "$f" ] && echo "$(basename "$f")=$(cat "$f" 2>/dev/null)"
  done
done
