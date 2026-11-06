# Autostart — AimDrop

Implementation notes for native macOS login items, introduced in version 0.6.4.

W **Ustawieniach** zaznacz **Uruchamiaj przy logowaniu** i kliknij **Zapisz**.
AimDrop rejestruje swój zwykły pakiet aplikacji jako rzecz otwieraną po
zalogowaniu do macOS. Odznaczenie i zapis wyrejestrowują autostart.

## Integracja

- `Sources/LoginItemManager.swift` korzysta z `SMAppService.mainApp` w systemowym
  frameworku ServiceManagement. Rejestracja nie uruchamia drugiej kopii aplikacji;
  wyrejestrowanie nie zamyka bieżącej.
- Stan pochodzi z macOS. `AppPreferences` nie przechowuje dodatkowej kopii
  ustawienia; aplikacja nie rejestruje się ponownie podczas zwykłego startu.
- Checkbox ma osobny szkic. Zamknięcie okna odrzuca zmianę. Zapis innych ustawień
  nie modyfikuje rejestracji, jeśli checkbox nie był edytowany.
- Stan odświeża się podczas otwierania ustawień i odzyskania przez okno fokusu.
  Własny niezapisany szkic checkboxa jest wtedy zachowany.
- `.requiresApproval` oznacza wyłączony autostart i pokazuje przycisk otwierający
  systemowe ustawienia logowania. `.notFound` przed pierwszą rejestracją jest
  prezentowany jako wyłączony autostart — taki stan zaobserwowano na tym Macu.
- Błąd rejestracji lub wyrejestrowania jest wyświetlany przy checkboxie i pozwala
  ponowić zapis. Pozostałe ustawienia są zapisywane wcześniej. Ich walidacja lub
  błąd zapisu blokują zmianę autostartu.

## Weryfikacja

- `tests/LoginItemChecks.swift`: rzeczywiste kontrolki AppKit, szkic/zamknięcie,
  walidacja, zapis przez AppDelegate, brak zmiany profilu odbiornika przy samym
  autostarcie, zmiany zewnętrzne, wymaganie zgody oraz błędy i ponowienia.
  Systemowa usługa jest w tych testach zastępowana kontrolowanym adapterem.
- Oddzielny podpisany ad hoc pakiet z unikatowym identyfikatorem potwierdził na
  macOS cykl `notFound → enabled → enabled w nowym procesie → notRegistered`.
  Po kontroli został wyrejestrowany. Używał produkcyjnego `LoginItemManager`.
- Przeszły dotychczasowe kontrole ustawień i awatara, test gotowej paczki przez
  IPC/TLS oraz ścisła weryfikacja podpisu aplikacji i procesu pomocniczego.
- Podglądy: `.build/aimdrop-settings.png`, `.build/aimdrop-settings-avatar.png`.
- Uruchomienie przez system po rzeczywistym logowaniu pozostaje do sprawdzenia
  przy następnym logowaniu użytkownika.
