# reclock-nv50 — GeForce 9600 GT (G94 / NV50·Tesla) на современной CachyOS

Заставляем старую **GeForce 9600 GT (G94)** работать на свежей CachyOS (ядро 7.x,
clang/LTO). **Основной путь — проприетарный NVIDIA 340.108 через DKMS.** Попытка
вытащить полные частоты через nouveau-reclocking оказалась тупиком и убрана в
`nouveau-attic/` (справочно).

Цель — одна конкретная машина: **mlamp**, i3-2120, 9600 GT (`10de:0622`), CachyOS,
ядро `7.1.x-cachyos` (clang+ThinLTO). Значения захардкожены сознательно.

## Быстрый старт

```
userspace/install-cachyos.sh      # ставит 340.108: utils (AUR) + патченый DKMS-модуль
sudo reboot                       # выбрать сессию Plasma (X11)
```

После ребута:
```
nvidia-smi                          # драйвер 340.108
lspci -k | grep -A3 -Ei 'vga|3d'    # Kernel driver in use: nvidia
```

Переключение между драйверами в любой момент:
```
userspace/nv-switch.sh status       # что стоит/грузится сейчас
userspace/nv-switch.sh nvidia       # на проприетарь 340.108 (блэклист nouveau)
userspace/nv-switch.sh nouveau      # обратно на nouveau
# затем sudo reboot
```

## Почему вендор-пакет, а не AUR

- Голый AUR `nvidia-340xx-dkms` — это **протухший 340.76 (Linux 4.0)**, он НЕ собирается.
- Живой `nvidia-340xx` (340.108-39) патчит только до ядра 6.15.
- Поэтому драйвер вендорится в `proprietary-340xx/`: PKGBUILD + патчи `0001-0019` (AUR)
  **+ наш `0020-kernel-7.0-7.1.patch`** под ядра 7.0/7.1 и clang/LTO. См.
  `proprietary-340xx/README.md`.

`0020` чинит: conftest (`-fms-extensions` — иначе `static_assert` в `linux/fs.h` валит
все пробы), `in_irq()`→`in_hardirq()`, удалённый глобал `screen_info` (conftest-фолбэк),
и `dkms.conf` (сборка через `SYSSRC=` + авто-детект clang → `CC=clang LLVM=1`).

**Проверено сборкой:** 7.0 gcc (7.0.13-zen) и 7.1 clang (7.1.0-cachyos), и
**DKMS-установкой на саму mlamp** (7.1-rc6 clang): `dkms status … installed`.

## Жёсткие потолки железа (физика чипа, не баг)

- Нет аппаратного Vulkan на Tesla → только OpenGL. DXVK/VKD3D/gamescope невозможны;
  gaming — через WineD3D (OpenGL), DXVK выключен намеренно.
- Проприетарный 340.108 — **только Xorg/X11**, без Wayland. Логиниться в Plasma (X11).
- Secure Boot должен быть выключен (модуль без подписи) либо подписать через MOK.

## Структура

| Путь | Что |
|---|---|
| `proprietary-340xx/` | вендор-пакет 340.108 DKMS (PKGBUILD + патчи 0001-0020) — **основное** |
| `userspace/install-cachyos.sh` | установка проприетарного пути |
| `userspace/nv-switch.sh` | переключатель nvidia ↔ nouveau (обе стороны) |
| `userspace/optimize-system-cachyos.sh` | тюнинг слабого CPU/8ГБ |
| `userspace/setup-gaming-9600gt.sh` | WineD3D-гейминг (DX9/DX10) |
| `userspace/{diagnose,fix}-display-cachyos.sh` | диагностика/восстановление входа |
| `userspace/nv9600gt.py` | контрольная панель (GUI/TUI) |
| `nouveau-attic/` | **архив**: старый nouveau-reclocking (патчи, src, docs, traces, скрипты) |

## Безопасность

- Переключение драйвера и сборка модуля безопасны. Боевой nouveau-reclocking (запись
  pstate в железо) живёт только в `nouveau-attic/` и требует фразы-подтверждения.
- Не коммить build-артефакты: `proprietary-340xx/{src,pkg,*.run,*.pkg.tar.*}` — в `.gitignore`.
