#!/usr/bin/env bash
# установить-всё.sh — ставит и собирает ВСЁ одной командой (путь nouveau).
#
# Один запуск, без вопросов:
#   1. Тюнинг системы ........... userspace/optimize-system-cachyos.sh
#   2. nouveau + Mesa + Wayland . userspace/optimize-nouveau-cachyos.sh
#                                 (+ сервис, пинящий максимальный pstate на буст)
#   3. Патченый nouveau.ko ...... scripts/build-nouveau.sh   (только СБОРКА)
#   4. Игры (Wine/WineD3D) ...... userspace/setup-gaming-9600gt.sh
#   5. yserver .................. userspace/build-yserver.sh  (СБОРКА + установка)
#   6. Живой reclock GPU ........ userspace/reclock-full.sh   (пишет частоты 0f)
#
# Без вопросов: все подвопросы скриптов авто-отвечаются безопасным дефолтом.
# Пароль sudo спрашивается ОДИН раз в начале и держится «тёплым».
#
# Живой reclock (шаг 6) пишет частоты в железо. Из TTY он делает это сам; из
# графики — пропускается (nouveau нельзя выгрузить под GUI) с инструкцией.
# Управление (переменные окружения, по-английски — bash требует латиницу):
#   LIVE_RECLOCK=0  — пропустить запись в железо
#   LIVE_RECLOCK=1  — форсировать даже в GUI (выгрузка nouveau, скорее всего, упадёт)
#   NV_KSRC=/путь   — где искать исходники ядра для сборки модуля
#
# Пути драйверов взаимоисключающи: это путь nouveau/Wayland/yserver. Скрипт
# откажется работать, если установлен проприетарный nvidia-340xx.
#
# Запуск:
#   ./установить-всё.sh
#   NV_KSRC=/путь/к/исходникам/ядра ./установить-всё.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$REPO/userspace"

err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[~]\033[0m %s\n' "$*"; }
hr()   { printf '\n\033[1;36m========== %s ==========\033[0m\n' "$*"; }

# --- предполётные проверки ---------------------------------------------------
[[ $EUID -eq 0 ]] && { err "Запускай обычным пользователем, не root (sudo вызывается сам где нужно)."; exit 1; }
command -v pacman >/dev/null || { err "Это не Arch-система (нет pacman)."; exit 1; }
[[ -d "$PACK" ]] || { err "Рядом нет каталога userspace/ — запускай из чекаута репозитория."; exit 1; }

# Это путь nouveau. Проприетарный 340 — только Xorg, без Wayland и yserver, и он
# взаимоисключающ. Лучше отказаться, чем поставить наполовину.
if pacman -Qq nvidia-340xx nvidia-340xx-dkms nvidia-340xx-utils 2>/dev/null | grep -q .; then
  err "Установлен проприетарный nvidia-340xx — он несовместим с путём nouveau."
  err "Сначала удали его (он блокирует nouveau, Wayland и yserver), потом повтори:"
  err '    sudo pacman -Rns $(pacman -Qq nvidia-340xx nvidia-340xx-dkms nvidia-340xx-utils)'
  exit 1
fi

# --- один запрос пароля, дальше держим sudo «тёплым» весь прогон --------------
info "Кэширую пароль sudo (спрошу один раз)..."
sudo -v || { err "Аутентификация sudo не прошла."; exit 1; }
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT

# --- делаем все подскрипты неинтерактивными (берут безопасный дефолт) ---------
export ASSUME_YES=1
export TM_ASSUME_YES=1   # guard target-machine.sh, если какой-то скрипт его подключает

# --- включаем [multilib] (нужен для 32-битных Wine/Mesa) ---------------------
if ! pacman -Sl multilib >/dev/null 2>&1; then
  warn "[multilib] выключен — включаю (нужен для 32-битных Wine/Mesa)."
  sudo cp -a /etc/pacman.conf "/etc/pacman.conf.bak-$(date +%Y%m%d-%H%M%S)"
  sudo sed -i '/^[[:space:]]*#[[:space:]]*\[multilib\]/{s/^[[:space:]]*#[[:space:]]*//; n; s/^[[:space:]]*#[[:space:]]*Include/Include/}' /etc/pacman.conf
  sudo pacman -Sy --noconfirm || warn "pacman -Sy после включения multilib сообщил о проблемах."
else
  info "[multilib] уже включён."
fi

# --- запуск шага: одна ошибка не валит весь прогон ---------------------------
RUN_FAILED=()
run_step() {  # $1 название  $2 скрипт  [аргументы...]
  local label="$1"; shift
  local script="$1"; shift
  hr "$label"
  if [[ ! -f "$script" ]]; then warn "нет файла: $script — пропускаю."; RUN_FAILED+=("$label (нет файла)"); return 0; fi
  if bash "$script" "$@"; then
    info "$label — готово."
  else
    local rc=$?
    err "$label — ОШИБКА (код $rc). Продолжаю; повтори вручную:"
    err "    ASSUME_YES=1 bash $script $*"
    RUN_FAILED+=("$label")
  fi
}

# 1) тюнинг всей системы (zram, sysctl, governor, io-sched, журнал, KDE-трим)
run_step "Тюнинг системы"                     "$PACK/optimize-system-cachyos.sh"

# 2) открытый стек nouveau/Mesa + сервис пина pstate на буст + Wayland
run_step "nouveau + Mesa + сервис reclock"    "$PACK/optimize-nouveau-cachyos.sh"

# 3) СБОРКА патченого nouveau.ko — только сборка, в железо не пишем (по наличию)
MODULE_BUILT=0
hr "Сборка патченого nouveau.ko"
if [[ -n "${NV_KSRC:-}" ]] || compgen -G "$REPO/src/linux*" >/dev/null 2>&1 || [[ -d "$REPO/src/nouveau" ]]; then
  if bash "$REPO/scripts/build-nouveau.sh" ${NV_KSRC:+"$NV_KSRC"}; then
    info "Патченый модуль собран. Загрузка его вживую — это шаг reclock ниже."
    MODULE_BUILT=1
  else
    warn "Сборка модуля упала — поправь исходники ядра (docs/05 §A), затем: bash scripts/build-nouveau.sh"
    RUN_FAILED+=("Сборка патченого nouveau.ko")
  fi
else
  warn "Нет исходников ядра (src/linux*, src/nouveau или NV_KSRC) — пропускаю сборку модуля."
  warn "Собрать позже: NV_KSRC=/путь/к/исходникам bash scripts/build-nouveau.sh"
fi

# 4) игры Wine/WineD3D (OpenGL; DXVK выключен — у Tesla нет аппаратного Vulkan)
run_step "Игры (Wine/WineD3D)"                "$PACK/setup-gaming-9600gt.sh"

# 5) yserver — собирается и ставится из исходников (это и есть «уже скомпилировано»)
run_step "yserver (сборка + установка)"       "$PACK/build-yserver.sh"

# 6) живой reclock памяти GPU — пишет реальные частоты (pstate 0f).
#    Разрешён работать без вопросов. Физика всё равно действует: для записи nouveau
#    надо выгрузить, а под GUI это невозможно -> нужен TTY.
#    LIVE_RECLOCK=auto (дефолт): из TTY делает reclock, из GUI — пропуск с инструкцией.
#    LIVE_RECLOCK=1 — форсировать даже в GUI (выгрузка nouveau, скорее всего, упадёт). =0 — пропуск.
LIVE_RECLOCK="${LIVE_RECLOCK:-auto}"
gui_up() { [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-tty}" == "x11" || "${XDG_SESSION_TYPE:-tty}" == "wayland" ]]; }
hr "Живой reclock памяти (pstate 0f)"
if [[ "$LIVE_RECLOCK" == 0 ]]; then
  info "LIVE_RECLOCK=0 — пропускаю запись в железо по запросу."
elif [[ "$MODULE_BUILT" != 1 ]]; then
  warn "Патченый модуль не собран — reclock невозможен. Дай исходники ядра и повтори."
  RUN_FAILED+=("Живой reclock (нет модуля)")
elif gui_up && [[ "$LIVE_RECLOCK" != 1 ]]; then
  warn "Обнаружена графсессия. Для reclock надо выгрузить nouveau — из GUI это невозможно."
  warn "Перейди в свободный TTY (Ctrl+Alt+F3), приготовь recovery (SSH/SysRq), затем запусти ОДНО из:"
  warn "    LIVE_RECLOCK=1 ./установить-всё.sh           # перезапуск; reclock из TTY"
  warn "    RECLOCK_LIVE=1 userspace/reclock-full.sh     # только пайплайн reclock"
  RUN_FAILED+=("Живой reclock (запусти из TTY)")
else
  gui_up && warn "LIVE_RECLOCK=1 форсирован в GUI — выгрузка nouveau, скорее всего, упадёт; твой выбор."
  warn "Пишу реальные частоты памяти GPU (только в RAM; обычный reboot откатит)."
  if RECLOCK_LIVE=1 bash "$PACK/reclock-full.sh"; then
    info "Пайплайн reclock завершён — проверь pstate/dmesg в его выводе выше."
  else
    err "Пайплайн reclock упал (см. вывод). При ошибке скрипт возвращает сток-nouveau."
    RUN_FAILED+=("Живой reclock")
  fi
fi

# --- итог --------------------------------------------------------------------
hr "ГОТОВО"
if ((${#RUN_FAILED[@]})); then
  warn "Некоторым шагам нужно внимание:"
  for f in "${RUN_FAILED[@]}"; do warn "  - $f"; done
else
  info "Все шаги выполнены."
fi

cat <<EOF

Поставлено/собрано за один проход (путь nouveau):
  * тюнинг системы (zram + sysctl + governor performance + io-sched + лимит журнала)
  * открытый стек Mesa/nouveau (+32-бит) + Wayland + nouveau-reclock.service (пин pstate на буст)
  * патченый nouveau.ko собран (если рядом были исходники ядра)
  * Wine/WineD3D + лаунчер 'wine9600' (DXVK выключен — у Tesla нет аппаратного Vulkan)
  * yserver собран и установлен -> $(command -v yserver 2>/dev/null || echo '/usr/local/bin/yserver')

ПЕРЕЗАГРУЗИСЬ, чтобы применить параметры ядра / сервис pstate / zram:
    sudo reboot

Живой reclock памяти: выполнен этим запуском (LIVE_RECLOCK=$LIVE_RECLOCK).
  * Из TTY пишет pstate 0f вживую (в RAM; reboot откатывает).
  * Из GUI пропускается — перезапусти из TTY:  LIVE_RECLOCK=1 ./установить-всё.sh
Чтобы патченый модуль + reclock пережили перезагрузку, поставь модуль через
DKMS/initramfs сам (осознанный шаг; см. docs/05 и README).

Попробовать yserver позже из свободного TTY (Ctrl+Alt+F3):
    cd "\${YSERVER_SRC:-\$HOME/.local/src/yserver}" && just startx
EOF
