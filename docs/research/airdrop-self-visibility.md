# AimDrop widoczny na własnym Macu — próby 2026-11-08

## Wynik

**Znaleziono działający lokalnie kierunek: ogłoszenia mDNS bezpośrednio przez
AWDL, bez rejestracji Bonjour i z wyłączonym multicast loopback.**
Natywny eksperyment wykrywa oba kontrolne typy usług, a nie wykrywa obu
wariantów z wyłączonym loopbackiem. **Taki sam wynik potwierdzono na rzeczywistym
testowym odbiorniku z PIN i HTTP3, uruchomionym jako aplikacja, oraz na fizycznym
iPhonie. Użytkownik potwierdził wysłanie pliku i brak testowego odbiornika
w AirDrop na tym samym Macu.**

Samo wykluczenie loopbacku z parametrów Network albo ograniczenie zwykłej
rejestracji Bonjour do AWDL nie pomaga. Wcześniejszy eksperyment z pakietami
wysyłanymi przez Pythona był nierozstrzygający. Dopiero natywna próba ze
sprawnym wariantem kontrolnym dała wynik opisany w sekcji 3.

System: macOS 26.5.2 (25F84), Apple Silicon. W czasie prób uruchomiony był
AimDrop 0.8.4 z `/Applications/AimDrop.app`. Próby używały losowych nazw i
syntetycznej usługi `pl.aimdrop.self-discovery-probe`; nie korzystały z
magazynu parowania, skrzynki odbiorczej ani ustawień użytkownika.

## Skąd bierze się lokalna pozycja

`NativeReceiver/helper.swift` publikuje dwóch aktorów Network:

- `_appSvcPrePair._tcp` — przed parowaniem;
- `_applicationServicePairing._tcp` — parowanie / ponowne uwierzytelnienie.

Reklamy zawierają nazwę usługi AirDrop oraz identyfikator i znacznik
uwierzytelnienia osobnej tożsamości AimDrop. `PairingStore` tworzy jej własne
UUID-y, klucz podpisujący i IRK. Lokalne Bonjour widzi także usługi opublikowane
przez procesy tego samego komputera.

Przekazywanie plików do Pythona przez loopback jest innym etapem. Blokowanie
połączeń lokalnych nie oznacza usunięcia ogłoszenia z katalogu odbiorców.

## Rozpoznawanie siebie w systemie

Analiza statyczna `/usr/libexec/rapportd`, arm64e, wskazała:

- `RPPairingClient.selfRPIdentity` — pole o offsecie 104; metadane offsetu
  pod `0x1001fb360`.
- Funkcja rozpoczynająca się pod `0x1000c7938` pobiera tę tożsamość oraz
  dane z rekordu TXT odbiornika. Pod `0x1000c7a40` wywołuje
  `verifyAuthTag:data:type:error:` z typem **6**. Dane pochodzą z UTF-8
  identyfikatora serwera.
- Po pozytywnej weryfikacji gałąź zawiera komunikat
  `Skipping PairVerify for our own bonjour device` (`0x1000c7af0`).

To dowód kryptograficznego rozpoznawania własnej usługi w tej ścieżce
PairVerify, **nie dowód kompletnego filtrowania interfejsu AirDrop** ani
przełącznika dostępnego aplikacji. Znacznika AimDrop nie można zastąpić
znacznikiem systemowym bez oceny skutków dla rozpoznawania tożsamości i parowania.
Wcześniejsze próby dostępu do systemowych tożsamości zostały odrzucone z powodu
braku uprawnienia Apple — patrz [badanie własnych urządzeń](airdrop-own-devices.md).

Inny napis `Ignoring our own Bonjour device` (`0x1000a4c88`) dotyczy porównania
pola `rpBA` w ścieżce Companion Link. Sam jego znaleziony tekst nie dowodzi
istnienia analogicznego parametru dla naszych dwóch usług parowania.

Zrzuty robocze i pomocnik do dekodowania selektorów Objective-C znajdują się
w `.build/self-discovery/`. Są materiałem statycznym z binarek systemowych,
bez zrzutów pamięci procesów ani kluczy użytkownika.

## 1. Próba zakresu publikacji — wynik negatywny

Źródło: `scripts/research/self-discovery-probe.m`.

Ośmiosekundowy proces uruchamia po dwa listenery TCP dla każdego wariantu,
z odrębnymi, losowymi nazwami. Równolegle przegląda oba rzeczywiste typy usług
przez Network, z włączonym odczytem TXT i `includePeerToPeer`. Syntetyczne
`sn` zapobiega traktowaniu próby jako rzeczywistego odbiornika AirDrop.
Przychodzące połączenia są odrzucane; parowanie nie jest wykonywane.

| Publikacja | Gotowość i reklama | Pre-pair widoczny lokalnie | Pairing widoczny lokalnie |
| --- | --- | --- | --- |
| Network, parametry obecnej publikacji | tak | tak | tak |
| Network, dodatkowo zakaz interfejsu loopback | tak | tak | tak |
| DNSServiceRegister, dowolny interfejs + P2P/AWDL | tak | tak | tak |
| DNSServiceRegister, wyłącznie indeks `awdl0` | tak | tak | tak |

Wariant Network z zakazem loopbacku nadal zwrócił wynik na `lo0`, `en0`,
`en1` i `awdl0`. Zakaz transportowy nie ograniczył w ten sposób reklamy.
Wariant AWDL-only został zwrócony na `awdl0` **temu samemu lokalnemu procesowi**.
Wszystkie osiem rejestracji zakończyło się bez błędu i zostało usuniętych
przy zakończeniu próby.

Jest to test odkrywania Bonjour, a nie pomiar zawartości okna Findera ani
próba z fizycznym iPhonem. Odrzuca założenie, że samo takie ograniczenie
publikacji usuwa lokalny wynik odkrywania.

Odtworzenie z katalogu projektu:

```sh
mkdir -p .build/self-discovery
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework Network scripts/research/self-discovery-probe.m -o .build/self-discovery/probe
.build/self-discovery/probe
```

Kod 0 oznacza poprawne uruchomienie eksperymentu. O skuteczności ukrycia mówi
osobno pole `visible_locally`, które w wykonanej próbie wynosiło **1** dla
każdego wariantu.

## 2. Bezpośredni multicast — wynik nierozstrzygający

Źródła:

- `scripts/research/self-discovery-observer.swift` — obserwator wyłącznie
  syntetycznych nazw z prefiksem danej próby;
- `scripts/research/self-discovery-multicast.py` — wysyła krótkotrwałe
  ogłoszenia PTR/SRV/TXT/AAAA przez aktywne interfejsy IPv6, z włączonym
  i wyłączonym `IPV6_MULTICAST_LOOP`.

Ogłoszenia nie są rejestrowane w `mDNSResponder`. Wykonana próba nie wykryła
żadnego wariantu, a późniejsze wysłania kończyły się timeoutem socketu.
Wynik powtórzył się także przy użyciu Pythona dołączonego do zainstalowanego
AimDrop. Dodatkowa kontrola dwóch socketów UDP, na osobnym porcie i z
włączonym multicast loopback, nie odebrała własnego datagramu przez
`lo0`, `en1` ani `awdl0` w zadanym dwusekundowym oknie.
Nie ustalono przyczyny; nie przypisujemy jej automatycznie uprawnieniom,
filtrowaniu przez system ani skutecznemu wyłączeniu lokalnego odbioru.
Proces jawnie kończy się błędem **Inconclusive**, jeśli wariant kontrolny
nie jest widoczny. Tym samym nie daje fałszywego wyniku „ukrywanie działa”.

Skrypt nie jest pełnym responderem mDNS: nie obsługuje zapytań, sondowania
nazw, ponownej konfiguracji interfejsów ani uwierzytelniania AimDrop.
Używa TTL 10 sekund i próbuje wysłać rekordy goodbye przy zakończeniu.

```sh
xcrun swiftc -parse-as-library -module-cache-path .build/module-cache scripts/research/self-discovery-observer.swift -o .build/self-discovery/observer
python3 -B -u scripts/research/self-discovery-multicast.py
```

## 3. Natywny multicast — pozytywna kontrola i lokalne ukrycie

Źródło: `scripts/research/self-discovery-multicast.swift`, uruchamiane przez
`xcrun swift`. Każdy interfejs i wariant ma odrębną nazwę testową; pozwala to
odróżnić lokalny loopback od powrotu pakietu przez drugi interfejs.

| Interfejs wysyłający | Loopback włączony: widoczne typy | Loopback wyłączony: widoczne typy |
| --- | --- | --- |
| en0 | 2 | 2 |
| en1 | 2 | 2 |
| awdl0 | **2** | **0** |

Wyniki z `en0` zostały znalezione przez `en1`, a wyniki z `en1` przez `en0`.
Oba interfejsy są w tej samej sieci, więc ogłoszenia wracają przewodowo /
bezprzewodowo mimo wyłączenia lokalnego loopbacku socketu. To wyklucza
rozsyłanie takich ogłoszeń po wszystkich interfejsach jako rozwiązanie.
AWDL w wykonanej próbie zachował rozróżnienie oczekiwane przez eksperyment.

```sh
xcrun swift -module-cache-path .build/module-cache scripts/research/self-discovery-multicast.swift
# Można ograniczyć próbę do jednego interfejsu:
xcrun swift -module-cache-path .build/module-cache scripts/research/self-discovery-multicast.swift awdl0
```

### Otoczenie sieciowe wcześniejszych prób

Na Macu działają LuLu i systemowy firewall. W dzienniku LuLu z 19:44:04
znaleziono zgodę użytkownika dla Pythona dołączonego do AimDrop na multicast
`ff02::fb:5353`; odpowiednia trwała reguła pozwalająca istnieje. Samo jej
istnienie nie rozwiązało wszystkich timeoutów testu Pythonowego.
Natywna kontrola UDP przez Swift wykonała poprawną komunikację przez `en0`
i `en1`, a pełna próba Bonjour także przez AWDL. Nie zmieniano konfiguracji
firewalla, jego reguł ani ustawień VPN narzędziami automatycznymi.

**Dalsza kontrola wykazała drugi, konkretny czynnik: macOS Local Network Privacy.**
Ta sama próba po kompilacji do samodzielnego pliku nie działała, choć
uruchomiona przez systemowy interpreter działała. Po zapakowaniu do
`AimDropDiscoveryProbe.app` z identyfikatorem `pl.aimdrop.discovery-probe`,
`NSLocalNetworkUsageDescription` i `NSBonjourServices`, oraz uruchomieniu
przez LaunchServices, `nehelper` zarejestrował o 20:05:39:

```text
Showing local network alert for pl.aimdrop.discovery-probe even though not in the foreground
Local network preference not yet set, prompting for AimDropDiscoveryProbe (pl.aimdrop.discovery-probe)
```

Użytkownik potwierdził zgodę w systemowym oknie. Po ponownym uruchomieniu
**tego samego podpisanego pakietu** zniknęły błędy wysyłania i otrzymano
`baseline_types=2 remote_only_types=0`. Jest to mocniejszy dowód niż sam
brak odpowiedzi z nieautoryzowanego procesu. Pierwszy proces ze socketami
utworzonymi przed zgodą nie wznowił skutecznej pracy w swoim oknie testowym.

Oficjalne zasady: [Apple TN3179 — Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
Opisują m.in. przypisywanie odpowiedzialnej aplikacji, tożsamość podpisu oraz
osobne wymaganie dostępu lokalnego dla multicastu. Uprawnienie multicast
przeznaczone dla iOS nie jest wymagane na macOS.

## 4. Odbiornik do próby z telefonem

`--remote-only` w **badawczym** `airfolder-pairing-prototype` tworzy
`NWActorSystem(parameters:)` bez `NWListener.Service`. Aktor nadal publikuje
zdalne metody i nasłuchuje na TCP, ale nie rejestruje usługi w Bonjour.
`awdl-only-advertisement.swift` wysyła jego rzeczywiste porty i TXT wyłącznie
przez AWDL. Nazwa odbiornika to **AimDrop AWDL Test**.

Przeszedł lokalny test transportu:

- rzeczywista wzajemna wymiana tożsamości po PIN-ie;
- restart obu niezarejestrowanych listenerów przy zachowanej tożsamości;
- ponowne PairVerify i `/Discover` HTTP3 bez nowego PIN-u;
- niezmienione bajty testowego magazynu tożsamości po ponownym połączeniu.

```sh
python3 -B scripts/research/build-pairing-prototypes.py
python3 -B scripts/research/check-remote-discovery.py
xcrun swiftc -parse-as-library -module-cache-path .build/module-cache scripts/research/self-discovery-observer.swift -o .build/self-discovery/observer
python3 -B scripts/research/check-awdl-visibility.py
python3 -B -u scripts/research/remote-discovery-live.py --duration 1200
```

`check-awdl-visibility.py` porównuje surowe ogłoszenia rzeczywistych listenerów
z włączonym i wyłączonym multicast loopback. Używa syntetycznego `sn`, dzięki
czemu próba automatyczna nie pojawia się w AirDrop jako odbiornik plików.
`remote-discovery-live.py` używa już nazwy usługi AirDrop i izolowanego backendu;
kod PIN pokazuje osobny panel na Macu. Otrzymane pliki pozostają w
`.build/self-discovery/live/Incoming`, a testowe parowanie w sąsiednim `Pairing`.
Nie jest to magazyn działającej aplikacji.

Powyższe dwa ostatnie polecenia wymagają kontekstu uruchomienia z dostępem
do sieci lokalnej. W tej sesji wariant CLI automatycznego testu zatrzymał się
na niedziałającej kontroli. Potwierdzenie uzyskano następnie w pakiecie `.app`:

```sh
python3 -B scripts/research/build-remote-discovery-app.py
open -n --env AIRFOLDER_PROBE_DURATION_SECONDS=1200 .build/self-discovery/AimDropDiscoveryProbe.app --args --advertise --remote-only
```

`ResearchBackend` uruchamia własny backend na `::1` przez `/usr/bin/python3`.
Backend kończy pracę po EOF pipe od aplikacji, także po zakończeniu procesu
rodzica. Pliki z testów pozostają w badawczym Inbox. Pakiet nie zmienia
ustawień ani magazynu tożsamości `/Applications/AimDrop.app`.

### Kontrola właściwego odbiornika jako aplikacji

Dwa uruchomienia tego samego pakietu ze sztucznym `sn`, żeby nie oferować
telefonowi odbiornika podczas automatycznej kontroli:

| `IPV6_MULTICAST_LOOP` | Natywne listenery / HTTP3 gotowe | Błędy ogłaszania | Lokalne typy usług |
| --- | --- | --- | --- |
| 1 (kontrola) | tak | brak | **2** |
| 0 (wariant docelowy) | tak | brak | **0** |

Pakiet ogłoszenia miał 1018 bajtów. Oba uruchomienia korzystały z tej samej
testowej tożsamości. Logi: `.build/self-discovery/receiver-control.log` oraz
`receiver-hidden.log`; odpowiadające logi stderr są puste. W drugiej próbie
backend prawidłowo zakończył pracę po zamknięciu aplikacji.

Włączenie `AIRFOLDER_PROBE_VERIFY_LOCAL=1` uruchamia obserwatora wyłącznie
własnych dwóch ogłoszeń. `AIRFOLDER_PROBE_ADVERTISEMENT_LOOPBACK=1` włącza
wariant kontrolny; `AIRFOLDER_PROBE_SYNTHETIC_ADVERTISEMENT=1` odłącza reklamy
od listy AirDrop. Wszystkie te przełączniki są wyłącznie badawcze.

Obecny ogłaszacz jest celowo prototypem: wysyła komplet rekordów co sekundę,
z TTL 6 sekund; przy zwykłym zakończeniu wysyła goodbye. Nie obsługuje jeszcze
zapytań / known-answer suppression ani zmiany adresu interfejsu. Źródło
ogłaszacza jest dołączone wyłącznie do kompilacji prototypów, nie do
produkcyjnego helpera. Pętla ogłoszeń i wszystkie pozostałe modyfikacje
uruchomienia są w ścieżce badawczej wyłączonej przez `AIRFOLDER_HELPER`.

### Fizyczny iPhone — sukces

Pierwsza sesja zakończyła się po 20 minutach przed wykonaniem próby przez
użytkownika. Została ponownie uruchomiona na godzinę, z tą samą testową tożsamością.

Druga sesja (`.build/self-discovery/live/receiver-app-2.log`) potwierdza:

- nowy PIN, przekazanie obrazu i wzajemną wymianę tożsamości;
- rozwiązanie endpointu natywnego HTTP3;
- `/Ask`: **HTTP 200**;
- `/Upload`: **179 825 441 bajtów**, **HTTP 200**;
- backend: `downloaded`, **jeden plik**, **jeden trwały transfer** po zamknięciu;
- pusty log stderr aplikacji.

Użytkownik potwierdził oba elementy celu: „Widać i plik wysłany” na iPhonie
oraz „Nie był widoczny” w systemowym AirDrop na tym samym Macu. Plik pozostaje
w badawczej skrzynce `.build/self-discovery/live/Incoming`.

### Sprawdzenie publicznego API multicast

SDK udostępnia `NWProtocolIP.Options.disableMulticastLoopback`, ale próba
`NWConnectionGroup` na `ff02::fb%awdl0:5353` zakończyła się `EADDRINUSE` (48),
mimo `allowLocalEndpointReuse` i `includePeerToPeer`. To samo uzyskano przy
wiązaniu `requiredLocalEndpoint` do własnego adresu AWDL. Próba miała wymagany
receive handler; bez niego grupa nie rozpoczęła faktycznej pracy.
Nie jest to dowód niemożliwości użycia wszystkich wariantów tego API, ale
nie daje podstaw do zastąpienia sprawdzonego transportu POSIX w bieżącym wdrożeniu.
Materiał roboczy: `.build/self-discovery/network-group-probe.swift`.

## Integracja 0.8.5 / build 25

Produkcja używa `NativeReceiver/MDNSAnnouncement.swift` oraz
`NativeReceiver/AWDLAdvertisement.swift`. Zachowuje potwierdzoną częstotliwość
jednego kompletnego ogłoszenia na sekundę i TTL 6 sekund, dodając:

- rozdzielenie długich reklam na pełne łańcuchy usług w pakietach ≤1232 bajty;
- kontrolę adresu i indeksu AWDL, nowe sockety po zmianie interfejsu i wykrytym
  uśpieniu oraz ponawianie po błędzie z opóźnieniem 1–5 sekund;
- połączony socket UDP, aby nie odbierać cudzych unicastowych pytań DNS
  przeznaczonych dla `mDNSResponder`;
- terminalne zatrzymanie, goodbye z zachowanego starego obrazu rekordów oraz
  krótką ścieżkę uporządkowanego zakończenia po EOF procesu nadrzędnego;
- odświeżanie TXT co godzinę / po wykrytym wybudzeniu, z obsługą błędów;
- oddzielne zdarzenia dostępności wykrywania, niezależne od gotowości skrzynki.

Wariant połączonego socketu przeszedł ponownie kontrolę: 2 lokalne typy przy
włączonym loopbacku i 0 przy wyłączonym. Integracja nie korzysta z
eksperymentalnych klas/paneli ani ich zmiennych środowiskowych.

### Weryfikacja finalnych workerów

`build-production-discovery-host.py` skopiował z `dist/AimDrop.app` niezmienione
binarki helperów i źródła workera do osobnego podpisanego hosta. Host uruchamia
**aplikacja → dołączony Python → natywny helper**, tak jak produkt. Zachowano
testową tożsamość z pierwszej fizycznej próby.

W tej konfiguracji iPhone wykonał dwa kolejne transfery po **4 151 124 bajty**:
`PairVerify` uwierzytelnione, `/Ask` i `/Upload` HTTP 200, dwa nowe trwałe pliki.
Nie pokazano nowego PIN-u; SHA-256 całego testowego `Pairing/identity.json`
pozostało identyczne. Obserwator lokalny zarejestrował **0** usług tego odbiorcy.
Po zamknięciu hosta nie pozostały jego procesy potomne.

Materiał: `.build/self-discovery/live/production-chain.log`,
`production-worker.log`; kod hosta w
`scripts/research/production-discovery-host.swift`. Testowe pliki nadal są
w `.build/self-discovery/live/Incoming`; ostatni został pokazany użytkownikowi
w Finderze. Nie są to wpisy skrzynki uruchomionej aplikacji `/Applications/AimDrop.app`.

Przeszły: 132 testy Pythona, `check-awdl-advertisement.py`, `native-smoke.py`,
`check-native-update.py` oraz kontrole `DiscoveryStatusChecks`, `LocalizationChecks`,
`PendingTransfersChecks` i `UpdateChecks`. Finalne pakowanie po zmianie nagłówka
LICENSE potwierdziło identyczne bajty testowanego helpera, workera i awatara.

## Pozostałe próby fizyczne

Próba iPhone → Mac oraz brak lokalnej pozycji zakończyły się sukcesem.
Ponowne połączenia z istniejącym parowaniem przeszły również na finalnym
workerze. Do sprawdzenia fizycznie pozostają drugi Mac, uśpienie i zmiana
interfejsu; odpowiednie przejścia ogłaszacza przeszły testy z kontrolowanym
zegarem i symulowanymi socketami. Kontynuacja rzeczywistych uprawnień systemowych
po aktualizacji oraz start przy ponownym logowaniu nadal wymagają odrębnej próby.
