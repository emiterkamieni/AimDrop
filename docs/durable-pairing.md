# Trwałe parowanie — stan 6 listopada 2026

## Zakres potwierdzenia

**Działa w lokalnych, rzeczywistych procesach natywnych:** pierwsze parowanie
PIN-em, zapis obu tożsamości, restart serwera, wzajemne PairVerify bez PIN-u,
zaszyfrowane uzyskanie endpointu i żądanie `/Discover` przez HTTP/3 do backendu.

**Potwierdzone fizycznym iPhonem:** pierwszy transfer z logo i PIN-em, następnie
restart procesu i kolejny transfer bez kodu. Użytkownik potwierdził oba wyniki.
Log `.build/durable-pairing-restart-zgkv3e42.log` zawiera `pair_verify_authenticated`,
`pair_verify_encrypted_endpoint_delivered` i `/Upload` HTTP 200, bez pre-pairingu.
Po restarcie przesłano 426 704 974 bajty; backend opublikował 5 plików.

Zwykła aplikacja zawiera ten transport od 0.5.0. Jej log potwierdził fizyczny
transfer 5 plików / 426 703 351 bajtów. W 0.5.2 sprawdzono również zmianę nazwy
z nowym PIN-em i poprawne połączenie po restarcie z niezmienioną nazwą.
Użytkownik potwierdził nową nazwę/PIN oraz końcowy restart bez kodu.

## Zapis

`scripts/research/pairing-store.swift` zapisuje obecnie `identity.json` wersji 4
w katalogu wskazanym przez `AIRFOLDER_PAIRING_STATE_DIR`. Bez tej zmiennej
izolowane starsze próby nadal używają tożsamości w pamięci.
Pakiet podaje katalog jawnie: `~/Library/Application Support/AirFrajer/Pairing/`.
Wersja 3 dodała `presentedName`; wersja 4 dodaje fingerprint awatara. Migracja
v3 z dotychczasową nazwą i domyślnym logo zachowuje wszystkie klucze i peerów.
Po migracji restart z tą samą nazwą i obrazem nie zmienia pliku. Starsze magazyny
1/2 odnawiają tożsamość zgodnie z wcześniejszą polityką naprawy testowej nazwy.
Szczegóły obrazu, ustawień i migracji: [awatar odbiorcy](receiver-avatar.md).

Zapis zawiera wyłącznie tożsamość wygenerowaną przez AirFolder oraz publiczne
tożsamości przekazane po prawidłowym PIN-ie:

- własny seed Ed25519, identyfikatory serwera i urządzenia trwałe dla danej nazwy;
- dokładny IRK i datę przekazane przy wymianie tożsamości;
- klucze publiczne, identyfikatory, IRK, daty dodania i ważności peerów.

Zmiana nazwy tworzy nowy seed, IRK i identyfikatory, czyści wcześniejsze
rejestracje peerów oraz unieważnia oczekujące poświadczenia PIN. Dotychczasowe
parowanie musi zostać odrzucone przed nową wymianą PIN-em. Bufor plików jest
odrębnym magazynem; zmiana nazwy go nie modyfikuje.

PIN i sesje szyfrowania nie są utrwalane. Nowe parowanie przy tej samej nazwie nie usuwa innych
ważnych peerów. Ponowne połączenie nie przedłuża ważności wpisu.
Domyślna ważność wynosi 30 dni od wymiany PIN-em, zgodnie z natywnym
`rapportd:0x10011ca04` (30 dni kalendarzowych). To parowanie czasowe;
po wygaśnięciu może być potrzebny nowy PIN.

Katalog ma prawa 0700, pliki 0600; otwarcie odrzuca symlinki, nieprawidłowego
właściciela, hardlinki i zbyt duże dane. `flock` wyklucza równoczesnych pisarzy.
Zapis: nowy plik, synchronizacja, atomowe `renameat`, synchronizacja katalogu.
Nieprawidłowy/nieczytelny istniejący zapis zatrzymuje uruchomienie zamiast
generować nowy klucz i tracić wcześniejsze parowania. Diagnostyka nie wypisuje
seedu ani treści magazynu.

## PairVerify i resolve

- RPC działają na `_appSvcPrePair._tcp`, pod nazwą modułu `rapportd`.
  Self-signed TLS jest transportem; uwierzytelnienie daje PairVerify.
- `pair-verify-bridge.m` używa `CUPairingSession`: flags `0x400000`,
  typ 4 serwer / 3 klient. Callback podpisuje 64 bajty kluczy efemerycznych
  własnym Ed25519. Weryfikacja sprawdza tylko niewygasłe, zapisane klucze peerów.
- Kolejność argumentów verify to `(flags, data, signature, error)`.
  Błędny podpis zwraca `-6754`, bez fallbacku do tożsamości systemowych.
- Zachowany jest ostatni komunikat M4 razem z wynikiem ukończenia silnika.
- Każda sesja UUID ma osobny silnik, timeout, sprawdzonego peera, zgodę na
  strumień i liczniki szyfrowania. Limit: 16 sesji / 60 s, wymiana: 10 s.
  Równoczesne operacje tej samej sesji są odrzucane. Sesje są czyszczone leniwie
  przy następnej operacji; proces przechowuje najwyżej 16 silników.
- Obsługiwane są warianty RPC z UUID i legacy. Drugi aktywny legacy start
  jest odrzucany; `resolveBonjourCompleted` zwalnia zakończoną sesję legacy.
- Strumień `RPPairingPairVerifyStream` używa natywnego szyfrowania z AAD
  `rppairing-bonjour-resolve`. Request po odszyfrowaniu to surowy klucz QUIC,
  response to JSON (`serverPublicKey` base64, `bonjourServiceID` UUID).
- Błąd uwierzytelnienia lub odszyfrowania unieważnia daną sesję.

## Weryfikacja

```sh
python3 scripts/research/build-pairing-prototypes.py
python3 scripts/research/test-persistent-pairing.py
python3 scripts/research/test-pairing-prototype.py
python3 scripts/research/test-http3-prototype.py
python3 scripts/build.py
python3 scripts/native-smoke.py
```

Wszystkie powyższe sprawdzenia przeszły po dodaniu trwałego parowania:

- osobne magazyny klienta i serwera, wzajemna rejestracja przez PAKE;
- drugi klient nie usuwa pierwszego parowania; obaj łączą się po restarcie;
- migracja starego magazynu jest jednorazowa; następny start zachowuje zapis;
- identyczny zapis i brak wywołania PIN-u po restarcie;
- PairVerify, szyfrowany resolve i rzeczywiste `h3`, także w następnej sesji;
- błędny klucz, wygasła tożsamość, resolve przed uwierzytelnieniem i bez
  zamówionego strumienia — odrzucone;
- replay, ciphertext innej sesji, ponowne użycie odrzuconej sesji — odrzucone;
- legacy: ochrona przed nakładającymi się startami i druga poprawna sesja;
- blokada magazynu, uszkodzony JSON, złe prawa i symlink — odrzucone;
- dotychczasowy błędny PIN nadal odrzucony;
- znana długość i chunked: 8 MiB, zgodny SHA-256, trwały Inbox, postęp przed EOF;
- anulowanie przy pierwszym postępie: przerwanie źródła, brak gotowej paczki.

Testy korzystają z własnych kluczy i izolowanych katalogów `.build/`.
Nie odczytują tożsamości konta Apple.

## Zwykła aplikacja

`AppKit → receiver/main.py → AirFolderReceiver`. Python uruchamia natywny
proces dopiero po związaniu backendu HTTPS na `[::1]:port`; port jest dynamiczny.
Gotowość UI wymaga gotowości obu usług parowania oraz listenera plików.
Natywne `pin`/`pin_closed` trafiają przez IPC do `PairingWindowController`.
Kod nie jest zapisywany do dziennika. EOF i zamknięcie Pythona zatrzymują helper;
śmierć helpera zgłasza błąd odbiornika. Zmiana nazwy wymienia tożsamość,
zatrzymuje stare aktory parowania i publikuje nowe, aktualizując odpowiedzi
backendu. Listener plików pozostaje oddzielny od odświeżanych usług parowania.

Helper korzysta z bezwzględnej ścieżki do PNG w Resources, stałej tożsamości
i własnego modułu `rapportd`. Wspólne źródła są kompilowane z `AIRFOLDER_HELPER`,
które wyłącza testowy punkt wejścia i testowe okno. Brak godzinnego limitu pracy.
Podpisywane są osobno helper i zewnętrzny pakiet, bez prywatnych entitlements.

`scripts/native-smoke.py` uruchamia gotową paczkę poza katalogiem projektu,
z odrębnym buforem i magazynami kluczy. Sprawdza PIN przez IPC, brak kodu
w logu, zmianę nazwy, odrzucenie starego parowania, nowy PIN, brak resetu przy
zapisie tej samej nazwy, szyfrowany resolve, upload HTTP3 i SHA-256, odłożenie
paczki, restart bez PIN-u, zapis do folderu, shutdown, EOF, SIGKILL Pythona,
SIGKILL helpera i zakończenie podczas startu. W fixture każdy request otwiera
nowe QUIC z nowym kluczem i resolve; iPhone normalnie używa wielu strumieni
w istniejącym połączeniu.

## Dlaczego potrzebny był pełny reset przy zmianie nazwy

Pierwsza wymiana tożsamości zapisuje na iPhonie tymczasowy kontakt z nazwą i
logo. Samo zaktualizowanie TXT `dnm`/odpowiedzi `/Discover` nie zmieniało jego
nazwy. Read-only `check-advertised-name.swift` potwierdził prawidłową nazwę
w Bonjour, podczas gdy iPhone pokazywał dawny kontakt „AirFolder”.

Próba 0.5.1 wymieniła IRK i identyfikatory, zachowując seed i zaufane klucze.
To było niewystarczające: log nadal zawierał udane PairVerify, a użytkownik
nie widział nowego PIN-u. Dlatego od 0.5.2 zmiana nazwy wymienia pełną tożsamość
i listenerów parowania. Test paczki wprost próbuje starego PairVerify **przed**
nowym PIN-em i wymaga odrzucenia, następnie sprawdza nowy PIN i trwały restart.

Fizyczna próba 0.5.2: użytkownik potwierdził „Tak, nowa nazwa i PIN”. Log zawiera
dwie nowe wymiany PIN-em i zakończone transfery 5 plików (426 706 912 oraz
426 705 014 bajtów), w tym po zmianie nazwy w działającej aplikacji. Ostatecznie
pozostawiona nazwa to „PAJONK”. Restart całej aplikacji zachował identyczny plik
parowania; użytkownik potwierdził „Tak, działa bez PIN-u”. Po restarcie w logu
jest PairVerify i zaszyfrowany resolve, bez wywołania `exchangePAKEIdentities`.
Ostatni transfer po tym restarcie został anulowany podczas odbierania
(`receiving` 09:27:18.833 UTC, `Upload canceled` 09:27:22.208 UTC). Ta próba
potwierdza ponowne uwierzytelnienie i rozpoczęcie odbioru bez kodu; pełne
zakończone transfery najnowszej wersji potwierdzają dwie wcześniejsze próby.
