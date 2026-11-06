import Foundation

enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case english = "en"
    case polish = "pl"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case swedish = "sv"
    case czech = "cs"
    case ukrainian = "uk"
    case japanese = "ja"
    case korean = "ko"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var nativeName: String {
        switch self {
        case .system: return L10n.text("System default", "Język systemu")
        case .english: return "English"
        case .polish: return "Polski"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .spanish: return "Español"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .dutch: return "Nederlands"
        case .swedish: return "Svenska"
        case .czech: return "Čeština"
        case .ukrainian: return "Українська"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }
    var displayName: String { nativeName }
}

/// Process-local selection shared by the app and headless Swift tools.
/// Preferences remain the caller's responsibility.
enum L10n {
    static let didChangeNotification = Notification.Name("AimDropLanguageDidChange")

    private final class Selection: @unchecked Sendable {
        let lock = NSLock()
        var effective = L10n.resolve(preferredLanguages: Locale.preferredLanguages)
        var catalogs: [AppLanguage: [String: String]] = [:]
    }
    private static let selection = Selection()

    static func resolve(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
            guard let base = parts.first else { continue }
            if base == "zh" {
                if parts.contains("hant") { return .traditionalChinese }
                if parts.contains("hans") { return .simplifiedChinese }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .traditionalChinese : .simplifiedChinese
            }
            if let language = AppLanguage(rawValue: String(base)), language != .system { return language }
        }
        return .english
    }

    static func configure(_ language: AppLanguage) {
        let effective = language == .system ? resolve(preferredLanguages: Locale.preferredLanguages) : language
        selection.lock.lock()
        let changed = selection.effective != effective
        selection.effective = effective
        selection.lock.unlock()
        guard changed else { return }
        // AppKit observers can refresh existing windows without replacing their state.
        if Thread.isMainThread {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didChangeNotification, object: nil)
            }
        }
    }

    static var effectiveLanguage: AppLanguage {
        selection.lock.lock(); defer { selection.lock.unlock() }
        return selection.effective
    }
    static var languageCode: String { effectiveLanguage.rawValue }
    static var locale: Locale { locale(for: effectiveLanguage) }
    private static func locale(for language: AppLanguage) -> Locale {
        Locale(identifier: language == .english ? "en_US" : language.rawValue)
    }
    static func text(_ english: String, _ polish: String) -> String {
        translated(english, polish, language: effectiveLanguage)
    }
    static func format(_ english: String, _ polish: String, _ args: CVarArg...) -> String {
        let language = effectiveLanguage
        return String(format: translated(english, polish, language: language),
                      locale: locale(for: language), arguments: args)
    }

    static func pluralCategory(_ count: Int, language: AppLanguage) -> String {
        let last = count % 10, lastTwo = count % 100
        switch language {
        case .polish:
            if count == 1 { return "one" }
            return (2...4).contains(last) && !(12...14).contains(lastTwo) ? "few" : "many"
        case .ukrainian:
            if last == 1 && lastTwo != 11 { return "one" }
            return (2...4).contains(last) && !(12...14).contains(lastTwo) ? "few" : "many"
        case .czech: return count == 1 ? "one" : ((2...4).contains(count) ? "few" : "other")
        case .japanese, .korean, .simplifiedChinese, .traditionalChinese: return "other"
        case .french, .portuguese: return (0...1).contains(count) ? "one" : "other"
        default: return count == 1 ? "one" : "other"
        }
    }

    /// Catalog keys are @<key>.<one|few|many|other>; arguments retain printf types.
    static func plural(_ key: String, count: Int, _ english: String, _ polish: String, _ args: CVarArg...) -> String {
        let language = effectiveLanguage
        let table = catalog(for: language)
        let category = pluralCategory(count, language: language)
        let template = table["@\(key).\(category)"] ?? table["@\(key).other"]
            ?? (language == .polish ? polish : english)
        return String(format: template, locale: locale(for: language), arguments: args)
    }

    private static func translated(_ english: String, _ polish: String, language: AppLanguage) -> String {
        catalog(for: language)[english] ?? (language == .polish ? polish : english)
    }

    private static func catalog(for language: AppLanguage) -> [String: String] {
        selection.lock.lock(); defer { selection.lock.unlock() }
        if let cached = selection.catalogs[language] { return cached }
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL { directories.append(resources.appendingPathComponent("Localizations")) }
        // Command-line checks compile the same source without an app bundle.
        if Bundle.main.bundleURL.pathExtension != "app" {
            directories.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Localizations"))
        }
        let table = directories.lazy.compactMap { directory -> [String: String]? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(language.rawValue + ".json")) else { return nil }
            return try? JSONDecoder().decode([String: String].self, from: data)
        }.first ?? [:]
        selection.catalogs[language] = table
        return table
    }
}
