import Foundation
import Network

final class SamsungController: NSObject, TVControlling, URLSessionDelegate, URLSessionWebSocketDelegate {
    var onEvent: ((ControllerEvent) -> Void)?

    private enum Path {
        case modern
        case encrypted
        case legacy
    }

    private let remoteName = "No Ads Remote"
    private var host = ""
    private var deviceID = ""
    private var secrets: SecretProviding?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var legacyConnection: NWConnection?
    private var path: Path = .modern
    private var encryptedContext: Data?
    private var encryptedSession = ""
    private var connected = false
    private var stopped = false
    private var pairingStarted = false
    private var apps: [InstalledApp] = []
    private var attemptToken = 0
    private var openOnce: OnceResume<Bool>?
    private var pinWaiter: OnceResume<String>?
    private var pendingPIN: String?
    private var timeoutTask: Task<Void, Never>?
    private var allowFallback = true

    func connect(device: TVDevice, secrets: SecretProviding) {
        host = device.host
        deviceID = device.id
        self.secrets = secrets
        stopped = false
        connected = false
        allowFallback = true
        Task { [weak self] in
            await self?.open()
        }
    }

    func disconnect() {
        stopped = true
        pinWaiter?.resume("")
        pinWaiter = nil
        timeoutTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        socket = nil
        legacyConnection?.cancel()
        legacyConnection = nil
        connected = false
    }

    func press(_ key: RemoteKey) {
        switch path {
        case .modern:
            guard let name = SamsungRemote.keyName(for: key) else {
                emit(.message(SamsungRemote.unavailableMessage(for: key)))
                return
            }
            send(SamsungRemote.clickObject(key: name))
        case .encrypted:
            guard let name = SamsungEncrypted.keyName(for: key) else {
                if key == .powerOn { return }
                emit(.message(key == .skipPrevious || key == .skipNext
                    ? "This Samsung doesn't have a skip button."
                    : "This Samsung doesn't use that button."))
                return
            }
            sendEncrypted(name)
        case .legacy:
            guard let name = SamsungEncrypted.keyName(for: key) ?? SamsungRemote.keyName(for: key) else {
                emit(.message(SamsungRemote.unavailableMessage(for: key)))
                return
            }
            let packet = SamsungLegacy.keyPacket(name == "KEY_POWER" && key == .powerOff ? "KEY_POWEROFF" : name)
            legacyConnection?.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    func deleteBackward() {
        guard path == .modern else {
            emit(.message("This Samsung doesn't take keyboard text from the remote."))
            return
        }
        send(SamsungRemote.textObject("\u{8}"))
    }

    func launch(_ shortcut: AppShortcut) {
        guard path == .modern else {
            emit(.message(SamsungEncrypted.appsUnavailable))
            return
        }
        let id = AppShortcutResolver.samsungID(for: shortcut, installed: apps)
        send(SamsungRemote.launchObject(appID: id))
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        guard path == .modern else {
            emit(.message("This Samsung doesn't take keyboard text from the remote."))
            return
        }
        send(SamsungRemote.textObject(text))
    }

    func submitPairing(_ value: String) {
        let pin = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let waiter = pinWaiter {
            pinWaiter = nil
            waiter.resume(pin)
        } else {
            pendingPIN = pin
        }
    }

    func select(input: TVInput) {
        guard case let .samsungKey(name) = input.route else { return }
        send(SamsungRemote.clickObject(key: name))
    }

    private func open() async {
        let started = Date()
        func expired() -> Bool { stopped || Date().timeIntervalSince(started) > 15 }
        note("\(host) connect started")
        await logPorts()
        if await modernAPI() {
            path = .modern
            let stored = secrets?.string(for: SecretAccount.samsungToken(deviceID))
            if await attempt(secure: true, token: stored) { return }
            if stopped || connected || pairingStarted || expired() { return finishIfNeeded(expired()) }
            if await attempt(secure: true, token: nil) { return }
            if stopped || connected || pairingStarted || expired() { return finishIfNeeded(expired()) }
            if await attempt(secure: false, token: nil) { return }
        }
        if stopped || connected || pairingStarted { return }
        if expired() { fail(); return }
        let port8080 = await TCPProbe.isOpen(host: host, port: UInt16(SamsungEncrypted.pairingPort), timeout: 1.5)
        note("\(host) encrypted port 8080 \(port8080 ? "open" : "closed")")
        if port8080 {
            path = .encrypted
            if await openEncrypted() { return }
            if stopped || connected || pairingStarted { return }
            note("\(host) PIN page did not open")
            emit(.notFound(SamsungPINPage.closedMessage))
            return
        }
        if stopped { return }
        if await TCPProbe.isOpen(host: host, port: SamsungLegacy.port, timeout: 1.5) {
            path = .legacy
            note("\(host) legacy port 55000 open")
            await openLegacy()
            return
        }
        if !stopped && !connected && !pairingStarted {
            fail()
        }
    }

    private func finishIfNeeded(_ expired: Bool) {
        if !stopped && !connected && !pairingStarted {
            fail()
        }
        _ = expired
    }

    private func fail() {
        emit(.notFound("Couldn't connect to this Samsung. Make sure it's on and on the same Wi-Fi."))
    }

    private func attempt(secure: Bool, token: String?) async -> Bool {
        attemptToken += 1
        let tokenNumber = attemptToken
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        session = created
        guard let url = SamsungRemote.websocketURL(host: host, secure: secure, name: remoteName, token: token) else {
            return false
        }
        let task = created.webSocketTask(with: url)
        socket = task
        return await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            openOnce = once
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled, let self, self.attemptToken == tokenNumber, !self.connected, !self.pairingStarted else { return }
                once.resume(false)
                self.socket?.cancel(with: .goingAway, reason: nil)
            }
            task.resume()
        }
    }

    private func send(_ object: [String: Any]) {
        guard connected, let text = String(data: JSONBox.data(object), encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func receive() {
        let task = socket
        task?.receive { [weak self, weak task] result in
            guard let self, !self.stopped, task === self.socket else { return }
            switch result {
            case let .success(message):
                if case let .string(text) = message {
                    self.handle(text)
                }
                self.receive()
            case .failure:
                if self.connected {
                    self.connected = false
                    self.emit(.connectionLost("Samsung connection dropped. Reconnecting…"))
                } else {
                    self.openOnce?.resume(false)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let object = JSONBox.object(Data(text.utf8)) else { return }
        let event = (object["event"] as? String) ?? ""
        let data = object["data"] as? [String: Any]
        if event == "ms.channel.connect" {
            if let token = data?["token"] as? String, !token.isEmpty {
                secrets?.set(token, for: SecretAccount.samsungToken(deviceID))
            }
            if !connected {
                connected = true
                timeoutTask?.cancel()
                emit(.connected)
                openOnce?.resume(true)
                Task { [weak self] in
                    await self?.loadMetadata()
                }
            }
            return
        }
        if event == "ms.channel.unauthorized" || event == "ms.channel.timeOut" {
            secrets?.set(nil, for: SecretAccount.samsungToken(deviceID))
            if allowFallback {
                allowFallback = false
                connected = false
                openOnce?.resume(false)
                emit(.pairingRequired(.acceptOnTV("Allow No Ads Remote on the Samsung screen, then it will connect.")))
            }
        }
    }

    private func loadMetadata() async {
        if let url = URL(string: "http://\(host):8001/api/v2/"),
           let data = await HTTPProbe.get(url: url, timeout: 3, trustHost: nil),
           let mac = MACAddress.find(in: JSONBox.object(data) ?? [:]) {
            emit(.learnedMAC(mac))
        }
        if let url = URL(string: "http://\(host):8001/api/v2/applications"),
           let data = await HTTPProbe.get(url: url, timeout: 3, trustHost: nil) {
            let found = SamsungRemote.parseApplications(data)
            if !found.isEmpty {
                apps = found
                emit(.apps(found))
            }
        }
    }

    /// Shows the PIN sheet only after CloudPINPage leaves `stopped`. Returns false when the TV never opened that page.
    private func openEncrypted() async -> Bool {
        if let saved = secrets?.string(for: SecretAccount.samsungEncrypted(deviceID)),
           let parsed = Self.parseEncryptedToken(saved) {
            note("\(host) trying saved encrypted session")
            if await connectSocket(context: parsed.context, sessionID: parsed.session) {
                return true
            }
        }
        secrets?.set(nil, for: SecretAccount.samsungEncrypted(deviceID))
        guard await showPINPage() else { return false }
        pairingStarted = true
        emit(.pairingRequired(.pin("Enter the 4-digit PIN shown on your Samsung TV.")))
        let pin = await nextPIN()
        guard !stopped, pin.count == 4, pin.allSatisfy(\.isNumber) else {
            if !stopped { emit(.pairingRejected("Enter the 4-digit PIN shown on the Samsung TV.")) }
            return true
        }
        guard let hello = SamsungEncrypted.serverHello(pin: pin),
              let step0 = SamsungEncrypted.stepURL(host: host, step: 0, type: 1),
              let step1 = SamsungEncrypted.stepURL(host: host, step: 1),
              let step2 = SamsungEncrypted.stepURL(host: host, step: 2) else {
            fail(); return true
        }
        let step0Result = await exchange(step0, method: "GET")
        note(statusLine("GET pairing step=0", step0Result, includeBody: false))
        let helloBody = "{\"auth_Data\":{\"auth_type\":\"SPC\",\"GeneratorServerHello\":\"\(HexBytes.encode(hello.serverHello).uppercased())\"}}"
        let step1Result = await exchange(step1, method: "POST", body: Data(helloBody.utf8), contentType: "application/json")
        note(statusLine("POST pairing step=1", step1Result, includeBody: false))
        guard let step1Data = step1Result.body,
              let clientHello = Self.jsonString(step1Data, keys: ["auth_data", "GeneratorClientHello"]) ?? Self.nestedClientHello(step1Data),
              let session = SamsungEncrypted.parseClientHello(clientHello, hash: hello.hash, aesKey: hello.aesKey) else {
            emit(.pairingRejected("That PIN didn't work. Check the TV and try again."))
            return true
        }
        let requestID = Self.jsonString(step1Data, keys: ["auth_data", "request_id"]) ?? "0"
        let ack = SamsungEncrypted.serverAcknowledge(skPrime: session.skPrime)
        let ackBody = "{\"auth_Data\":{\"auth_type\":\"SPC\",\"request_id\":\"\(requestID)\",\"ServerAckMsg\":\"\(ack)\"}}"
        let step2Result = await exchange(step2, method: "POST", body: Data(ackBody.utf8), contentType: "application/json")
        note(statusLine("POST pairing step=2", step2Result, includeBody: false))
        guard let step2Data = step2Result.body,
              let clientAck = Self.nestedClientAck(step2Data),
              SamsungEncrypted.clientAcknowledgeMatches(clientAck, skPrime: session.skPrime),
              let sessionID = Self.nestedSession(step2Data) else {
            emit(.pairingRejected("That PIN didn't work. Check the TV and try again."))
            return true
        }
        if let page = SamsungEncrypted.pinPageURL(host: host) {
            var close = page
            close.append(path: "run")
            let closed = await exchange(close, method: "DELETE")
            note(statusLine("DELETE CloudPINPage/run", closed, includeBody: false))
        }
        let token = HexBytes.encode(session.context) + ":" + sessionID
        secrets?.set(token, for: SecretAccount.samsungEncrypted(deviceID))
        if await connectSocket(context: session.context, sessionID: sessionID) { return true }
        if !stopped { fail() }
        return true
    }

    /// POST `pin4` the way samsungctl does, then read the page again. The sheet waits for `state` other than `stopped`.
    private func showPINPage() async -> Bool {
        guard let page = SamsungEncrypted.pinPageURL(host: host) else { return false }
        let before = await exchange(page, method: "GET", timeout: 4)
        note(statusLine("GET CloudPINPage", before, includeBody: true))
        if SamsungPINPage.isShowing(Self.text(before.body)) {
            note("\(host) PIN page already open")
            return true
        }
        let posted = await exchange(page, method: "POST", body: Data("pin4".utf8), contentType: "text/plain", timeout: 6)
        note(statusLine("POST CloudPINPage", posted, includeBody: true))
        if SamsungPINPage.isShowing(Self.text(posted.body)) {
            note("\(host) PIN page open")
            return true
        }
        var after = await exchange(page, method: "GET", timeout: 4)
        note(statusLine("GET CloudPINPage", after, includeBody: true))
        if !SamsungPINPage.isShowing(Self.text(after.body)) {
            let retry = await exchange(page, method: "POST", body: Data("pin4".utf8), contentType: nil, timeout: 6)
            note(statusLine("POST CloudPINPage retry", retry, includeBody: true))
            if SamsungPINPage.isShowing(Self.text(retry.body)) {
                note("\(host) PIN page open")
                return true
            }
            after = await exchange(page, method: "GET", timeout: 4)
            note(statusLine("GET CloudPINPage", after, includeBody: true))
        }
        let showing = SamsungPINPage.isShowing(Self.text(after.body))
        note("\(host) PIN page \(showing ? "open" : "still stopped")")
        return showing
    }

    private func connectSocket(context: Data, sessionID: String) async -> Bool {
        let handshakeURL = URL(string: "http://\(host):8000/socket.io/1/?t=\(Int(Date().timeIntervalSince1970 * 1000))")
        let handshake = await exchange(handshakeURL, method: "GET", timeout: 4)
        note(statusLine("GET socket.io", handshake, includeBody: false))
        guard let text = Self.text(handshake.body),
              let id = text.split(separator: ":").first,
              let url = URL(string: "ws://\(host):8000/socket.io/1/websocket/\(id)") else {
            note("\(host) socket.io handshake missing a session")
            return false
        }
        encryptedContext = context
        encryptedSession = sessionID
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        session = created
        let task = created.webSocketTask(with: url)
        socket = task
        task.resume()
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !stopped else { return false }
        connected = true
        emit(.connected)
        return true
    }

    private func sendEncrypted(_ key: String) {
        guard connected, let context = encryptedContext,
              let message = SamsungEncrypted.socketMessage(key: key, context: context, sessionID: encryptedSession) else { return }
        socket?.send(.string("1::/com.samsung.companion")) { _ in }
        socket?.send(.string(message)) { _ in }
    }

    private func openLegacy() async {
        guard let port = NWEndpoint.Port(rawValue: SamsungLegacy.port) else { fail(); return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        legacyConnection = connection
        let ready: Bool = await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(true)
                case .failed, .cancelled: once.resume(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        guard ready else {
            note("\(host) legacy connection failed")
            fail()
            return
        }
        note("\(host) legacy handshake sent, waiting for Allow")
        pairingStarted = true
        emit(.pairingRequired(.acceptOnTV("Allow No Ads Remote on the Samsung screen.")))
        let packet = SamsungLegacy.handshake(description: "iPhone", id: SamsungEncrypted.userID, name: remoteName)
        connection.send(content: packet, completion: .contentProcessed { _ in })
        if await legacyGranted(connection) {
            connected = true
            emit(.connected)
        } else if !stopped {
            emit(.notFound("The Samsung didn't allow this phone. Try again and choose Allow on the TV."))
        }
    }

    private func legacyGranted(_ connection: NWConnection) async -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while !stopped, Date() < deadline {
            guard let data = await receive(connection, max: 512) else { return false }
            if data.contains(Data([0x64, 0x00, 0x01, 0x00])) { return true }
            if data.contains(Data([0x64, 0x00, 0x00, 0x00])) || data.contains(0x65) { return false }
        }
        return false
    }

    private func receive(_ connection: NWConnection, max: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            let once = OnceResume<Data?>(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, error in
                if let data, !data.isEmpty { once.resume(data) }
                else { once.resume(nil) }
                _ = error
            }
        }
    }

    private func nextPIN() async -> String {
        if let pending = pendingPIN {
            pendingPIN = nil
            return pending
        }
        return await withCheckedContinuation { continuation in
            pinWaiter = OnceResume(continuation)
        }
    }

    private struct HTTPResult {
        var status: Int?
        var body: Data?
        var error: String?
    }

    private func logPorts() async {
        let ports: [UInt16] = [8001, 8002, 8080, 8000, 7676, 9197, 55000]
        var lines: [String] = []
        await withTaskGroup(of: String.self) { group in
            for port in ports {
                group.addTask { [host] in
                    let open = await TCPProbe.isOpen(host: host, port: port, timeout: 1.2)
                    return "\(host) TCP \(port) \(open ? "open" : "closed")"
                }
            }
            for await line in group {
                lines.append(line)
            }
        }
        for line in lines.sorted() {
            note(line)
        }
    }

    /// 2016 and newer sets answer `/api/v2/` with a device document. A bare HTTP status is not enough.
    private func modernAPI() async -> Bool {
        let result = await exchange(URL(string: "http://\(host):8001/api/v2/"), method: "GET", timeout: 2.5)
        let text = Self.text(result.body)?.lowercased() ?? ""
        let match = text.contains("samsung") || text.contains("tizen") || text.contains("\"device\"") || text.contains("devicename")
        let ok = match && (result.status.map { (200...299).contains($0) } ?? false)
        note(statusLine("GET :8001/api/v2/", result, includeBody: false) + " match=\(ok)")
        return ok
    }

    private func exchange(
        _ url: URL?,
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval = 6
    ) async -> HTTPResult {
        guard let url else { return HTTPResult(status: nil, body: nil, error: "bad url") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return HTTPResult(status: status, body: data, error: nil)
        } catch {
            return HTTPResult(status: nil, body: nil, error: error.localizedDescription)
        }
    }

    private func statusLine(_ label: String, _ result: HTTPResult, includeBody: Bool) -> String {
        let status = result.status.map(String.init) ?? "none"
        let error = result.error.map { " error=\($0)" } ?? ""
        guard includeBody, let snippet = Self.text(result.body)?.replacingOccurrences(of: "\n", with: " "), !snippet.isEmpty else {
            return "\(host) \(label) status=\(status)\(error)"
        }
        let clipped = snippet.count > 160 ? String(snippet.prefix(160)) : snippet
        return "\(host) \(label) status=\(status)\(error) \(clipped)"
    }

    private func note(_ line: String) {
        emit(.diagnostic(line))
    }

    private static func text(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parseEncryptedToken(_ saved: String) -> (context: Data, session: String)? {
        guard let split = saved.lastIndex(of: ":") else { return nil }
        let context = HexBytes.decode(String(saved[..<split]))
        let session = String(saved[saved.index(after: split)...])
        guard let context, !session.isEmpty else { return nil }
        return (context, session)
    }

    private static func nestedClientHello(_ data: Data) -> String? {
        jsonString(data, keys: ["auth_data", "GeneratorClientHello"])
    }

    private static func nestedClientAck(_ data: Data) -> String? {
        jsonString(data, keys: ["auth_data", "ClientAckMsg"])
    }

    private static func nestedSession(_ data: Data) -> String? {
        jsonString(data, keys: ["auth_data", "session_id"])
    }

    /// `auth_data` is sometimes a JSON string and sometimes an object.
    private static func jsonString(_ data: Data, keys: [String]) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var value: Any = root
        for key in keys {
            if let object = value as? [String: Any],
               let next = object[key] ?? object.first(where: { $0.key.compare(key, options: .caseInsensitive) == .orderedSame })?.value {
                value = next
            } else if let text = value as? String,
                      let inner = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let next = inner[key] {
                value = next
            } else {
                return nil
            }
        }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func emit(_ event: ControllerEvent) {
        if case .pairingRequired = event { pairingStarted = true }
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(event)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        LocalNetworkTrust.handle(challenge, expectedHost: host, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        LocalNetworkTrust.handle(challenge, expectedHost: host, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol `protocol`: String?
    ) {
        guard webSocketTask === socket else { return }
        let saved = secrets?.string(for: SecretAccount.samsungToken(deviceID)) ?? ""
        if saved.isEmpty {
            emit(.pairingRequired(.acceptOnTV("Allow No Ads Remote on the Samsung TV.")))
        }
        receive()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask === socket, !stopped else { return }
        if connected {
            connected = false
            emit(.connectionLost("Samsung connection dropped. Reconnecting…"))
        } else {
            openOnce?.resume(false)
        }
    }
}
