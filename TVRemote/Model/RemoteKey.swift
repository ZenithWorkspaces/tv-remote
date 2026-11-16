import Foundation

enum RemoteKey: String, CaseIterable, Equatable {
    case powerOn
    case powerOff
    case input
    case home
    case back
    case up
    case down
    case left
    case right
    case ok
    case volumeUp
    case volumeDown
    case mute
    case channelUp
    case channelDown
    case playPause
    case rewind
    case fastForward
    case skipPrevious
    case skipNext
    case menu
    case backspace
    case enter
}

enum TVBrand: String, Codable, CaseIterable, Identifiable {
    case roku
    case lg
    case samsung
    case androidtv
    case firetv
    case sony
    case vizio

    var id: String { rawValue }

    var badgeName: String {
        switch self {
        case .roku: return "Roku"
        case .lg: return "LG"
        case .samsung: return "Samsung"
        case .androidtv: return "Google"
        case .firetv: return "Fire"
        case .sony: return "Sony"
        case .vizio: return "Vizio"
        }
    }

    var badgeColor: (red: Double, green: Double, blue: Double) {
        switch self {
        case .samsung: return (0.20, 0.45, 0.95)
        case .roku: return (0.45, 0.36, 0.95)
        case .lg: return (0.55, 0.28, 0.75)
        case .androidtv: return (0.18, 0.62, 0.42)
        case .vizio: return (0.15, 0.55, 0.72)
        case .firetv: return (0.85, 0.45, 0.18)
        case .sony: return (0.35, 0.38, 0.45)
        }
    }

    var displayName: String {
        switch self {
        case .roku: return "Roku"
        case .lg: return "LG webOS"
        case .samsung: return "Samsung"
        case .androidtv: return "Android TV"
        case .firetv: return "Fire TV"
        case .sony: return "Sony Bravia"
        case .vizio: return "Vizio"
        }
    }

    /// Sony stays undiscovered. The other brands have a local control path.
    var isOffered: Bool {
        self != .sony
    }

    var support: SupportLevel {
        isOffered ? .supported : .planned
    }

    var supportsKeyboard: Bool {
        switch self {
        case .roku, .lg, .samsung, .androidtv, .firetv: return true
        default: return false
        }
    }

    var usesInputSheet: Bool {
        switch self {
        case .roku, .lg, .sony: return true
        default: return false
        }
    }
}

enum SupportLevel: Equatable {
    case supported
    case beta
    case planned
}

struct TVDevice: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var host: String
    var brand: TVBrand
    var macAddress: String?
    var modelName: String?
    var lastSeen: Date?

    static func makeID(brand: TVBrand, host: String) -> String {
        "\(brand.rawValue)|\(host)"
    }

    static func make(name: String, host: String, brand: TVBrand, macAddress: String? = nil, modelName: String? = nil) -> TVDevice {
        TVDevice(
            id: makeID(brand: brand, host: host),
            name: name,
            host: host,
            brand: brand,
            macAddress: macAddress,
            modelName: modelName,
            lastSeen: Date()
        )
    }
}

struct InstalledApp: Equatable {
    var id: String
    var name: String
}

enum InputRoute: Equatable {
    case rokuKey(String)
    case launchApp(String)
    case lgInput(String)
    case sonyCode(String)
    case samsungKey(String)
    case vizioCycle
}

struct TVInput: Identifiable, Equatable {
    var id: String
    var name: String
    var route: InputRoute
}

struct AppShortcut: Identifiable, Equatable {
    var id: String { slug }
    var slug: String
    var title: String
    var matchNames: [String]
    var excludeNames: [String]
    var rokuFallbacks: [String]
    var lgFallbacks: [String]
    var samsungFallbacks: [String]

    static let all: [AppShortcut] = [
        AppShortcut(
            slug: "netflix",
            title: "Netflix",
            matchNames: ["netflix"],
            excludeNames: [],
            rokuFallbacks: ["12"],
            lgFallbacks: ["netflix"],
            samsungFallbacks: ["11101200001", "3201907018807"]
        ),
        AppShortcut(
            slug: "prime",
            title: "Prime Video",
            matchNames: ["prime video", "amazon prime", "amazon video"],
            excludeNames: [],
            rokuFallbacks: ["13"],
            lgFallbacks: ["amazon"],
            samsungFallbacks: ["3201910019365", "3201512006785"]
        ),
        AppShortcut(
            slug: "disney",
            title: "Disney+",
            matchNames: ["disney+", "disney plus", "disney"],
            excludeNames: [],
            rokuFallbacks: ["291097"],
            lgFallbacks: ["com.disney.disneyplus-prod"],
            samsungFallbacks: ["3201901017640"]
        ),
        AppShortcut(
            slug: "youtube-tv",
            title: "YouTube TV",
            matchNames: ["youtube tv", "youtubetv"],
            excludeNames: [],
            rokuFallbacks: ["195316"],
            lgFallbacks: ["youtube.leanback.ytv.v1"],
            samsungFallbacks: ["3201707014489"]
        ),
        AppShortcut(
            slug: "youtube",
            title: "YouTube",
            matchNames: ["youtube"],
            excludeNames: ["youtube tv", "youtubetv", "youtube kids", "youtubekids"],
            rokuFallbacks: ["837"],
            lgFallbacks: ["youtube.leanback.v4"],
            samsungFallbacks: ["111299001912"]
        ),
        AppShortcut(
            slug: "max",
            title: "Max",
            matchNames: ["max", "hbo max", "hbomax"],
            excludeNames: [],
            rokuFallbacks: ["61322"],
            lgFallbacks: ["com.wbd.stream", "com.hbo.hbomax"],
            samsungFallbacks: ["3202301029760", "3201601007230"]
        ),
        AppShortcut(
            slug: "hulu",
            title: "Hulu",
            matchNames: ["hulu"],
            excludeNames: [],
            rokuFallbacks: ["2285"],
            lgFallbacks: ["hulu"],
            samsungFallbacks: ["3201601007625"]
        ),
        AppShortcut(
            slug: "peacock",
            title: "Peacock",
            matchNames: ["peacock"],
            excludeNames: [],
            rokuFallbacks: ["593099"],
            lgFallbacks: ["com.peacocktv.peacocktv", "com.peacocktv.peacock"],
            samsungFallbacks: ["3202006020991"]
        ),
        AppShortcut(
            slug: "paramount",
            title: "Paramount+",
            matchNames: ["paramount+", "paramount plus", "paramount"],
            excludeNames: [],
            rokuFallbacks: ["31440"],
            lgFallbacks: ["com.cbs-ott.2", "com.paramount.paramountplus"],
            samsungFallbacks: ["3201710014981", "3202110025305"]
        ),
        AppShortcut(
            slug: "apple-tv",
            title: "Apple TV+",
            matchNames: ["apple tv"],
            excludeNames: [],
            rokuFallbacks: ["551012"],
            lgFallbacks: ["com.apple.appletv"],
            samsungFallbacks: ["3201807016597"]
        ),
        AppShortcut(
            slug: "spotify",
            title: "Spotify",
            matchNames: ["spotify"],
            excludeNames: [],
            rokuFallbacks: ["22297"],
            lgFallbacks: ["spotify-beehive"],
            samsungFallbacks: ["3201606009684"]
        )
    ]

    static func named(_ slug: String) -> AppShortcut {
        all.first { $0.slug == slug } ?? all[0]
    }
}

enum AppShortcutResolver {
    static func rokuID(for shortcut: AppShortcut, installed: [InstalledApp]) -> String {
        resolved(fallbacks: shortcut.rokuFallbacks, installed: installed, names: shortcut.matchNames, excluding: shortcut.excludeNames)
    }

    static func lgID(for shortcut: AppShortcut, installed: [InstalledApp]) -> String {
        resolved(fallbacks: shortcut.lgFallbacks, installed: installed, names: shortcut.matchNames, excluding: shortcut.excludeNames)
    }

    static func samsungID(for shortcut: AppShortcut, installed: [InstalledApp]) -> String {
        resolved(fallbacks: shortcut.samsungFallbacks, installed: installed, names: shortcut.matchNames, excluding: shortcut.excludeNames)
    }

    static func resolved(fallbacks: [String], installed: [InstalledApp], names: [String], excluding: [String]) -> String {
        if let matched = matchID(installed: installed, names: names, excluding: excluding) {
            return matched
        }
        if !installed.isEmpty, let known = fallbacks.first(where: { id in installed.contains { $0.id == id } }) {
            return known
        }
        return fallbacks[0]
    }

    static func matchID(installed: [InstalledApp], names: [String], excluding: [String]) -> String? {
        let needles = names.map { $0.lowercased() }.sorted { $0.count > $1.count }
        let excludes = excluding.map { $0.lowercased() }
        let apps = installed.map { ($0.id, $0.name.lowercased()) }
        for needle in needles {
            if let exact = apps.first(where: { $0.1 == needle && !isExcluded($0.1, excludes) }) {
                return exact.0
            }
        }
        for needle in needles {
            if let contains = apps.first(where: { name in
                name.1.contains(needle) && !isExcluded(name.1, excludes)
            }) {
                return contains.0
            }
        }
        return nil
    }

    private static func isExcluded(_ name: String, _ excludes: [String]) -> Bool {
        excludes.contains { name.contains($0) }
    }
}
