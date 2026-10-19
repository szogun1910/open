#!/usr/bin/env bash
# Harness testowy oc-rotate — podrobione `opencode`, `mullvad`, `curl`.
#
#   bash test/run-tests.sh                       # testuje ../oc-rotate.sh
#   S=/sciezka/do/skryptu bash test/run-tests.sh # testuje wskazany skrypt
#
# Wszystko jest nadpisane na test/home/: PATH, HOME, BIN_DIR, RUN_DIR.
# Prawdziwa konfiguracja i prawdziwy VPN nie są ruszane.
#
# UWAGA: wszystkie ścieżki są budowane od `pwd` (HERE), nie wpisywane literalnie.
# W niektórych piaskownicach literały w plikach tworzonych przez narzędzia bywają
# przepisywane na makra i skrypt "nie widzi" własnego katalogu.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
S="${S:-$ROOT/oc-rotate.sh}"
T="$HERE"

[[ -f "$S" ]] || { echo "nie znaleziono skryptu: $S (ustaw S=...)" >&2; exit 1; }

export TESTHOME="$T/home"
export PATH="$TESTHOME/.local/bin:$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export TESTLOG="$TESTHOME/testlog"
export IPCOUNTER="$TESTHOME/ipcount"
export COUNTER="$TESTHOME/callcount"
export LIMIT_UNTIL="$TESTHOME/limit"
export MODE="$TESTHOME/mode"
export MULLVAD_STATUS="$TESTHOME/mstatus"
export HOME="$TESTHOME"
export BIN_DIR="$TESTHOME/.local/bin"
export RUN_DIR="$TESTHOME/.config/oc-rotate/run"

mkdir -p "$BIN_DIR" "$TESTHOME/.config" "$T/bin"
echo "Connected to se-got-wg-001" > "$MULLVAD_STATUS"

strip() { sed 's/\x1b\[[0-9;]*m//g'; }
# rc musi być brany bezpośrednio po skrypcie — potok go zgubi
cap()   { OUT=$(bash "$S" "$@" 2>&1); RC=$?; OUT=$(strip <<<"$OUT"); }
caph()  { OUT=$(oc-hop "$@" 2>&1);    RC=$?; OUT=$(strip <<<"$OUT"); }
clean() { rm -f "$TESTLOG" "$IPCOUNTER" "$COUNTER" "$MODE"; echo 0 > "$LIMIT_UNTIL"; }

pass=0; fail=0; OUT=""; RC=0
chk() { if eval "$2"; then printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1));
        else printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$(strip <<<"$OUT" | tail -2 | tr '\n' ' ')"
             fail=$((fail+1)); fi; }
sec() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# ───────────────────────── instalacja ─────────────────────────
sec "install / symlink (FIX-1)"
clean; rm -rf "$BIN_DIR" "$RUN_DIR"; mkdir -p "$BIN_DIR"; cap install
chk "install rc=0"                    '[[ $RC -eq 0 ]]'
chk "oc-hop -> oc-rotate"             '[[ "$(readlink "$BIN_DIR/oc-hop")" == "oc-rotate" ]]'
chk "oc-hop wykonywalny"              '[[ -x "$BIN_DIR/oc-hop" ]]'
chk "doctor: 0 problemów"             'grep -q "wszystko gotowe" <<<"$OUT"'

sec "hop przez symlink"
clean; caph
chk "oc-hop rotuje i potwierdza IP"   '[[ $RC -eq 0 ]] && grep -q "rotacja potwierdzona" <<<"$OUT"'

# ───────────────────────── run ─────────────────────────
sec "run: przełączanie modeli"
clean; echo 2 > "$LIMIT_UNTIL"; cap run "napraw build"
chk "rc=0"                            '[[ $RC -eq 0 ]]'
chk "3. model, bez ruszania VPN"      'grep -q "SUKCES na opencode/hy3-free" <<<"$OUT" && ! grep -q "rotacja IP" <<<"$OUT"'

sec "run: MAX_ROTATIONS bez off-by-one (FIX-1)"
clean; echo 99 > "$LIMIT_UNTIL"
MAX_ROTATIONS=1 MAX_ATTEMPTS=9 SETTLE=0 cap run x
chk "dokładnie 1 rotacja"             'grep -q "rotacje=1)" <<<"$OUT" && ! grep -q "rotacje=2" <<<"$OUT"'

sec "pusta pula modeli (FIX-2)"
clean; printf 'VPN_BACKEND="none"\nMODELS=()\nAUTO_MODELS=0\n' > "$TESTHOME/.config/oc-rotate/config.sh"
cap run x
chk "rc=1 + czytelny błąd"            '[[ $RC -eq 1 ]] && grep -q "pula modeli jest pusta" <<<"$OUT"'
chk "brak 'unbound variable'"         '! grep -q "unbound variable" <<<"$OUT"'
bash "$S" status >/dev/null 2>/tmp/st.err; src=$?; OUT=$(cat /tmp/st.err)
chk "status rc=0, bez crashu"         '[[ $src -eq 0 ]] && ! grep -q "unbound variable" <<<"$OUT"'
rm -f "$TESTHOME/.config/oc-rotate/config.sh"

sec "prompt zaczynający się od '-' (FIX-4)"
clean; rm -f "$TESTLOG"; cap run "--verbose build fix"
chk "'--verbose…' trafia po '--'"    '[[ "$(grep -a "FAKE-OC: run" "$TESTLOG" | tail -1)" == *" -- --verbose build fix" ]]'
clean; rm -f "$TESTLOG"; cap run "-m anthropic/claude-sonnet-4"
chk "'-m …' nie podmienia modelu"    '[[ "$(grep -a "FAKE-OC: run" "$TESTLOG" | tail -1)" == *"--model opencode/deepseek-v4-flash-free -- -m anthropic/claude-sonnet-4" ]]'

sec "timeout rc=124 (FIX-5)"
clean; echo hang > "$MODE"
CMD_TIMEOUT=2 MAX_TIMEOUTS=2 MAX_ATTEMPTS=9 cap run x
chk "rc=1"                            '[[ $RC -eq 1 ]]'
chk "osobna gałąź timeout"            'grep -q "timeout po 2s (rc=124)" <<<"$OUT" && ! grep -q "błąd inny niż limit" <<<"$OUT"'
chk "koniec po MAX_TIMEOUTS=2"        '[[ "$(grep -c "rc=124" <<<"$OUT")" -eq 2 ]]'

sec "inny błąd: backoff i limit prób (FIX-5)"
clean; echo fail > "$MODE"
MAX_OTHER_FAILS=2 MAX_ATTEMPTS=9 BACKOFF_BASE=1 cap run x
chk "rc=1"                            '[[ $RC -eq 1 ]]'
chk "backoff 1s -> 2s"                'grep -q "pauza 1s" <<<"$OUT" && grep -q "pauza 2s" <<<"$OUT"'
chk "pokazuje ogon błędu"             'grep -q "| Error: connection reset" <<<"$OUT"'

sec "fałszywy '429' w odpowiedzi przy rc=0 (FIX-3)"
clean; echo dash429 > "$MODE"
MAX_ATTEMPTS=5 cap run x
chk "rc=0 = SUKCES"                   '[[ $RC -eq 0 ]] && grep -q SUKCES <<<"$OUT"'
chk "zero wywołań mullvada"           '! grep -aq FAKE-MULLVAD "$TESTLOG"'

sec "prawdziwy limit nadal wykrywany"
clean; echo 1 > "$LIMIT_UNTIL"
OC_MODELS="opencode/hy3-free" MAX_ROTATIONS=1 MAX_ATTEMPTS=3 SETTLE=0 cap run x
chk "FreeUsageLimitError -> rotacja"  'grep -q "rotacja IP" <<<"$OUT"'

sec "rotacja relayów (FIX-8)"
clean; rm -f "$RUN_DIR/relays-used"
for _ in 1 2 3 4 5 6 7 8; do oc-hop >/dev/null 2>&1; done
seq8=$(cat "$RUN_DIR/relays-used" 2>/dev/null)
chk "8 obrotów = 8 wpisów"            '[[ "$(wc -l <<<"$seq8")" -eq 8 ]]'
chk "brak powtórek z rzędu"           '[[ "$(awk "NR>1 && \$0==p{c++} {p=\$0} END{print c+0}" <<<"$seq8")" -eq 0 ]]'
chk "'relay set location' (2026.x)"   'grep -aq "relay set location" "$TESTLOG"'
chk "status sprawdzany przed IP"      'grep -aq "FAKE-MULLVAD: status" "$TESTLOG"'

sec "pliki robocze (FIX-6, FIX-7)"
clean; cap run pierwszy; cap run drugi
chk "log nie kasowany per run"        '[[ "$(grep -ac "=== run" "$RUN_DIR/oc-rotate.log")" -ge 2 ]]'
chk "RUN_DIR ma tryb 700"             '[[ "$(stat -c %a "$RUN_DIR")" == "700" ]]'
OUT_FILE=/nonexistent/x cap run x
chk "niezapisywalny OUT_FILE: rc=1"   '[[ $RC -eq 1 ]] && grep -q "nie mogę pisać" <<<"$OUT"'

sec "dispatch i help"
bash "$S" foobar >/dev/null 2>&1; rc=$?; OUT=x
chk "nieznana komenda rc=2"           '[[ $rc -eq 2 ]]'
chk "version"                         '[[ "$(bash "$S" version)" == *"oc-rotate"* ]]'
bash "$S" help >/dev/null 2>/tmp/h.txt; OUT=$(cat /tmp/h.txt)
chk "help: nowe zmienne"              'grep -q OC_DISABLE_ROTATION <<<"$OUT" && grep -q RATE_LIMIT_RE <<<"$OUT"'
chk "help: ostrzeżenie o ToS"         'grep -q "terms-of-service" <<<"$OUT"'

sec "OC_DISABLE_ROTATION=1 (FIX-15)"
clean; echo 99 > "$LIMIT_UNTIL"
OC_DISABLE_ROTATION=1 MAX_ATTEMPTS=9 cap run x
chk "kończy bez ruszania VPN"         'grep -q "OC_DISABLE_ROTATION=1 -> kończę" <<<"$OUT" && ! grep -aq FAKE-MULLVAD "$TESTLOG"'

sec "prompt z pliku i ze stdin"
clean; printf 'tresc z pliku\n' > /tmp/p.txt; rm -f "$TESTLOG"
cap run /tmp/p.txt; a=$(grep -a 'FAKE-OC: run' "$TESTLOG" | tail -1)
bash "$S" run < /tmp/p.txt >/dev/null 2>&1; b=$(grep -a 'FAKE-OC: run' "$TESTLOG" | tail -1); OUT="$a|$b"
chk "z pliku"                         '[[ "$a" == *" -- tresc z pliku" ]]'
chk "ze stdin"                        '[[ "$b" == *" -- tresc z pliku" ]]'

sec "doctor wykrywa pętlę symlinków (regresja FIX-1)"
ln -sfn oc-hop "$BIN_DIR/oc-hop"; cap doctor
chk "wykrywa uszkodzony symlink"      'grep -q "uszkodzony symlink" <<<"$OUT"'
cap install
chk "install naprawia pętlę"          '[[ "$(readlink "$BIN_DIR/oc-hop")" == "oc-rotate" ]]'

sec "models"
clean; OUT=$(bash "$S" models --free 2>&1); RC=$?
chk "--free filtruje"                 '[[ $RC -eq 0 ]] && [[ "$(wc -l <<<"$OUT")" -eq 3 ]]'

printf '\n\033[1mPASS=%d FAIL=%d\033[0m\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
