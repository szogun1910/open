#!/usr/bin/env bash
# harness testowy dla oc-rotate (fake opencode/mullvad/curl)
S="$ARENA_WORKSPACE"/oc-rotate/oc-rotate-fixed.sh
export PATH=""$ARENA_WORKSPACE"/oc-rotate/test/home/.local/bin:"$ARENA_WORKSPACE"/oc-rotate/test/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export TESTHOME="$ARENA_WORKSPACE"/oc-rotate/test/home
export TESTLOG=$TESTHOME/testlog IPCOUNTER=$TESTHOME/ipcount COUNTER=$TESTHOME/callcount
export LIMIT_UNTIL=$TESTHOME/limit MODE=$TESTHOME/mode MULLVAD_STATUS=$TESTHOME/mstatus
export HOME=$TESTHOME BIN_DIR=$TESTHOME/.local/bin
export RUN_DIR=$TESTHOME/.config/oc-rotate/run
clean() { rm -f "$TESTLOG" "$IPCOUNTER" "$COUNTER" "$MODE"; echo 0 > "$LIMIT_UNTIL"; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
t() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
echo "Connected to se-got-wg-001" > "$MULLVAD_STATUS"

t "T1 install: symlink oc-hop (FIX-1)"
clean; rm -f "$BIN_DIR/oc-hop" "$BIN_DIR/oc-rotate" "$RUN_DIR/oc-rotate.log"
bash $S install 2>&1 | strip | grep -E 'symlink|binarka|gotowe|problemów'
ls -l "$BIN_DIR/oc-hop"

t "T1b oc-hop przez symlink działa"
clean; oc-hop 2>&1 | strip | grep -E 'oc-hop|IP (przed|po)|gotowe'

t "T2 run: limit na 2 modelach -> 3. model (ścieżka podstawowa)"
clean; echo 2 > "$LIMIT_UNTIL"
bash $S run "napraw build" 2>&1 | strip | grep -E 'próba|SUKCES|następny model'

t "T3 MAX_ROTATIONS=1 robi DOKŁADNIE 1 rotację (FIX-1 off-by-one)"
clean; echo 99 > "$LIMIT_UNTIL"; MAX_ROTATIONS=1 MAX_ATTEMPTS=9 SETTLE=0 \
  bash $S run "x" 2>&1 | strip | grep -E 'rotacje=|KONIEC'

t "T4 pusta pula modeli: czytelny błąd zamiast 'unbound variable' (FIX-2)"
clean; cat > "$TESTHOME/.config/oc-rotate/config.sh" <<'CFG'
VPN_BACKEND="none"
MODELS=()
AUTO_MODELS=0
CFG
bash $S run "x" 2>&1 | strip | tail -5; echo "rc=${PIPESTATUS[0]}"
echo "-- status z pustą pulą --"; bash $S status >/dev/null 2>/tmp/st.err; echo "rc=$?"; tail -2 /tmp/st.err | strip
rm -f "$TESTHOME/.config/oc-rotate/config.sh"

t "T5 prompt zaczynający się od '-' (FIX-4)"
clean; echo 0 > "$LIMIT_UNTIL"
bash $S run "--verbose build fix" >/dev/null 2>&1
grep -a 'FAKE-OC: run' "$TESTLOG" | tail -1

t "T6 timeout: osobna gałąź + brak sierot (FIX-5)"
clean; echo hang > "$MODE"
time (CMD_TIMEOUT=2 MAX_TIMEOUTS=2 MAX_ATTEMPTS=4 BACKOFF_BASE=1 \
  bash $S run "x" 2>&1 | strip | grep -E 'timeout|za dużo|KONIEC')

t "T6b sieroty po timeout"
clean; echo orphan > "$MODE"
CMD_TIMEOUT=2 MAX_ATTEMPTS=1 bash $S run "x" >/dev/null 2>&1
sleep 1; cp=$(cat /tmp/child.pid 2>/dev/null)
if [ -n "$cp" ] && kill -0 "$cp" 2>/dev/null; then echo "ORPHAN ALIVE pid=$cp"; kill "$cp" 2>/dev/null; else echo "brak sierot (grupa procesów zabita)"; fi
rm -f /tmp/child.pid

t "T7 fałszywy '429' w odpowiedzi modelu przy rc=0 (FIX-3)"
clean; echo dash429 > "$MODE"
MAX_ATTEMPTS=3 bash $S run "x" 2>&1 | strip | grep -E 'rc=0|SUKCES|rotacja|KONIEC'
echo "ile razy ruszono mullvada: $(grep -ac 'FAKE-MULLVAD' "$TESTLOG")"

t "T8 powtarzalny błąd != limit: backoff i koniec (FIX-5)"
clean; echo fail > "$MODE"
MAX_OTHER_FAILS=2 MAX_ATTEMPTS=5 BACKOFF_BASE=1 \
  bash $S run "x" 2>&1 | strip | grep -E 'błąd inny|za dużo|connection reset'

t "T9 log nie jest kasowany przy każdym run (FIX-6)"
clean; echo 0 > "$LIMIT_UNTIL"
bash $S run "pierwszy" >/dev/null 2>&1
bash $S run "drugi"   >/dev/null 2>&1
echo "wpisów '=== run' w logu: $(grep -ac '=== run' "$RUN_DIR/oc-rotate.log")"

t "T10 relay cooldown: brak powtórek z rzędu (FIX-8)"
clean; rm -f "$RUN_DIR/relays-used"
for i in 1 2 3 4 5 6; do oc-hop >/dev/null 2>&1; done
echo "wylosowane releje:"; cat "$RUN_DIR/relays-used"

t "T11 niezapisywalny OUT_FILE -> twardy błąd na starcie (FIX-7)"
clean; OUT_FILE=/nonexistent/x.out LOG_FILE=/nonexistent/x.log bash $S run "x" 2>&1 | strip | head -3
OUT_FILE=/nonexistent/x.out LOG_FILE=/nonexistent/x.log bash $S run "x" >/dev/null 2>&1; echo "rc=$?"

t "T12 nieznana komenda -> rc=2 (FIX-16)"
bash $S foobar >/dev/null 2>&1; echo "rc=$?"

t "T13 OC_DISABLE_ROTATION=1 (FIX-15)"
clean; echo 99 > "$LIMIT_UNTIL"
MAX_ATTEMPTS=5 OC_DISABLE_ROTATION=1 bash $S run "x" 2>&1 | strip | grep -E 'DISABLE|kończę|rotacja IP'
echo "mullvad wywołany razy: $(grep -ac 'FAKE-MULLVAD' "$TESTLOG")"

t "T14 stdin i plik jako prompt"
clean; echo 0 > "$LIMIT_UNTIL"; printf 'tresc z pliku\n' > /tmp/p.txt
bash $S run /tmp/p.txt >/dev/null 2>&1; grep -a 'FAKE-OC: run' "$TESTLOG" | tail -1
bash $S run < /tmp/p.txt >/dev/null 2>&1; grep -a 'FAKE-OC: run' "$TESTLOG" | tail -1

t "T15 doctor"
clean; bash $S doctor 2>&1 | strip | grep -E '^.*(OK|WARN|ERR)' | head -20
