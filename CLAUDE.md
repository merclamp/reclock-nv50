# CLAUDE.md — инструкции для агента (Claude / GJC) в этом репозитории

Прочитай это ПОЛНОСТЬЮ перед любыми действиями. Репо узкоспециализированное:
оно про **одну конкретную машину** и **одну видеокарту**. Не обобщай.

## Что это за проект

`reclock-nv50` — заставить **GeForce 9600 GT (G94 / NV50 / Tesla)** работать на
современной CachyOS. ОСНОВНОЙ путь теперь — **проприетарный NVIDIA 340.108**
через DKMS. nouveau-reclocking оказался тупиком и убран в архив.

Структура:
- **`proprietary-340xx/` (ГЛАВНОЕ):** вендоренный PKGBUILD драйвера 340.108 +
  патчи `0001-0019` (AUR, до 6.15) **+ наш `0020-kernel-7.0-7.1.patch`** — сборка на
  ядрах 7.0/7.1 и clang/LTO (CachyOS). См. `proprietary-340xx/README.md`.
- **Userspace (`userspace/`):** `install-cachyos.sh` (ставит проприетарь из вендор-
  пакета), `nv-switch.sh` (переключатель nvidia↔nouveau), системный тюнинг, gaming,
  восстановление графики, панель `nv9600gt.py`.
- **`nouveau-attic/` (АРХИВ, не трогать без надобности):** весь старый nouveau-reclock
  (`patches/`, `src/nvkm-*`, `scripts/build-nouveau.sh`, `docs/00-07`, `traces/`,
  `установить-всё.sh`, nouveau-скрипты). Справочно, не поддерживается.

## ЦЕЛЕВАЯ МАШИНА (всё заточено ровно под неё — НЕ универсально)

| Компонент | Значение |
|---|---|
| GPU | NVIDIA **G94 [GeForce 9600 GT]**, PCI `10de:0622`, slot `0000:01:00.0` |
| Семейство | **NV50 / Tesla** (nouveau-класс `nv50`, чип `NV94`) |
| CPU | **Intel i3-2120 / 2130** (Sandy Bridge, 2 ядра / 4 потока) — СЛАБЫЙ |
| RAM | ~**8 ГБ** |
| ОС | **CachyOS** (Arch-based), ядро `7.0.11+-cachyos`, KDE Plasma |
| Сессия | Wayland (с проблемами входа — см. ниже) |
| Mesa | 26.x |

Эти значения захардкожены в скриптах СОЗНАТЕЛЬНО. Не переписывай их «для общности».

## ЖЁСТКИЕ ПОТОЛКИ ЖЕЛЕЗА (не пытайся обойти — это физика чипа)

- **Нет аппаратного Vulkan** на Tesla → только OpenGL. DXVK/VKD3D/gamescope невозможны.
  Поэтому gaming сделан через **WineD3D (OpenGL)**, DXVK ВЫКЛЮЧЕН намеренно — это не баг.
- На проприетарном 340.108 частотами управляет сам драйвер — reclocking вручную НЕ нужен.
  Ручной nouveau-reclock (pstate = `-ENOSYS` на стоке, прирост ~10%→~80%) — в `nouveau-attic/`, архив.
- Проприетарный 340.108 и nouveau **взаимоисключающи**. 340 = Xorg-only, без Wayland,
  yserver на нём НИКОГДА не заработает.

## BOUNDARY — что НЕЛЬЗЯ делать без явного «go» пользователя

- **НИКОГДА не писать в железо GPU** (pstate / MMIO / live memory-reclock) без явного
  согласия И плана восстановления (SSH со второй машины / Magic SysRq / reset).
  Это касается только архивного nouveau-reclock (`nouveau-attic/userspace/reclock-full.sh`
  требует фразы-подтверждения — не обходи). Проприетарь в железо так не лезет.
- **Переключение драйвера** — только через `userspace/nv-switch.sh` (он владеет своими
  modprobe.d-файлами и делает бэкапы). Пересборка initramfs обязательна, живой swap драйвера не делать.
- Безопасны: сборка модуля (`proprietary-340xx/`, makepkg/dkms), чтение-диагностика.
- Не коммить build-артефакты: `proprietary-340xx/{src,pkg,*.run,*.pkg.tar.*}`,
  `nouveau-attic/src/linux*`, `nouveau-attic/src/nouveau/` (всё в `.gitignore`).

## ЕСЛИ ПОЛЬЗОВАТЕЛЬ ЖАЛУЕТСЯ «KDE не запускает иксы / чёрный экран после логина»

Наиболее вероятно: SDDM в Wayland-сессии падает на старом GPU, ИЛИ остатки
проприетарного 340 + блэклист nouveau. Порядок действий (НЕ чини вслепую):

1. Попроси зайти в TTY: **Ctrl+Alt+F3**, логин текстом.
2. Запустить read-only диагностику и прислать отчёт:
   ```
   bash userspace/diagnose-display.sh      # пишет display-diag-*.txt, ничего не меняет
   ```
3. По отчёту: если виноваты остатки nvidia/блэклист/stale xorg.conf →
   ```
   bash userspace/fix-display-cachyos.sh   # вернёт вход через nouveau + X11 (с бэкапами)
   ```
4. Аварийный фолбэк (всегда работает): `sudo systemctl set-default multi-user.target`
   (грузиться в текст), починить, потом `graphical.target`.

## ТИПОВЫЕ СЦЕНАРИИ → какой скрипт

| Хочет | Запускать |
|---|---|
| Поставить проприетарный 340.108 (ОСНОВНОЙ путь, X11-only) | `userspace/install-cachyos.sh` |
| Переключиться nvidia ↔ nouveau | `userspace/nv-switch.sh {status\|nvidia\|nouveau}` |
| Собрать драйвер вручную | `cd proprietary-340xx && NVIDIA_340XX_DKMS_ONLY=1 makepkg -si` |
| Ускорить систему (слабый CPU/8ГБ) | `userspace/optimize-system-cachyos.sh` |
| Старые игры (DX9/DX10) | `userspace/setup-gaming-9600gt.sh`, потом `wine9600 game.exe` |
| Сломан вход в графику | `userspace/diagnose-display.sh` → `userspace/fix-display-cachyos.sh` |
| Меню «что делать» | `python3 userspace/nv9600gt.py` |
| Старый nouveau-reclock / yserver | `nouveau-attic/` (архив, справочно) |

## ПРИНЦИПЫ ПОЛЬЗОВАТЕЛЯ (учитывай)

- keyless, без вендорных API, без платных сервисов. Решения — через конфиг/открытый стек.
- Прямота без воды и без выпрашивания разрешений на очевидные шаги.
- Скрипты идемпотентны, делают бэкапы (`.bak-<дата>`), не трогают пользовательские данные.

## ПЕРЕД ИЗМЕНЕНИЯМИ

- Все shell-скрипты обязаны проходить `bash -n`; Python — парситься.
- Патч драйвера под новое ядро — в `proprietary-340xx/00NN-kernel-*.patch`; проверяй сборку
  против реальных заголовков ядра (clang — `CC=clang LLVM=1`), не на глазок.
- Если действие пишет в железо или может уронить графику — СНАЧАЛА предупреди и получи «go».
