# Ikona odbiorcy AirDrop — ustalenia 2026-11-06

> Historyczne próby używały nazwy i logo AirFolder. Od 0.7.0 bieżąca aplikacja
> to AimDrop; aktualny pakiet i grafiki opisuje [README](../../README.md).

## Wynik dla AirFolder

**Użytkownik potwierdził 6 listopada wyświetlenie logo AirFolder na iPhonie**
po parowaniu z osobnym prototypem: „działa, widzę ikonę aplikacji”.
Po próbie strumieniowej potwierdził również: „wysyłanie działa poprawnie”.
Po uzupełnieniu ALPN `h3` kolejna próba zakończyła się również `/Upload` HTTP 200
(`pairing-prototype-live-6.log`). Użytkownik zauważył jednak, że pasek na Macu
ruszał dopiero po wysłaniu pliku. Przyczyną był dwuetapowy most; został zastąpiony
strumieniowym przekazywaniem do backendu. Testy potwierdzają postęp przed końcem
odbioru oraz przerwanie transferu przez anulowanie. Kolejna fizyczna próba
(`live-7`) potwierdziła 5 plików / 426 704 666 bajtów: panel narysowany 92 ms
po rozpoczęciu odbioru, transfer zakończony po 8,85 s. Zmiana samego
`ReceiverModelName` na `Mac13,1` wcześniej
nie zmieniła sylwetki; skutecznym kanałem obrazu okazała się tożsamość Rapport.

Analiza systemowego kodu znacznie zawęziła problem: w prześledzonej ścieżce
Bonjour/HTTPS grafika pochodzi z lokalnych Kontaktów po rozpoznaniu tożsamości.
Bez kontaktu system generuje domyślny awatar. Model sprzętu jest zapisywany
osobno i nie usuwa oznaczenia „nieznana osoba”.

Nowszy mechanizm Rapport **ma pole `contactImageData`** i przekazuje odebrane
zdjęcie do magazynu sparowanych kontaktów. Lokalna próba potwierdziła również,
że proces bez prywatnych uprawnień Apple może uruchomić systemowy serwer
parowania dla osobnej usługi aplikacyjnej. Samo to nie pozwala jednak ustawić
logo: systemowy serwer tworzy dane kontaktu z „Mojej wizytówki”, a konfiguracja
nasłuchu ignoruje dopisane `contactImageData`.

**Aktualizacja 6 listopada:** osobny aktor AirFolder z własną tożsamością
przekazał logo fizycznemu iPhone'owi po poprawnym PIN-ie. Telefon odesłał dwie
tymczasowe tożsamości, ale formularz kodu pozostał otwarty: prototyp odrzucał
następujące po tej wymianie `resolveBonjour`. Nie był to jeszcze sukces całej
operacji. Ten brak został uzupełniony delegacją do natywnego serwera QUIC.
Lokalnie przeszedł już pełny `/Discover` → `/Ask` → `/Upload` do rzeczywistego
backendu Python, z identycznym SHA-256 pliku 2 MiB i trwałym buforem.
W kolejnej fizycznej próbie (`pairing-prototype-live-5.log`) użytkownik
potwierdził logo, a log potwierdził przekazanie endpointu. Transfer zatrzymał się
w negocjacji TLS: `INVALID_ALPN_PROTOCOL`. Uzupełniono brakujące `h3`, zgodnie
z `sharingd:0x100613b0c`; test pełnego transferu z klientem akceptującym wyłącznie
`h3` przeszedł. Następna fizyczna próba potwierdziła `/Ask` i `/Upload` HTTP 200.
Szczegóły implementacji i ograniczeń są w sekcji 8.

To analiza macOS 26.5.2, nie disassembly iOS 26.6.1. Jest zgodna z obserwacją
na iPhonie i opisem Apple, ale nie dowodzi zachowania wszystkich wariantów
protokołu ani wszystkich wersji iOS.

## Materiał i odtwarzalność

- System: macOS **26.5.2 (25F84)**.
- Plik: `/usr/libexec/sharingd`, architektura `arm64e`.
- UUID tej architektury: `8623E197-9333-3873-ADD5-8E5241CF041C`.
- SHA-256 całego pliku uniwersalnego:
  `8c6b1c8f4b4b1d8e764f3a272a1377f6ca2e69e6936edf83ef3b127c68a1eaf0`.
- Druga badana binarka: `/usr/libexec/rapportd`, `arm64e`.
  UUID: `AAE2CD45-6D75-3CDC-A876-18B28E15A119`.
  SHA-256 całego pliku:
  `f8e5a44cffb04d0aa8f613bb318b86a3a7af2aa205378442597337356b4a4efa`.
- Podane niżej adresy są adresami statycznymi, przed ASLR.
- Analizowano binarkę na dysku; materiał nie zawiera wyeksportowanych kluczy,
  danych konta ani zrzutów pamięci działającego procesu.

Lokalne materiały robocze są w `.build/sharingd-*.asm`,
`.build/sharingd-objc.txt` i `.build/sharingd-strings.txt`.
`.build/inspect-sharingd.py` dopisuje nazwy selektorów do wywołań ARM64,
odczytując względne metody Objective-C i wskaźniki selektorów z tej binarki.
To pomocnik badawczy dla tego układu Mach-O, nie narzędzie aplikacji.
Analogiczne materiały Rapport mają prefiks `.build/rapportd-`;
pomocnik wybiera tę binarkę przez `AIRFOLDER_RE_BINARY=rapportd`.
Eksporty i funkcje Network/Sharing sprawdzano także po załadowaniu frameworków
do własnego procesu pomocniczego.

Podstawowe zrzuty można odtworzyć:

```sh
strings -a /usr/libexec/sharingd > .build/sharingd-strings.txt
otool -arch arm64e -ov /usr/libexec/sharingd > .build/sharingd-objc.txt
xcrun llvm-objdump --macho --arch=arm64e --disassemble /usr/libexec/sharingd > .build/sharingd-arm64e.asm
python3 .build/inspect-sharingd.py 'parseDiscoverResponse:|startPictureQuery:' --asm
```

## 1. `/Discover` nie przenosi awatara w sprawdzonych parserach

`-[SDAirDropClient parseDiscoverResponse:]` — **`0x10014746c`** — odczytuje:

- `ReceiverRecordData`,
- `ReceiverMediaCapabilities`,
- `ReceiverModelName`,
- `ReceiverComputerName`,
- `ReceiverDeviceIRKData`,
- `ReceiverEdPKData`,
- `ReceiverIDSDeviceID`,
- `SendersKnownAlias`.

Nie ma tu odczytu PNG/JPEG/SVG ani pola awatara. Dodanie arbitralnego
`ReceiverIcon` lub `FileIcon` do odpowiedzi nie jest oparte na tym parserze.

Metadane refleksji nowszego Swiftowego `DiscoverResponse`
(`__swift5_fieldmd`, **`0x1007dceb8`**) zawierają te same kategorie danych
oraz `rapportFeatureFlags` i `isAirDropable`; również bez obrazu.
Sama refleksja nie stanowi pełnej analizy wykonania tej nowszej ścieżki.

`FileIcon` w `/Ask` służy miniaturze **wysyłanego elementu**. Nie jest ikoną
odbiornika na liście urządzeń.

## 2. Stary trop zdjęcia przez Bonjour jest nieczynny w prześledzonej ścieżce

Historyczne nagłówki iOS 7 zawierają `processNULLRecordUpdate:rdlen:rdata:`
i `personIconChanged:iconData:`. W obecnej binarce pozostało
`-[SDBonjourBrowser startPictureQuery:]` — **`0x10004dc0c`** — przygotowujące
zapytanie DNS typu **NULL (10)** dla nazwy/typu/domeny usługi.

Jednak obecny
`handleQueryCallBack:error:fullname:rrtype:rdlen:rdata:` — **`0x10005031c`** —
obsługuje wyłącznie **TXT (16)**. Inne typy trafiają do ścieżki błędu;
nie znaleziono metody parsującej NULL ani wywołania `startPictureQuery:`
przez tablicę stubów Objective-C.

W `processTXTRecordUpdate:rdlen:rdata:` — **`0x10004fe28`** — gałąź AirDrop
odczytuje `flags`, `atag`, `cname`, `phash`, `ehash`, `nhash`.
`personInfoChanged:flags:atag:cname:phash:ehash:nhash:` — **`0x10004f05c`** —
ustawia flagi i rozpoczyna żądanie HTTP. W tej implementacji przekazane
`phash`/`ehash`/`nhash` nie zasilają rozpoznania zdjęcia kontaktu.

Nie ma podstaw do wdrażania reklamy obrazu jako rekordu NULL w AirFolder.

## 3. Faktyczny wybór grafiki

Prześledzony ciąg:

1. `SDBonjourBrowser addService:type:domain:interface:` — **`0x10004c52c`** —
   tworzy dla AirDrop węzeł z rodzajami `Person` i `Unknown`.
2. `airDropClient:event:withResults:` — **`0x10004e9c4`** — po odpowiedzi
   `/Discover` przekazuje rekord i zaufanie TLS do weryfikacji. Niezależnie
   zapisuje `ReceiverModelName` przez `SFNodeSetModel` (**`0x10004eb60`**).
3. Funkcja **`0x100153864`** sprawdza rekord przez
   `verifyAndParseValidationRecordData:intoDictionary:`, łańcuch certyfikatów
   przez `SFAppleIDVerifyCertificateChainSync` i zgodność identyfikatora
   konta z nazwą certyfikatu. Dopiero potem używa zweryfikowanych hashy.
4. Funkcja **`0x100154270`** może ustawić `SFNodeSetAppleID`,
   `SFNodeSetEmailHash` i `SFNodeSetPhoneHash`.
5. Funkcja **`0x100152ecc`** wyszukuje kontakt. Usuwa `Unknown` przy
   rozpoznanym kontakcie/nazwie; w gałęzi bez kontaktu dodaje `Unknown`
   i używa nazwy komputera.
6. Funkcja **`0x100153128`** pobiera grafikę kontaktu. Funkcja pomocnicza
   **`0x100152cf4`** używa `thumbnailImageData`, a przy braku zdjęcia
   `CNAvatarImageRenderer.avatarImageForContacts:scope:`. Bez kontaktu
   tworzy pusty `CNContact` i renderuje domyślny awatar.
7. Wynik trafia do `SFNodeSetIconData` pod **`0x100153420`**.

Samo dodanie kontaktu „AirFolder” na iPhonie nie realizuje tego procesu:
odbiornik musi jeszcze przedstawić tożsamość pasującą do kontaktu.
Podobnie pojedynczy parametr modelu, nazwy lub flag nie zastępuje weryfikacji.

## 4. Dwie różne implementacje parowania

W tej samej binarce istnieją `SDTempPairingClient`, `SDTempPairingServer`,
`SDTempPairingConnection`, `SDPairedContactManager` i tożsamości Rapport
typu ad-hoc. Pasuje to do opisanego przez Apple parowania kodem i okresu
rozpoznawania przez 30 dni, wprowadzonego w systemach 26.2.

Odczytane metadane struktur:

| Struktura | Pola |
| --- | --- |
| `SDTempPairingTXTRecord` (`0x1007dbc00`) | `service`, `displayName`, `publicKey`, `authTag` |
| `SDTempPairingMessage.Request` (`0x1007df0a0`) | `version`, `name`, `identifier`, `publicKey`, `deviceIRKData` |
| `SDTempPairingMessage.Response` (`0x1007df044`) | `version`, `error`, `identifier`, `publicKey`, `deviceIRKData` |

Te wiadomości **nie mają pola zdjęcia**, ale nie wyczerpują nowszego protokołu.
W `rapportd` istnieje odrębna implementacja:

| Struktura | Pola |
| --- | --- |
| `RPPairingTemporaryIdentity` (`0x1001c7974`) | `contactIdentifier`, **`contactImageData`**, `dateAdded`, `deviceName`, `identifier`, `givenName`, `familyName`, `deviceIRKData`, `devicePublicKey` |
| jej `CodingKeys` (`0x1001c7ab0`) | te same nazwy, łącznie z `contactImageData` |

Zdalny aktor `rapportd.RPPairingDistributedActor` udostępnia m.in.
`pairAndReceiveTemporaryIdentities(pairingData:)`, `shareTemporaryIdentities`,
`exchangePAKEIdentities` oraz operacje PairVerify. Korzysta z `NWActorSystem`;
importy i wywołania potwierdzają użycie SPAKE2+ i szyfrowanej wymiany tożsamości.
Nie jest to dodatkowy endpoint obecnego serwera HTTPS AirFolder.

### Prześledzony zapis odebranego zdjęcia

1. Kontynuacja po odebraniu tymczasowych tożsamości wywołuje funkcję zapisu
   pod `rapportd:0x1000bd83c`.
2. Obsługa udostępnionych tożsamości loguje `Saving shared temporary identities`
   pod `0x1000e1a88` i wywołuje tę samą funkcję pod `0x1000e1b24`.
3. Funkcja `0x10011c6d8` pobiera obraz i nazwy z otrzymanej struktury, wyznacza
   termin wygaśnięcia przez dodanie 30 dni i tworzy obiekt kontaktu przez
   `initIdentifier:imageData:deviceName:givenName:familyName:expiryDate:`
   (`0x10011cc18`). Następnie wywołuje `donateContactToSharing:` (`0x10011cc68`).
4. `RPContactsWrapper.donateContactToSharing:` (`0x100058308`) przekazuje obraz,
   nazwy i termin do
   `donateContactWithIdentifier:imageData:deviceName:givenName:familyName:expiryDate:completion:`.
5. `sharingd` ma ścieżkę odczytu sparowanego kontaktu po `contactID`
   (`0x10030044c`, komunikat `Found paired contact for contactID` pod `0x1003006d0`).

Ta analiza potwierdziła kanał przesyłania i przechowywania zdjęcia w macOS.
Późniejsza próba na fizycznym iPhonie potwierdziła również wyświetlenie obrazu
jako ikony osobnego odbiornika AirFolder (sekcja 8).

## 5. Transport współczesnego AirDrop

- Natywna usługa aplikacyjna: **`com.apple.sharingd.AirDrop`**
  (`sharingd:0x10058e334`).
- Konfiguracja parowania PIN: `sharingd:0x100591e24`.
- Parametry transferu QUIC/HTTP3: `sharingd:0x1006174b0`.
- Osobne usługi wykrywania parowania w Rapport:
  **`_applicationServicePairing._tcp`** i **`_appSvcPrePair._tcp`**.
- `sharingd:0x100414d0c` sprawdza bit **16 (`0x10000`)**. Po jego ustawieniu
  usuwa endpoint legacy, oczekując wykrycia odbiornika przez Rapport.

Włączenie tej flagi w samym odbiorniku Bonjour/HTTPS może więc ukryć AirFolder.
Obsługa PIN wymaga również właściwego wykrywania i transportu.

## 6. Sprawdzenie zwykłego procesu i konfiguracji — wynik wykonania

Kod źródłowy powtarzalnych prób:

- `scripts/research/pairing-configuration-codec.swift` — używa rzeczywistego
  typu `Network.NWListener.Service.PairingConfiguration` znalezionego przez
  runtime Swift i jego implementacji `Codable`; operuje na danych syntetycznych.
- `scripts/research/pairing-transport-probe.m` — sześciosekundowy listener QUIC
  dla **`pl.airfolder.protocolprobe`**. Kończy reklamowanie po próbie i odrzuca
  nowe połączenia. Tryb `--pairing` dodaje zweryfikowaną konfigurację PIN.

### Rzeczywisty format konfiguracji

```json
{
  "supportedPairingTypes": [{"pin": {}}],
  "generatePairingValueImmediately": false,
  "_advertiseSensitiveInfo": false
}
```

Klucz **`_advertiseSensitiveInfo` ma podkreślenie**. Początkowe odtworzenie
bez podkreślenia nie przeszło natywnego dekodera (`keyNotFound`). Poprawiona
wersja przechodzi decode → encode bez zmiany treści. Dopisanie
`contactImageData` do tego JSON-u jest ignorowane — po round-trip pole znika.
Nie jest to sposób przekazania logo do `RPPairingTemporaryIdentity`.

### Wykonane próby

| Próba, czas lokalny 2026-11-05 | Wynik |
| --- | --- |
| Zwykły proces, baseline, 23:08:24–23:08:30 | listener `ready`, reklama osobnej usługi QUIC, poprawne zakończenie |
| Zwykły proces, `--pairing`, 23:09:03–23:09:09 | `ready`; Rapport: `Successfully activated pairing server`; uruchomienie reklam pairing i pre-pairing, następnie ich zatrzymanie |
| Pomocniczy bundle `.app`, podpis ad hoc, 23:11:03–23:11:09 | `entitled=0`, `ready`, ponownie `Successfully activated pairing server` |

W ostatniej próbie `NSBundle.mainBundle.bundleIdentifier` wynosił
`pl.airfolder.protocolprobe`. To potwierdza dostępność badanego mechanizmu
również dla lokalnego bundle bez prywatnych entitlements. **Stan `ready` sam
w sobie nie dowodzi parowania**; pozytywny wynik serwera pochodzi osobno
z logu Rapport. Próby nie obejmowały wymiany z iPhonem ani usługi
`com.apple.sharingd.AirDrop`.

### Prefiks nazwy i uprawnienia

`RPNWAgentClient.updateAgentClientInfo…` sprawdza
`com.apple.private.application-service-browse` pod `0x1000813a4`.
`shouldPrefixBundleID` (`0x100080e70`) zwraca domyślnie `true` dla procesu
bez tego uprawnienia. Dalsza funkcja rejestracji ma jednak także gałąź
`Using appSvc only` (`0x1000814b4`), zależną od kontekstu i dostępnego bundle ID.

W obu wykonanych trybach bez uprawnień log zawierał jednocześnie
`Un-entitled client, shouldPrefix:1` i `Using appSvc only: 'pl.airfolder.protocolprobe'`.
Dlatego sam brak entitlement ani sam tekst `shouldPrefix:1` **nie dowodzą
blokady rejestracji usługi**. Zachowanie dla zarezerwowanej nazwy AirDrop
i współistnienia z usługą systemową pozostaje niesprawdzone.

Odtworzenie próby z katalogu projektu:

```sh
xcrun swift scripts/research/pairing-configuration-codec.swift
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework Network scripts/research/pairing-transport-probe.m -o .build/pairing-transport-probe
.build/pairing-transport-probe
.build/pairing-transport-probe --pairing
```

## 7. Dlaczego potrzebny był własny aktor

**Systemowy listener nie udostępnia w zbadanej konfiguracji własnej wizytówki.**
Źródło obrazu zostało prześledzone:

1. `RPContactsWrapper.getMeCard:queue:` (`0x100057a2c`) pobiera kontakt
   użytkownika przez `_crossPlatformUnifiedMeContactWithKeysToFetch:error:`
   (`0x100057afc`) oraz systemową nazwę urządzenia.
2. Odczytuje `imageData` tego kontaktu (`0x100057c54`) i buduje dane wizytówki.
3. Funkcja tworząca tymczasowe tożsamości (`0x100139a24`) pobiera ten obraz
   (`0x100139bf4`) i zapisuje go w strukturze tożsamości (`0x100139d40`).
4. Konfiguracja `NWListener` opisuje typ parowania, PIN/dane parowania oraz
   sposób reklamowania. Nie zawiera nazwy/obrazu tożsamości aplikacji.
   `pairingData` jest używane w ścieżce pozyskania PIN
   (`agentClientListenerGetPairingData:`, `0x10011f9c0`), nie jako zdjęcie.

Zatem uruchomienie natywnego serwera nie daje automatycznie osobnej tożsamości
z logo AirFolder. Własny aktor z sekcji 8 realizuje wymianę
`RPPairingTemporaryIdentity` z własnymi kluczami i obrazem. Wciąż brakuje
PairVerify dla ponownych połączeń, trwałej tożsamości i integracji z główną
aplikacją; wyświetlenie obrazu i odbiór przez nowy transport już potwierdzono.

## 8. Własny aktor, fizyczny iPhone i most HTTP3

Źródła są zachowane w `scripts/research/`; `.build/` zawiera wygenerowane
moduły, programy i lokalne dzienniki. Główna aplikacja pozostaje w wersji
0.4.1, a prototyp uruchamia się jako osobny proces **AirFolder Logo Test**.

### Mechanizm

- `network-actor-declarations.swiftinterface` odtwarza deklaracje eksportowane
  przez systemowy Network. `build-network-research-module.py` tworzy lokalną
  nakładkę modułu bez modyfikowania zainstalowanego SDK.
- `airfolder-pairing-prototype.swift` jest kompilowany z nazwą modułu
  **`rapportd`**: natywny dispatcher wymaga dokładnej nazwy zdalnej metody,
  np. `$s8rapportd25RPPairingDistributedActorC33pairAndReceiveTemporaryIdentities11pairingDataSayAA0bH8IdentityVGSg10Foundation0K0V_tYaKFTE`.
- Pre-pairing wymienia identyfikatory klienta i serwera. Uwierzytelniony
  listener stosuje TLS-SPAKE2+ w kontekście
  `application-service-pairing-context`. IRK przechodzi przez natywny
  `RPIRKRatchet`. Pierwotnie klucze i IRK były generowane przy każdym starcie;
  obecnie opcjonalny trwały magazyn zachowuje tożsamość między uruchomieniami.
- Dynamiczny PAKE wymaga `nw_swift_tls_record_create_options`; zwykłe opcje
  TLS w tej ścieżce kończyły się `NO_CERTIFICATE_SET`. Oferowane identyfikatory
  PAKE są `NSData`, dekodowanymi do tekstu przed wyszukaniem poświadczeń.
- Wymieniana tożsamość zawiera PNG 256 px, **52 619 bajtów**, wygenerowany
  z grafiki AirFolder. Aktor przed uwierzytelnieniem odrzuca żądanie tożsamości.
- `native-file-service.swift` uruchamia osobną natywną usługę aplikacyjną
  z losowym PIN-em i deleguje do jej aktora `resolveBonjour`. Wynikiem jest
  klucz serwera QUIC (294 bajty w wykonanych próbach) i usługa `_asquic._udp`.
  Na zewnątrz nadal wymieniana jest tożsamość AirFolder.
- Odkrywanie tego aktora wymaga `.bonjourWithTXTRecord`, a zarówno parametry
  przeglądania, jak i połączenia wymagają `includePeerToPeer = true`.
- Natywny konstruktor usługi QUIC sam nie dodaje ALPN `h3`. Dwa jednakowo
  skonfigurowane prototypy przechodziły wcześniejszy test, lecz iPhone kończył
  negocjację z `INVALID_ALPN_PROTOCOL` (08:06:23 lokalnie, 6 listopada).
  `sharingd:0x100613b0c` wywołuje `sec_protocol_options_add_tls_application_protocol`
  z `h3`. Most robi teraz to samo; klient testowy usuwa pozostałe ALPN i sprawdza
  rzeczywiście wynegocjowany protokół, aby wykluczyć taki fałszywie dodatni wynik.
- `pake-bridge.m` obsługuje prywatne metadane HTTP3. Callback odczytu ścieżki
  dostaje jeden C string; callback nagłówków dostaje **name, length, value,
  length** i zwraca `bool`. Pierwotna deklaracja z dwoma argumentami powodowała
  SIGSEGV; poprawiona przeszła rzeczywisty transfer z `TransferID` i typem treści.

### Wyniki

| Próba | Wynik |
| --- | --- |
| Dwa procesy, pre-pairing → dynamiczny PAKE → logo | poprawny PIN: dokładne bajty obrazu i wzajemna wymiana tożsamości; błędny PIN odrzucony |
| Fizyczny iPhone, wcześniejszy prototyp | znaleziono AirFolder Logo Test; przyjęto PIN; wysłano obraz; odebrano dwie tożsamości; błąd przy `resolveBonjour`, formularz kodu nadal otwarty |
| Fizyczny iPhone, próba 6 listopada około 08:06 | **logo widoczne — potwierdzenie użytkownika**; endpoint przekazany; brak HTTP z powodu `INVALID_ALPN_PROTOCOL` |
| Fizyczny iPhone, po dodaniu `h3`, log `live-6` | `/Ask` i `/Upload` HTTP 200; użytkownik zgłosił opóźniony pasek postępu po pobraniu do surowego spoolu |
| Fizyczny iPhone, most strumieniowy, log `live-7` | 5 plików, 426 704 666 bajtów, HTTP 200; backend ruszył przy 11 801 bajtach źródła, panel narysowany po 92 ms, koniec transferu po 8,85 s |
| Natywne rozwiązywanie endpointu i HTTP3 | prawidłowy endpoint, `/Discover` HTTP 200 z działającego backendu AirFolder |
| Izolowany rzeczywisty backend, pełny HTTP3, także po poprawce ALPN | klient wymusza i sprawdza `h3`; `/Discover`, `/Ask`, `/Upload`: HTTP 200; plik 2 MiB + 17 bajtów, zgodny SHA-256, pojedynczy luźny plik w trwałym buforze |
| Ponowne wysłanie tego samego transferu | HTTP 403; drugi plik nie powstał; surowy spool odrzuconej próby zachowany |
| Strumieniowy most, znana długość oraz chunked | plik 8 MiB + 17 bajtów, zgodny SHA-256; zdarzenia `receiving` i `progress`, gdy spool jest jeszcze niekompletny; odrzucenie replay przed kolejną zgodą 100 |
| Anulowanie przy pierwszym `progress` | źródło HTTP3 przerwane przed EOF; brak gotowej paczki; niekompletny katalog Inbox usunięty |

`test-http3-prototype.py` używa osobnego katalogu i backendu. Po transferze
ponownie otwiera `Inbox`, sprawdza treść pliku i usunięcie tylko poprawnie
przyjętego spoolu. Test obejmuje odpowiedź `100 Continue`; klient ma sekundowy
limit oczekiwania i następnie wysyła body, ponieważ natywne API buforowało
same nagłówki. **Nie potwierdza to obsługi nadawcy, który czeka na 100 bez
takiego limitu.** Dla połączenia do Pythona most ustawia `Expect: 100-continue`,
aby backend mógł odmówić przed otrzymaniem całego body.

### Uruchomienie z katalogu projektu

```sh
python3 scripts/research/build-pairing-prototypes.py
python3 scripts/research/test-pairing-prototype.py
python3 scripts/research/test-http3-prototype.py
.build/airfolder-pairing-prototype --native-resolve-check
.build/airfolder-pairing-prototype --advertise
```

Wymagana grafika: `.build/artwork/AirFolder.png` z budowania aplikacji.
Port backendu domyślnie wynosi 49875; można go wskazać przez
`AIRFOLDER_PROBE_BACKEND_PORT`. Tryb `--advertise` pokazuje okno z nazwą,
a po żądaniu telefonu — PIN. Działa do godziny lub kliknięcia **Zakończ próbę**.

### Strumieniowy postęp i anulowanie

`streaming-upload.swift` otwiera loopback HTTPS od pierwszego bloku `/Upload`.
Przed przekazaniem body oczekuje na zgodę `100 Continue` istniejącego backendu.
Każdy blok (maksymalnie 64 KiB) jest zapisywany w surowym spoolu i od razu
przekazywany do Pythona; następny odczyt następuje po `contentProcessed`.
Przy braku długości most używa chunked i zachowuje `TotalBytes` jako wskazówkę.
Backend zapisuje i rozpakowuje plik w trwałym buforze już podczas odbierania,
emitując zwykłe zdarzenia postępu do działającej aplikacji.

Fizyczna próba z 6 listopada, znaczniki UTC z `receiver.log`:
`receiving` 07:21:41.261, pierwszy blok 07:21:41.263, panel widoczny
07:21:41.350, pierwszy render 07:21:41.353, komplet 5 plików
07:21:50.113. Liczba bajtów jest identyczna z `native_http3_upload_source_complete`
w logu `live-7`. To potwierdza działanie panelu podczas tej transmisji,
zamiast dopiero po pobraniu pełnego spoolu.

Zamknięcie połączenia przez `cancel_transfer` przerywa odczyt HTTP3; brak zgody
na replay daje 403 bez czytania reszty body. Surowe spools w
`~/Library/Application Support/AirFrajer/http3-probe-buffer/` są usuwane dopiero
po HTTP 200 backendu. Dane nieudanych prób pozostają do diagnostyki.

### Pozostały zakres

Trwały zapis i PairVerify przeszły test restartu, szyfrowanego resolve i HTTP3
w oddzielnych procesach oraz fizyczny transfer iPhone'a bez ponownego PIN-u.
Wersja 0.5.0 integruje cykl życia ze zwykłą aplikacją; szczegóły i zakres testu
paczki opisuje [trwałe parowanie](durable-pairing.md). Surowe spools są teraz
opcjonalną diagnostyką prób, a trwały odbiór aplikacji należy do Inbox backendu.
Anulowanie nowej ścieżki przeszło test lokalny; wymaga jeszcze fizycznej próby.

### Dlaczego „Osoby”, a nie „Moje urządzenia”

Prototyp przedstawia osobną tożsamość sparowaną PIN-em. iOS rozpoznaje ją jako
kontakt i wyświetla przekazany obraz w sekcji „Osoby”. „Moje urządzenia” wymaga
rozpoznania odbiornika jako urządzenia tego samego konta Apple. Zmiana nazwy,
modelu Maca lub obrazu nie zastępuje tej integracji konta; nie została wdrożona.
Osobna [próba dostępu do systemowej tożsamości](airdrop-own-devices.md) potwierdziła
odmowę `RPErrorDomain -71168` z powodu braku `com.apple.rapport.Client`.
Próba brokera wykrywania wymagała dodatkowo
`com.apple.private.application-service-browse`. Lokalne podpisanie osobnych
programów testowych z tymi uprawnieniami zakończyło się odmową AMFI -424.

## Praktyczny wniosek

Udokumentowaną drogą do zdjęcia kontaktu jest **zweryfikowana tożsamość
odbiorcy oraz odpowiadający jej kontakt ze zdjęciem na urządzeniu nadawcy**.
Prototyp zrealizował tę ścieżkę przez tymczasowy kontakt Rapport z własnym logo.
Uzyskanie kategorii „własnego urządzenia”
wymaga osobnej weryfikacji rozpoznania tego samego konta przez iOS.

Projekt OpenDrop opisuje użycie tożsamości wydanej przez Apple, ale jego
historyczny ekstraktor wymaga prywatnej grupy dostępu
`com.apple.sharing.appleidauthentication` i zmian ochrony systemu.
Nie jest to gotowe rozwiązanie dla zwykłej aplikacji na niezmodyfikowanym
macOS 26.5.2. Nie przeprowadzano ekstrakcji ani zmian zabezpieczeń.

**Własny aktor wymienia tożsamość z logo, a iPhone wyświetla tę ikonę** —
potwierdzenie użytkownika z 6 listopada. Log fizycznej próby potwierdził także
odbiór `/Upload` po poprawce `h3`. Nowsza wersja mostu przekazuje dane w trakcie
odbioru; lokalnie sprawdzono zgodność bajtów, wczesny postęp i anulowanie.

## Źródła zewnętrzne

- [Apple: AirDrop security](https://support.apple.com/guide/security/airdrop-security-sec2261183f4/web)
  — opis sylwetki przy braku uwierzytelnienia i zdjęcia z Kontaktów.
- [Apple: Use AirDrop on iPhone or iPad](https://support.apple.com/en-us/119857)
  — aktualny proces, w tym kody AirDrop.
- [FuriousMAC: AirDrop BLE 0x05](https://github.com/furiousMAC/continuity/blob/master/messages/airdrop.md)
  — brak pola modelu w opisanym formacie.
- [FuriousMAC: Nearby Action 0x0F](https://github.com/furiousMAC/continuity/blob/master/messages/nearby_action.md)
  — pola klasy/modelu w wariancie konfiguracji iOS; brak dowodu na sterowanie ikoną AirDrop.
- [Historyczne symbole sharingd iOS 7.1.1](https://github.com/ichitaso/iOS-iphoneheaders/blob/master/iOS7.1.1/usr/libexec/sharingd/sharingd-Symbols.h)
  — źródło tropu rekordów obrazu NULL.
- [OpenDrop: ekstraktor tożsamości](https://github.com/seemoo-lab/airdrop-keychain-extractor)
  — wymagania dostępu i użycie tożsamości w alternatywnym odbiorniku.
- [GoOpenDrop](https://github.com/bodaay/GoOpenDrop)
  — rozpoznawanie kontaktu po integracji tożsamości; ustawienie
  `thumbnail_picture_jp2` dotyczy `/Ask`, nie awatara odbiorcy.
