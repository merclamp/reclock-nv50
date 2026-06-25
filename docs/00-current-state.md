# 00 — Текущее состояние (обязательный первый шаг промпта)

Все факты ниже **измерены на живой системе 2026-06-25**, а не взяты по памяти.
Маркировка: `[измерено]` — прямой вывод команды; `[вывод]` — заключение из измерений.

## 1. Идентификация железа `[измерено]`

```
01:00.0 VGA compatible controller: NVIDIA Corporation G94 [GeForce 9600 GT] (rev a1)
PCI_ID=10DE:0622  SUBSYS=1043:827C  driver=nouveau
renderer: NV94   (nouveau-класс nv50, семейство Tesla)
```

## 2. Дисплей / KMS — РАБОТАЕТ `[измерено]`

- Сейчас активна сессия **Wayland** (`XDG_SESSION_TYPE=wayland`) на этой карте.
- `modetest -M nouveau -c`: коннектор **DVI-I-1 connected, 18 режимов**; DVI-I-2 disconnected.
- Plane-типы: Primary / Cursor / Overlay (atomic KMS — `dispnv50`).
- `/dev/dri/card0` + `renderD128` присутствуют, `direct rendering: Yes`.

**Вывод `[вывод]`:** цель промпта №1 (Wayland через atomic KMS) закрыта upstream.
Срезы 1–2 из методологии промпта («лампочка», atomic modeset) уже пройдены.

## 3. 3D-ускорение — OpenGL 3.3 / GLES 3.0 ДОСТИГНУТЫ `[измерено]`

```
OpenGL renderer: NV94 (Mesa 26.1.2-arch3.1)
OpenGL core profile version: 3.3 (Core Profile)
OpenGL version (compat):    3.3 (Compatibility Profile)
OpenGL ES profile version:  OpenGL ES 3.0
Max core profile version:   3.3
EGL: 1.5
Vulkan: устройств нет
```

**Вывод `[вывод]`:** цель №2 закрыта. Vulkan отсутствует — соответствует промпту
(NV50 аппаратно без Vulkan; DXVK/Zink неприменимы). «Реалистичный потолок» подтверждён.

## 4. Reclocking / Power management — ЕДИНСТВЕННЫЙ ПРОБЕЛ `[измерено]`

`/sys/kernel/debug/dri/0000:01:00.0/pstate`:
```
0f: core 650 MHz  shader 1625 MHz  memory 900 MHz    ← доступный performance pstate
AC: core 500 MHz  shader 1250 MHz  memory 499 MHz    ← ТЕКУЩИЙ реальный режим
```

hwmon (`name=nouveau`): `temp1_input=45000` (45 °C), `in0_input=1150` (≈1.15 В ядро).
Узлы `clk`/`volt` в debugfs вывода не дали (нет файла или иное имя — проверить).

**Вывод `[вывод]`:**
- Память работает на **499 из 900 МГц**, ядро 500/650, шейдеры 1250/1625 — карта
  сидит в пониженном режиме и **сама не поднимается** до `0f`.
- Это и есть «частично реализованный, нестабильный reclocking» из промпта.
- Потенциальный прирост: memory clock ×1.8, core ×1.3, shader ×1.3 — существенный
  для игр (память — обычно бутылочное горло на NV50).

## 5. Доступ к исходникам `[измерено]`

- Установлены `linux-cachyos-headers 7.0.11-1` → есть `…/build` symlink (заголовки).
- Полных `.c` nouveau в дереве **нет** (поиск `*nouveau*clk*.c` пуст).
- Прямой `git clone` с `gitlab.freedesktop.org` в этом окружении закрыт (запрос логина).
- `modinfo nouveau`: `srcversion=312143483E5151BCCE1C10D`, vermagic `7.0.11-1-cachyos`.

**Следствие:** для реальных правок нужно добыть полные исходники nouveau
(см. `docs/02-roadmap.md`, шаг 0).

## Открытые вопросы для следующего шага

1. Что произойдёт при ручном `echo 0f > pstate` — поднимется стабильно или зависнет?
   (рискованный тест; только при наличии пути перезагрузки).
2. Почему нет промежуточных pstate (обычно 07 boot + 0a + 0f)? Только `0f` и `AC`.
3. Содержимое `clk`/`volt`/`therm` узлов debugfs (имена уточнить).
