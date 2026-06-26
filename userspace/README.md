# NVIDIA GeForce 9600 GT (512 MB) на CachyOS — самый свежий рабочий драйвер

## TL;DR

- **Чип:** G94, архитектура **Tesla** (карта 2008 г.).
- **Единственная драйверная ветка:** NVIDIA **340.xx legacy**, последний релиз — **340.108**
  (вышел 23.12.2019, дальше EOL). Это потолок от NVIDIA — ничего новее для этой карты
  не существует и не появится.
- На современных ядрах (7.0/7.1, clang/LTO) 340.108 **не собирается** без патчей.
- Голый AUR `nvidia-340xx-dkms` — **протухший 340.76 (Linux 4.0)**, НЕ собирается. Живой
  `nvidia-340xx` (340.108-39) патчит только до 6.15. Поэтому мы вендорим драйвер в
  `../proprietary-340xx/` (PKGBUILD + патчи 0001-0019 **+ наш `0020-kernel-7.0-7.1.patch`**).

## Установка (одной командой)

```bash
chmod +x install-cachyos.sh
./install-cachyos.sh
sudo reboot
```

Скрипт сам:
1. находит видеокарту и проверяет, что это 340-класс (G94/9600 GT),
2. определяет пакет **headers под запущенное ядро** (`linux-cachyos-headers`,
   `linux-cachyos-rc-headers`, `linux-zen-headers` и т.д. — у CachyOS их несколько),
3. ставит `nvidia-340xx-utils` (AUR) + собирает патченый `nvidia-340xx-dkms` из `../proprietary-340xx/`,
4. блэклистит nouveau и пересобирает initramfs,
5. проверяет, что DKMS-модуль реально собрался.

> Запускать **от обычного пользователя**, не из-под root (paru собирает без рута и сам
> вызовет sudo, где нужно).

## Установка вручную (если не хочешь скрипт)

```bash
# headers строго под текущее ядро (пример для cachyos; проверь: uname -r)
sudo pacman -S --needed base-devel dkms linux-cachyos-headers

# utils — из AUR (он свежий, 340.108); модуль — из нашего вендор-пакета
paru -S --needed nvidia-340xx-utils
# clang-ядро (CachyOS)? добавь: sudo pacman -S --needed clang llvm lld
cd ../proprietary-340xx
NVIDIA_340XX_DKMS_ONLY=1 makepkg -f --nodeps      # --nodeps: PKGBUILD makedepends тянут стоковый linux
sudo pacman -U --noconfirm nvidia-340xx-dkms-*.pkg.tar.*

# отключить nouveau
printf 'blacklist nouveau\noptions nouveau modeset=0\n' | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
sudo mkinitcpio -P
sudo reboot
```

> **Почему именно `-dkms`, а не обычный `nvidia-340xx`:** обычный пакет привязан к
> конкретной версии ядра и отвалится при первом же обновлении ядра. DKMS пересобирает
> модуль автоматически — на CachyOS с её свежими/частыми ядрами это критично.

## Проверка после ребута

```bash
nvidia-smi                          # должна показать драйвер 340.108 и карту
lspci -k | grep -A3 -Ei 'vga|3d'    # 'Kernel driver in use: nvidia'
glxinfo | grep "OpenGL renderer"    # пакет mesa-utils; должен показать GeForce 9600 GT
dkms status                         # nvidia ... installed
```

## Steam-игры (железный рендер, а не 1 FPS)

Steam гоняет игры в контейнере pressure-vessel, а драйвер 340 — до-glvnd, поэтому
контейнер не видит nvidia-GL и сваливается в софтовый Mesa/llvmpipe → **1 FPS**.
Лечится так (см. `STEAM-GAMING.md` — там полная история и ловушка SLR 4.0):

```bash
./setup-steam-340.sh                 # host-GL + 32-битные либы + helper + env
# поставить GE-Proton11 в ~/.steam/root/compatibilitytools.d/ и пересадить на sniper
# (SLR 4.0 у Steam битый — "invalid platform"/"version 0"):
sed -i 's/"require_tool_appid" *"4183110"/"require_tool_appid" "1628350"/' \
  ~/.steam/root/compatibilitytools.d/GE-Proton11-1/toolmanifest.vdf
steam -shutdown && steam-340-fix GE-Proton11-1
```

Универсальная launch-опция (helper проставляет её всем играм):
`PROTON_USE_WINED3D=1 __GL_SHADER_DISK_CACHE=1 STEAM_RUNTIME=0 %command%`.
Потолок железа: **нет Vulkan** (DXVK/VKD3D/gamescope невозможны, только WineD3D/OpenGL)
и **512 МБ VRAM** (на высоких текстурах всё равно подлагивает — снижай детализацию).

## Важно именно для CachyOS / KDE Plasma

- **Только Xorg (X11), не Wayland.** Драйвер 340.xx древний и под Wayland фактически
  не работает. На экране входа (SDDM) выбирай сессию **"Plasma (X11)"**.
- **Secure Boot — выключить** в UEFI (неподписанный модуль не загрузится), либо подписать
  модуль через MOK.
- При смене/обновлении ядра проверь, что стоит соответствующий `*-headers` — DKMS тогда
  пересоберёт модуль сам.
- Запасной вариант — **nouveau** (open-source, уже в ядре). Проще всего:
  `./nv-switch.sh nouveau && sudo reboot` (обратно — `./nv-switch.sh nvidia`). nouveau медленнее в 3D,
  но работает везде и умеет Wayland.

## Существующие проекты на GitHub (research — изобретать своё не нужно)

Драйвер закрытый; легально мы только патчим NVIDIA-шный модуль под новое ядро. Живые
проекты, которые это уже делают:

| Проект | Что даёт | Статус |
|---|---|---|
| **AUR `nvidia-340xx`** (maint. JerryXiao) | База 340.108-39, патчи до ядра 6.15 | ✅ Живой — **основа нашего вендор-пакета + 0020** |
| ~~AUR `nvidia-340xx-dkms`~~ (maint. Anish Bhatt) | Протух на 340.76 / Linux 4.0 | ❌ НЕ собирается |
| **dkosmari/nvidia-340.108-updated** | Скрипты+патчи сборки 340.108 под Linux 6.0+ | ✅ Живой |
| **kda2210/nvidia-340-ubuntu-24.04** | DKMS 340.108 под Ubuntu 24.04 + ядро 6.11 | ✅ Живой (для Ubuntu) |
| **steamos-community/pkg-...-legacy-340xx** | .deb-пакеты ветки 340xx | ✅ Поддерживается |
| **MeowIce/nvidia-legacy** | Патченные .run под ядра 5.8–6.8 | ⚠️ Архив (18.09.2025, max 6.8) |
| **Frogging-Family / If-Not-True-Then-False** | Исходные патчи, на которые опираются остальные | ✅ Источник патчей |

**Вывод:** берём живую базу AUR `nvidia-340xx` (340.108-39) и докладываем
`0020-kernel-7.0-7.1.patch` под ядра 7.0/7.1 + clang/LTO. Голый `nvidia-340xx-dkms`
(Anish Bhatt) застрял на 340.76 и не годится. Новее 340.108 для этой карты не бывает.

## Типичные грабли

| Симптом | Причина / решение |
|---|---|
| Чёрный экран после ребута | nouveau не отключён, или DKMS не собрался под текущее ядро. Проверь `dkms status` и headers под `uname -r`. |
| Картинка отвалилась после `pacman -Syu` (новое ядро) | Ставил не-DKMS пакет, либо нет headers под новое ядро. Используй `nvidia-340xx-dkms` + поставь нужные headers. |
| Пустой/глючный экран в сессии | Зашёл в Wayland-сессию. Перелогинься в **Plasma (X11)**. |
| Модуль не грузится, в dmesg про подпись | Включён Secure Boot. Отключи или подпиши через MOK. |
| `paru` собирает с ошибкой патча | Очисти кэш сборки: `paru -Sc`, затем повтори; или собери вручную из `aur.archlinux.org/nvidia-340xx-dkms.git`. |
