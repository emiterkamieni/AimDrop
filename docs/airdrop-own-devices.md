# „Osoby” / „Moje urządzenia” — sprawdzenie 2026-11-06

## Decyzja końcowa

Po zapoznaniu się z wynikami użytkownik wybrał pozostanie przy osobnym odbiorniku
AirFolder z własnym logo, parowaniem PIN i bezpośrednim, strumieniowym odbiorem.
To docelowy tryb produktu. iOS sam przypisuje odbiorcę do sekcji „Osoby” /
„Inne osoby”; ta etykieta nie jest ustawieniem AirFolder. Badania „Moich urządzeń”
poniżej pozostają dokumentacją sprawdzonych ograniczeń.

## Wynik

Nie ma obecnie potwierdzonego przełącznika, który przenosi osobny odbiornik
AirFolder z logo i własną tożsamością PIN do „Moich urządzeń”. Kategoria jest
wynikiem rozpoznania tożsamości przez nadawcę, nie deklaracją modelu sprzętu.

Użytkownik potwierdził, że iPhone i Mac korzystają z tego samego konta iCloud,
i początkowo wybrał badanie **pełnej integracji** (własne logo i bezpośredni
odbiór). Po próbach przyjął tryb opisany w decyzji końcowej powyżej.

Bezpośrednia, sprawdzona ścieżka do systemowych tożsamości Rapport wymaga
`com.apple.rapport.Client`. Zwykły proces na tym Macu dostał odmowę nawet
przy żądaniu pustego zestawu kategorii (flags=0):

```text
identity_api=denied domain=RPErrorDomain code=-71168 rapport_client_entitlement_required=yes
```

To potwierdza blokadę konkretnego interfejsu; nie dowodzi niemożliwości każdej
przyszłej integracji. Publiczne usługi aplikacyjne Network mogą korzystać
z systemowego brokera połączeń, ale samo uruchomienie takiej usługi nie dowodzi
uzyskania osobnej pozycji AirDrop w „Moich urządzeniach”.

Po zbadaniu brokera i lokalnego podpisywania znaleziono kolejne konkretne
blokady opisane poniżej. W obecnym, lokalnym buildzie bez autoryzacji Apple
sprawdzone drogi do pełnej integracji są niedostępne. Przełącznik w UI
pozostaje niewdrożony, ponieważ brak działającego trybu, który mógłby włączać.

## Odtwarzalna próba bez pobierania tożsamości

`scripts/research/account-capability-probe.m` tworzy `RPClient` i wywołuje
`getIdentitiesWithFlags:completion:` z **0**. Analiza
`RPIdentityDaemon getIdentitiesWithFlags:` (`0x100065ed0`) potwierdziła, że
przy tej wartości żadna kategoria tożsamości nie jest wybierana.
Program wypisuje wyłącznie wynik autoryzacji, domenę/kod błędu i informację
o wymaganym uprawnieniu. Nie odczytuje ani nie zapisuje pól tożsamości.

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation scripts/research/account-capability-probe.m -o .build/account-capability-probe
.build/account-capability-probe
```

## Broker połączeń bez udostępniania kluczy aplikacji

`scripts/research/account-browser-probe.m` wykonuje wyłącznie odkrywanie
usługi aplikacyjnej `com.apple.sharingd.AirDrop`. Nie rejestruje listenera,
nie przejmuje systemowego odbiornika i nie nawiązuje połączeń do znalezionych
urządzeń. Loguje tylko obecność endpointów i flagi protokołu.

Pierwszy wariant z ogólnymi parametrami Network zwracał `ready` i zero wyników.
To nie stanowiło dowodu braku urządzeń ani uprawnień. Analiza
`SDAirDropApplicationServiceBrowser` (`sharingd:0x10053ae88`–`0x10053af80`)
wykazała, że system wymaga agenta o domenie `com.apple.rapport.browse`
i typie `RapportBrowseAgent`.

Sharing `NWParameters.airDropNetworkBrowserParameters(domain:type:)`
(`Sharing+0x2ebfe0`) ustawia te klasy przez
`nw_parameters_set_required_netagent_classes` oraz włącza BLE.
Po odtworzeniu parametrów program nadal zgłaszał `ready`, ale log `rapportd`
z 09:09:36 lokalnie jednoznacznie podał:

```text
BROWSE: Ignoring browse request - pid=28242 lacks entitlement com.apple.private.application-service-browse
```

Wynik: stan `NWBrowser.ready` nie dowodzi zgody brokera. Zwykły proces nie
otrzymał dostępu do tej ścieżki odkrywania własnych urządzeń.

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework Network scripts/research/account-browser-probe.m -o .build/account-browser-probe
.build/account-browser-probe
```

## Próby podpisu lokalnego

Sprawdzono osobne binarki z pojedynczym uprawnieniem każda:

| Próba, czas lokalny | Uprawnienie | Wynik uruchomienia |
| --- | --- | --- |
| `account-browser-entitled-probe`, 09:12:35 | `com.apple.private.application-service-browse` | SIGKILL przed wejściem do `main`; AMFI -424 |
| `account-capability-entitled-probe`, 09:14:33 | `com.apple.rapport.Client` | SIGKILL przed wejściem do `main`; AMFI -424 |

Systemowy `amfid` w obu przypadkach zapisał:

```text
The file is adhoc signed but contains restricted entitlements
```

Pierwsza binarka przechodziła `codesign --verify --strict` — poprawność podpisu
na dysku nie oznacza, że system zezwoli na wykonanie z zastrzeżonym uprawnieniem.
Pliki `scripts/research/account-browser-probe.entitlements` i
`account-capability-probe.entitlements` zachowują dokładną konfigurację prób.
Nie są częścią podpisu ani budowania AirFolder. Nie zmieniano ustawień ochrony
systemu i nie pobierano kluczy konta.

## Potwierdzenie statyczne na macOS 26.5.2

- `RPDaemonXPCConnection getIdentitiesWithFlags:completion:` — `0x1000522a8` —
  sprawdza `_entitledForLabel:error:` przed pobraniem jakichkolwiek tożsamości.
- `_entitledForLabel:error:` — `0x100051710` — wymaga wartości true
  dla `com.apple.rapport.Client`, w przeciwnym razie zwraca błąd.
- `SDRapportBrowser createSFNodeFromMyRPDevice:` — `0x100104568` — buduje
  węzeł z rozpoznanego urządzenia Rapport i lokalnej wizytówki; nie odczytuje
  przełącznika „osoba/urządzenie” z naszego `/Discover`.
- `RPNWListener addListenerAgentClient:` — `0x100047c50` — wyszukuje wpis
  po nazwie usługi. Jeśli PID właściciela jest inny, usuwa poprzednie mapowanie
  (`0x100047fd8`–`0x100048024`; komunikat pomocniczy pod `0x10014bc7c`).
  Rejestracja drugiego listenera pod `com.apple.sharingd.AirDrop` nie jest więc
  potwierdzonym sposobem bezkonfliktowego dodania drugiej pozycji tego Maca.

Lokalne materiały: `.build/rapportd-identity-entitlement.asm`,
`.build/rapportd-zero-flags-identities.asm`,
`.build/rapportd-listener-registration-check.asm`,
`.build/sharingd-own-device-discovery.asm`.

## Znaczenie dla ewentualnej opcji w aplikacji

- **Odbiornik AirFolder („Osoby”)**: własne logo, PIN, bezpośredni odbiór do
  bufora oraz postęp i anulowanie. To obecna, sprawdzona ścieżka prototypu.
- **Systemowy AirDrop („Moje urządzenia”)**: kandydat na odrębny tryb organizacji
  plików już odebranych przez macOS. Na telefonie odbiornikiem byłby systemowy
  Mac z jego nazwą/ikoną. Nasz obecny transport nie otrzymywałby transmisji,
  więc jego pasek i anulowanie nie obejmowałyby pobierania przez macOS.

Drugi wariant wymaga zgody na zmianę działania oraz sprawdzenia niezawodnego
rozpoznawania i grupowania plików systemowego AirDrop. Nie został jeszcze
zaimplementowany ani wybrany. Ostateczną decyzją jest osobny odbiornik AirFolder.

Pełny wariant wymagałby autoryzowanego dostępu do systemowej tożsamości/usługi
lub innego interfejsu Apple, który rzeczywiście obsługuje ten scenariusz.
Samo „Zaloguj przez Apple”, nazwa/model urządzenia, TXT czy przełącznik UI
nie zapewniają certyfikatu ani uprawnień wymaganych przez sprawdzone ścieżki.

[Apple: AirDrop security](https://support.apple.com/guide/security/airdrop-security-sec2261183f4/web)
opisuje uwierzytelnianie z użyciem iCloud i certyfikatów. Treść tej strony ma
datę 2021; szczegóły aktualnej próby wynikają z macOS 26.5.2 i powyższego testu.
