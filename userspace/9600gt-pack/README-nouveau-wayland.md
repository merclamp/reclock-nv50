# GeForce 9600 GT + Wayland на CachyOS: nouveau «как можно ближе к NVIDIA»

## Сначала — честно, без вранья

Ты просила «чтобы nouveau был не хуже nvidia» и «чтобы Wayland работал». Вот правда:

- **Wayland на 9600 GT возможен ТОЛЬКО через nouveau.** Проприетарный 340.xx физически
  не умеет Wayland — у него нет GBM-бэкенда (он появился только с драйвера 495+).
  Это не лечится патчами: в закрытый бинарник 340.108 нельзя дописать половину драйвера.
- **`nvidia-open` к этой карте не относится** — он только для Turing+ (RTX 20xx и новее).
  Сравнивать не с чем.
- **«Не хуже nvidia» недостижимо на 100%**, но достижимо **~80%** — и это упирается в одну
  вещь: reclocking.

## Почему nouveau обычно «тормозит» и как это чинится

nouveau по умолчанию держит Tesla-карту на **минимальной загрузочной частоте** → ты получаешь
**~10%** производительности проприетарного драйвера. Причина — NVIDIA не дала автоматическое
управление частотами.

**НО:** чип 9600 GT — это **G94**, а nouveau поддерживает **ручной reclocking** для
**Tesla G94-GT218**. Если принудительно выставить максимальный pstate — получаешь **~80%**
производительности проприетарного 340 в OpenGL. Это подтверждено и официальной вики nouveau,
и бенчмарками ventureoo/nouveau-reclocking.

Скрипт `optimize-nouveau-cachyos.sh` именно это и делает автоматически на каждом старте.

## Жёсткие потолки железа (их не обойти ничем)

| Ограничение | Следствие |
|---|---|
| Tesla **не имеет Vulkan** на уровне железа | OpenGL-игры — да; чисто Vulkan-игры — **никогда** (ни nouveau, ни 340 это не дадут) |
| Reclocking на Tesla **ручной** | частоты пиним на максимум → выше idle-температура/потребление |
| Карта 2008 года, 512 МБ | тяжёлые современные игры всё равно не потянет — это не про драйвер |

Итог: **OpenGL ~80% от nvidia-340, полноценный Wayland, открытый драйвер.** Это максимум
из физически возможного на этой карте.

## А что насчёт DXVK?

Коротко: **DXVK на 9600 GT не работает и не нужен.** DXVK переводит Direct3D 9/10/11 в
**Vulkan**, а у Tesla (G94) **нет аппаратного Vulkan** — ни через nouveau/NVK, ни через
проприетарный 340. Vulkan-устройства на этой карте просто нет, DXVK не инициализируется.

Единственный способ «запустить» DXVK — программный Vulkan (**lavapipe**, на CPU). Но у твоего
парня **i3-2120/2130 (Sandy Bridge, 2 ядра / 4 потока)** — софт-Vulkan на нём = слайд-шоу.

**Правильный путь для этой карты — WineD3D** (Direct3D → OpenGL), а OpenGL у nouveau
аппаратный. Для DX9/DX10-игр (а это ровно эпоха 9600 GT) WineD3D и быстрее, и стабильнее DXVK.

| Слой | На 9600 GT | Вердикт |
|---|---|---|
| **WineD3D** (D3D→OpenGL) | ✅ аппаратно на nouveau | **использовать это** |
| DXVK + аппаратный Vulkan | ❌ нет Vulkan-железа | невозможно |
| DXVK + lavapipe (CPU Vulkan) | ⚠️ на 2-ядерном Sandy Bridge — слайд-шоу | бессмысленно |
| VKD3D-Proton (D3D12) | ❌ | невозможно (и не для карты 2008 г.) |

Игровой скрипт: **`setup-gaming-9600gt.sh`** — ставит Wine, поднимает WineD3D-префикс,
явно отключает DXVK и включает fsync/esync для разгрузки слабого CPU.

```bash
chmod +x setup-gaming-9600gt.sh
./setup-gaming-9600gt.sh
# запуск игры:  wine9600 /path/to/game.exe
```

## Установка (одной командой)

```bash
chmod +x optimize-nouveau-cachyos.sh
./optimize-nouveau-cachyos.sh
sudo reboot
```

Скрипт:
1. ставит полный открытый стек Mesa/nouveau (+32-битный для Steam/Wine),
2. убирает проприетарный 340 и блэклист nouveau, если остались,
3. добавляет `nouveau config=NvBoost=2` (разрешить максимальный boost),
4. ставит **systemd-юнит `nouveau-reclock.service`**, который при каждом старте пинит
   максимальный pstate — это и есть весь прирост,
5. задаёт Wayland-дефолты (`GBM_BACKEND=nouveau`),
6. опционально ставит CLI `ventureoo/nouveau-reclocking`.

## Проверка после ребута (что прирост реально включился)

```bash
# 1. драйвер — nouveau, не nvidia:
lspci -k | grep -A3 -Ei 'vga|3d'

# 2. ГЛАВНОЕ: pstate запинен на максимум (звёздочка * на самом высоком уровне):
sudo cat /sys/kernel/debug/dri/*/pstate
#    пример хорошего вывода:
#    03: core 169 MHz ...
#    07: core 580 MHz memory 1000 MHz  *      <-- звезда на топовом => ок

# 3. рендерер:
glxinfo | grep -E "OpenGL renderer|OpenGL version"

# 4. на экране входа SDDM выбери сессию "Plasma (Wayland)"
```

Если звёздочка `*` стоит на низком уровне (00/01) — reclocking не применился: проверь
`systemctl status nouveau-reclock` и что debugfs смонтирован.

## Ручное управление частотами (по желанию)

```bash
# посмотреть доступные уровни:
sudo cat /sys/kernel/debug/dri/0/pstate
# выставить максимум вручную (NN — самый высокий номер из вывода выше):
echo 07 | sudo tee /sys/kernel/debug/dri/0/pstate
# тихий/холодный режим (минимум):
echo 03 | sudo tee /sys/kernel/debug/dri/0/pstate

# или через установленный CLI:
sudo nouveau-reclocking --list
sudo nouveau-reclocking --max --save     # запинить максимум навсегда
sudo nouveau-reclocking --min            # энергосбережение
```

## Wayland vs X11

Обе сессии работают на одном и том же nouveau. На очень старых GPU **X11 иногда стабильнее**.
Если Wayland-сессия глючит/падает — залогинься в **Plasma (X11)**, драйвер тот же,
reclocking-прирост сохраняется. Wayland здесь возможен именно потому, что nouveau умеет GBM
(чего у проприетарного 340 нет).

## Откат к проприетарному 340 (если передумаешь)

Если Wayland не нужен, а нужен максимум OpenGL (~+20% к nouveau) — ставь проприетарный путь
из соседнего `README.md` / `install-cachyos.sh`. Но тогда **только X11**.

| Хочешь | Ставь |
|---|---|
| Wayland + открытый драйвер + ~80% перфа | этот путь (nouveau + reclocking) |
| Максимум OpenGL, X11-only | `install-cachyos.sh` (nvidia-340xx-dkms) |

## Источники (research)

- nouveau.freedesktop.org — официально: reclocking для **Tesla G94-GT218** в `/sys/kernel/debug/dri/*/pstate`.
- **ventureoo/nouveau-reclocking** — утилита + бенчмарки (~10% → ~80% после reclocking), факт об
  отсутствии Wayland/GBM в драйверах ≤495 и отсутствии аппаратного Vulkan у Tesla.
- polhdez/nouveau-reclocking-guide, hibbes/nouveau-pstate-daemon — гайды по ручному pstate.
