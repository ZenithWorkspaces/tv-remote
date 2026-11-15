import Foundation

/// Turns discovery strings into names a person would actually say.
enum TVDisplayName {
    static func suggestion(brand: TVBrand, discovered: String?) -> String {
        switch brand {
        case .lg:
            if let discovered, isPersonalName(discovered) {
                return discovered.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "LG TV"
        case .roku:
            if let discovered, isPersonalName(discovered) {
                return discovered.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "Roku TV"
        default:
            return "TV"
        }
    }

    static func isPersonalName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || looksTechnical(trimmed) { return false }
        let lower = trimmed.lowercased()
        if lower == "lg" || lower == "roku" || lower == "tv" { return false }
        if lower.contains("webos") || lower.contains("[lg]") { return false }
        if lower.contains("roku tv") && lower.contains("[") { return false }
        if trimmed.range(of: #"[A-Za-z]{1,4}\d{3,}[A-Za-z0-9]*"#, options: .regularExpression) != nil,
           lower.contains("tv") || lower.contains("webos") || lower.contains("lg") {
            return false
        }
        return true
    }

    /// Serials, URNs, and service instance ids such as `amzn.dmgr:…` are not names.
    static func looksTechnical(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("amzn.") || lower.contains("dmgr") { return true }
        if lower.contains("urn:") || lower.hasPrefix("uuid:") || trimmed.contains("://") { return true }
        if trimmed.filter({ $0 == ":" }).count >= 2 { return true }
        let compact = trimmed.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        if compact.count >= 12, compact.allSatisfy(\.isHexDigit) { return true }
        return false
    }

    static func unique(_ base: String, taken: some Sequence<String>) -> String {
        let used = Set(taken)
        if !used.contains(base) { return base }
        var number = 2
        while used.contains("\(base) \(number)") {
            number += 1
        }
        return "\(base) \(number)"
    }
}

struct ShortcutLayout: Codable, Equatable {
    var order: [String]
    var hidden: [String]

    static var standard: ShortcutLayout {
        ShortcutLayout(
            order: ["netflix", "prime", "disney", "youtube", "hulu", "peacock", "paramount", "apple-tv", "spotify", "youtube-tv", "max"],
            hidden: ["youtube-tv", "max"]
        )
    }

    func visibleShortcuts() -> [AppShortcut] {
        let catalog = Dictionary(uniqueKeysWithValues: AppShortcut.all.map { ($0.slug, $0) })
        let hiddenSet = Set(hidden)
        var result: [AppShortcut] = []
        var seen = Set<String>()
        for slug in order {
            guard let shortcut = catalog[slug], !hiddenSet.contains(slug), seen.insert(slug).inserted else { continue }
            result.append(shortcut)
        }
        for shortcut in AppShortcut.all where !hiddenSet.contains(shortcut.slug) && seen.insert(shortcut.slug).inserted {
            result.append(shortcut)
        }
        return result
    }

    func hiddenShortcuts() -> [AppShortcut] {
        let hiddenSet = Set(hidden)
        return AppShortcut.all.filter { hiddenSet.contains($0.slug) }
    }

    func moving(_ slug: String, before target: String) -> ShortcutLayout {
        guard slug != target else { return self }
        var next = visibleShortcuts().map(\.slug)
        guard let from = next.firstIndex(of: slug) else { return self }
        next.remove(at: from)
        let destination = next.firstIndex(of: target) ?? next.endIndex
        next.insert(slug, at: destination)
        var copy = self
        copy.order = next + hidden
        return copy
    }

    func setting(_ slug: String, hidden isHidden: Bool) -> ShortcutLayout {
        var copy = self
        if isHidden {
            if !copy.hidden.contains(slug) {
                copy.hidden.append(slug)
            }
        } else {
            copy.hidden.removeAll { $0 == slug }
            if !copy.order.contains(slug) {
                copy.order.append(slug)
            }
        }
        return copy
    }
}
