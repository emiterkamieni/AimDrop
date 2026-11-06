import Foundation

struct PreferenceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SaveDestination: Codable, Equatable {
    let bookmark: Data
    let displayPath: String
    let volumeUUID: String?

    init(url: URL) throws {
        let url = url.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey])
        guard values.isDirectory == true else { throw PreferenceError(message: L10n.text("Choose a save folder.", "Wybierz folder zapisu.")) }
        bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil)
        displayPath = url.path
        volumeUUID = values.volumeUUIDString
    }

    func resolve() throws -> (url: URL, refreshed: SaveDestination) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale).resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey])
        guard values.isDirectory == true, volumeUUID == nil || volumeUUID == values.volumeUUIDString else {
            throw PreferenceError(message: L10n.text("The save folder is unavailable. Connect the drive or choose another folder in Settings.", "Folder zapisu jest niedostępny. Podłącz dysk lub wybierz inny folder w Ustawieniach."))
        }
        let refreshed = stale || url.path != displayPath ? try SaveDestination(url: url) : self
        return (url, refreshed)
    }
}

struct AppPreferences: Codable, Equatable {
    var receiverName = "AimDrop"
    var automaticSave = false
    var destination: SaveDestination?
    var completionSound = true
    var avatarPNG: Data? = nil
    var language = AppLanguage.system
    var updateNotifications = true

    private enum CodingKeys: String, CodingKey {
        case receiverName, automaticSave, destination, completionSound, avatarPNG, language, updateNotifications
    }

    static func normalizedName(_ value: String) throws -> String {
        // Keep this contract identical to receiver/configuration.py.
        let invalid = value.unicodeScalars.contains { scalar in
            let code = scalar.value
            return code < 0x20 || (0x7f...0x9f).contains(code) || (0xd800...0xdfff).contains(code)
                || (0x2028...0x202e).contains(code) || (0x2066...0x2069).contains(code)
        }
        guard !invalid else { throw PreferenceError(message: L10n.text("The name cannot contain control characters or line breaks.", "Nazwa nie może zawierać znaków sterujących ani nowych wierszy.")) }
        let name = value.trimmingCharacters(in: CharacterSet(charactersIn: " ")).precomposedStringWithCanonicalMapping
        guard !name.isEmpty else { throw PreferenceError(message: L10n.text("Enter a receiver name.", "Wpisz nazwę odbiorcy.")) }
        guard name.utf8.count <= 128 else { throw PreferenceError(message: L10n.text("The name is too long. Choose a shorter receiver name.", "Nazwa jest za długa. Użyj krótszej nazwy odbiorcy.")) }
        return name
    }

    func validated(checkAvatar: Bool = true) throws -> AppPreferences {
        var result = self
        result.receiverName = try Self.normalizedName(receiverName)
        if checkAvatar, let avatarPNG { _ = try ReceiverAvatar(png: avatarPNG) }
        if automaticSave && destination == nil {
            throw PreferenceError(message: L10n.text("Choose a folder for automatic saving.", "Wybierz folder dla automatycznego zapisu."))
        }
        return result
    }
}

extension AppPreferences {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        receiverName = try values.decode(String.self, forKey: .receiverName)
        automaticSave = try values.decode(Bool.self, forKey: .automaticSave)
        destination = try values.decodeIfPresent(SaveDestination.self, forKey: .destination)
        completionSound = try values.decode(Bool.self, forKey: .completionSound)
        avatarPNG = try values.decodeIfPresent(Data.self, forKey: .avatarPNG)
        // Missing or future language codes must never reset existing preferences.
        language = (try? values.decode(String.self, forKey: .language)).flatMap(AppLanguage.init(rawValue:)) ?? .system
        updateNotifications = try values.decodeIfPresent(Bool.self, forKey: .updateNotifications) ?? true
    }
}

final class PreferencesStore {
    private let defaults: UserDefaults
    // Durable key shared with previous application names.
    private let key = "AirFolderPreferences.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> AppPreferences {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(AppPreferences.self, from: data),
              let valid = try? value.validated(checkAvatar: false) else { return AppPreferences() }
        return valid
    }

    @discardableResult func save(_ value: AppPreferences) throws -> AppPreferences {
        let valid = try value.validated()
        defaults.set(try JSONEncoder().encode(valid), forKey: key)
        return valid
    }
}
