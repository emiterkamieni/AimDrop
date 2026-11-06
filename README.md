# AirFolder — AirDrop z wyborem folderu i powiadomieniami

Odbiornik na macOS. Na iPhonie używasz zwykłego **Udostępnij → AirDrop**
i wybierasz **AirFolder** lub własną nazwę ustawioną w aplikacji. AirFolder
odbiera pliki do bufora i pokazuje postęp. Po transferze pyta o folder docelowy
albo automatycznie zapisuje nowe pliki w wybranym miejscu.

## Uruchomienie na tym Macu

Otwórz `dist/AirFolder.app` lub kliknij `Uruchom.command`.

Znak AirFolder pojawia się w pasku menu. Menu pokazuje nazwę i stan odbioru
oraz pozycje **Pokaż ostatni folder**, **Ustawienia…**, **O AirFolder**
i **Zakończ AirFolder**. Zezwól na dostęp do sieci lokalnej i powiadomienia,
gdy macOS o nie poprosi.
Po zamknięciu wyboru folderu bez zapisu pojawia się dodatkowo **Zapisz pliki…**
— dla ostatniej odebranej, niezapisanej przesyłki.

### Odbieranie plików z iPhone'a

1. Uruchom aplikację i sprawdź w jej menu stan **Gotowy do odbioru**.
2. Na iPhonie zaznacz pliki i wybierz
   **Udostępnij → AirDrop → AirFolder**.
3. Przy pierwszym parowaniu wpisz na iPhonie kod pokazany w oknie AirFolder
   na Macu. Logo jest przekazywane podczas parowania; restart aplikacji zachowuje
   parowanie. Następnie obserwuj postęp odbioru. Domyślnie po transferze pojawi się wybór folderu.
4. Wybierz folder i kliknij **Zapisz tutaj**. Użyj przycisków
   **Pokaż w Finderze** i **Otwórz** w powiadomieniu.
5. Jeśli anulujesz wybór folderu, pliki pozostają w trwałym buforze.
   Dla ostatniej przesyłki wybierz **Zapisz pliki…** w menu AirFolder, aby ponownie
   wskazać folder. Po zapisaniu tej paczki opcja znika. Możesz też kliknąć
   przypomnienie **Pliki odebrane** w Centrum powiadomień.

Wybierz pozycję **AirFolder** (lub swoją nazwę odbiorcy), aby trafić do naszego
odbiornika. Jest to osobna pozycja w AirDrop. Gdy aplikacja jest uruchomiona,
przyjmuje przesyłki do bufora automatycznie. Bieżący transfer anulujesz
przyciskiem **×** na panelu postępu.

### Ustawienia

Otwórz **AirFolder → Ustawienia…**:

- **Nazwa widoczna w AirDrop** — własna nazwa, np. „Studio — zdjęcia”. Po kliknięciu
  **Zapisz** jest zapamiętywana i stosowana bez restartu aplikacji. Zmiana nazwy
  tworzy nową tożsamość odbiornika i wymaga nowego PIN-u na urządzeniach nadawców,
  aby iOS pobrał nową nazwę i logo. Otwórz ponownie listę AirDrop i wybierz nową
  nazwę. Zapis bez zmiany nazwy oraz zwykły restart zachowują parowanie.
- **Awatar w AirDrop** — **Wybierz zdjęcie…** otwiera wybór obrazu i kadrowanie.
  Przeciągaj obraz w okręgu i użyj suwaka przybliżenia, potem kliknij **Użyj awatara**.
  Okrągły podgląd w Ustawieniach pokazuje wybrany kadr. **Przywróć logo** przywraca
  grafikę AirFolder. Całość zatwierdza **Zapisz**. Nowa grafika wymaga nowego PIN-u
  na iPhonie. **Po sparowaniu zamknij i ponownie otwórz AirDrop na iPhonie**, aby
  odświeżyć wyświetlany awatar. Ponowny zapis tego samego obrazu i restart zachowują parowanie.
  Gotowy obraz jest przechowywany w aplikacji — oryginalny plik można później usunąć.
- **Zapisywanie nowych plików** — domyślnie pytanie o folder; opcjonalnie automatyczny
  zapis do wybranego folderu. Dotyczy tylko nowych przesyłek. Odłożone paczki
  pozostają do ręcznego zapisania. Przy odłączonym dysku lub błędzie pliki czekają
  w buforze, bez ponawiania zapisu w pętli.
- **Dźwięk po zapisaniu plików** — włączony domyślnie, można go wyłączyć.

**Zapisz** zatwierdza ustawienia. Zamknięcie okna bez zapisu pomija zmiany.

### Panel postępu i powiadomienia

- Podczas odbioru pojawia się mały panel w prawym górnym rogu: **niebieski pasek
  postępu**, podsumowanie zdjęć/wideo, odebrane MB i miniatura, jeśli iPhone ją
  udostępni. Aktualizacja następuje mniej więcej co 100 ms, bez przejmowania
  klawiatury i aktywnego okna.
- Tekst pokazuje odebrane MB i liczbę plików. Wypełnienie paska opiera się na
  znanej długości transmisji lub szacunku według rozpakowanego archiwum iOS.
  Bez rozmiaru pasek pokazuje postęp liczby plików lub animowaną aktywność.
- **×** anuluje odbieranie i usuwa niekompletne dane. Podczas kopiowania do
  folderu docelowego anuluje zapis, zachowując gotową paczkę w buforze.
- Przy ręcznym zapisie po odebraniu otwiera się wybór folderu. Anulowanie okna zachowuje pliki w buforze
  i dodaje systemowe przypomnienie **Wybierz folder**.
- Po zapisaniu: podsumowanie zdjęć, wideo i innych plików, opcjonalna miniatura,
  dźwięk oraz dwa od razu widoczne przyciski **Pokaż w Finderze** i **Otwórz**.
  Panel pozostaje do kliknięcia akcji albo zamknięcia **×**. Przyciski wskazują
  rzeczywiste nowe ścieżki, także po zmianie nazw z powodu kolizji.

Panele postępu i zakończenia są własnymi oknami AppKit stylizowanymi na kartę
AirDrop. Panel zakończenia pokazuje akcje bez dodatkowego menu „Opcje” i działa
podczas pracy aplikacji. Przypomnienia o plikach oczekujących na wybór folderu
korzystają z UserNotifications i trafiają do systemowego Centrum powiadomień.

## Zgodność i historia zmian

- Zbudowana natywna aplikacja AppKit; odbiornik HTTP3/PIN jako proces pomocniczy,
  bufor i odbiornik loopback HTTPS w Pythonie bez pakietów pip.
- **Wersja 0.5.0:** zwykły pakiet uruchamia natywny odbiornik z logo, oknem PIN
  należącym do aplikacji i trwałym parowaniem. iPhone potwierdził odbiór bez
  ponownego kodu po restarcie odbiornika; test paczki obejmuje też cykl życia
  trzech procesów i zmianę nazwy. Domyślna ważność parowania: 30 dni.
- **Wersja 0.5.2:** zmiana nazwy wymienia pełną tożsamość i ponownie publikuje
  usługi parowania. Potwierdzone na iPhonie: nowa nazwa i nowy PIN; restart
  z tą samą nazwą zachowuje parowanie. Wcześniejsza próba 0.5.1 zmieniała tylko
  identyfikatory/IRK, co pozwalało iPhone'owi nadal rozpoznawać stary kontakt.
- **Wersja 0.6.0:** awatar odbiorcy na iPhonie z okrągłym podglądem, kadrowaniem
  przez przeciąganie/przybliżanie i przywracaniem logo. Nazwa i awatar są stosowane
  razem; aktualizacja z domyślnym logo zachowuje dotychczasowe parowanie.
  Usunięto widoczne procenty z paneli postępu.
- **Wersja 0.6.1:** fizyczny iPhone potwierdził własny awatar po ponownym otwarciu
  AirDrop. Dodano wskazówkę o odświeżeniu listy po parowaniu.
- **Wersja 0.6.2:** warunkowe **Zapisz pliki…** w menu dla ostatniej odebranej
  przesyłki po odłożeniu zapisu. Otwiera ponownie wybór folderu, jest ukryte podczas
  zapisywania i znika po zakończeniu. Identyfikator ostatniego odbioru jest
  zachowywany także po zapisaniu paczki oraz restarcie aplikacji.
- **Wersja 0.6.3:** krótszy nagłówek i treść systemowego przypomnienia o zapisie,
  aby zmieścić informację o plikach obok przycisku **Wybierz folder**.
- Lokalnie sprawdzono strumieniowy odbiór do bufora, zapis do wybranego miejsca
  przez IPC, powrót do oczekującej paczki po restarcie i kolizje nazw.
- **Potwierdzono na fizycznych urządzeniach: iOS 26.6.1 → macOS 26.5.2
  (2026-11-05).** Użytkownik potwierdził pojawienie się okna wyboru folderu,
  przesłanie jednego pliku i poprawny zapis w wybranym miejscu. Dziennik
  odbiornika potwierdza zakończony transfer dvzip: 1 plik, 17 063 bajty transmisji.
- Przeszło 95 testów lokalnych oraz test gotowego pakietu przez IPC i TLS,
  porównujący SHA-256 pliku 2 MiB.
- **Poprawka 0.1.1:** próba wysłania paczki 10 plików ujawniła, że iOS dołącza
  wewnętrzne ścieżki `Containers/…` i `Media/PhotoData/OutgoingTemp/…`.
  Odbiornik korzysta teraz z listy wybranych elementów (`Files` z żądania Ask):
  osobne pliki zapisuje bezpośrednio w folderze docelowym, a świadomie wysłane
  foldery zachowuje wraz z ich zawartością. Lokalnie odtworzono układ tej paczki:
  powstało dokładnie 10 plików w katalogu głównym, z identycznymi SHA-256.
  Użytkownik potwierdził, że ponowny transfer z iPhone'a zapisuje paczkę poprawnie.
- **Wersja 0.2.0:** zgodnie z kolejną decyzją użytkownika wybór folderu odbywa
  się po pobraniu plików do trwałego bufora. Dodano systemowe powiadomienia,
  postęp odbierania i zapisywania oraz zapis odłożonych paczek. Log potwierdza
  kolejne udane odbiory paczek 10 plików i przyjęcie powiadomień przez macOS.
- **Wersja 0.2.1:** graficzny panel z paskiem postępu i anulowaniem. Sprawdzono
  render panelu oraz przeliczanie postępu (bajty transmisji i rozpakowanego
  archiwum mają osobne jednostki). Potwierdzono odbiór filmów około 146 MB
  w 2–3 s, ale użytkownik zgłosił około 20 s od kliknięcia do panelu.
- **Wersja 0.2.2:** możliwości HEVC/HEIF pobierane z tego Maca podczas budowania;
  miniatura dekodowana w tle po pokazaniu panelu. Test AppKit potwierdza
  responsywność panelu nawet przy zatrzymanym dekoderze oraz odrzucanie spóźnionej
  miniatury po zamknięciu. Dodano pomiary TLS, metadanych, IPC, kolejki UI
  i pierwszego rysowania panelu. Wpływ na zgłoszone 20 s wymaga ponownej próby
  z tym samym filmem na iPhonie.
- **Wersja 0.2.3:** panel zakończenia z bezpośrednimi przyciskami **Pokaż w Finderze**
  i **Otwórz**. Sprawdzono render oraz przejście z postępu do zakończenia,
  działanie obu przycisków i zamykanie bez anulowania transferu.
- **Wersja 0.3.0:** nazwa **AirFolder**, znak użytkownika w pasku menu i niebiesko-
  turkusowa ikona aplikacji. `/Discover` i `/Ask` zgłaszają rzeczywisty model Maca
  (`hw.model`) zamiast nazwy OpenDrop. Wybór grafiki odbiorcy na iPhonie pozostaje
  po stronie iOS; efekt wymaga sprawdzenia na urządzeniu.
- **Wersja 0.4.0:** menu do codziennego używania i Ustawienia: nazwa odbiorcy,
  opcjonalny stały folder oraz dźwięk zakończenia. Zmiana nazwy została sprawdzona
  w trakcie transmisji TLS i zapisu. Kontrole Swift obejmują trwałość preferencji,
  odłożone paczki, przeniesiony/odłączony folder, anulowanie i brak ponawiania.
  Użytkownik potwierdził, że zgłaszanie modelu Mac Studio nie zmieniło sylwetki
   odbiorcy na iPhonie; nie ma potwierdzonej poprawki tego wyglądu.
- **Wersja 0.4.1:** uproszczone menu: usunięto zapis z bufora i wstrzymywanie
  odbioru, a **O AirFolder** przeniesiono bezpośrednio do menu głównego.
  Usunięto podmenu Pomoc oraz pozycje instrukcji i otwierania dziennika.
- Większe paczki, dłuższe oczekiwanie i dyski zewnętrzne wymagają jeszcze testów
  z iPhone'em.
- Punktem odniesienia są badania OpenDrop i poprawki dla iOS 26 w projekcie
  `jedbillyb/airdrop-mt7921`, którego autorzy opisują działający odbiór na Linuksie.

### Zakres

Odbiór zwykłych plików oraz folderów zawierających pliki, po jednej przesyłce
naraz. Kilka plików w jednej przesyłce korzysta z jednego wyboru folderu.
Wersja ta nie obsługuje udostępniania samych URL-i, kontaktów, haseł, dowiązań
ani pustych folderów. Nie odtwarza integracji z kontem Apple/trybem Tylko kontakty.
Zgodność nowego parowania kodem AirDrop pozostaje częścią testu na iPhonie.

Przy budowaniu `scripts/media-capabilities.m` pobiera z systemowego PhotosFormats
rzeczywiste tabele kodeków i kontenerów tego Maca. W `/Discover` są przesyłane
jako JSON w polu danych binarnego plist. Dzięki temu iOS może rozpoznać obsługę
HEVC/HEIF zamiast wybierać konwersję do starszych formatów. Deklaracje obsługi
zasobów edycji i Live Photos są pomijane. Jeśli opcjonalne prywatne API jest
niedostępne, aplikacja wraca do podstawowego profilu zgodności.

Wybór formatu nadal zależy od aplikacji i opcji udostępniania na iPhonie.
Do testów identyczności bajtów użyj pliku z aplikacji Pliki. Metadane osadzone
we właściwym pliku pozostają w nim; dodatkowe rekordy AppleDouble (`._…`)
są pomijane. Zachowanie Live Photos wymaga osobnego testu.

### Pomiar opóźnienia

Od 0.2.2 obie części aplikacji zapisują czas UTC z milisekundami (`Z`),
bez nazw plików i miniatur. `Metadata` rozdziela odczyt sieciowy i parsowanie;
`UI event` podaje czas IPC i kolejki głównej; `Progress card drawn` oznacza
pierwsze rysowanie, a `Progress panel presented` zlecenie prezentacji AppKit.
`/Discover` służy też przeglądaniu odbiorników — nie wyznacza chwili kliknięcia
w iPhonie. Do pełnego pomiaru potrzebny jest również czas kliknięcia użytkownika.

### Zapis

- Pierwszy zapis odbywa się strumieniowo w
  `~/Library/Application Support/AirFrajer/Incoming/`.
- Dopiero kompletna, zweryfikowana przesyłka trafia na listę oczekujących.
  Anulowanie wyboru folderu lub zamknięcie aplikacji zachowuje tę paczkę.
- Po wyborze miejsca pliki są kopiowane do ukrytego katalogu `.airfrajer-…`
  na dysku docelowym. Uchwyty folderów są utrzymywane przez cały zapis.
- Po sprawdzeniu kompletności każdy element jest publikowany operacją
  niepozwalającą nadpisać istniejącego pliku. Kolizje dostają sufiks `(1)`, `(2)`.
- Po udanym zapisie kopia w buforze jest usuwana. Błąd zapisu zachowuje odebraną
  paczkę do ponownej próby. Normalne przerwanie usuwa nieukończone pliki robocze.
  Po utracie zasilania lub odłączeniu
  dysku może pozostać ukryty katalog konkretnej niedokończonej przesyłki.
- Publikacja jest atomowa dla pojedynczego elementu, nie całej paczki.
  Błąd w trakcie publikowania paczki pozostawia wcześniej ukończone elementy.
- Oczekujące paczki nie mają limitu czasu na wybór folderu. Limit rozpoczęcia
  zaakceptowanego transferu to 90 s, a bezczynności podczas odbioru 30 s.

## Budowanie i testy

```sh
python3 -m unittest discover -s tests -v
python3 scripts/build.py
python3 scripts/smoke.py
open dist/AirFolder.app
```

Wymagane: macOS 26 na Apple Silicon, narzędzia Command Line Tools ze Swift,
Python 3.9+. Natywny transport sprawdzono na macOS 26.5.2 z iOS 26.6.1.
Prototyp zapisuje ścieżkę bieżącego Pythona w `Info.plist`; przygotowana aplikacja
jest lokalnym buildem na ten Mac, a nie samowystarczalnym instalatorem na inne
komputery. Sygnatura aplikacji jest lokalna (ad hoc).

### Grafika i nazwa odbiorcy

Źródłem znaku jest `docs/airfolder_znak.svg`. Budowanie generuje z niego szablon
PDF do paska menu (system dopasowuje kolor do tła) oraz `AirFolder.icns`
z rozmiarami 16–1024 px. Paleta ikony: błękit `#2CBDF1`, niebieski `#1876E8`,
głęboki niebieski `#0C479D` i biały znak `#F3FBFF`. Podgląd 1024 px znajduje się
w `.build/artwork/AirFolder.png`.

Domyślna nazwa widoczna w AirDrop to **AirFolder**. `ReceiverModelName` przekazuje
model sprzętu, ale próba z `Mac13,1` nie zmieniła sylwetki na iPhonie.
W sprawdzonych parserach `/Discover` nie znaleziono pola na SVG/PNG awatara.
Prześledzony kod macOS pobiera grafikę rozpoznanego kontaktu, a przy jego braku
generuje domyślny awatar. Ikona aplikacji macOS nie jest przesyłana do iPhone'a.
Nowszy protokół parowania Rapport przenosi zdjęcie w tymczasowej tożsamości.
Osobny prototyp **AirFolder Logo Test** przekazał logo fizycznemu iPhone'owi
po wpisaniu PIN-u, ale telefon zatrzymał się przy ustalaniu połączenia do plików.
Uzupełniono ten krok; lokalny test HTTP3 → backend Python przeszedł pełny
odbiór pliku 2 MiB z porównaniem SHA-256 i ponownym otwarciem trwałego bufora.
**6 listopada użytkownik potwierdził widoczność logo AirFolder na iPhonie.**
Transfer prototypem zatrzymał się jeszcze w negocjacji protokołu (`INVALID_ALPN_PROTOCOL`).
Uzupełniono `h3` i potwierdzono pełny transfer lokalnie z klientem wymuszającym
ten protokół. Kolejna fizyczna próba zakończyła się `/Ask` i `/Upload` HTTP 200.
Zgłoszony opóźniony pasek postępu wynikał z pobierania całego pliku przed
przekazaniem go do backendu. Most przekazuje teraz bloki na bieżąco; testy 8 MiB
potwierdziły zgodny SHA-256, postęp przed końcem odbioru i skuteczne anulowanie.
Następna fizyczna próba potwierdziła 5 plików / około 427 MB: panel narysowany
92 ms po rozpoczęciu odbioru, transfer zakończony po 8,85 s, HTTP 200.

**Docelowo pozostajemy przy osobnym odbiorniku AirFolder z własnym logo,
PIN-em i bezpośrednim odbiorem — zgodnie z decyzją użytkownika.** Ten tryb
został sprawdzony w prototypie. iOS przypisuje go do sekcji **Osoby / Inne osoby**.
Sekcja **Moje urządzenia** wymaga rozpoznania tego samego
konta Apple, którego integracji AirFolder obecnie nie ma.
Sprawdzenie tożsamości i brokera wykrywania zwróciło brak prywatnych uprawnień.
macOS odrzucił też lokalne próby podpisu z tymi zastrzeżonymi uprawnieniami
(AMFI -424). Zakres sprawdzenia i różnicę względem trybu systemowego opisano w
[badaniu „Moich urządzeń”](docs/airdrop-own-devices.md).
Kod transportu współdzielony przez próby i pakiet znajduje się w `scripts/research/`;
`NativeReceiver/helper.swift` jest bezokienkowym punktem wejścia zwykłej aplikacji.
Od wersji 0.5.0 `dist/AirFolder.app` uruchamia ten odbiornik przez backend Python.
[Trwałe parowanie](docs/durable-pairing.md) przeszło lokalne testy restartu i
PairVerify oraz fizyczny transfer iPhone'a po restarcie bez ponownego kodu.
W 0.5.2 użytkownik potwierdził też poprawną nazwę i PIN po zmianie ustawień
oraz ponowne połączenie zwykłej aplikacji po restarcie bez kodu.
Szczegóły, wyniki prób i zakres potwierdzenia opisano w
[badaniu ikony odbiorcy](docs/airdrop-recipient-icon.md).
Po zmianie nazwy zamknij i ponownie otwórz arkusz AirDrop, aby odświeżyć listę.

## Pliki aplikacji

- `Sources/AirFolder.swift` — pasek menu, systemowy wybór folderu, sterowanie procesem.
- `Sources/Branding.swift`, `scripts/artwork.swift` — znak paska menu i ikona aplikacji.
- `Sources/AppPreferences.swift`, `Sources/SettingsWindowController.swift` — ustawienia i stały folder zapisu.
- `Sources/TransferProgressBanner.swift` — panele postępu i zakończenia, miniatury i przyciski.
- `Sources/TransferPresentation.swift` — jednostki postępu, podsumowanie plików i akcje otwierania.
- `Sources/TransferNotifications.swift` — systemowe przypomnienia o wyborze folderu.
- `receiver/main.py` — cykl życia procesu i komunikacja JSON z aplikacją.
- `receiver/native.py`, `NativeReceiver/helper.swift` — nadzorowanie natywnego
  odbiornika PIN/PairVerify/HTTP3, gotowość, zmiana nazwy i zamykanie.
- `Sources/PairingWindowController.swift` — okno kodu parowania.
- `Sources/ReceiverAvatar.swift`, `Sources/AvatarCropWindowController.swift` —
  obraz awatara, okrągły podgląd, kadrowanie i identyfikator wyświetlanych pikseli.
- `receiver/configuration.py` — walidacja nazwy odbiorcy przy uruchomieniu i zmianie na żywo.
- `receiver/bonjour.py` — ogłaszanie odbiornika przez natywny mDNSResponder/AWDL.
- `receiver/sessions.py` — zgoda i folder przypisane do przesyłki i adresu nadawcy.
- `receiver/layout.py` — rozróżnianie ścieżek roboczych iOS i wybranych folderów.
- `receiver/inbox.py` — trwały bufor, odłożone paczki i kopiowanie do folderu docelowego.
- `receiver/http.py` — Discover, Ask, Upload; TLS i strumieniowe ramkowanie HTTP.
- `receiver/media.py`, `scripts/media-capabilities.m` — natywne możliwości multimedialne tego Maca.
- `receiver/archive.py` — dvzip/gzip/ODC, bezpieczny zapis i kolizje nazw.
- `tests/` — testy zachowania i integracyjne HTTPS.

Stan lokalny, samopodpisany certyfikat odbiornika oraz dziennik znajdują się w
`~/Library/Application Support/AirFrajer/`. Dziennik nie zapisuje treści żądań,
tokenów Apple ani zawartości przesyłanych plików. Wybrane ostatnio miejsce jest
zapamiętywane w preferencjach aplikacji. Licencja: GPL-3.0-only; źródła badań:
`THIRD_PARTY.md`.

Historyczna nazwa katalogu danych i identyfikator `pl.airfrajer.prototype` są
stabilnymi identyfikatorami instalacji: zmiana nazwy aplikacji zachowuje odebrane
paczki, ostatni folder i zgody systemowe.
