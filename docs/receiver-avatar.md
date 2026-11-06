# Awatar odbiorcy — 0.6.1

## Ustawienia

Wybór obrazu otwiera osobny arkusz z okrągłym kadrem, przeciąganiem i suwakiem
przybliżenia 1–4×. Obraz nie może odsłonić pustego obszaru poza własnymi brzegami.
Podgląd i eksport korzystają z tego samego przekształcenia. Eksport to kwadratowy
PNG 256×256; okrąg jest maską podglądu oraz późniejszego wyświetlania na iPhonie.
ImageIO stosuje orientację EXIF przed kadrowaniem.

„Użyj awatara” i „Przywróć logo” zmieniają wersję roboczą ustawień.
Dopiero „Zapisz” zatwierdza obraz. Anulowanie wyboru pliku/kadrowania albo zamknięcie
niezapisanych ustawień zachowuje poprzednią grafikę. Oba arkusze rezerwują wspólny
stan wyboru pliku, aby nie otwierać równocześnie wyboru folderu odebranej paczki.

## Zapis i komunikacja

`AppPreferences.avatarPNG` to opcjonalne dane PNG; brak pola oznacza logo
dołączone do aplikacji. Starsze ustawienia nazwy, folderu i dźwięku nadal się
dekodują. Obraz nie zależy od późniejszej dostępności oryginalnego zdjęcia.

Na potrzeby helpera AppKit materializuje plik pod
`~/Library/Application Support/AirFrajer/Avatars/<sha256-pliku>.png`.
Jest to odtwarzalny plik pochodny; źródłem zapisanych ustawień pozostają preferencje.
Plik powstaje przed zatwierdzeniem preferencji i ma prawa 0600, katalog 0700.
Różne zatwierdzenia mają niezmienne ścieżki, więc oczekujące żądanie nie odczyta
pliku podmienionego przez późniejszy zapis. PNG nie trafia wprost do IPC (limit linii
64 KiB); żądanie `set_profile` przenosi ścieżkę, nazwę, digest i identyfikator żądania.

`ready` i `profile_result` raportują nazwę oraz digest rzeczywiście zastosowanego
obrazu. AppKit sprawdza identyfikator żądania i obie wartości, ignorując spóźnione
potwierdzenia. Zmiana samego awatara także wysyła profil, a równoczesna zmiana nazwy
i obrazu daje jeden reset parowania.

Digest opisuje znormalizowane piksele 256×256 sRGB RGBA8. Ta sama grafika z innej
ścieżki lub z innymi metadanymi PNG nie wymaga kolejnego PIN-u. Helper weryfikuje
plik i digest przed modyfikacją kluczy. Przechowywane awatary są ograniczone do
256×256, 8-bit RGB(A), maksymalnie 512 KiB. Kontrola PNG obejmuje granice chunków,
CRC, IEND, pełny strumień zlib, rozmiar i filtry scanline — ImageIO samo potrafi
uznać uszkodzony, częściowy obraz za kompletny.

## Parowanie

Magazyn v4 dodaje `presentedAvatarDigest`. W v3 brak tego pola oznacza dawne logo
AirFolder. Aktualizacja v3 → v4 przy tej samej nazwie i logo dopisuje fingerprint,
zachowując seed, identyfikatory, IRK, daty i peerów. Pierwsze uruchomienie z nowym
obrazem od razu wykonuje jeden pełny reset. Historyczna migracja v1/v2 zachowuje
wcześniejszą zasadę resetu.

Rzeczywista zmiana nazwy lub pikseli odświeża pełną tożsamość, poświadczenia PIN
i aktory parowania. Powtórzony zapis oraz restart z tym samym profilem nie zmieniają
kluczy. Grafika nadal jest przesyłana jako `RPPairingTemporaryIdentity.contactImageData`.

## Weryfikacja

Przeszły:

- `tests/AvatarChecks.swift`: kierunek przesuwania, pokrycie kadru, limity zoomu,
  EXIF (obrót i odbicie), usunięcie oryginału, odtworzenie pliku pochodnego,
  fingerprint niezależny od metadanych, odrzucenie uciętego IDAT i CRC-valid
  strumienia z niepełną liczbą wierszy;
- `tests/SettingsChecks.swift`: starsze preferencje, zapis obrazu, zmiana tylko
  awatara, korelacja profilu, anulowanie wyboru/kadrowania i niezapisanej zmiany,
  zatwierdzanie przywróconego logo;
- `scripts/native-smoke.py`: rzeczywisty pakiet, migracja v3 bez ponownego PIN-u,
  nowa nazwa/awatar, odrzucenie dawnych kluczy, dokładne bajty PNG po PIN-ie,
  ta sama grafika z innych plików, restart z własnym awatarem, błędne PNG bez
  zmiany kluczy, przywrócenie logo, HTTP3/SHA-256, bufor i cykl życia procesów;
- testy trwałego PairVerify, 95 testów Pythona, model postępu i ścisła weryfikacja
  podpisu gotowego pakietu.

Podglądy UI: `.build/settings-avatar-check.png`, `.build/avatar-crop-check.png`,
`.build/progress-no-percent.png`.

## Próba fizyczna

Użytkownik wybrał własny obraz i ponownie sparował odbiornik. Log potwierdził
przekazanie PNG **109 330 bajtów**, wzajemną wymianę tożsamości oraz zakończony
transfer jednego pliku (63 379 792 bajty transmisji). Początkowo nowy awatar nie
był widoczny na liście. Po ponownym otwarciu AirDrop na iPhonie użytkownik
potwierdził wyświetlenie grafiki. W 0.6.1 ustawienia i komunikat po zapisaniu
profilu wskazują konieczność odświeżenia listy po wpisaniu PIN-u.
