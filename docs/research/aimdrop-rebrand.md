# AimDrop — 0.7.0

Historical release notes; see the repository README for the current version.

## Nazwa i grafiki

Pakiet `dist/AimDrop.app` zawiera główny program `AimDrop` oraz proces pomocniczy
`AimDropReceiver`. `Uruchom.command` otwiera nowy pakiet. Menu, ustawienia, okno
PIN, panele postępu, komunikaty odbiornika i metadane aplikacji używają AimDrop.

Źródłem wszystkich grafik marki jest dostarczony `docs/aimdrop-icon.svg`:

- `AimDrop.icns`: rozmiary 16–1024 px, czarny znak na jasnym zaokrąglonym tle;
- `AimDropStatus.pdf`: oryginalne proporcje 200×180, szablon 20×18 w pasku menu;
- `AimDrop.png`: wspólny obraz dla domyślnego awatara i podglądu ustawień.

## Ciągłość danych i parowanie

Identyfikator `pl.airfrajer.prototype`, katalog `Application Support/AirFrajer`,
klucz preferencji `AirFolderPreferences.v1` i przestrzeń fingerprintów awatara
są trwałymi identyfikatorami poprzedniej instalacji. Wspólny transport zachowuje
moduł `rapportd` i nazwy RPC wymagane przez iPhone'a.

Użytkownik wybrał również zmianę bieżącej nazwy odbiorcy i własnego awatara na
AimDrop z nowym logo. Zmiana obu pól naraz powoduje jeden pełny reset parowania;
przy kolejnym połączeniu wymagany jest nowy PIN. Następnie należy ponownie
otworzyć AirDrop na iPhonie, aby odświeżyć zapamiętany obraz.

Magazyn v3 nie zapisywał fingerprintu obrazu. Odtwarzamy jego historyczny
fingerprint ze starego logo AirFolder, a nie z nowej grafiki dołączonej do
AimDrop. Dzięki temu migracja starego domyślnego logo z v3 i v4 wymaga PIN-u
dokładnie raz. Własny, niezmieniony profil v4 zachowuje parowanie.

## Weryfikacja

- 98 testów Python.
- Natywny test paczki: migracja v3/v4, nowy PIN, zgodne bajty awatara,
  restart z niezmienionym profilem, PairVerify, HTTP3/SHA-256 i cykl życia procesów.
- AppKit: ustawienia, autostart, awatar, zapis ostatniej przesyłki oraz panele
  postępu i zakończenia. Podglądy `.build/aimdrop-settings.png`,
  `.build/aimdrop-progress.png`, `.build/aimdrop-completion.png`.
- Podpisy pakietu i helpera: `codesign --verify --deep --strict`.

## Uruchomienie lokalne

Zainstalowany `dist/AimDrop.app` zgłosił gotowość odbiornika. Bieżący rekord
Bonjour potwierdził nazwę AimDrop, a magazyn parowania — fingerprint nowego
logo. Zastosowano zatwierdzoną przez użytkownika zmianę profilu z pełną wymianą
tożsamości. Zachowano 12 oczekujących przesyłek, historię ostatniego odbioru,
ostatni folder i pozostałe preferencje. Poprzedni pakiet znajduje się w
`.build/releases/`.
