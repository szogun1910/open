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
set -uo pipefail

VERSION="1.2.0"

# ─────────────────────────── ŚCIEŻKI ────────────────────────────────

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/oc-rotate"
CONF_FILE="$CONF_DIR/config.sh"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

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
OUT_FILE="${OUT_FILE:-/tmp/oc-rotate.out}"
LOG_FILE="${LOG_FILE:-/tmp/oc-rotate.log}"
RESUME_FLAG="${RESUME_FLAG:-}"
OC_EXTRA_ARGS="${OC_EXTRA_ARGS:-}"

# config użytkownika nadpisuje domyślne
# shellcheck disable=SC1090
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

# ──────────────────── WYKRYWANIE BINARKI (wczesne) ──────────────────
# Uwaga: definiowane tutaj, przed resztą funkcji, bo używa tylko `command -v`.

resolve_oc_bin() {
  command -v "$OC_BIN" >/dev/null 2>&1 && return 0
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
  c="$(find "$HOME" -maxdepth 5 -type f -name 'opencode' -executable 2>/dev/null | head -1)"
  [[ -n "$c" ]] && { OC_BIN="$c"; return 0; }
  return 1
}
resolve_oc_bin

# pula modeli: jeśli użytkownik nie podał OC_MODELS, wykryj darmowe z CLI
autodetect_models() {
  [[ "$AUTO_MODELS" == "1" ]] || return 0
  [[ -n "${OC_MODELS:-}" ]] && return 0
  command -v "$OC_BIN" >/dev/null 2>&1 || return 0

  local detected=() out=() d m seen
  mapfile -t detected < <(
    "$OC_BIN" models 2>/dev/null \
      | awk '{print $1}' \
      | grep -E '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
      | grep -i 'free' | sort -u
  )
  (( ${#detected[@]} )) || return 0

  for m in "${MODELS[@]}"; do
    for d in "${detected[@]}"; do [[ "$d" == "$m" ]] && out+=("$d"); done
  done
  for d in "${detected[@]}"; do
    seen=0
    for m in "${out[@]}"; do [[ "$d" == "$m" ]] && seen=1; done
    (( seen == 0 )) && out+=("$d")
  done

  MODELS=("${out[@]:0:MAX_MODELS}")
}

# OC_MODELS z env ma najwyższy priorytet
[[ -n "${OC_MODELS:-}" ]] && read -r -a MODELS <<< "$OC_MODELS"

# ─────────────────────────── LOG / UI ───────────────────────────────

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[[ -t 2 ]] || { C_R=; C_G=; C_Y=; C_B=; C_D=; C_0=; }

log()  { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }
ok()   { log "${C_G}OK${C_0}   $*"; }
warn() { log "${C_Y}WARN${C_0} $*"; }
err()  { log "${C_R}ERR${C_0}  $*"; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s\n' "${C_D}────────────────────────────────────────${C_0}" >&2; }

# ─────────────────────────── ZALEŻNOŚCI ────────────────────────────

have() { command -v "$1" >/dev/null 2>&1; }

opencode_ok() { have "$OC_BIN" || [[ -x "$OC_BIN" ]]; }

oc_version() { "$OC_BIN" --version 2>/dev/null | head -1; }

proton_bin() {
  have protonvpn && { echo protonvpn; return; }
  have protonvpn-cli && { echo protonvpn-cli; return; }
  return 1
}

deps_check() {
  local missing=()
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

rotate_mullvad() {
  local host
  host="$(mullvad relay list 2>/dev/null \
          | grep -oE '[a-z]{2}-[a-z]{3}-wg-[0-9]+' \
          | shuf -n1)"
  [[ -z "$host" ]] && { err "mullvad: brak relayów (zaloguj się: mullvad account login)"; return 1; }
  log "mullvad -> ${C_B}$host${C_0}"
  mullvad relay set hostname "$host" >/dev/null 2>&1 || { err "mullvad relay set"; return 1; }
  mullvad reconnect >/dev/null 2>&1 || { err "mullvad reconnect"; return 1; }
}

rotate_proton() {
  local bin
  bin="$(proton_bin)" || { err "proton: brak CLI"; return 1; }
  log "proton -> losowy serwer"
  if [[ "$bin" == "protonvpn" ]]; then
    "$bin" connect --random >/dev/null 2>&1
  else
    "$bin" connect -r >/dev/null 2>&1
  fi
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
  log "IP przed: ${before:-nieznane}"

  for i in 1 2 3 4 5; do
    rotate_vpn || return 1
    sleep 4
    after="$(get_ip)"
    if [[ -n "$after" && "$after" != "$before" ]]; then
      ok "IP po:   ${C_G}$after${C_0} (rotacja potwierdzona)"
      return 0
    fi
    warn "IP bez zmian (próba $i/5)"
    sleep 6
  done

  err "nie udało się zmienić IP"
  return 1
}

# ─────────────────────────── WYKRYWANIE LIMITU ──────────────────────

is_rate_limited() {
  grep -qiE 'FreeUsageLimitError|Free usage exceeded|Rate limit exceeded|429|quota exceeded' "$OUT_FILE" 2>/dev/null
}

# ─────────────────────────── RUN ────────────────────────────────────

run_once() {
  local prompt="$1" model="$2" rc
  : > "$OUT_FILE"
  # shellcheck disable=SC2086
  timeout "$CMD_TIMEOUT" "$OC_BIN" run $RESUME_FLAG --model "$model" $OC_EXTRA_ARGS "$prompt" \
    2>&1 | tee "$OUT_FILE"
  rc="${PIPESTATUS[0]}"
  (( rc == 0 )) && ! is_rate_limited && return 0
  return 1
}

cmd_run() {
  local prompt="${1:-}"

  if [[ -z "$prompt" ]]; then
    if [[ -f "${2:-}" ]]; then
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

  : > "$LOG_FILE"
  hr
  log "start v$VERSION | backend=$(vpn_detect) | modeli=${#MODELS[@]} | max rotacji=$MAX_ROTATIONS"
  hr

  local attempt=0 rotations=0 mi=0 model

  while (( attempt < MAX_ATTEMPTS && rotations <= MAX_ROTATIONS )); do
    model="${MODELS[$mi]}"
    log "próba $(( attempt + 1 )) | model=${C_B}${model}${C_0} | rotacje=$rotations/$MAX_ROTATIONS"

    if run_once "$prompt" "$model"; then
      hr; ok "SUKCES na $model (próby=$(( attempt + 1 )), rotacje=$rotations)"; hr
      return 0
    fi

    if is_rate_limited; then
      if (( mi + 1 < ${#MODELS[@]} )); then
        mi=$(( mi + 1 ))
        log "limit na '$model' -> następny model (bez ruszania VPN)"
      else
        mi=0
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
    else
      warn "błąd inny niż limit -> ponawiam za 5s"
      sleep 5
    fi

    attempt=$(( attempt + 1 ))
  done

  hr; err "KONIEC bez sukcesu (próby=$attempt, rotacje=$rotations)"; hr
  return 1
}

# ─────────────────────────── HOP (TUI) ──────────────────────────────

cmd_hop() {
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
  hr
  log "szukam binarki opencode..."
  hr
  if opencode_ok; then
    ok "znaleziona: $OC_BIN"
    printf '  %-10s %s\n' "wersja:" "$(oc_version)" >&2
    hr
    log "wpisz do configu ($CONF_FILE), jeśli chcesz na sztywno:"
    printf '  OC_BIN="%s"\n' "$OC_BIN" >&2
    if ! command -v opencode >/dev/null 2>&1; then
      hr
      warn "opencode nie jest w PATH — wystaw symlinkiem:"
      printf '  ln -sf %s %s/opencode\n' "$OC_BIN" "$BIN_DIR" >&2
    fi
  else
    err "nie znaleziono w żadnej standardowej lokalizacji"
    log "uruchom ręcznie: find ~ -maxdepth 5 -name 'opencode' -executable"
  fi
  hr
}

# ─────────────────────────── STATUS ─────────────────────────────────

cmd_status() {
  autodetect_models
  hr
  printf '%s\n' "${C_B}oc-rotate v$VERSION${C_0}" >&2
  hr
  printf '  %-14s %s\n' "backend:"  "$(vpn_detect)" >&2
  printf '  %-14s %s\n' "egress IP:" "${C_G}$(get_ip)${C_0}" >&2
  printf '  %-14s %s\n' "opencode:"  "$(opencode_ok && echo "$OC_BIN ($(oc_version))" || echo BRAK)" >&2
  printf '  %-14s %s\n' "config:"    "$([[ -f "$CONF_FILE" ]] && echo "$CONF_FILE" || echo 'brak (domyślne)')" >&2
  printf '  %-14s %s\n' "bin:"       "$BIN_DIR" >&2
  hr
  printf '  %-14s %s\n' "modele:"    "${MODELS[0]}" >&2
  local m; for m in "${MODELS[@]:1}"; do printf '  %-14s %s\n' "" "$m" >&2; done
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
        ok "mullvad: $(mullvad --version 2>/dev/null | head -1)"
        mullvad status 2>/dev/null | head -2 | sed 's/^/       /' >&2
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

  Konto: https://mullvad.net (platne, bez logów, 5 urządzeń)

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
  local miss=()
  for c in curl timeout shuf; do have "$c" || miss+=("$c"); done
  if ((${#miss[@]})); then
    err "brakujące narzędzia: ${miss[*]}"; problems=$(( problems + 1 ))
    log "instalacja: sudo apt install -y curl coreutils"
  else
    ok "curl, timeout, shuf: obecne"
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
    "$OC_BIN" models 2>/dev/null \
      | awk '{print $1}' \
      | grep -E '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
      | grep -i 'free' | sort -u
  else
    "$OC_BIN" models
  fi
}

# ─────────────────────────── INSTALL ────────────────────────────────

cmd_install() {
  hr
  printf '%s\n' "${C_B}instalacja oc-rotate v$VERSION${C_0}" >&2
  hr

  mkdir -p "$CONF_DIR" "$BIN_DIR" || die "nie mogę utworzyć katalogów"

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

# WireGuard (VPN_BACKEND="wg")
# WG_DIR="$HOME/.config/oc-rotate/wg"
# WG_IF="wg0"

# Wznawiaj ostatnią sesję zamiast wysyłać prompt od nowa
# RESUME_FLAG="--continue"

# Dodatkowe flagi opencode, np. tryb samodzielny albo katalog projektu
# OC_EXTRA_ARGS="--standalone"
# OC_EXTRA_ARGS="--cwd /home/user/projekt"

# Ścieżka do binarki, gdy auto-wykrywanie zawiedzie
# OC_BIN="/home/szogun/.config/.opencode/bin/opencode"
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
  ln -sf "oc-hop" "$BIN_DIR/oc-hop" || die "symlink oc-hop nieudany"
  ok "symlink: $BIN_DIR/oc-hop"

  if ! printf '%s' ":$PATH:" | grep -q ":$BIN_DIR:"; then
    warn "$BIN_DIR nie jest w PATH"
    log  "dodaj do ~/.bashrc:  export PATH=\"$BIN_DIR:\$PATH\""
  fi

  if [[ "$VPN_BACKEND" == "mullvad" ]] && have mullvad; then
    if mullvad tunnel set ipv6 off >/dev/null 2>&1 \
       || mullvad tunnel ipv6 set off >/dev/null 2>&1; then
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
           SETTLE, CMD_TIMEOUT, RESUME_FLAG, OC_EXTRA_ARGS, WG_DIR, OC_BIN

${C_B}ENV${C_0}
  VPN_BACKEND=mullvad|proton|wg|none
  OC_MODELS="provider/model provider/model"
  AUTO_MODELS=0
  RESUME_FLAG=--continue
  LOG_FILE=/tmp/oc-rotate.log

${C_B}PRZYKŁADY${C_0}
  OC_MODELS="opencode/deepseek-v4-flash-free" VPN_BACKEND=proton \\
    oc-rotate run "napraw build"

  RESUME_FLAG=--continue oc-rotate run ./task.txt

${C_B}UWAGA${C_0}
  Limit darmowych modeli Zen jest przypisany do IP. Rotacja po IPv6
  bywa bezskuteczna (serwer obcina adres do 4 pierwszych grup), dlatego
  instalator wymusza IPv6 off w Mullvad.
EOF
}

# ─────────────────────────── DISPATCH ───────────────────────────────

case "$(basename "$0")" in
  oc-hop) cmd_hop "$@"; exit $? ;;
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
  help|-h|--help|*) cmd_help ;;
esac
