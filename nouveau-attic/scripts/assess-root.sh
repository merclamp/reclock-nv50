#!/usr/bin/env bash
# Чтение reclocking-состояния (нужен root: debugfs + dmesg).
# Запуск:  sudo ./assess-root.sh    (или через `! sudo bash scripts/assess-root.sh`)
# ТОЛЬКО ЧТЕНИЕ. Ничего не пишет в pstate/MMIO.
set -u
DRI=/sys/kernel/debug/dri
echo "===== pstate ====="
find "$DRI" -name pstate 2>/dev/null | while read -r f; do echo "--- $f ---"; cat "$f"; done
echo "===== прочие clk/volt/therm узлы ====="
for n in clk volt therm; do
  find "$DRI" -name "$n" 2>/dev/null | while read -r f; do echo "--- $f ---"; cat "$f"; done
done
echo "===== dmesg: nouveau reclocking/volt/pmu/therm ====="
dmesg | grep -iE "nouveau|nvkm" | grep -iE "clk|pmu|therm|volt|fan|pstate|cstep|boost|fail|error|timeout|fb|ram"
