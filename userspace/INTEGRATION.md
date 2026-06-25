# 9600gt-pack — обвязка userspace вокруг reclock-nv50

Этот пак — **userspace-половина** проекта `reclock-nv50`. Корневой репозиторий
решает ядерную часть (снимает гейт `allow_reclock=false` в `nvkm/subdev/clk/nv50.c`
и собирает патченый `nouveau.ko`). Пак даёт удобную обвязку вокруг готового модуля:
установку, оптимизацию, gaming, восстановление графики и контрольную панель.

## Как пак стыкуется с ядерным патчем (ВАЖНО)

На NV50/Tesla (наш G94) **стоковый** `nouveau.ko` отдаёт `-ENOSYS` на запись в
`pstate` (см. `docs/03`, `docs/04`). Поэтому:

> `optimize-nouveau-cachyos.sh` пинит максимальный pstate через `/sys/.../pstate`.
> Это даёт реальный прирост (~10% → ~80%) **только после** установки патченого
> модуля из корня репозитория (`scripts/build-nouveau.sh` → §C/§D в `docs/05`).
> На стоковом модуле скрипт отработает, но pstate не переключится (ENOSYS).

Правильный порядок на машине с 9600 GT:

1. **Ядерная часть (корень репо):** собрать патченый модуль и пройти dry-run.
   ```
   scripts/build-nouveau.sh /путь/к/исходникам/ядра   # см. docs/05 §A-B
   # затем БЕЗОПАСНЫЙ dry-run по docs/05 §C (NvMemExec=0), и только потом §D
   ```
2. **Userspace (этот пак):** после того как reclock реально работает —
   ```
   userspace/optimize-nouveau-cachyos.sh   # пинит max pstate + mesa + Wayland
   ```

### Либо одной командой — связанный пайплайн

`reclock-full.sh` гонит весь путь end-to-end с дисциплиной безопасности из `docs/05`:

```
userspace/reclock-full.sh        # из TTY, с готовым recovery (SSH/SysRq)
# опц.: NV_KSRC=/path/to/linux-7.0.11 userspace/reclock-full.sh
```

Стадии (каждая за явным «go», в железо не пишет до фразы-подтверждения):
`assess (RO)` → `build-nouveau.sh` → `dry-run NvMemExec=0` (§C) →
`live reclock` (§D) → `optimize-nouveau-cachyos.sh`.

## Состав пака

| Файл | Назначение | Драйвер |
|---|---|---|
| `nv9600gt.py` | GUI/TUI контрольная панель (stdlib, без зависимостей) | — |
| `reclock-full.sh` | end-to-end: build → dry-run → live reclock → optimize (gated) | nouveau |
| `aggressive-tweaks.sh` | выжать всё на полигоне: CPU/RAM/IO/KDE opt-in, GPU-reclock за подтверждением | nouveau |
| `target-machine.sh` | sourceable guard: предупреждает при запуске не на той машине | — |
| `optimize-nouveau-cachyos.sh` | mesa-стек + пин max pstate (нужен патченый модуль) + Wayland | nouveau |
| `optimize-system-cachyos.sh` | системная оптимизация под слабый CPU (i3-2120, 8 ГБ) | любой |
| `setup-gaming-9600gt.sh` | Wine + WineD3D (OpenGL), DXVK выключен, virtual-desktop | nouveau |
| `diagnose-display.sh` | read-only сбор логов из TTY при сломанном входе | любой |
| `fix-display-cachyos.sh` | восстановление графического входа (nouveau + X11) | nouveau |
| `install-cachyos.sh` | проприетарный 340.108-dkms (Xorg-only) — **альтернатива nouveau** | nvidia-340xx |
| `build-yserver.sh` | сборка экспериментального X11-сервера joske/yserver | nouveau |
| `README.md` / `README-nouveau-wayland.md` | гайды по обоим путям | — |

## Развилка драйверов (взаимоисключающе)

- **nouveau + reclock-патч** (этот проект) → Wayland работает, ~80% перфа после reclock,
  открытый стек. Совместимо с yserver.
- **проприетарный 340.108** (`install-cachyos.sh`) → максимум OpenGL, но **Xorg-only**,
  без Wayland, и yserver на нём НИКОГДА не заведётся. Конфликтует с reclock-веткой.

`nv9600gt.py` предупреждает об этом конфликте перед установкой проприетарного драйвера.

## Жёсткие потолки железа (G94 / Tesla)

- **Нет аппаратного Vulkan** → только OpenGL-игры; DXVK/VKD3D невозможны (отсюда WineD3D в gaming-скрипте).
- Reclocking ручной → pstate пинится на максимум (выше idle-температура).
- Цель reclock: pstate `0f` — core 650 / shader 1625 / memory 900 МГц (паспортные).

## Безопасность

Userspace-скрипты делают бэкапы и идемпотентны. Любые операции, пишущие в железо
(reclock memory), живут в КОРНЕ репозитория и требуют явного согласия + плана
восстановления (`docs/05` §D/§E). Пак сам в железо не пишет.
