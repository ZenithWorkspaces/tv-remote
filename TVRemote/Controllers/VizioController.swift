import Foundation

final class VizioController: TVControlling {
    var onEvent: ((ControllerEvent) -> Void)?

    private let trust = LocalTLSTrust(host: "")
    private var session: URLSession?
    private var host = ""
    private var deviceID = ""
    private var secrets: SecretProviding?
    private var base = ""
    private var auth: String?
    private var pairToken: String?
    private var challengeType = 1
    private var vizioDeviceID = ""
    private var connected = false
    private var playNext = true

    func connect(device: TVDevice, secrets: SecretProviding) {
        host = device.host
        deviceID = device.id
        self.secrets = secrets
        trust.host = device.host
        connected = false
        vizioDeviceID = existingDeviceID()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: .main)
        Task { [weak self] in
            await self?.open()
        }
    }

    func disconnect() {
        session?.invalidateAndCancel()
        session = nil
        connected = false
    }

    func submitPairing(_ value: String) {
        let pin = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty, let pairToken else {
            emit(.message("Enter the PIN shown on the Vizio TV."))
            return
        }
        Task { [weak self] in
            await self?.finish(pin: pin, token: pairToken)
        }
    }

    func press(_ key: RemoteKey) {
        guard VizioSmartCast.key(for: key) != nil else {
            emit(.message("This Vizio doesn't use that button."))
            return
        }
        if key == .playPause {
            sendKey(key, playNext: playNext)
            playNext.toggle()
            return
        }
        sendKey(key, playNext: playNext)
    }

    func launch(_ shortcut: AppShortcut) {
        guard let spec = VizioSmartCast.app(for: shortcut), let auth, connected else {
            emit(.message("Open \(shortcut.title) from the Vizio home screen. App launch varies by model."))
            return
        }
        let body = VizioSmartCast.launchObject(appID: spec.id, nameSpace: spec.nameSpace)
        Task { [weak self] in
            guard let self else { return }
            if await self.request(path: "/app/launch", method: "PUT", body: body, auth: auth) == nil {
                self.emit(.message("Open \(shortcut.title) from the Vizio home screen. This model didn't accept the app launch."))
            }
        }
    }

    func select(input: TVInput) {
        sendKey(.input, playNext: true)
    }

    private func open() async {
        guard await selectBase() else {
            emit(.notFound("Vizio not found at \(host). SmartCast has to be on the same Wi-Fi."))
            return
        }
        if let saved = secrets?.string(for: SecretAccount.vizioAuth(deviceID)), !saved.isEmpty {
            auth = saved
            if await authorized() {
                connected = true
                emit(.connected)
                return
            }
            secrets?.set(nil, for: SecretAccount.vizioAuth(deviceID))
            auth = nil
        }
        await startPairing()
    }

    private func selectBase() async -> Bool {
        for candidate in ["https://\(host):\(VizioSmartCast.securePort)", "http://\(host):\(VizioSmartCast.plainPort)"] {
            base = candidate
            if let status = await status(path: "/state/device/deviceinfo"), (200...499).contains(status) {
                return true
            }
        }
        return false
    }

    private func authorized() async -> Bool {
        await request(path: "/state/device/deviceinfo", method: "GET", body: nil, auth: auth) != nil
    }

    private func startPairing() async {
        let body = VizioSmartCast.startPairingObject(deviceID: vizioDeviceID, name: "No Ads Remote")
        guard let data = await request(path: "/pairing/start", method: "PUT", body: body, auth: nil),
              let object = JSONBox.object(data) else {
            emit(.notFound("Vizio at \(host) did not start pairing."))
            return
        }
        let item = (object["ITEM"] as? [String: Any]) ?? object
        if let token = item["PAIRING_REQ_TOKEN"] {
            pairToken = Self.stringify(token)
        }
        if let type = item["CHALLENGE_TYPE"] as? Int {
            challengeType = type
        } else if let type = item["CHALLENGE_TYPE"] as? String, let number = Int(type) {
            challengeType = number
        }
        guard pairToken != nil else {
            emit(.message("The Vizio didn't return a pairing token. Put the TV on the pairing screen and try again."))
            return
        }
        emit(.pairingRequired(.pin("Enter the 4-digit PIN shown on the Vizio TV.")))
    }

    private func finish(pin: String, token: String) async {
        let body = VizioSmartCast.finishPairingObject(
            deviceID: vizioDeviceID,
            challengeType: challengeType,
            pin: pin,
            token: token
        )
        guard let data = await request(path: "/pairing/pair", method: "PUT", body: body, auth: nil),
              let object = JSONBox.object(data) else {
            emit(.message("That PIN didn't work. Check the TV and try again."))
            return
        }
        let item = (object["ITEM"] as? [String: Any]) ?? object
        guard let raw = item["AUTH_TOKEN"], let saved = Self.stringify(raw), !saved.isEmpty else {
            emit(.message("That PIN didn't work. Check the TV and try again."))
            return
        }
        auth = saved
        secrets?.set(saved, for: SecretAccount.vizioAuth(deviceID))
        connected = true
        emit(.connected)
    }

    private func sendKey(_ key: RemoteKey, playNext: Bool) {
        guard let auth, connected, let mapped = VizioSmartCast.key(for: key, playNext: playNext) else {
            if auth == nil {
                emit(.pairingRequired(.pin("Enter the PIN shown on the Vizio TV.")))
            }
            return
        }
        let body = VizioSmartCast.commandObject(codeset: mapped.codeset, code: mapped.code)
        Task { [weak self] in
            _ = await self?.request(path: "/key_command/", method: "PUT", body: body, auth: auth)
        }
    }

    private func status(path: String) async -> Int? {
        guard let session, let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }

    private func request(path: String, method: String, body: [String: Any]?, auth: String?) async -> Data? {
        guard let session, let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth, !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "AUTH")
        }
        if let body {
            request.httpBody = JSONBox.data(body)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private func existingDeviceID() -> String {
        let account = SecretAccount.vizioDevice(deviceID)
        if let saved = secrets?.string(for: account), !saved.isEmpty {
            return saved
        }
        let created = UUID().uuidString
        secrets?.set(created, for: account)
        return created
    }

    private func emit(_ event: ControllerEvent) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(event)
            }
        }
    }

    private static func stringify(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = value as? Int { return String(number) }
        if let number = value as? Double, number.rounded() == number { return String(Int(number)) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
