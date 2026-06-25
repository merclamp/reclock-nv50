# reclock-nv50 — стабилизация reclocking в nouveau для GeForce 9600 GT (G94 / NV50·Tesla)

Рабочее пространство для **патчей к существующему nouveau**, а не нового драйвера.
Основано на промпте `../nvidia_legacy_driver_prompt.md`.

**Миссия (по итогам разведки):** дисплей/KMS и OpenGL 3.3/GLES 3.0 уже работают upstream;
единственный реальный пробел — power management. Цель проекта — довести **reclocking
до стабильных полных частот** (`0f`: core 650 / shader 1625 / memory 900 МГц).

## Состав проекта

Проект — две половины одного решения для 9600 GT:

- **Ядерная часть (этот корень):** `patches/`, `src/`, `scripts/build-nouveau.sh`,
  `docs/00-07` — снимают гейт `allow_reclock=false` и собирают патченый `nouveau.ko`.
- **Userspace-обвязка (`userspace/`):** установка, оптимизация (mesa +
  пин pstate + Wayland), gaming (WineD3D, без DXVK), восстановление графики, и
  контрольная панель `nv9600gt.py`. Подробности — `userspace/INTEGRATION.md`.

Связанный пайплайн одной командой (build → dry-run → live → optimize, всё за явным
согласием, с recovery-дисциплиной из `docs/05`):

```
userspace/reclock-full.sh
```

> На стоковом nouveau.ko reclock на NV50 отдаёт `-ENOSYS` — userspace-пин pstate даёт
> реальный прирост (~10%→~80%) только поверх патченого модуля из этого репо.

## ▶ Текущий статус (на момент паузы)

**Сделано (всё безопасно, железо не менялось):**
- Корень найден: reclocking административно выключен — `allow_reclock=false` в `nv50.c:562`;
  `nvkm_clk_ustate_update` отдаёт `-ENOSYS`. VBIOS даёт ровно один pstate `0f`, вольтаж
  уже на максимуме (1.15 В). Разбор: `docs/03`, `docs/04`.
- Патч готов: `patches/0001-...patch` (`false→true`), сверен с rnndb (`docs/06`).
- **Патченный `nouveau.ko` СОБРАН** (`build/nouveau-src/nouveau.ko`), vermagic совпал
  с ядром (`7.0.11-1-cachyos`), MODVERSIONS off ⇒ загрузится. Сборка: `scripts/build-nouveau.sh`.
- Второй фронт (TTM ENOMEM, мешает сейчас) локализован в исходнике: `docs/07`.

**Следующий шаг — ТРЕБУЕТ ТЕБЯ (уронит графсессию на этой карте):**
безопасная сухая прогонка `NvMemExec=0` по плану `docs/05` §C — проверит, что гейт снят
и `calc` считает частоты БЕЗ записи в память. Боевой memory-reclock — только после неё и
с планом восстановления (`docs/05` §D/E). Ничего с железом без твоего «go» не делаю.

## Целевая система (измерено 2026-06-25, не по памяти)

| Параметр | Значение | Источник |
|---|---|---|
| GPU | NVIDIA G94 [GeForce 9600 GT], PCI `10de:0622`, slot `0000:01:00.0` | `lspci`, sysfs uevent |
| Семейство | NV50 / Tesla (nouveau-класс `nv50`, чип `NV94`) | renderer string `NV94` |
| Ядро | `7.0.11-1-cachyos` (новее, чем 6.8+ из промпта) | `uname -r` |
| Драйвер | `nouveau` загружен, стек `drm_gpuvm`+`gpu_sched`+`drm_exec`+`ttm` | `lsmod` |
| Mesa | `26.1.2` | `pacman -Q mesa` |
| Сессия | Wayland (wayland-0), Xwayland на :0 | env |

## Главный вывод разведки

Цели промпта №1 (Wayland/KMS) и №2 (OpenGL 3.3 / GLES 3.0) **уже закрыты upstream**
на этой машине. Vulkan отсутствует — как и предсказано (NV50 его не поддерживает).
**Единственный реальный незакрытый фронт — reclocking (цель №4).**

Подробности и доказательства: `docs/00-current-state.md`.
Архитектура и точки приложения сил: `docs/01-architecture.md`.
План по срезам: `docs/02-roadmap.md`.

## Скрипты

- `scripts/assess.sh` — read-only диагностика без root (воспроизводимо).
- `scripts/assess-root.sh` — чтение `pstate`/`clk`/`dmesg` (нужен root).

## Безопасность железа

Reclocking-эксперименты могут **намертво подвесить GPU**. Любая запись в `pstate`
или MMIO выполняется только: (а) с явного согласия, (б) при наличии способа удалённой
перезагрузки (SSH/watchdog). По умолчанию делаем только чтение.
