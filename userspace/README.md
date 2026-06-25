# NVIDIA GeForce 9600 GT (512 MB) на CachyOS — самый свежий рабочий драйвер

## TL;DR

- **Чип:** G94, архитектура **Tesla** (карта 2008 г.).
- **Единственная драйверная ветка:** NVIDIA **340.xx legacy**, последний релиз — **340.108**
  (вышел 23.12.2019, дальше EOL). Это потолок от NVIDIA — ничего новее для этой карты
  не существует и не появится.
- На современных ядрах (6.x/7.x) ванильный 340.108 **не собирается** — нужен community-патч.
- На CachyOS правильный путь: **AUR-пакет `nvidia-340xx-dkms`** (DKMS = автопересборка
  при смене ядра). Пакет живой, патчится под ядра вплоть до 7.x (обновлён 2025-08-03).

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
3. ставит `nvidia-340xx-dkms` + `nvidia-340xx-utils` через `paru`,
4. блэклистит nouveau и пересобирает initramfs,
5. проверяет, что DKMS-модуль реально собрался.

> Запускать **от обычного пользователя**, не из-под root (paru собирает без рута и сам
> вызовет sudo, где нужно).

## Установка вручную (если не хочешь скрипт)

```bash
# headers строго под текущее ядро (пример для cachyos; проверь: uname -r)
sudo pacman -S --needed base-devel dkms linux-cachyos-headers

# сам драйвер из AUR (DKMS-вариант — обязателен на CachyOS из-за частых апдейтов ядра)
paru -S nvidia-340xx-dkms nvidia-340xx-utils

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

## Важно именно для CachyOS / KDE Plasma

- **Только Xorg (X11), не Wayland.** Драйвер 340.xx древний и под Wayland фактически
  не работает. На экране входа (SDDM) выбирай сессию **"Plasma (X11)"**.
- **Secure Boot — выключить** в UEFI (неподписанный модуль не загрузится), либо подписать
  модуль через MOK.
- При смене/обновлении ядра проверь, что стоит соответствующий `*-headers` — DKMS тогда
  пересоберёт модуль сам.
- Запасной вариант, если что-то пошло не так: **nouveau** (open-source, уже в ядре).
  Удали `/etc/modprobe.d/blacklist-nouveau.conf`, сделай `sudo mkinitcpio -P`, ребут —
  картинка вернётся через nouveau (медленнее в 3D, но работает везде и умеет Wayland).

## Существующие проекты на GitHub (research — изобретать своё не нужно)

Драйвер закрытый; легально мы только патчим NVIDIA-шный модуль под новое ядро. Живые
проекты, которые это уже делают:

| Проект | Что даёт | Статус |
|---|---|---|
| **AUR `nvidia-340xx-dkms` / `nvidia-340xx`** (maint. JerryXiao) | Готовый пакет для Arch/CachyOS, патчи под ядра до 7.x | ✅ Живой (2025-08-03) — **наш выбор** |
| **dkosmari/nvidia-340.108-updated** | Скрипты+патчи сборки 340.108 под Linux 6.0+ | ✅ Живой |
| **kda2210/nvidia-340-ubuntu-24.04** | DKMS 340.108 под Ubuntu 24.04 + ядро 6.11 | ✅ Живой (для Ubuntu) |
| **steamos-community/pkg-...-legacy-340xx** | .deb-пакеты ветки 340xx | ✅ Поддерживается |
| **MeowIce/nvidia-legacy** | Патченные .run под ядра 5.8–6.8 | ⚠️ Архив (18.09.2025, max 6.8) |
| **Frogging-Family / If-Not-True-Then-False** | Исходные патчи, на которые опираются остальные | ✅ Источник патчей |

**Вывод:** для CachyOS отдельный проект делать незачем — AUR `nvidia-340xx-dkms` уже
является «most up-to-date driver» для 9600 GT. Новее 340.108 для этой карты не бывает.

## Типичные грабли

| Симптом | Причина / решение |
|---|---|
| Чёрный экран после ребута | nouveau не отключён, или DKMS не собрался под текущее ядро. Проверь `dkms status` и headers под `uname -r`. |
| Картинка отвалилась после `pacman -Syu` (новое ядро) | Ставил не-DKMS пакет, либо нет headers под новое ядро. Используй `nvidia-340xx-dkms` + поставь нужные headers. |
| Пустой/глючный экран в сессии | Зашёл в Wayland-сессию. Перелогинься в **Plasma (X11)**. |
| Модуль не грузится, в dmesg про подпись | Включён Secure Boot. Отключи или подпиши через MOK. |
| `paru` собирает с ошибкой патча | Очисти кэш сборки: `paru -Sc`, затем повтори; или собери вручную из `aur.archlinux.org/nvidia-340xx-dkms.git`. |
