#!/usr/bin/env bash
#
#  oc-rotate — OpenCode + rotacja IP. Jeden plik, zależności: curl, timeout, shuf.
#
#  Komendy:
#    oc-rotate install           instalacja (config, symlinki, weryfikacja)
#    oc-rotate doctor            diagnoza: co brakuje i jak to zainstalować
#    oc-rotate locate            znajdź binarkę opencode i pokaż ścieżkę
#    oc-rotate run <prompt|plik> zadanie z auto-rotacją przy 429
#    oc-rotate hop               jedna rotacja IP (dla pracy w TUI)
#    oc-rotate status            stan: IP, backend, modele, zależności
#    oc-rotate models            lista dostępnych modeli
#    oc-rotate uninstall         usuwa binarki i config
#
#  Wywołanie jako `oc-hop` = skrót do `hop` (multi-call).
#
#  Wymagania: bash 4.4+, curl, timeout, shuf. VPN: mullvad-cli | protonvpn | wg-quick
#
#  v1.3.0 — lista poprawek względem 1.2.0 jest na dole pliku (sekcja CHANGELOG).
set -uo pipefail

VERSION="1.3.0"

# ─────────────────────────── ŚCIEŻKI ────────────────────────────────

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/oc-rotate"
CONF_FILE="$CONF_DIR/config.sh"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

# [FIX-7] pliki robocze w katalogu per-użytkownik (0700), nie w gołym /tmp.
# Stare /tmp/oc-rotate.out na współdzielonej maszynie = EACCES albo (gorzej)
# czytanie CUDZEGO outputu przez is_rate_limited.
RUN_DIR="${RUN_DIR:-$CONF_DIR/run}"

# ─────────────────────────── DOMYŚLNE ───────────────────────────────

OC_BIN="${OC_BIN:-opencode}"
VPN_BACKEND="${VPN_BACKEND:-mullvad}"
WG_DIR="${WG_DIR:-$CONF_DIR/wg}"
WG_IF="${WG_IF:-wg0}"
MODELS=(
  "opencode/deepseek-v4-flash-free"
  "opencode/mimo-v2.5-free"
  "opencode/hy3-free"
)
AUTO_MODELS="${AUTO_MODELS:-1}"     # 1 = wykryj darmowe modele przez `opencode models`
MAX_MODELS="${MAX_MODELS:-5}"       # ile modeli trzymać w puli
MAX_ROTATIONS="${MAX_ROTATIONS:-25}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-300}"
SETTLE="${SETTLE:-12}"
CMD_TIMEOUT="${CMD_TIMEOUT:-900}"
KILL_GRACE="${KILL_GRACE:-10}"      # [FIX-5] SIGKILL po tylu sekundach od SIGTERM
OUT_FILE="${OUT_FILE:-$RUN_DIR/oc-rotate.out}"
LOG_FILE="${LOG_FILE:-$RUN_DIR/oc-rotate.log}"
RESUME_FLAG="${RESUME_FLAG:-}"
OC_EXTRA_ARGS="${OC_EXTRA_ARGS:-}"

# [FIX-5] ile razy pod rząd wolno paść z błędu innego niż limit / timeout
MAX_OTHER_FAILS="${MAX_OTHER_FAILS:-3}"
MAX_TIMEOUTS="${MAX_TIMEOUTS:-3}"
BACKOFF_BASE="${BACKOFF_BASE:-5}"   # 5s, 10s, 20s...
BACKOFF_MAX="${BACKOFF_MAX:-120}"
MODELS_TIMEOUT="${MODELS_TIMEOUT:-45}"   # [FIX-11] `opencode models` nie może wisieć
VPN_WAIT="${VPN_WAIT:-40}"               # [FIX-8] ile czekać na tunel po reconnect
RELAY_COOLDOWN="${RELAY_COOLDOWN:-8}"    # [FIX-8] ile ostatnich relayów omijać
OC_DISABLE_ROTATION="${OC_DISABLE_ROTATION:-0}"  # [FIX-15] 1 = jeden strzał, bez VPN

# [FIX-3] wzorzec limitu. Gołe `429` z 1.2.0 łapało każdy numer portu, linii
# czy fragment kodu w odpowiedzi modelu — przy rc=0 skrypt i tak wchodził w
# pętlę rotacji IP i nigdy nie meldował sukcesu.
# Celowo NIE ma tu samotnego `429`: musi mu towarzyszyć kontekst HTTP.
_RL_429='(status|code|HTTP|error)[^0-9A-Za-z]{0,12}429|429[^0-9]{0,3}(Too Many Requests|Rate)'
RATE_LIMIT_RE="${RATE_LIMIT_RE:-FreeUsageLimitError|Free usage (limit )?exceeded|[Rr]ate[ _-]?limit(ed)?|Too Many Requests|quota exceeded|${_RL_429}}"
unset _RL_429

# config użytkownika nadpisuje domyślne
# shellcheck disable=SC1090
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

# [FIX-7] katalog roboczy musi istnieć i być zapisywalny — inaczej reszta
# działa po omacku (patrz FIX-3: pusty OUT_FILE == "brak limitu" == "sukces").
mkdir -p "$RUN_DIR" 2>/dev/null && chmod 700 "$RUN_DIR" 2>/dev/null
_OUT_WRITABLE=1
{ : >>"$OUT_FILE"; } 2>/dev/null || _OUT_WRITABLE=0
if (( ! _OUT_WRITABLE )); then
  printf 'oc-rotate: nie mogę pisać do OUT_FILE=%s\n' "$OUT_FILE" >&2
  printf '           ustaw OUT_FILE/LOG_FILE/RUN_DIR na zapisywalną ścieżkę\n' >&2
  exit 1
fi

# ──────────────────── WYKRYWANIE BINARKI (wczesne) ──────────────────

# [FIX-12] szybka ścieżka: PATH + znane lokalizacje. Bez `find ~`.
resolve_oc_bin() {
  command -v "$OC_BIN" >/dev/null 2>&1 && return 0
  [[ -x "$OC_BIN" ]] && return 0
  local c
  for c in \
    "$HOME/.config/.opencode/bin/opencode" \
    "$HOME/.opencode/bin/opencode" \
    "$HOME/.config/.opencode/bin/opencode2" \
    "$HOME/.local/bin/opencode" \
    "$HOME/bin/opencode" \
    "$HOME/.bun/bin/opencode" \
    "$HOME/.npm-global/bin/opencode" \
    "$HOME/.local/share/pnpm/opencode" \
    "$HOME/.volta/bin/opencode" \
    "$HOME/.deno/bin/opencode" \
    "/usr/local/bin/opencode" \
    "/usr/bin/opencode" \
    "/snap/bin/opencode" \
    "/home/linuxbrew/.linuxbrew/bin/opencode"; do
    [[ -x "$c" ]] && { OC_BIN="$c"; return 0; }
  done
  for c in "$HOME"/.nvm/versions/node/*/bin/opencode \
           "$HOME"/.local/share/fnm/node-versions/*/installation/bin/opencode; do
    [[ -x "$c" ]] && { OC_BIN="$c"; return 0; }
  done
  return 1
}

# [FIX-12] wolna ścieżka (find po $HOME) — tylko na wyraźne żądanie (`locate`).
# W 1.2.0 leciała przy KAŻDYM wywołaniu, także `oc-rotate --help`, bez limitu
# czasu i bez prunowania node_modules/.cache — potrafiła zamulić na minutach.
resolve_oc_bin_deep() {
  resolve_oc_bin && return 0
  local c
  c="$(timeout 20 find "$HOME" \
        \( -name node_modules -o -name .git -o -name .cache -o -name .npm \
           -o -name .rustup -o -name .gradle -o -name .m2 \) -prune -o \
        -type f -name opencode -perm -u+x -print 2>/dev/null | head -1)"
  [[ -n "$c" ]] && { OC_BIN="$c"; return 0; }
  return 1
}
resolve_oc_bin

# pula modeli: jeśli użytkownik nie podał OC_MODELS, wykryj darmowe z CLI
_MODELS_CACHE=""
autodetect_models() {
  [[ "$AUTO_MODELS" == "1" ]] || return 0
  [[ -n "${OC_MODELS:-}" ]] && return 0
  opencode_ok || return 0
  [[ -n "$_MODELS_CACHE" ]] && return 0     # [FIX-11] raz na proces, nie 3x

  local detected=() out=() d m seen
  mapfile -t detected < <(
    timeout "$MODELS_TIMEOUT" "$OC_BIN" models 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | awk '{print $1}' \
      | grep -E '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
      | grep -iE '(^|/)free|(^|-)free($|-)|free-' | sort -u
  )
  _MODELS_CACHE=1
  (( ${#detected[@]} )) || return 0

  for m in ${MODELS+"${MODELS[@]}"}; do
    for d in "${detected[@]}"; do [[ "$d" == "$m" ]] && out+=("$d"); done
  done
  for d in "${detected[@]}"; do
    seen=0
    for m in ${out+"${out[@]}"}; do [[ "$d" == "$m" ]] && seen=1; done
    (( seen == 0 )) && out+=("$d")
  done

  # [FIX-14] MAX_MODELS=0 dawałoby pustą pulę -> crash z `set -u`
  (( MAX_MODELS >= 1 )) || MAX_MODELS=1
  MODELS=("${out[@]:0:MAX_MODELS}")
}

# OC_MODELS z env ma najwyższy priorytet
if [[ -n "${OC_MODELS:-}" ]]; then
  read -r -a MODELS <<< "$OC_MODELS"
  # [FIX-2] `OC_MODELS=" "` w 1.2.0 czyścił pulę -> "unbound variable"
  (( ${#MODELS[@]} )) || MODELS=()
fi

# ─────────────────────────── LOG / UI ───────────────────────────────

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[[ -t 2 ]] || { C_R=; C_G=; C_Y=; C_B=; C_D=; C_0=; }

# [FIX-6] jeden otwarty FD zamiast `tee -a` per linia logu.
# W 1.2.0 każdy log() forkował tee; gdy LOG_FILE był niezapisywalny,
# błędy tee lądowały na stdout i mieszały się z odpowiedzią modelu.
#
# UWAGA (pułapka basha): `exec {FD}>>plik 2>/dev/null` gasi stderr na stałe —
# przekierowania w exec są stosowane lewo-prawo i przy alokacji {FD} potrafi
# trafić w fd 2. Dlatego exec jest w grupie `{ }`, a 2>/dev/null NA ZEWNĄTRZ.
LOG_FD=""
open_log() {
  [[ -n "$LOG_FD" ]] && return 0
  { exec {LOG_FD}>>"$LOG_FILE"; } 2>/dev/null || LOG_FD=""
  [[ -n "$LOG_FD" ]] || LOG_FD="nowrite"
  return 0
}

log() {
  local line; line="$(printf '%s  %s' "$(date '+%H:%M:%S')" "$*")"
  printf '%s\n' "$line" >&2
  if [[ -n "$LOG_FD" && "$LOG_FD" != "nowrite" ]]; then
    printf '%s\n' "$line" >&"$LOG_FD" || true
  fi
}
ok()   { log "${C_G}OK${C_0}   $*"; }
warn() { log "${C_Y}WARN${C_0} $*"; }
err()  { log "${C_R}ERR${C_0}  $*"; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s\n' "${C_D}────────────────────────────────────────${C_0}" >&2; }

# ─────────────────────────── ZALEŻNOŚCI ────────────────────────────

have() { command -v "$1" >/dev/null 2>&1; }

opencode_ok() { have "$OC_BIN" || [[ -x "$OC_BIN" ]]; }

oc_version() { timeout 10 "$OC_BIN" --version 2>/dev/null | head -1; }

proton_bin() {
  have protonvpn && { echo protonvpn; return; }
  have protonvpn-cli && { echo protonvpn-cli; return; }
  return 1
}

deps_check() {
  local c missing=()                       # [FIX-13] `c` było globalne
  for c in curl timeout shuf; do have "$c" || missing+=("$c"); done
  opencode_ok || missing+=("opencode")
  ((${#missing[@]})) && warn "brakujące: ${missing[*]}"
  return 0
}

vpn_detect() {
  case "$VPN_BACKEND" in
    mullvad) have mullvad && echo "mullvad (zainstalowany)" || echo "mullvad (BRAK)" ;;
    proton)  proton_bin >/dev/null 2>&1 && echo "proton (zainstalowany)" || echo "proton (BRAK)" ;;
    wg)      have wg-quick && echo "wireguard (zainstalowany)" || echo "wireguard (BRAK)" ;;
    none)    echo "none (bez VPN)" ;;
    *)       echo "nieznany backend: $VPN_BACKEND" ;;
  esac
}

# ─────────────────────────── SIEĆ ───────────────────────────────────

get_ip() { curl -4 -s --max-time 10 https://api.ipify.org 2>/dev/null || true; }

# ─────────────────────────── ROTACJA ────────────────────────────────

# [FIX-8] pamięć ostatnich relayów — `shuf -n1` potrafił wylosować ten sam
# serwer dwa razy z rzędu, czyli "rotacja" bez rotacji.
RELAY_SEEN_FILE="$RUN_DIR/relays-used"
: >"$RELAY_SEEN_FILE" 2>/dev/null || true

mullvad_relays() {
  timeout 25 mullvad relay list 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -oE '\b[a-z]{2}-[a-z0-9]{2,4}-wg-[0-9]{2,4}\b' \
    | sort -u
}

pick_relay() {
  local all=() fresh=() r used
  mapfile -t all < <(mullvad_relays)
  (( ${#all[@]} )) || return 1
  mapfile -t used < <(tail -n "$RELAY_COOLDOWN" "$RELAY_SEEN_FILE" 2>/dev/null)
  for r in "${all[@]}"; do
    local skip=0 u
    for u in ${used+"${used[@]}"}; do [[ "$r" == "$u" ]] && skip=1; done
    (( skip )) || fresh+=("$r")
  done
  (( ${#fresh[@]} )) || fresh=("${all[@]}")
  printf '%s\n' "${fresh[@]}" | shuf -n1
}

# [FIX-8] `mullvad reconnect` wraca od razu, tunel dopiero się spina.
# W 1.2.0 po 4s sprawdzaliśmy IP — często jeszcze stare — więc pętla
# "IP bez zmian (próba 1/5)" robiła kolejne reconnecty na ślepo.
mullvad_wait_connected() {
  local i st
  for ((i = 0; i < VPN_WAIT / 2; i++)); do
    st="$(timeout 10 mullvad status 2>/dev/null | head -1)"
    case "$st" in
      *Connected*) return 0 ;;
      *Error*|*Blocked*) err "mullvad: $st"; return 1 ;;
    esac
    sleep 2
  done
  warn "mullvad: brak 'Connected' po ${VPN_WAIT}s"
  return 1
}

rotate_mullvad() {
  local host out rc
  host="$(pick_relay)" || {
    err "mullvad: brak relayów (zaloguj się: mullvad account login)"
    return 1
  }
  log "mullvad -> ${C_B}$host${C_0}"
  printf '%s\n' "$host" >>"$RELAY_SEEN_FILE" 2>/dev/null || true

  # [FIX-8] `relay set hostname` to stara składnia; w 2026.x jest
  # `relay set location <host>`. Próbujemy obie i NIE połykamy stderr,
  # bo tam jest prawdziwy powód ("Failure to select a matching tunnel relay").
  out="$(timeout 25 mullvad relay set location "$host" 2>&1)"; rc=$?
  if (( rc != 0 )); then
    out="$(timeout 25 mullvad relay set hostname "$host" 2>&1)"; rc=$?
  fi
  if (( rc != 0 )); then
    err "mullvad relay set: ${out:-rc=$rc}"
    return 1
  fi

  if ! out="$(timeout 60 mullvad reconnect 2>&1)"; then
    err "mullvad reconnect: ${out:-nieznany błąd}"
    return 1
  fi
  mullvad_wait_connected || return 1
}

rotate_proton() {
  local bin rc
  bin="$(proton_bin)" || { err "proton: brak CLI"; return 1; }
  log "proton -> losowy serwer"
  # [FIX-9] 1.2.0 gubił kod wyjścia: `if/else` zwracał status ostatniego
  # `>/dev/null 2>&1`, więc cichy błąd connect wyglądał jak sukces.
  if [[ "$bin" == "protonvpn" ]]; then
    timeout 90 "$bin" connect --random >/dev/null 2>&1; rc=$?
  else
    timeout 90 "$bin" connect -r >/dev/null 2>&1; rc=$?
  fi
  (( rc == 0 )) || { err "proton connect: rc=$rc"; return 1; }
}

rotate_wg() {
  local cfg
  cfg="$(find "$WG_DIR" -name '*.conf' 2>/dev/null | shuf -n1)"
  [[ -z "$cfg" ]] && { err "wireguard: brak .conf w $WG_DIR"; return 1; }
  log "wireguard -> ${C_B}$(basename "$cfg")${C_0}"
  sudo wg-quick down "$WG_IF" 2>/dev/null || true
  sudo install -m 600 "$cfg" "/etc/wireguard/${WG_IF}.conf" || { err "install conf"; return 1; }
  sudo wg-quick up "$WG_IF" >/dev/null 2>&1 || { err "wg-quick up"; return 1; }
}

rotate_vpn() {
  case "$VPN_BACKEND" in
    mullvad) rotate_mullvad ;;
    proton)  rotate_proton ;;
    wg)      rotate_wg ;;
    none)    return 0 ;;
    *)       err "nieznany VPN_BACKEND=$VPN_BACKEND"; return 1 ;;
  esac
}

rotate_and_verify() {
  if [[ "$VPN_BACKEND" == "none" ]]; then
    warn "backend=none — brak rotacji IP"
    return 0
  fi

  local before after i
  before="$(get_ip)"
  if [[ -z "$before" ]]; then
    # [FIX-10] bez "przed" nie da się potwierdzić zmiany — 1.2.0 i tak
    # meldowało "rotacja potwierdzona", bo "" != "cokolwiek".
    warn "brak odpowiedzi z api.ipify.org — nie zweryfikuję rotacji"
  else
    log "IP przed: $before"
  fi

  for i in 1 2 3 4 5; do
    rotate_vpn || return 1
    after="$(get_ip)"
    if [[ -n "$after" && ( -z "$before" || "$after" != "$before" ) ]]; then
      ok "IP po:   ${C_G}$after${C_0} (rotacja potwierdzona)"
      return 0
    fi
    warn "IP bez zmian (próba $i/5)"
    sleep 4
  done

  err "nie udało się zmienić IP"
  return 1
}

# ─────────────────────────── WYKRYWANIE LIMITU ──────────────────────

is_rate_limited() {
  # [FIX-3] plik musi istnieć i być niepusty: pusty == "brak limitu",
  # a w 1.2.0 pusty bywał też wtedy, gdy tee nie mógł pisać.
  [[ -s "$OUT_FILE" ]] || return 1
  grep -qiE "$RATE_LIMIT_RE" "$OUT_FILE" 2>/dev/null
}

# ─────────────────────────── RUN ────────────────────────────────────

run_once() {
  local prompt="$1" model="$2"
  : >"$OUT_FILE" 2>/dev/null

  # [FIX-6] argumenty w tablicy zamiast word-splittingu $OC_EXTRA_ARGS.
  local -a args=(run) extra=()
  if [[ -n "$RESUME_FLAG" ]]; then
    read -r -a extra <<<"$RESUME_FLAG"; args+=("${extra[@]}")
  fi
  args+=(--model "$model")
  if [[ -n "$OC_EXTRA_ARGS" ]]; then
    extra=(); read -r -a extra <<<"$OC_EXTRA_ARGS"; args+=("${extra[@]}")
  fi
  # [FIX-4] `--` oddziela flagi od promptu. Bez tego prompt zaczynający się
  # od "-" (np. "--verbose build fix") był zjadany jako flaga opencode.
  args+=(-- "$prompt")

  # [FIX-5] --foreground + -k: sygnał idzie do całej grupy procesów, więc
  # sieroty (serwery MCP/LSP odpalone przez opencode) nie zostają po timeoutie.
  timeout --foreground -k "$KILL_GRACE" "$CMD_TIMEOUT" "$OC_BIN" "${args[@]}" \
    2>&1 | tee "$OUT_FILE"
  LAST_RC="${PIPESTATUS[0]}"

  if (( LAST_RC == 0 )); then
    if is_rate_limited; then
      # [FIX-3] rc=0 + tekst o limicie = albo limit złapany po drodze, albo
      # fałszywy alarm (np. agent sam napisał "serwer zwrócił 429").
      # 1.2.0 traktował to jako twardy limit i rotował IP bez końca.
      warn "rc=0, ale output pasuje do wzorca limitu — uznaję za sukces"
      warn "jeśli to fałszywy alarm, zawęź RATE_LIMIT_RE w $CONF_FILE"
    fi
    return 0
  fi
  return 1
}

print_models_or_die() {
  # [FIX-2] pusta pula = natychmiastowy, czytelny błąd zamiast
  # "MODELS[$mi]: unbound variable" z wnętrza pętli.
  (( ${#MODELS[@]} > 0 )) && return 0
  err "pula modeli jest pusta"
  log "  ustaw w $CONF_FILE:  MODELS=(\"provider/model\")"
  log "  albo podaj jednorazowo: OC_MODELS=\"provider/model\" oc-rotate run ..."
  log "  dostępne: oc-rotate models --free"
  return 1
}

cmd_run() {
  local prompt="${1:-}"
  open_log

  if [[ -z "$prompt" ]]; then
    if [[ -n "${2:-}" && -f "${2:-}" ]]; then
      prompt="$(cat "$2")"
    elif [[ ! -t 0 ]]; then
      prompt="$(cat)"
    else
      die "użycie: oc-rotate run \"prompt\" | oc-rotate run ./plik.txt | ... | oc-rotate run"
    fi
  elif [[ -f "$prompt" ]]; then
    prompt="$(cat "$prompt")"
  fi

  [[ -n "$prompt" ]] || die "pusty prompt"
  opencode_ok || die "brak binarki opencode — uruchom: oc-rotate locate"
  autodetect_models
  print_models_or_die || return 1

  open_log
  # [FIX-6] 1.2.0 robił `: > "$LOG_FILE"` — kasował całą historię przy każdym run.
  log "=== run v$VERSION $(date '+%F %T') ==="
  hr
  log "start v$VERSION | backend=$(vpn_detect) | modeli=${#MODELS[@]} | max rotacji=$MAX_ROTATIONS"
  hr

  local attempt=0 rotations=0 mi=0 model other_fails=0 timeouts=0 wait_s rc

  # [FIX-1] było `rotations <= MAX_ROTATIONS`, więc MAX_ROTATIONS=1 robił DWA
  # obroty VPN (rotacje=2 w logu). Teraz dokładnie tyle, ile zamówiono.
  while (( attempt < MAX_ATTEMPTS && rotations < MAX_ROTATIONS )); do
    model="${MODELS[$mi]}"
    log "próba $(( attempt + 1 )) | model=${C_B}${model}${C_0} | rotacje=$rotations/$MAX_ROTATIONS"

    if run_once "$prompt" "$model"; then
      hr; ok "SUKCES na $model (próby=$(( attempt + 1 )), rotacje=$rotations)"; hr
      return 0
    fi
    rc="$LAST_RC"

    if is_rate_limited; then
      other_fails=0; timeouts=0
      if (( mi + 1 < ${#MODELS[@]} )); then
        mi=$(( mi + 1 ))
        log "limit na '$model' -> następny model (bez ruszania VPN)"
      else
        mi=0
        if [[ "$OC_DISABLE_ROTATION" == "1" ]]; then
          hr; warn "wszystkie modele w limicie, OC_DISABLE_ROTATION=1 -> kończę"; hr
          return 1
        fi
        warn "wszystkie modele w limicie -> rotacja IP"
        if rotate_and_verify; then
          rotations=$(( rotations + 1 ))
          log "czekam ${SETTLE}s na wygaśnięcie limitu"
          sleep "$SETTLE"
        else
          warn "rotacja nieudana, pauza 20s"
          sleep 20
        fi
      fi

    elif (( rc == 124 || rc == 137 )); then
      # [FIX-5] timeout w 1.2.0 wpadał do worka "inny błąd" i był retry'owany
      # w nieskończoność (300 x 900s = 75h) bez zmiany modelu i bez backoffu.
      timeouts=$(( timeouts + 1 ))
      err "timeout po ${CMD_TIMEOUT}s (rc=$rc) — próba $timeouts/$MAX_TIMEOUTS"
      if (( timeouts >= MAX_TIMEOUTS )); then
        hr; err "za dużo timeoutów — kończę (podnieś CMD_TIMEOUT albo sprawdź sieć)"; hr
        return 1
      fi
      mi=$(( (mi + 1) % ${#MODELS[@]} ))

    else
      other_fails=$(( other_fails + 1 ))
      wait_s=$(( BACKOFF_BASE * (2 ** (other_fails - 1)) ))
      (( wait_s > BACKOFF_MAX )) && wait_s=$BACKOFF_MAX
      warn "błąd inny niż limit (rc=$rc) — próba $other_fails/$MAX_OTHER_FAILS, pauza ${wait_s}s"
      [[ -s "$OUT_FILE" ]] && tail -n 3 "$OUT_FILE" | sed 's/^/       | /' >&2
      if (( other_fails >= MAX_OTHER_FAILS )); then
        hr; err "za dużo powtarzalnych błędów — kończę (zobacz $OUT_FILE)"; hr
        return 1
      fi
      sleep "$wait_s"
      mi=$(( (mi + 1) % ${#MODELS[@]} ))
    fi

    attempt=$(( attempt + 1 ))
  done

  hr; err "KONIEC bez sukcesu (próby=$attempt, rotacje=$rotations)"; hr
  return 1
}

# ─────────────────────────── HOP (TUI) ──────────────────────────────

cmd_hop() {
  open_log
  hr
  log "oc-hop — rotacja IP dla pracy w TUI"
  hr
  if rotate_and_verify; then
    ok "gotowe. Wróć do opencode i pisz dalej — sesja zostaje."
    return 0
  fi
  return 1
}

# ─────────────────────────── LOCATE ─────────────────────────────────

cmd_locate() {
  open_log
  hr
  log "szukam binarki opencode..."
  hr
  # [FIX-12] dopiero tutaj odpalamy kosztownego finda
  resolve_oc_bin_deep
  if opencode_ok; then
    ok "znaleziona: $OC_BIN"
    printf '  %-10s %s\n' "wersja:" "$(oc_version)" >&2
    hr
    log "wpisz do configu ($CONF_FILE), jeśli chcesz na sztywno:"
    printf '  OC_BIN="%s"\n' "$OC_BIN" >&2
    if ! command -v opencode >/dev/null 2>&1; then
      hr
      warn "opencode nie jest w PATH — wystaw symlinkiem:"
      printf '  mkdir -p %s && ln -sf %s %s/opencode\n' "$BIN_DIR" "$OC_BIN" "$BIN_DIR" >&2
    fi
  else
    err "nie znaleziono w żadnej standardowej lokalizacji"
    log "uruchom ręcznie: find ~ -maxdepth 5 -name 'opencode' -type f -perm -u+x"
  fi
  hr
}

# ─────────────────────────── STATUS ─────────────────────────────────

cmd_status() {
  autodetect_models
  open_log
  hr
  printf '%s\n' "${C_B}oc-rotate v$VERSION${C_0}" >&2
  hr
  printf '  %-14s %s\n' "backend:"  "$(vpn_detect)" >&2
  printf '  %-14s %s\n' "egress IP:" "${C_G}$(get_ip)${C_0}" >&2
  printf '  %-14s %s\n' "opencode:"  "$(opencode_ok && echo "$OC_BIN ($(oc_version))" || echo BRAK)" >&2
  printf '  %-14s %s\n' "config:"    "$([[ -f "$CONF_FILE" ]] && echo "$CONF_FILE" || echo 'brak (domyślne)')" >&2
  printf '  %-14s %s\n' "bin:"       "$BIN_DIR" >&2
  printf '  %-14s %s\n' "run dir:"   "$RUN_DIR" >&2
  hr
  # [FIX-2] `MODELS[0]` przy pustej puli = "unbound variable" i rc=1
  if (( ${#MODELS[@]} == 0 )); then
    printf '  %-14s %s\n' "modele:" "${C_Y}(pusta pula — ustaw MODELS/OC_MODELS)${C_0}" >&2
  else
    printf '  %-14s %s\n' "modele:" "${MODELS[0]}" >&2
    local m; for m in ${MODELS[@]:1]+"${MODELS[@]:1}"}; do
      printf '  %-14s %s\n' "" "$m" >&2
    done
  fi
  hr
  printf '  %-14s %s\n' "rotacje:"   "max=$MAX_ROTATIONS settle=${SETTLE}s timeout=${CMD_TIMEOUT}s" >&2
  printf '  %-14s %s\n' "log:"       "$LOG_FILE" >&2
  hr
  deps_check
  if ! printf '%s' ":$PATH:" | grep -q ":$BIN_DIR:"; then
    warn "$BIN_DIR nie jest w PATH — dodaj: export PATH=\"$BIN_DIR:\$PATH\""
  fi
  hr
}

# ─────────────────────────── DOCTOR ─────────────────────────────────

cmd_doctor() {
  open_log
  hr
  printf '%s\n' "${C_B}oc-rotate doctor v$VERSION${C_0}" >&2
  hr
  local problems=0

  # ── opencode
  if opencode_ok; then
    ok "opencode: $OC_BIN ($(oc_version))"
    autodetect_models
    if ((${#MODELS[@]})); then
      ok "darmowe modele wykryte: ${#MODELS[@]}"
      local m; for m in "${MODELS[@]}"; do printf '       %s\n' "$m" >&2; done
    else
      warn "nie wykryto modeli z 'free' — ustaw MODELS w configu"
      problems=$(( problems + 1 ))
    fi
  else
    err "brak opencode"; problems=$(( problems + 1 ))
    cat >&2 <<'EOF'

  Instalacja:
    curl -fsSL https://opencode.ai/install | bash
    echo 'export PATH="$HOME/.config/.opencode/bin:$PATH"' >> ~/.bashrc
    source ~/.bashrc
    opencode auth login

EOF
  fi

  # ── VPN
  case "$VPN_BACKEND" in
    mullvad)
      if have mullvad; then
        ok "mullvad: $(timeout 10 mullvad --version 2>/dev/null | head -1)"
        timeout 10 mullvad status 2>/dev/null | head -2 | sed 's/^/       /' >&2
        local nr; nr="$(mullvad_relays | wc -l)"
        if (( nr > 0 )); then ok "relayów w puli: $nr"
        else err "mullvad relay list zwraca 0 hostów — sprawdź login/konto"
             problems=$(( problems + 1 )); fi
      else
        err "brak mullvad"; problems=$(( problems + 1 ))
        cat >&2 <<EOF

  Instalacja (Ubuntu/Debian):
    sudo curl -fsSLo /usr/share/keyrings/mullvad-keyring.asc \\
      https://repository.mullvad.net/deb/mullvad-keyring.asc
    echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=\$(dpkg --print-architecture)] https://repository.mullvad.net/deb/stable \$(lsb_release -cs) main" \\
      | sudo tee /etc/apt/sources.list.d/mullvad.list
    sudo apt update && sudo apt install -y mullvad-vpn
    mullvad account login <NUMER-KONTA>
    mullvad tunnel set ipv6 off
    mullvad connect

  Konto: https://mullvad.net (płatne, bez logów, 5 urządzeń)

  Darmowo: ProtonVPN free -> konfigi WireGuard do
  $WG_DIR/ i ustaw VPN_BACKEND="wg"

EOF
      fi ;;
    proton)
      if proton_bin >/dev/null 2>&1; then
        ok "proton: CLI obecne ($(proton_bin))"
      else
        err "brak protonvpn CLI"; problems=$(( problems + 1 ))
        cat >&2 <<'EOF'

  Instalacja: https://protonvpn.com/support/official-linux-vpn-debian
  Albo: konfigi WireGuard + VPN_BACKEND="wg"

EOF
      fi ;;
    wg)
      if have wg-quick; then ok "wg-quick obecne"
      else
        err "brak wg-quick"; problems=$(( problems + 1 ))
        log "instalacja: sudo apt install -y wireguard-tools"
      fi
      local n
      n="$(find "$WG_DIR" -name '*.conf' 2>/dev/null | wc -l)"
      if (( n >= 5 )); then ok "pula WireGuard: $n konfigów"
      elif (( n > 0 )); then warn "tylko $n konfigów w $WG_DIR (zalecane min. 5)"
      else warn "brak konfigów w $WG_DIR"; problems=$(( problems + 1 ))
      fi ;;
    none)
      warn "backend=none — działa, ale bez rotacji IP" ;;
    *)
      err "nieznany VPN_BACKEND=$VPN_BACKEND"; problems=$(( problems + 1 )) ;;
  esac

  # ── narzędzia
  hr
  local c miss=()                          # [FIX-13]
  for c in curl timeout shuf; do have "$c" || miss+=("$c"); done
  if ((${#miss[@]})); then
    err "brakujące narzędzia: ${miss[*]}"; problems=$(( problems + 1 ))
    log "instalacja: sudo apt install -y curl coreutils"
  else
    ok "curl, timeout, shuf: obecne"
  fi
  # [FIX-5] --foreground jest od coreutils 8.27; bez niego sieroty przeżywają timeout
  if have timeout && timeout --foreground -k 1 1 true >/dev/null 2>&1; then
    ok "timeout --foreground: działa"
  else
    warn "timeout nie obsługuje --foreground/-k (coreutils < 8.27)"
  fi

  # ── katalog roboczy
  if [[ -w "$RUN_DIR" && -w "$OUT_FILE" ]]; then
    ok "run dir: $RUN_DIR (zapisywalny)"
  else
    err "run dir niezapisywalny: $RUN_DIR"; problems=$(( problems + 1 ))
  fi

  # ── symlink oc-hop
  if [[ -L "$BIN_DIR/oc-hop" ]]; then
    if [[ -x "$BIN_DIR/oc-hop" ]]; then
      ok "symlink oc-hop -> $(readlink "$BIN_DIR/oc-hop")"
    else
      # [FIX-1] instalator 1.2.0 robił `ln -sf oc-hop $BIN_DIR/oc-hop`,
      # czyli pętlę wskazującą samą na siebie: "Too many levels of symbolic links"
      err "$BIN_DIR/oc-hop to uszkodzony symlink ($(readlink "$BIN_DIR/oc-hop"))"
      log "napraw:  ln -sfn oc-rotate \"$BIN_DIR/oc-hop\""
      problems=$(( problems + 1 ))
    fi
  fi

  # ── PATH
  if ! printf '%s' ":$PATH:" | grep -q ":$BIN_DIR:"; then
    warn "$BIN_DIR nie jest w PATH"
    log  "dodaj: echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc"
  else
    ok "PATH zawiera $BIN_DIR"
  fi

  # ── łączność
  hr
  local ip; ip="$(get_ip)"
  if [[ -n "$ip" ]]; then ok "egress IP: $ip"
  else err "brak łączności z api.ipify.org"; problems=$(( problems + 1 ))
  fi

  hr
  if (( problems == 0 )); then
    ok "wszystko gotowe — możesz używać: oc-rotate run \"...\""
  else
    warn "problemów do naprawy: $problems"
  fi
  hr
  return 0
}

# ─────────────────────────── MODELS ─────────────────────────────────

cmd_models() {
  opencode_ok || die "brak binarki opencode — uruchom: oc-rotate locate"
  if [[ "${1:-}" == "--free" ]]; then
    timeout "$MODELS_TIMEOUT" "$OC_BIN" models 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | awk '{print $1}' \
      | grep -E '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
      | grep -iE '(^|/)free|(^|-)free($|-)|free-' | sort -u
  else
    timeout "$MODELS_TIMEOUT" "$OC_BIN" models
  fi
}

# ─────────────────────────── INSTALL ────────────────────────────────

cmd_install() {
  open_log
  hr
  printf '%s\n' "${C_B}instalacja oc-rotate v$VERSION${C_0}" >&2
  hr

  mkdir -p "$CONF_DIR" "$BIN_DIR" "$RUN_DIR" || die "nie mogę utworzyć katalogów"
  chmod 700 "$RUN_DIR" 2>/dev/null || true

  if [[ ! -f "$CONF_FILE" ]]; then
    cat > "$CONF_FILE" <<'EOF'
# oc-rotate — konfiguracja użytkownika
# Nadpisuje wartości domyślne ze skryptu.

# mullvad | proton | wg | none
VPN_BACKEND="mullvad"

# Pula modeli. Puste = auto-wykrywanie darmowych przez `opencode models`.
# Sprawdź dostępne:  oc-rotate models --free
# MODELS=(
#   "opencode/deepseek-v4-flash-free"
#   "opencode/mimo-v2.5-free"
# )

# Auto-wykrywanie darmowych modeli (1 = włączone)
# AUTO_MODELS=1
# MAX_MODELS=5

# Parametry rotacji
# MAX_ROTATIONS=25
# SETTLE=12
# CMD_TIMEOUT=900
# KILL_GRACE=10
# MAX_OTHER_FAILS=3
# MAX_TIMEOUTS=3

# Rotacja relayów (Mullvad)
# VPN_WAIT=40          # ile czekać na "Connected" po reconnect
# RELAY_COOLDOWN=8     # ilu ostatnich relayów nie losować ponownie

# Wyłącz całkowicie rotację IP (zostaje samo przełączanie modeli)
# OC_DISABLE_ROTATION=1

# WireGuard (VPN_BACKEND="wg")
# WG_DIR="$HOME/.config/oc-rotate/wg"
# WG_IF="wg0"

# Wznawiaj ostatnią sesję zamiast wysyłać prompt od nowa
# RESUME_FLAG="--continue"

# Dodatkowe flagi opencode (rozdzielane spacją; wartości z odstępami
# trzeba podać jako OC_EXTRA_ARGS_LIST=(...) w bashu, nie tutaj).
# v1:  --dir /path/to/project   --standalone (tylko v2)
# v2:  --directory /path        --standalone
# OC_EXTRA_ARGS="--dir /home/user/projekt"
# OC_EXTRA_ARGS="--standalone"

# Ścieżka do binarki, gdy auto-wykrywanie zawiedzie
# OC_BIN="/home/user/.config/.opencode/bin/opencode"

# Gdzie trzymać pliki robocze (domyślnie ~/.config/oc-rotate/run, tryb 700)
# RUN_DIR / OUT_FILE / LOG_FILE
EOF
    ok "config: $CONF_FILE"
  else
    warn "config istnieje, zostawiam: $CONF_FILE"
  fi

  mkdir -p "$WG_DIR"
  ok "pula WireGuard: $WG_DIR"

  local target="$BIN_DIR/oc-rotate"
  if [[ "$SELF" != "$target" ]]; then
    install -m 755 "$SELF" "$target" || die "nie mogę zainstalować binarki"
    ok "binarka: $target"
  else
    chmod 755 "$target"
    ok "binarka już na miejscu: $target"
  fi

  # [FIX-1] było: ln -sf "oc-hop" "$BIN_DIR/oc-hop"  ->  symlink do samego
  # siebie, "Too many levels of symbolic links". -n żeby nie wchodzić w katalog.
  ln -sfn "oc-rotate" "$BIN_DIR/oc-hop" || die "symlink oc-hop nieudany"
  ok "symlink: $BIN_DIR/oc-hop -> oc-rotate"

  # naprawa pętli zostawionej przez 1.2.0
  if [[ -L "$BIN_DIR/oc-hop" && "$(readlink "$BIN_DIR/oc-hop")" == "oc-hop" ]]; then
    ln -sfn "oc-rotate" "$BIN_DIR/oc-hop"
    warn "naprawiłem uszkodzony symlink oc-hop z wersji 1.2.0"
  fi

  if ! printf '%s' ":$PATH:" | grep -q ":$BIN_DIR:"; then
    warn "$BIN_DIR nie jest w PATH"
    log  "dodaj do ~/.bashrc:  export PATH=\"$BIN_DIR:\$PATH\""
  fi

  if [[ "$VPN_BACKEND" == "mullvad" ]] && have mullvad; then
    if timeout 20 mullvad tunnel set ipv6 off >/dev/null 2>&1 \
       || timeout 20 mullvad tunnel ipv6 set off >/dev/null 2>&1; then
      ok "mullvad: ipv6 off"
    else
      warn "nie ustawiono ipv6=off (ustaw ręcznie)"
    fi
  fi

  hr
  ok "instalacja zakończona"
  hr
  log "uruchamiam diagnozę..."
  cmd_doctor
}

# ─────────────────────────── UNINSTALL ──────────────────────────────

cmd_uninstall() {
  open_log
  rm -f "$BIN_DIR/oc-hop" "$BIN_DIR/oc-rotate"
  ok "usunięto binarki"
  log "config zostawiony: $CONF_FILE"
  log "usuń ręcznie:  rm -rf $CONF_DIR"
}

# ─────────────────────────── HELP ───────────────────────────────────

cmd_help() {
  cat >&2 <<EOF
${C_B}oc-rotate v$VERSION${C_0} — OpenCode z rotacją IP

${C_B}UŻYCIE${C_0}
  oc-rotate install                 instalacja + config + symlink oc-hop
  oc-rotate doctor                  co brakuje i jak to zainstalować
  oc-rotate locate                  znajdź binarkę opencode
  oc-rotate run "<prompt>"          zadanie z auto-rotacją przy 429
  oc-rotate run ./prompt.txt        prompt z pliku
  cat p.txt | oc-rotate run         prompt ze stdin
  oc-rotate hop                     jedna rotacja IP (do pracy w TUI)
  oc-rotate status                  stan systemu
  oc-rotate models [--free]         dostępne modele
  oc-rotate uninstall               usuwa binarki

${C_B}JAK TO DZIAŁA${C_0}
  1. limit na modelu      -> przełącza na następny model (darmowe, natychmiast)
  2. wszystkie w limicie  -> rotuje egress IP przez VPN i wznawia
  3. weryfikuje           -> czeka aż publiczne IP faktycznie się zmieni

${C_B}KONFIGURACJA${C_0}
  $CONF_FILE
  Zmienne: VPN_BACKEND, MODELS, AUTO_MODELS, MAX_MODELS, MAX_ROTATIONS,
           SETTLE, CMD_TIMEOUT, KILL_GRACE, MAX_OTHER_FAILS, MAX_TIMEOUTS,
           RESUME_FLAG, OC_EXTRA_ARGS, WG_DIR, OC_BIN, RUN_DIR,
           VPN_WAIT, RELAY_COOLDOWN, RATE_LIMIT_RE, OC_DISABLE_ROTATION

${C_B}ENV${C_0}
  VPN_BACKEND=mullvad|proton|wg|none
  OC_MODELS="provider/model provider/model"
  AUTO_MODELS=0
  RESUME_FLAG=--continue
  OC_DISABLE_ROTATION=1     tylko przełączanie modeli, bez ruszania VPN
  LOG_FILE=~/.config/oc-rotate/run/oc-rotate.log

${C_B}PRZYKŁADY${C_0}
  OC_MODELS="opencode/deepseek-v4-flash-free" VPN_BACKEND=proton \\
    oc-rotate run "napraw build"

  RESUME_FLAG=--continue oc-rotate run ./task.txt

${C_B}UWAGA (ryzyko blokady konta)${C_0}
  Limit darmowych modeli Zen jest przypisany do IP. Rotacja po IPv6
  bywa bezskuteczna (serwer obcina adres do 4 pierwszych grup), dlatego
  instalator wymusza IPv6 off w Mullvad.

  ToS OpenCode (opencode.ai/legal/terms-of-service) zabrania obejścia
  limitów użycia oraz obciążania infrastruktury w sposób nierozsądny.
  Automatyczna rotacja IP w celu zresetowania limitu mieści się w tym
  zakazie i grozi terminacją konta. Bezpieczne alternatywy:
    - własny klucz providera:  opencode auth login <provider>
    - płatny Zen / budżet w Console
    - OC_DISABLE_ROTATION=1 (sama rotacja modeli, bez VPN)
EOF
}

# ─────────────────────────── DISPATCH ───────────────────────────────

# [FIX-1] multi-call: sprawdzamy zarówno $0 (nazwa symlinka, pod którą nas
# wywołano), jak i SELF — bo `readlink -f` rozwiązuje symlink i SELF zawsze
# wskazuje na rzeczywisty plik oc-rotate.
case "$(basename "$0")|$(basename "$SELF")" in
  *oc-hop*) cmd_hop "$@"; exit $? ;;
esac

case "${1:-help}" in
  install|i)     shift; cmd_install "$@" ;;
  doctor|d)      shift; cmd_doctor "$@" ;;
  locate|l)      shift; cmd_locate "$@" ;;
  run|r)         shift; cmd_run "$@" ;;
  hop)           shift; cmd_hop "$@" ;;
  status|s)      shift; cmd_status "$@" ;;
  models|m)      shift; cmd_models "$@" ;;
  uninstall)     shift; cmd_uninstall "$@" ;;
  version|-v|--version) printf 'oc-rotate %s\n' "$VERSION" ;;
  help|-h|--help) cmd_help ;;
  # [FIX-16] 1.2.0 traktował nieznaną komendę jak `help` i zwracał 0,
  # więc w skrypcie CI literówka przechodziła jako sukces.
  *) err "nieznana komenda: $1"; hr; cmd_help; exit 2 ;;
esac

# ─────────────────────────── CHANGELOG ──────────────────────────────
#
# 1.3.0 — poprawki (każda odtworzona testem przed i po):
#  FIX-1   ln -sf "oc-hop" "$BIN_DIR/oc-hop" tworzył symlink do samego siebie
#          -> `oc-hop` = "Too many levels of symbolic links". Znak firmowy
#          skryptu nie działał wcale. Teraz: ln -sfn "oc-rotate".
#          Dodatkowo `rotations <= MAX_ROTATIONS` robiło o jeden obrót VPN
#          za dużo (MAX_ROTATIONS=1 -> rotacje=2).
#  FIX-2   Pusta pula modeli + `set -u` = crash "MODELS[0]/MODELS[$mi]:
#          unbound variable" w `run` i w `status` (rc=1, bez komunikatu).
#          Teraz czytelny błąd z podpowiedzią.
#  FIX-3   `is_rate_limited` łapał gołe "429" w CAŁYM outputcie. Odpowiedź
#          modelu zawierająca "429" (kod błędu, port, numer linii) przy rc=0
#          była czytana jako limit -> nieskończona pętla rotacji IP i brak
#          sukcesu mimo poprawnie wykonanego zadania. Wzorzec zawężony
#          (RATE_LIMIT_RE), do tego wymóg rc!=0 albo niepustego pliku.
#  FIX-4   Brak `--` przed promptem: `oc-rotate run "--verbose build fix"`
#          wysyłało "--verbose build fix" jako flagi opencode.
#  FIX-5   timeout (rc=124) wpadał do "błąd inny niż limit" i był retry'owany
#          300x po 900s bez backoffu. Teraz osobna gałąź, limit MAX_TIMEOUTS,
#          a `timeout --foreground -k` zabija całą grupę procesów (w 1.2.0
#          sieroty po opencode — serwery MCP/LSP — przeżywały timeout;
#          potwierdzone testem).
#  FIX-6   log() forował `tee -a` na każdą linię i sypał "tee: ... No such
#          file" na stdout, mieszając to z odpowiedzią modelu. Teraz jeden
#          FD. `: > "$LOG_FILE"` kasowało historię przy każdym run.
#  FIX-7   OUT_FILE/LOG_FILE w gołym /tmp: na współdzielonej maszynie cudzy
#          plik = EACCES, a wtedy stary output był czytany jako bieżący.
#          Teraz ~/.config/oc-rotate/run (0700) + test zapisywalności na starcie.
#  FIX-8   Mullvad: `mullvad reconnect` wraca zanim tunel stanie, a sprawdzenie
#          IP było po sztywnych 4s -> fałszywe "IP bez zmian" i kolejne ślepe
#          reconnecty. Dodane czekanie na "Connected", `relay set location`
#          (stare `set hostname` jako fallback), stderr z mullvada nie jest już
#          połykany, a shuf nie losuje ponownie relayów z ostatnich N obrotów.
#  FIX-9   rotate_proton nie zwracał kodu wyjścia `connect` — cichy błąd
#          wyglądał jak udana rotacja.
#  FIX-10  Gdy api.ipify.org nie odpowiadał, before="" i dowolne after
#          "potwierdzało" rotację.
#  FIX-11  `opencode models` bez timeouta mogło zawiesić start; wynik
#          cache'owany (status wołał autodetect 2x).
#  FIX-12  `find "$HOME" -maxdepth 5` leciał przy KAŻDYM wywołaniu (nawet
#          --help), bez limitu czasu i bez prunowania node_modules/.cache,
#          i brał pierwszy trafiony plik (np. ./node_modules/.bin/opencode).
#          Teraz tylko w `locate`, z timeoutem i prunowaniem.
#  FIX-13  `c` w deps_check/cmd_doctor nie było `local` — wyciek do globala.
#  FIX-14  MAX_MODELS=0 dawałoby pustą pulę (patrz FIX-2).
#  FIX-15  OC_DISABLE_ROTATION=1 — tryb bez ruszania VPN.
#  FIX-16  Nieznana komenda zwracała 0 i drukowała help; teraz rc=2.
#  Config: `OC_EXTRA_ARGS="--cwd ..."` z szablonu 1.2.0 to nieistniejąca flaga
#          (opencode run ma --dir w v1 / --directory w v2) -> każdy run
#          kończyłby się błędem parsera, który pętla brałaby za "inny błąd".
