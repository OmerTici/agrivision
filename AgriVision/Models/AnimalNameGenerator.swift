import Foundation

/// Suggests cow names in the app's language, skipping names the farmer's herd
/// already uses. Suggestions prefill the Add-Animal name field — the farmer can
/// keep, reshuffle, or clear and type their own.
enum AnimalNameGenerator {
    private static let pools: [AppLanguage: [String]] = [
        .turkish: [
            "Sarıkız", "Karakız", "Pamuk", "Boncuk", "Nazlı", "Benekli",
            "Çiçek", "Şeker", "Fındık", "Badem", "Karamel", "Duman",
            "Bulut", "Yıldız", "Ceylan", "Kiraz", "Vişne", "Zeytin",
            "Maviş", "Sultan", "Elmas", "İnci", "Zümrüt", "Lale",
            "Gonca", "Kınalı", "Alaca", "Tombul", "Bereket", "Kısmet",
            "Meltem", "Yonca", "Çimen", "Petek", "Papatya", "Menekşe",
        ],
        .english: [
            "Daisy", "Bella", "Bessie", "Buttercup", "Clover", "Rosie",
            "Molly", "Dottie", "Maggie", "Annabelle", "Luna", "Hazel",
            "Willow", "Ginger", "Pepper", "Cocoa", "Oreo", "Patches",
            "Honey", "Biscuit", "Marigold", "Petunia", "Pearl", "Ruby",
            "Olive", "Ivy", "Poppy", "Meadow", "Snowflake", "Caramel",
            "Mocha", "Cinnamon", "Nutmeg", "Blossom", "Duchess", "Stella",
        ],
    ]

    /// Returns a random name not already used in the herd. `current` (the
    /// suggestion being replaced) is also excluded so reshuffling always
    /// visibly changes the field. If the whole pool is taken, falls back to
    /// numbering a base name ("Pamuk 2").
    static func suggest(language: AppLanguage, takenNames: [String], current: String? = nil) -> String {
        var taken = Set(takenNames.map(normalize))
        if let current { taken.insert(normalize(current)) }

        let pool = pools[language] ?? pools[.english] ?? []
        if let pick = pool.filter({ !taken.contains(normalize($0)) }).randomElement() {
            return pick
        }

        let base = pool.randomElement() ?? "Cow"
        var n = 2
        while taken.contains(normalize("\(base) \(n)")) { n += 1 }
        return "\(base) \(n)"
    }

    /// Case/whitespace-insensitive form used for uniqueness checks.
    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
