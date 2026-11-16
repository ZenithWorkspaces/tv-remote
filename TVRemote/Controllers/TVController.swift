import Foundation

enum PairingKind: Equatable {
    case acceptOnTV(String)
    case pin(String)
    case code(String)
    case psk(String)
}

enum ControllerEvent {
    case connected
    case notFound(String)
    case connectionLost(String)
    case pairingRequired(PairingKind)
    case pairingRejected(String)
    case apps([InstalledApp])
    case inputs([TVInput])
    case learnedMAC(String)
    case learnedName(String)
    case message(String)
    case diagnostic(String)
}

protocol TVControlling: AnyObject {
    var onEvent: ((ControllerEvent) -> Void)? { get set }
    func connect(device: TVDevice, secrets: SecretProviding)
    func disconnect()
    func press(_ key: RemoteKey)
    func launch(_ shortcut: AppShortcut)
    func sendText(_ text: String)
    func deleteBackward()
    func refreshInputs()
    func select(input: TVInput)
    func submitPairing(_ value: String)
}

extension TVControlling {
    func sendText(_ text: String) {}
    func deleteBackward() {}
    func refreshInputs() {}
    func submitPairing(_ value: String) {}
}

enum ControllerFactory {
    static func make(brand: TVBrand) -> any TVControlling {
        switch brand {
        case .roku: return RokuController()
        case .lg: return LGController()
        case .samsung: return SamsungController()
        case .sony: return SonyController()
        case .vizio: return VizioController()
        case .androidtv: return AndroidTVController()
        case .firetv: return FireTVController()
        }
    }
}

final class PlannedController: TVControlling {
    var onEvent: ((ControllerEvent) -> Void)?
    private let brand: TVBrand

    init(brand: TVBrand) {
        self.brand = brand
    }

    func connect(device: TVDevice, secrets: SecretProviding) {
        onEvent?(.message(plannedMessage))
    }

    func disconnect() {}

    func press(_ key: RemoteKey) {
        onEvent?(.message(plannedMessage))
    }

    func launch(_ shortcut: AppShortcut) {
        onEvent?(.message(plannedMessage))
    }

    func select(input: TVInput) {}

    private var plannedMessage: String {
        switch brand {
        case .androidtv:
            return "Android TV is saved. The Remote v2 pairing protocol is not finished in this build, so buttons stay off."
        case .firetv:
            return "Fire TV is saved. It has no supported local remote API in this build, so buttons stay off."
        default:
            return "Controls for this TV are not available yet."
        }
    }
}
