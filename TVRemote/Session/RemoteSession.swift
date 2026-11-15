import Foundation
import Observation

struct LibrarySnapshot: Codable, Equatable {
    var devices: [TVDevice]
    var lastDeviceID: String?

    static let empty = LibrarySnapshot(devices: [], lastDeviceID: nil)
}

struct PairingRequest: Identifiable {
    let id = UUID()
    var kind: PairingKind
}

final class DeviceStore {
    private let defaults: UserDefaults
    private let key = "tvremote.library.v1"
    private let namesKey = "tvremote.names.v1"
    private let shortcutsKey = "tvremote.shortcuts.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> LibrarySnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    func save(_ snapshot: LibrarySnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    func loadNames() -> [String: String] {
        guard let data = defaults.data(forKey: namesKey),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return names
    }

    func saveNames(_ names: [String: String]) {
        guard let data = try? JSONEncoder().encode(names) else { return }
        defaults.set(data, forKey: namesKey)
    }

    func loadShortcuts() -> ShortcutLayout {
        guard let data = defaults.data(forKey: shortcutsKey),
              let layout = try? JSONDecoder().decode(ShortcutLayout.self, from: data) else {
            return .standard
        }
        return layout
    }

    func saveShortcuts(_ layout: ShortcutLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: shortcutsKey)
    }
}

@MainActor
@Observable
final class RemoteSession {
    private(set) var devices: [TVDevice] = []
    private(set) var activeID: String?
    private(set) var linkState: LinkState = .idle
    private(set) var statusText = "No TV selected"
    private(set) var inputs: [TVInput] = []
    private(set) var isScanning = false

    var pairing: PairingRequest?
    var pairingDraft = ""
    var pairingError: String?
    var showManualAdd = false
    var showKeyboard = false
    var showInputs = false
    var confirmForget = false
    var showRename = false
    var renameDraft = ""

    var needsReconnect: Bool {
        switch linkState {
        case .notFound, .lost, .idle, .unavailable:
            return activeDevice != nil
        default:
            return false
        }
    }

    enum LinkState: Equatable {
        case idle
        case connecting
        case connected
        case pairing
        case reconnecting
        case notFound
        case lost
        case unavailable
    }

    private let store = DeviceStore()
    private let secrets = KeychainStore()
    private let discovery = DiscoveryService()
    private var friendlyNames: [String: String] = [:]
    private var resolvedNames: [String: String] = [:]
    private var shortcutLayout = ShortcutLayout.standard
    private var renameID: String?
    private var renameBaseline = ""
    private var controller: (any TVControlling)?
    private var didStart = false
    private var connectGeneration = 0
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var suppressReconnect = false

    var activeDevice: TVDevice? {
        devices.first { $0.id == activeID }
    }

    var showsFailure: Bool {
        switch linkState {
        case .notFound, .lost, .unavailable, .reconnecting:
            return true
        default:
            return false
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        let snapshot = store.load()
        devices = snapshot.devices.filter { $0.brand == .roku || $0.brand == .lg }
        friendlyNames = store.loadNames()
        shortcutLayout = store.loadShortcuts()
        refreshResolvedNames()
        if devices.count != snapshot.devices.count {
            persist()
        }
        activeID = snapshot.lastDeviceID ?? devices.first?.id
        if let activeID, !devices.contains(where: { $0.id == activeID }) {
            self.activeID = devices.first?.id
        }
        guard !Runtime.isRunningTests else { return }
        discovery.onFound = { [weak self] device in
            Task { @MainActor in
                self?.upsert(device)
            }
        }
        discovery.onScanning = { [weak self] scanning in
            Task { @MainActor in
                self?.isScanning = scanning
            }
        }
        discovery.start()
        if let device = activeDevice {
            connect(device, resetAttempts: true)
        } else {
            statusText = "Looking for TVs on Wi-Fi…"
        }
    }

    func select(_ device: TVDevice) {
        if device.id == activeID && (linkState == .connected || linkState == .connecting || linkState == .pairing) {
            return
        }
        connect(device, resetAttempts: true)
    }

    func retry() {
        guard let device = activeDevice else {
            rescan()
            return
        }
        connect(device, resetAttempts: true)
    }

    func rescan() {
        guard !Runtime.isRunningTests else { return }
        isScanning = true
        statusText = devices.isEmpty ? "Looking for TVs on Wi-Fi…" : statusText
        discovery.rescan()
    }

    func press(_ key: RemoteKey) {
        guard let device = activeDevice else { return }
        if device.brand.support == .planned {
            linkState = .unavailable
            statusText = plannedCopy(device.brand)
            return
        }
        if key == .ok {
            Haptics.firmTap()
        } else {
            Haptics.tap()
        }
        controller?.press(key)
    }

    func launch(_ shortcut: AppShortcut) {
        guard let device = activeDevice, device.brand.support != .planned else { return }
        Haptics.tap()
        controller?.launch(shortcut)
    }

    func openInputs() {
        guard let device = activeDevice else { return }
        Haptics.tap()
        if device.brand.support == .planned {
            linkState = .unavailable
            statusText = plannedCopy(device.brand)
            return
        }
        if !device.brand.usesInputSheet {
            controller?.press(.input)
            return
        }
        controller?.refreshInputs()
        showInputs = true
    }

    func select(input: TVInput) {
        Haptics.tap()
        controller?.select(input: input)
        showInputs = false
    }

    func openKeyboard() {
        guard let device = activeDevice else { return }
        guard device.brand.supportsKeyboard else {
            statusText = "Keyboard entry isn't available on \(device.brand.displayName)."
            return
        }
        Haptics.tap()
        showKeyboard = true
    }

    func sendKeyboardText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Haptics.tap()
        controller?.sendText(trimmed)
    }

    func deleteBackward() {
        Haptics.tap()
        controller?.deleteBackward()
    }

    func submitPairing() {
        pairingError = nil
        let value = pairingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        controller?.submitPairing(value)
    }

    func cancelPairing() {
        pairing = nil
        pairingError = nil
        connectGeneration += 1
        controller?.disconnect()
        controller = nil
        linkState = .idle
        statusText = "Pairing cancelled"
    }

    func power() {
        guard let device = activeDevice else { return }
        if device.brand.support == .planned {
            linkState = .unavailable
            statusText = plannedCopy(device.brand)
            return
        }
        Haptics.firmTap()
        if linkState == .connected {
            suppressReconnect = true
            controller?.press(.powerOff)
            linkState = .idle
            statusText = "Turning off \(displayName(for: device))"
            return
        }
        suppressReconnect = false
        if let mac = device.macAddress {
            WakeSender.send(mac: mac, host: device.host)
        }
        controller?.press(.powerOn)
        if device.brand == .lg && device.macAddress == nil {
            linkState = .notFound
            statusText = "Turn the LG on once and connect so Wake-on-LAN can remember its MAC address."
            return
        }
        statusText = "Power on sent to \(displayName(for: device))"
        let generation = connectGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.connectGeneration == generation else { return }
            self.connect(device, resetAttempts: true)
        }
    }

    func forgetActive() {
        guard let device = activeDevice else { return }
        reconnectTask?.cancel()
        connectGeneration += 1
        controller?.disconnect()
        controller = nil
        secrets.set(nil, for: SecretAccount.lgClientKey(device.id))
        secrets.set(nil, for: SecretAccount.samsungToken(device.id))
        secrets.set(nil, for: SecretAccount.sonyPSK(device.id))
        secrets.set(nil, for: SecretAccount.vizioAuth(device.id))
        devices.removeAll { $0.id == device.id }
        friendlyNames[device.id] = nil
        refreshResolvedNames()
        activeID = devices.first?.id
        pairing = nil
        inputs = []
        persist()
        if let next = activeDevice {
            connect(next, resetAttempts: true)
        } else {
            linkState = .idle
            statusText = "No TV selected"
        }
    }

    func addManual(host: String, name: String, brand: TVBrand?) async -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalIPv4.isValidIPv4(trimmed) else {
            return "Enter an IPv4 address, for example 192.168.1.20."
        }
        let chosen = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let brand {
            guard brand == .roku || brand == .lg else {
                return "This app controls LG and Roku TVs."
            }
            let device = TVDevice.make(
                name: chosen.isEmpty ? TVDisplayName.suggestion(brand: brand, discovered: nil) : chosen,
                host: trimmed,
                brand: brand
            )
            if !chosen.isEmpty {
                friendlyNames[device.id] = chosen
                store.saveNames(friendlyNames)
            }
            upsert(device, selectIfIdle: false)
            showManualAdd = false
            select(fresh(device))
            return nil
        }
        linkState = .connecting
        statusText = "Looking for a TV at \(trimmed)…"
        if let found = await PortProbe.identify(host: trimmed, timeout: 0.85, suggestedName: chosen.isEmpty ? nil : chosen) {
            guard found.brand == .roku || found.brand == .lg else {
                linkState = .idle
                return "This app controls LG and Roku TVs."
            }
            var device = found
            if !chosen.isEmpty {
                device.name = chosen
                friendlyNames[device.id] = chosen
                store.saveNames(friendlyNames)
            }
            upsert(device, selectIfIdle: false)
            showManualAdd = false
            select(fresh(device))
            return nil
        }
        linkState = .notFound
        statusText = "No TV found at \(trimmed)."
        return "No TV answered at \(trimmed). Check the address, or pick the brand yourself."
    }

    private func fresh(_ device: TVDevice) -> TVDevice {
        devices.first { $0.id == device.id } ?? device
    }

    private func connect(_ device: TVDevice, resetAttempts: Bool) {
        if resetAttempts {
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        suppressReconnect = false
        connectGeneration += 1
        let generation = connectGeneration
        controller?.disconnect()
        inputs = []
        activeID = device.id
        pairing = nil
        persist()

        if device.brand.support == .planned {
            controller = nil
            linkState = .unavailable
            statusText = plannedCopy(device.brand)
            return
        }

        linkState = .connecting
        statusText = "Connecting to \(displayName(for: device))…"
        let created = ControllerFactory.make(brand: device.brand)
        controller = created
        created.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self, self.connectGeneration == generation else { return }
                self.handle(event)
            }
        }
        created.connect(device: device, secrets: secrets)
    }

    private func handle(_ event: ControllerEvent) {
        switch event {
        case .connected:
            reconnectAttempt = 0
            suppressReconnect = false
            pairing = nil
            pairingError = nil
            linkState = .connected
            statusText = "Connected"
            considerRenamePrompt()
        case let .notFound(message):
            pairing = nil
            linkState = .notFound
            statusText = message
        case let .connectionLost(message):
            if suppressReconnect {
                linkState = .idle
                statusText = "Turned off"
                return
            }
            scheduleReconnect(fallback: message)
        case let .pairingRequired(kind):
            linkState = .pairing
            pairingError = nil
            statusText = pairingStatus(kind)
            if pairing?.kind != kind {
                pairingDraft = ""
                pairing = PairingRequest(kind: kind)
            }
        case let .pairingRejected(text):
            linkState = .pairing
            pairingError = text
            pairingDraft = ""
            statusText = text
        case let .inputs(found):
            var seen = Set<String>()
            inputs = found.filter { seen.insert($0.id).inserted }
        case let .learnedMAC(mac):
            guard let normalized = MACAddress.normalize(mac) else { return }
            updateActive { device in
                if device.macAddress == nil {
                    device.macAddress = normalized
                }
            }
        case let .learnedName(name):
            guard !name.isEmpty, let id = activeID, friendlyNames[id] == nil else { return }
            updateActive { device in
                device.name = name
            }
            refreshResolvedNames()
            if showRename, renameID == id, renameDraft == renameBaseline {
                let updated = displayName(forID: id)
                renameDraft = updated
                renameBaseline = updated
            }
        case .apps:
            break
        case let .message(text):
            statusText = text
        }
    }

    private func scheduleReconnect(fallback: String) {
        guard let device = activeDevice else { return }
        reconnectAttempt += 1
        if reconnectAttempt > 4 {
            linkState = .lost
            statusText = "Couldn't reconnect to \(displayName(for: device)). Check that the TV is on and this phone is on the same Wi-Fi."
            return
        }
        linkState = .reconnecting
        statusText = "Connection lost. Reconnecting…"
        _ = fallback
        let delay = UInt64(reconnectAttempt) * 1_000_000_000
        let generation = connectGeneration
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.connectGeneration == generation else { return }
                self.connect(device, resetAttempts: false)
            }
        }
    }

    func displayName(for device: TVDevice) -> String {
        resolvedNames[device.id] ?? TVDisplayName.suggestion(brand: device.brand, discovered: device.name)
    }

    var visibleShortcuts: [AppShortcut] {
        shortcutLayout.visibleShortcuts()
    }

    var hiddenShortcuts: [AppShortcut] {
        shortcutLayout.hiddenShortcuts()
    }

    func beginRename(for device: TVDevice? = nil) {
        guard let device = device ?? activeDevice else { return }
        renameID = device.id
        let current = displayName(for: device)
        renameDraft = current
        renameBaseline = current
        showRename = true
    }

    func saveRename() {
        guard let id = renameID ?? activeID else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        friendlyNames[id] = trimmed
        store.saveNames(friendlyNames)
        refreshResolvedNames()
        showRename = false
    }

    func dismissRename() {
        if let id = renameID, friendlyNames[id] == nil, let device = devices.first(where: { $0.id == id }) {
            friendlyNames[id] = displayName(for: device)
            store.saveNames(friendlyNames)
            refreshResolvedNames()
        }
        showRename = false
    }

    func moveShortcut(_ slug: String, before target: String) {
        shortcutLayout = shortcutLayout.moving(slug, before: target)
        store.saveShortcuts(shortcutLayout)
    }

    func setShortcut(_ slug: String, hidden: Bool) {
        shortcutLayout = shortcutLayout.setting(slug, hidden: hidden)
        store.saveShortcuts(shortcutLayout)
    }

    private func considerRenamePrompt() {
        guard let device = activeDevice, friendlyNames[device.id] == nil, !showRename else { return }
        beginRename(for: device)
    }

    private func displayName(forID id: String) -> String {
        guard let device = devices.first(where: { $0.id == id }) else { return "" }
        return displayName(for: device)
    }

    private func refreshResolvedNames() {
        var taken = Set<String>()
        var result: [String: String] = [:]
        for device in devices {
            if let saved = friendlyNames[device.id], !saved.isEmpty {
                result[device.id] = saved
                taken.insert(saved)
            }
        }
        for device in devices where result[device.id] == nil {
            let unique = TVDisplayName.unique(
                TVDisplayName.suggestion(brand: device.brand, discovered: device.name),
                taken: taken
            )
            result[device.id] = unique
            taken.insert(unique)
        }
        resolvedNames = result
    }

    private func upsert(_ found: TVDevice, selectIfIdle: Bool = true) {
        guard found.brand == .roku || found.brand == .lg else { return }
        if let index = devices.firstIndex(where: { $0.id == found.id }) {
            var current = devices[index]
            if current.name.isEmpty || current.name == current.brand.displayName {
                current.name = found.name
            }
            if current.macAddress == nil {
                current.macAddress = found.macAddress
            }
            if let model = found.modelName {
                current.modelName = model
            }
            current.lastSeen = Date()
            devices[index] = current
        } else {
            var created = found
            created.lastSeen = Date()
            devices.append(created)
        }
        refreshResolvedNames()
        persist()
        if selectIfIdle, activeID == nil, let device = devices.first(where: { $0.id == found.id }) {
            select(device)
        }
    }

    private func updateActive(_ change: (inout TVDevice) -> Void) {
        guard let id = activeID, let index = devices.firstIndex(where: { $0.id == id }) else { return }
        change(&devices[index])
        refreshResolvedNames()
        persist()
    }

    private func persist() {
        store.save(LibrarySnapshot(devices: devices, lastDeviceID: activeID))
    }

    private func pairingStatus(_ kind: PairingKind) -> String {
        switch kind {
        case let .acceptOnTV(text): return text
        case let .pin(text): return text
        case let .psk(text): return text
        }
    }

    private func plannedCopy(_ brand: TVBrand) -> String {
        switch brand {
        case .androidtv:
            return "Android TV is saved. Remote protocol v2 pairing isn't finished, so the buttons stay off."
        case .firetv:
            return "Fire TV is saved. There's no supported local remote API in this build, so the buttons stay off."
        default:
            return "Controls for this TV aren't available yet."
        }
    }
}
