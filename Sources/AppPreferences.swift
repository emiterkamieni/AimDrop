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
        guard values.isDirectory == true else { throw PreferenceError(message: "Wybierz folder zapisu.") }
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
            throw PreferenceError(message: "Folder zapisu jest niedostępny. Podłącz dysk lub wybierz inny folder w Ustawieniach.")
        }
        let refreshed = stale || url.path != displayPath ? try SaveDestination(url: url) : self
        return (url, refreshed)
    }
}

struct AppPreferences: Codable, Equatable {
    var receiverName = "AirFolder"
    var automaticSave = false
    var destination: SaveDestination?
    var completionSound = true
    var avatarPNG: Data? = nil

    static func normalizedName(_ value: String) throws -> String {
        // Keep this contract identical to receiver/configuration.py.
        let invalid = value.unicodeScalars.contains { scalar in
            let code = scalar.value
            return code < 0x20 || (0x7f...0x9f).contains(code) || (0xd800...0xdfff).contains(code)
                || (0x2028...0x202e).contains(code) || (0x2066...0x2069).contains(code)
        }
        guard !invalid else { throw PreferenceError(message: "Nazwa nie może zawierać znaków sterujących ani nowych wierszy.") }
        let name = value.trimmingCharacters(in: CharacterSet(charactersIn: " ")).precomposedStringWithCanonicalMapping
        guard !name.isEmpty else { throw PreferenceError(message: "Wpisz nazwę odbiorcy.") }
        guard name.utf8.count <= 128 else { throw PreferenceError(message: "Nazwa jest za długa. Użyj krótszej nazwy odbiorcy.") }
        return name
    }

    func validated(checkAvatar: Bool = true) throws -> AppPreferences {
        var result = self
        result.receiverName = try Self.normalizedName(receiverName)
        if checkAvatar, let avatarPNG { _ = try ReceiverAvatar(png: avatarPNG) }
        if automaticSave && destination == nil {
            throw PreferenceError(message: "Wybierz folder dla automatycznego zapisu.")
        }
        return result
    }
}

final class PreferencesStore {
    private let defaults: UserDefaults
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
