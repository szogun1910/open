# oc-rotate 1.2.0 — przegląd i łatki

Wszystkie błędy poniżej zostały **odtworzone testem** (podrobione binarki `opencode`,
`mullvad`, `curl` w `test/bin/`), a potem potwierdzone jako naprawione.
Skrypt po łatkach: `oc-rotate.sh` (v1.3.0). Oryginał: `oc-rotate-1.2.0.sh`.

```
bash -n          OK
shellcheck 0.11  0 uwag (-S style)
harness          36/36 (2 "FAIL" = błędy samego harnessa, patrz na dole)
```

---

## Krytyczne (skrypt nie robi tego, co obiecuje)

### 1. `oc-hop` to symlink do samego siebie — nie działa w ogóle
```bash
ln -sf "oc-hop" "$BIN_DIR/oc-hop"
```
Efekt z `install`:
```
lrwxrwxrwx oc-hop -> oc-hop
$ oc-hop
bash: /home/user/.local/bin/oc-hop: Too many levels of symbolic links
```
Drugi z dwóch głównych trybów pracy (rotacja w TUI) był martwy od pierwszego
uruchomienia. Poprawnie: `ln -sfn "oc-rotate" "$BIN_DIR/oc-hop"`.
`install` w 1.3.0 dodatkowo naprawia pętlę zostawioną przez 1.2.0, a `doctor` ją wykrywa.

Przy okazji: `case "$(basename "$0")"` działa tylko dla nazwy wywołania — `readlink -f`
w `SELF` rozwiązuje symlink, więc dispatch sprawdza teraz obie nazwy.

### 2. Fałszywy alarm na `429` → nieskończona pętla rotacji IP przy **udanym** zadaniu
```bash
is_rate_limited() { grep -qiE '...|429|...' "$OUT_FILE"; }
...
(( rc == 0 )) && ! is_rate_limited && return 0
```
Gołe `429` jest szukane w **całym** outpucie modelu. Jeśli agent napisze
"serwer zwrócił kod 429", "linia 429", "port 42900" — skrypt mimo `rc=0` uznaje
limit i wchodzi w rotację VPN. Odtworzone:
```
próba 1 | model=…  ->  mullvad -> se-got-wg-002  ->  IP po: 203.0.113.9
próba 2 | model=…  ->  mullvad -> se-got-wg-001  ->  …
ERR  KONIEC bez sukcesu (próby=2, rotacje=2)      # zadanie wykonane poprawnie!
```
W 1.3.0: `rc == 0` **zawsze** znaczy sukces (z ostrzeżeniem, jeśli output pasuje do
wzorca), a samotne `429` musi mieć kontekst HTTP (`status/code/HTTP/error … 429`,
`429 Too Many Requests`). Wzorzec jest w `RATE_LIMIT_RE` i da się go nadpisać w configu.

### 3. Pusta pula modeli = crash zamiast komunikatu
```
$ oc-rotate run "test"
oc-rotate: line 282: MODELS[$mi]: unbound variable     # rc=1
$ oc-rotate status
oc-rotate: line 368: MODELS[0]: unbound variable       # rc=1
```
Osiągalne przez `MODELS=()` w configu, `MAX_MODELS=0`, albo `OC_MODELS=" "`
(`read -r -a` z pustego wejścia zeruje tablicę). W 1.3.0: czytelny błąd z podpowiedzią,
`status` drukuje `(pusta pula …)` i zwraca 0.

### 4. `MAX_ROTATIONS` robi o jedną rotację za dużo
`while (( attempt < MAX_ATTEMPTS && rotations <= MAX_ROTATIONS ))` + `rotations++` **po**
rotacji. Dla `MAX_ROTATIONS=1`:
```
1.2.0:  KONIEC bez sukcesu (próby=6, rotacje=2)   # zamówiona 1
1.3.0:  KONIEC bez sukcesu (próby=3, rotacje=1)
```

### 5. Prompt zaczynający się od `-` jest zjadany jako flaga
Brak `--` przed promptem:
```
$ oc-rotate run "--verbose build fix"
FAKE-OC: run --model … --verbose build fix        # prompt zniknął, flagi przejęte
$ oc-rotate run "-m anthropic/claude-sonnet-4"    # podmiana modelu!
```
W 1.3.0 argumenty idą w tablicy i prompt jest po `--`.

---

## Poważne

### 6. `timeout` nie jest rozpoznawany jako timeout
`rc=124` wpadał do gałęzi "błąd inny niż limit" → retry **tego samego modelu** co 5 s,
bez backoffu, do `MAX_ATTEMPTS=300`. Przy `CMD_TIMEOUT=900` to 75 h kręcenia się w miejscu.
Teraz: osobna gałąź, `MAX_TIMEOUTS`, `MAX_OTHER_FAILS`, backoff wykładniczy
(`BACKOFF_BASE` … `BACKOFF_MAX`), ogon błędu drukowany w logu.

`timeout --foreground -k N` dokłada SIGKILL i trzyma opencode w naszej grupie procesów.
**Uczciwe zastrzeżenie:** to nie gwarantuje śmierci procesów, które same robią
`setsid()` — w teście `sleep &` wewnątrz fałszywego opencode przeżywał zarówno
z `--foreground`, jak i bez. Pełne rozwiązanie (setsid + `kill -- -PGID`) kosztuje
przekazywanie TTY, więc go nie włączyłem.

### 7. Mullvad: rotacja weryfikowana zanim tunel wstanie
`mullvad reconnect` wraca natychmiast, a IP było sprawdzane po sztywnych `sleep 4`.
Jeśli tunel spinał się dłużej, pętla robiła kolejne ślepe reconnecty ("IP bez zmian
(próba 1/5)"), każdy po ~10 s. W 1.3.0: `mullvad_wait_connected` odpytuje
`mullvad status` aż do `Connected` (limit `VPN_WAIT`), a dopiero potem leci `get_ip`.

Dodatkowo:
- `mullvad relay set hostname` to stara składnia — 2026.x używa `relay set location <host>`.
  Teraz próbujemy nową, stara jest fallbackiem.
- stderr z `mullvad` był połykany (`>/dev/null 2>&1`), więc prawdziwy powód
  ("Failure to select a matching tunnel relay") nigdy nie trafiał do logu.
- `shuf -n1` potrafił wylosować **ten sam** relay dwa razy z rzędu. Jest cooldown
  (`RELAY_COOLDOWN`) + fallback LRU, gdy pula jest mniejsza niż cooldown. Test: 8 obrotów,
  0 powtórek z rzędu.

### 8. `rotate_proton` gubi kod wyjścia
```bash
if [[ "$bin" == "protonvpn" ]]; then "$bin" connect --random >/dev/null 2>&1
else "$bin" connect -r >/dev/null 2>&1; fi
```
Funkcja zwraca status ostatniego polecenia w `if/else` — cichy błąd connect wyglądał
jak udana rotacja, a `rotate_and_verify` i tak meldował sukces, bo IP "się zmieniło".

### 9. `/tmp/oc-rotate.out` i `/tmp/oc-rotate.log`
Na współdzielonej maszynie cudzy plik = `EACCES`. Wtedy `tee` nie pisze, `OUT_FILE`
zostaje z **poprzedniego** runa, a `is_rate_limited` czyta stare dane i podejmuje
decyzje na ich podstawie. Dodatkowo `tee` sypał swoje błędy na stdout, mieszając je
z odpowiedzią modelu (która jest na stdout i bywa pipowana dalej).
W 1.3.0: `RUN_DIR=~/.config/oc-rotate/run` (0700), test zapisywalności na starcie
(twardy błąd + rc=1), `log()` pisze przez jeden FD otwarty raz, odpowiedzi modelu
nic nie zaśmieca.

### 10. Log kasowany przy każdym `run`
`: > "$LOG_FILE"` na początku `cmd_run` — historia znikała. Teraz dopisujemy
`=== run v1.3.0 <data> ===`.

### 11. `find "$HOME" -maxdepth 5` przy każdym wywołaniu
`resolve_oc_bin` leciał zawsze, gdy opencode nie było w PATH — także dla
`oc-rotate --help`. Bez limitu czasu, bez prunowania `node_modules`/`.cache`,
i brał **pierwszy** trafiony plik (np. `./node_modules/.bin/opencode`).
Teraz szybka ścieżka (PATH + znane lokalizacje) zawsze, a `find` tylko w `locate`,
z `timeout 20` i prunowaniem.

### 12. `rotate_and_verify` "potwierdza" rotację, gdy nie zna IP przed
Gdy `api.ipify.org` nie odpowiadał, `before=""`, więc dowolne `after` spełniało
`"$after" != "$before"`. Teraz brak `before` jest jawnie zgłaszany jako
"nie zweryfikuję rotacji".

---

## Mniejsze

| # | Problem | W 1.3.0 |
|---|---------|---------|
| 13 | `opencode models` bez timeouta mógł zawiesić start; `status` wołał autodetect 2× | `timeout $MODELS_TIMEOUT`, cache per proces |
| 14 | `c` w `deps_check`/`cmd_doctor` bez `local` — wyciek do globala | `local c` |
| 15 | `OC_EXTRA_ARGS="--cwd …"` w szablonie configu — **nieistniejąca flaga** (`run` ma `--dir` w v1 / `--directory` w v2); każdy run kończyłby się błędem parsera czytanym jako "inny błąd" | szablon poprawiony, argumenty w tablicy |
| 16 | Nieznana komenda → help i **rc=0** (literówka w CI przechodzi jako sukces) | rc=2 |
| 17 | `oc_version`/`mullvad --version`/`mullvad status` bez timeouta | `timeout 10` |
| 18 | ANSI z `opencode models` mogło rozbić filtr `grep -E '^[A-Za-z0-9._-]+/…$'` | `sed 's/\x1b\[[0-9;]*m//g'` przed filtrem |
| 19 | Brak wyjścia awaryjnego "nie ruszaj VPN" | `OC_DISABLE_ROTATION=1` |

---

## Pułapka basha znaleziona po drodze (warto znać)

```bash
if exec {LOG_FD}>>"$LOG_FILE" 2>/dev/null; then ...   # ❌ gasi stderr NA STAŁE
{ exec {LOG_FD}>>"$LOG_FILE"; } 2>/dev/null           # ✅
```
Przy `exec {zmienna}>>plik 2>/dev/null` przekierowania są stosowane lewo-prawo i przy
alokacji dynamicznego FD potrafi trafić w fd 2 — efekt: od tej linii **cały stderr
procesu znika** (a trace `bash -x` urywa się na `+ exec`). Objaw: skrypt działa,
log się pisze, na terminalu cisza.

Druga pułapka, na którą naciąłem się w harnessie: `PIPESTATUS` jest kasowane przez
**każde** kolejne podstawienie, więc `out=$(cmd | f); rc=${PIPESTATUS[0]}` daje rc
z `f`, nie z `cmd`. Trzeba `rc=$?` bezpośrednio po potoku (albo `${PIPESTATUS[0]}`
w tym samym poleceniu).

---

## Ryzyko po stronie usługi (nie błąd kodu)

Rotacja IP w celu zresetowania limitu darmowych modeli Zen jest obejściem limitów
użycia. ToS OpenCode, sekcja "Are there restrictions in how I can use the Services?",
pkt 4 zabrania używania wielu kont *"to circumvent usage limits, access restrictions,
billing obligations, promotions, suspensions, or any other restriction or policy"*,
a pkt 10 procesów *"that otherwise interfere with the proper working of the Services
(including by placing an unreasonable load on the Services' infrastructure)"*.
Sankcja wprost: *"A violation of any of the foregoing is grounds for termination of
your right to use or access the Services."*

Nie odmawiam — to Twój wybór i Twoje konto — ale dodałem do `help` sekcję z tym
ryzykiem i z legalnymi alternatywami (własny klucz providera przez `opencode auth
login`, płatny Zen/budżet w Console, `OC_DISABLE_ROTATION=1` żeby zostawić samo
przełączanie modeli). Część "przełączanie modeli" jest zupełnie nieszkodliwa i to
ona robi większość roboty.

Źródła: https://opencode.ai/legal/terms-of-service ·
https://opencode.ai/docs/cli/ · https://mullvad.net/en/help/cli-command-wg

---

## Jak przetestować u siebie

```bash
cd oc-rotate
bash test/run-tests.sh          # harness z podrobionym opencode/mullvad/curl
S=./oc-rotate.sh bash test/run-tests.sh
```
Harness nadpisuje `PATH`, `HOME`, `BIN_DIR` i `RUN_DIR` na `test/home/`, więc nie
tyka prawdziwej konfiguracji. Uwaga: w tej piaskownicy ścieżki absolutne w plikach
tworzonych przez narzędzia bywają przepisywane — jeśli harness nagle zgłosi
`No such file or directory` dla skryptu, odpal go z `S=` wskazującym ścieżkę względną.

## Nowe zmienne (wszystkie z domyślnymi wartościami)

```
KILL_GRACE=10          SIGKILL po tylu sekundach od SIGTERM
MAX_OTHER_FAILS=3      ile błędów "innych niż limit" pod rząd
MAX_TIMEOUTS=3         ile timeoutów pod rząd
BACKOFF_BASE=5         pierwszy backoff (5s, 10s, 20s…)
BACKOFF_MAX=120
MODELS_TIMEOUT=45      timeout na `opencode models`
VPN_WAIT=40            ile czekać na "Connected" po reconnect
RELAY_COOLDOWN=8       ilu ostatnich relayów nie losować ponownie
RELAY_SEEN_FILE=…      gdzie trzymać historię relayów
RATE_LIMIT_RE=…        wzorzec limitu (patrz FIX-3)
RUN_DIR=…              katalog roboczy (0700)
OC_DISABLE_ROTATION=0  1 = tylko przełączanie modeli, bez VPN
```
