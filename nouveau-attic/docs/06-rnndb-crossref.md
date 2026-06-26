# 06 — Сверка регистров reclocking с rnndb (envytools)

Требование промпта: не доверять адресам «по памяти», сверять с rnndb. Здесь —
сопоставление регистров из кода (docs/04) с `tools/envytools/rnndb/`.
G94 относится к g80-семейству ⇒ файлы `memory/g80_pfb.xml` (PFB, база 0x100000)
и `pm/g80_pclock.xml` (PCLOCK, база 0x004000).

Метки: `[rnndb✓]` — адрес и смысл подтверждены; `[только исходник]` — в rnndb
для G80 не описан, семантика лишь из кода nouveau/реверса (повышенный риск).

## PLL (pm/g80_pclock.xml, база 0x4000)

| MMIO | rnndb | Вариант | Исп. в коде |
|---|---|---|---|
| 0x004008 | `MPLL0_CTRL` | G80:MCP77 (вкл. G94) | `nv50_ram_calc` память [rnndb✓] |
| 0x00400c | `MPLL0_COEF` | G80:MCP77 | коэф. N/M память [rnndb✓] |
| 0x004020 | `SPLL_CTRL` | все | shader PLL [rnndb✓] |
| 0x004024 | `SPLL_COEF` | все | shader коэф. [rnndb✓] |
| 0x004028 | `NVPLL_CTRL` | все | core PLL [rnndb✓] |
| 0x00402c | `NVPLL_COEF` | все | core коэф. [rnndb✓] |
| 0x00c040 | мастер-мукс клоков | — | `read_pll`/`mast` [rnndb частично] |

Вывод: вся PLL-часть reclocking (и память, и ядро/шейдер) **подтверждена rnndb**,
включая покрытие именно G94 вариантом `G80:MCP77`.

## Контроллер памяти (memory/g80_pfb.xml, база 0x100000)

| MMIO | rnndb | Подтверждение в коде |
|---|---|---|
| 0x100200 | `CFG0` (бит2=RANKS) | `& 0x4 ? 2:1` ranks (ramnv50.c:575) [rnndb✓] |
| 0x100204 | `CFG1` (COLBITS[12:15], ROWBITSA[16:19], ROWBITSB[20:23], BANKBITS[24]) | `nv50_fb_vram_rblock` :517-520 [rnndb✓] |
| 0x10020c | `MEM_AMOUNT` | размер VRAM (ramnv50.c:548) [rnndb✓] |
| 0x100210 | `REFCTRL` (бит31=AUTO_REFRESH, PUT[0:7], GET[8:15]) | вкл `0x80000000`/выкл `0` :324,370 [rnndb✓] |
| 0x100220–0x100240 | `MEM_TIMINGS_0..8` (RC[0:7], RFC[8:15], …) | массив `timing[0..8]` :158,621 [rnndb✓] |
| 0x100244 | `MEM_TIMINGS_REFRESH` | — [rnndb✓] |
| 0x100248 | `MEM_TIMINGS_10` (вариант **G94:GF100**) | G94-специфичный тайминг [rnndb✓] |
| 0x100250 | `BANKCFG` | `rt` в rblock (:513) [rnndb✓] |
| 0x1002c0/c4/e0/e4 | `RAMCHIP_CFG` (массив 0x2c0, stride 0x30) | mode-регистры `mr[0..3]` :624-632 [rnndb✓] |

## ⚠ Регистры, НЕ описанные в rnndb для G80 — `[только исходник]`

Самые **опасные** в последовательности — триггеры команд DRAM:

| MMIO | Назначение (из кода) | Где |
|---|---|---|
| 0x1002d0 | refresh (однократный) | ramnv50.c:322-323 |
| 0x1002d4 | precharge / disable self-refresh | ramnv50.c:321,369 |
| 0x1002dc | **enter/exit self-refresh** | ramnv50.c:325,368 |
| 0x10053c | (некий разрешающий бит при rammap) | ramnv50.c:449-451 |
| 0x1005a0/a4 | запись ramcfg-полей | ramnv50.c:444-447 |
| 0x100710/714/718/71c | chip-specific тюнинг (часть G94) | ramnv50.c:404-439 |
| 0x100da0 | (GDDR3, chipset≥0x92) | ramnv50.c:360 |
| 0x611200 | display/FB gate (`0x3300`/`0x3330`) | ramnv50.c:311,464 |

Для NV-старых аналоги были описаны (`nv_pfb.xml`: PRECHARGE@0x14, SELF_REFRESH@0x1c),
но для G80 эти триггеры в rnndb **отсутствуют** — их смысл известен только из драйвера
и mmiotrace. Это ключевой довод осторожности: именно на self-refresh/MPLL-участке
(0x1002dc → 0x004008) и происходят зависания, а первоисточника-спеки на эти биты нет.

## Итог

- PLL и тайминги reclocking — **полностью подтверждены rnndb** (риск адресной ошибки низкий).
- Триггеры self-refresh/precharge/refresh — **только из исходника**; перед боевым тестом
  стоит снять mmiotrace проприетарного драйвера для верификации последовательности
  (методология — раздел «Реверс-инжиниринг» исходного промпта).
