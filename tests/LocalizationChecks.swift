import Foundation

@main struct LocalizationChecks {
    /// Optional fixture lives beside the standalone test executable, never in source resources.
    static func checkCatalog() throws {
        guard CommandLine.arguments.contains("--catalog-fixture") else { return }
        let directory = Bundle.main.resourceURL!.appendingPathComponent("Localizations")
        let file = directory.appendingPathComponent("de.json")
        let existed = FileManager.default.fileExists(atPath: directory.path)
        precondition(!FileManager.default.fileExists(atPath: file.path), "Use a fresh temporary test-executable directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: file)
            if !existed { try? FileManager.default.removeItem(at: directory) }
        }
        let fixture = ["Catalog fixture %@": "Katalogprobe %@", "@fixture.count.one": "%ld Datei", "@fixture.count.other": "%ld Dateien"]
        try JSONEncoder().encode(fixture).write(to: file)
        L10n.configure(.german)
        precondition(L10n.format("Catalog fixture %@", "Próba katalogu %@", "ok") == "Katalogprobe ok")
        precondition(L10n.plural("fixture.count", count: 1, "%ld item", "%ld element", 1) == "1 Datei")
        precondition(L10n.plural("fixture.count", count: 2, "%ld items", "%ld elementy", 2) == "2 Dateien")
        precondition(L10n.text("Untranslated fixture", "Nieprzetłumaczona próba") == "Untranslated fixture")
        print("PASS: Swift JSON catalog loading, format placeholders, plural lookup, English fallback")
    }

    static func main() throws {
        try checkCatalog()
        precondition(AppLanguage.allCases.count == 16)
        for language in AppLanguage.allCases {
            let decoded = try JSONDecoder().decode(AppLanguage.self, from: JSONEncoder().encode(language))
            precondition(decoded == language && !language.nativeName.isEmpty)
        }
        let cases: [([String], AppLanguage)] = [
            (["zz", "pl-PL", "en"], .polish), (["de-DE", "pl"], .german),
            (["en-GB", "pl"], .english), (["pt_BR"], .portuguese),
            (["zh-TW"], .traditionalChinese), (["zh-HK"], .traditionalChinese),
            (["zh-Hans-TW"], .simplifiedChinese), (["zh-Hant-CN"], .traditionalChinese),
            (["zh_CN"], .simplifiedChinese), (["zh"], .simplifiedChinese),
            (["ar", "xx"], .english), ([], .english)
        ]
        for (preferences, expected) in cases { precondition(L10n.resolve(preferredLanguages: preferences) == expected) }
        L10n.configure(.system)
        precondition(L10n.effectiveLanguage == L10n.resolve(preferredLanguages: Locale.preferredLanguages))
        L10n.configure(.english)
        precondition(L10n.format("Fixture %.1f %@", "Próba %.1f %@", 1.5, "ok") == "Fixture 1.5 ok")
        L10n.configure(.polish)
        precondition(L10n.format("Fixture %.1f %@", "Próba %.1f %@", 1.5, "ok") == "Próba 1,5 ok")
        precondition(L10n.languageCode == "pl")
        let counts = [0, 1, 2, 4, 5, 11, 12, 14, 21, 22, 101, 112]
        let categories: [(AppLanguage, [String])] = [
            (.polish, ["many", "one", "few", "few", "many", "many", "many", "many", "many", "few", "many", "many"]),
            (.ukrainian, ["many", "one", "few", "few", "many", "many", "many", "many", "one", "few", "one", "many"]),
            (.czech, ["other", "one", "few", "few", "other", "other", "other", "other", "other", "other", "other", "other"])
        ]
        for (language, expected) in categories {
            precondition(counts.map { L10n.pluralCategory($0, language: language) } == expected)
        }
        for language in [AppLanguage.japanese, .korean, .simplifiedChinese, .traditionalChinese] {
            precondition(counts.allSatisfy { L10n.pluralCategory($0, language: language) == "other" })
        }
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            L10n.configure(index % 2 == 0 ? .english : .polish)
            precondition(["Fixture", "Próba"].contains(L10n.text("Fixture", "Próba")))
            precondition([AppLanguage.english, .polish].contains(L10n.effectiveLanguage))
        }
        L10n.configure(.english)
        print("PASS: 15 languages, Codable, system/Chinese resolution, localized numbers, plural categories, concurrent selection")
    }
}
