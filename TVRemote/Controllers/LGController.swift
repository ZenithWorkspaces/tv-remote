import Foundation

enum LGAttemptResult: Equatable {
    case connected
    case failed
    case stop(String)
}

final class LGController: NSObject, TVControlling, URLSessionDelegate, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
    var onEvent: ((ControllerEvent) -> Void)?

    private enum Phase {
        case opening
        case hello
        case register
        case user
        case connected
    }

    private enum WaitKind {
        case open
        case hello
        case register
        case user
    }

    private var host = ""
    private var deviceID = ""
    private var secrets: SecretProviding?
    private var session: URLSession?
    private var commandSocket: URLSessionWebSocketTask?
    private var pointerSocket: URLSessionWebSocketTask?
    private var registered = false
    private var pointerReady = false
    private var stopped = false
    private var apps: [InstalledApp] = []
    private var pendingButtons: [String] = []
    private var nextID = 0
    private var playingNext = true
    private var muted = false
    private var attemptToken = 0
    private var openOnce: OnceResume<LGAttemptResult>?
    private var timeoutTask: Task<Void, Never>?
    private var timeoutGeneration = 0
    private var handshake = LGHandshake(manifest: .signed)
    private var phase: Phase = .opening
    private var userPromptVisible = false
    private var helloRejected = false
    private var socketOpened = false
    private var socketEnded = false
    private var attemptScheme = "wss"
    private var attemptPort = LGSSAP.securePort
    private var tried: Set<String> = []
    private var pendingRequests: [String: OnceResume<[String: Any]?>] = [:]
    private var powerGeneration = 0
    private var powerMAC: String?

    func connect(device: TVDevice, secrets: SecretProviding) {
        host = device.host
        deviceID = device.id
        self.secrets = secrets
        stopped = false
        registered = false
        helloRejected = false
        tried = []
        Task { [weak self] in
            await self?.open()
        }
    }

    func submitPairing(_ value: String) {
        guard handshake.pairing == .pin, userPromptVisible else { return }
        let pin = value.filter(\.isNumber)
        guard !pin.isEmpty else {
            emit(.pairingRejected("Enter the PIN shown on the TV."))
            return
        }
        handshake.waitingForPIN = true
        let data = LGSSAP.requestData(
            id: LGSSAP.setPinRequestID,
            uri: LGSSAP.setPinURI,
            payload: LGSSAP.setPinPayload(pin)
        )
        guard let text = String(data: data, encoding: .utf8) else { return }
        commandSocket?.send(.string(text)) { _ in }
        schedule(.user)
    }

    func disconnect() {
        stopped = true
        powerGeneration += 1
        timeoutTask?.cancel()
        let waiters = pendingRequests
        pendingRequests = [:]
        for waiter in waiters.values {
            waiter.resume(nil)
        }
        finish(.failed)
        teardownSocket()
    }

    func togglePower(mac: String?) {
        powerMAC = mac
        powerGeneration += 1
        let generation = powerGeneration
        Task { [weak self] in
            await self?.runPowerToggle(generation)
        }
    }

    func press(_ key: RemoteKey) {
        if key == .playPause {
            let command = LGSSAP.command(for: key, muted: muted, playNext: playingNext)
            playingNext.toggle()
            perform(command)
            return
        }
        if key == .mute {
            muted.toggle()
            perform(LGSSAP.command(for: key, muted: muted, playNext: playingNext))
            return
        }
        perform(LGSSAP.command(for: key, muted: muted, playNext: playingNext))
    }

    func launch(_ shortcut: AppShortcut) {
        let id = AppShortcutResolver.lgID(for: shortcut, installed: apps)
        sendRequest(uri: LGSSAP.launchURI, payload: LGSSAP.launchPayload(appID: id))
    }

    func sendText(_ text: String) {
        sendRequest(uri: LGSSAP.insertTextURI, payload: LGSSAP.textPayload(text))
    }

    func deleteBackward() {
        perform(LGSSAP.command(for: .backspace))
    }

    func refreshInputs() {
        emit(.inputs(LGSSAP.defaultInputs))
        sendRequest(uri: LGSSAP.inputListURI, payload: LGPayload())
    }

    func select(input: TVInput) {
        switch input.route {
        case let .launchApp(id):
            sendRequest(uri: LGSSAP.launchURI, payload: LGSSAP.launchPayload(appID: id))
        case let .lgInput(id):
            sendRequest(uri: "ssap://tv/switchInput", payload: LGPayload(strings: ["inputId": id]))
        default:
            break
        }
    }

    private func open() async {
        let steps: [(String, Int, LGSSAP.Manifest)] = [
            ("wss", LGSSAP.securePort, .signed),
            ("wss", LGSSAP.securePort, .unsigned),
            ("ws", LGSSAP.plainPort, .signed),
            ("ws", LGSSAP.plainPort, .unsigned)
        ]
        for (scheme, port, manifest) in steps {
            if stopped || registered { return }
            let key = stepKey(scheme: scheme, port: port, manifest: manifest)
            if tried.contains(key) { continue }
            let result = await attempt(scheme: scheme, port: port, manifest: manifest)
            switch result {
            case .connected:
                return
            case let .stop(message):
                guard !stopped else { return }
                emit(.notFound(message))
                return
            case .failed:
                break
            }
        }
        guard !stopped, !registered else { return }
        emit(.notFound("Couldn't pair with the LG TV at \(host). Leave it on and try again. If no PIN or Allow prompt appears, remove the TV in the app and add it again."))
    }

    private func attempt(scheme: String, port: Int, manifest: LGSSAP.Manifest) async -> LGAttemptResult {
        attemptToken += 1
        handshake = LGHandshake(manifest: manifest)
        phase = .opening
        userPromptVisible = false
        socketOpened = false
        socketEnded = false
        attemptScheme = scheme
        attemptPort = port
        tried.insert(stepKey(scheme: scheme, port: port, manifest: manifest))
        teardownSocket()
        let trustSession = URLSession(
            configuration: ephemeralConfiguration(),
            delegate: self,
            delegateQueue: .main
        )
        session = trustSession
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else { return .failed }
        emit(.diagnostic("LG opening \(scheme)://\(host):\(port) (\(manifest == .signed ? "signed" : "unsigned") registration)"))
        let socket = trustSession.webSocketTask(with: url)
        commandSocket = socket
        return await withCheckedContinuation { continuation in
            openOnce = OnceResume(continuation)
            schedule(.open)
            socket.resume()
        }
    }

    private func stepKey(scheme: String, port: Int, manifest: LGSSAP.Manifest) -> String {
        "\(scheme):\(port):\(manifest == .signed ? "signed" : "unsigned")"
    }

    private func schedule(_ kind: WaitKind) {
        timeoutGeneration += 1
        let generation = timeoutGeneration
        let token = attemptToken
        timeoutTask?.cancel()
        let nanoseconds: UInt64
        switch kind {
        case .open: nanoseconds = 8_000_000_000
        case .hello: nanoseconds = 1_500_000_000
        case .register: nanoseconds = 8_000_000_000
        case .user: nanoseconds = 90_000_000_000
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, self.timeoutGeneration == generation, self.attemptToken == token, !self.stopped, !self.registered else { return }
                self.handleTimeout(kind)
            }
        }
    }

    private func handleTimeout(_ kind: WaitKind) {
        switch kind {
        case .open:
            noteSchemeUnreachable()
            emit(.diagnostic("LG socket timed out before it opened."))
            finish(.failed)
        case .hello:
            finishHelloAndRegister()
        case .register:
            emit(.diagnostic("LG registration did not answer. Trying the next handshake."))
            apply(handshake.timedOutWaitingForRegister())
        case .user:
            finish(.stop("Pairing timed out. Check the TV for a PIN or an Allow prompt, then try again."))
        }
    }

    /// A port that never opens will not open for the other registration style either.
    private func noteSchemeUnreachable() {
        tried.insert(stepKey(scheme: attemptScheme, port: attemptPort, manifest: .signed))
        tried.insert(stepKey(scheme: attemptScheme, port: attemptPort, manifest: .unsigned))
    }

    private func finish(_ result: LGAttemptResult) {
        timeoutTask?.cancel()
        if result != .connected {
            socketEnded = true
        }
        // Capture the socket before resuming. The next attempt can replace
        // `commandSocket` if this continuation runs before the function returns.
        let closing = result == .connected ? nil : commandSocket
        openOnce?.resume(result)
        closing?.cancel(with: .goingAway, reason: nil)
    }

    private func teardownSocket() {
        let command = commandSocket
        let pointer = pointerSocket
        let current = session
        commandSocket = nil
        pointerSocket = nil
        pointerReady = false
        session = nil
        command?.cancel(with: .goingAway, reason: nil)
        pointer?.cancel(with: .goingAway, reason: nil)
        current?.invalidateAndCancel()
    }

    private func finishHelloAndRegister() {
        guard phase == .hello else { return }
        sendRegister()
    }

    private func sendRegister() {
        phase = .register
        let stored = handshake.droppedClientKey ? nil : secrets?.string(for: SecretAccount.lgClientKey(deviceID))
        let key = (stored?.isEmpty == false) ? stored : nil
        handshake.sentClientKey = key != nil
        tried.insert(stepKey(scheme: attemptScheme, port: attemptPort, manifest: handshake.manifest))
        let style = handshake.manifest == .signed ? "signed" : "unsigned"
        let keyNote = key == nil ? "no saved key" : "saved key"
        emit(.diagnostic("LG registering (\(style), \(keyNote), \(handshake.pairing.rawValue))"))
        send(LGSSAP.registerObject(clientKey: key, pairingType: handshake.pairing, manifest: handshake.manifest))
        if !userPromptVisible {
            schedule(.register)
        }
    }

    private func send(_ object: [String: Any]) {
        guard let text = String(data: JSONBox.data(object), encoding: .utf8), text != "{}" else { return }
        commandSocket?.send(.string(text)) { _ in }
    }

    private func apply(_ move: LGHandshakeMove) {
        switch move {
        case let .saveKeyAndConnect(key):
            if let key, !key.isEmpty {
                secrets?.set(key, for: SecretAccount.lgClientKey(deviceID))
            }
            guard !registered else { return }
            registered = true
            phase = .connected
            timeoutTask?.cancel()
            emit(.connected)
            emit(.inputs(LGSSAP.defaultInputs))
            finish(.connected)
            sendRequest(uri: LGSSAP.pointerSocketURI, payload: LGPayload())
            sendRequest(uri: LGSSAP.connectionInfoURI, payload: LGPayload())
            sendRequest(uri: LGSSAP.systemInfoURI, payload: LGPayload())
            sendRequest(uri: LGSSAP.launchPointsURI, payload: LGPayload())
        case .showPIN:
            userPromptVisible = true
            phase = .user
            handshake.pairing = .pin
            emit(.diagnostic("LG asked for a PIN."))
            emit(.pairingRequired(.pin("Type the code shown on the TV.")))
            schedule(.user)
        case .showPrompt:
            userPromptVisible = true
            phase = .user
            handshake.pairing = .prompt
            emit(.diagnostic("LG asked for an Allow prompt."))
            emit(.pairingRequired(.acceptOnTV("Accept No Ads Remote on the TV. The joystick button under the TV presses OK.")))
            schedule(.user)
        case .wrongPIN:
            emit(.pairingRejected("That PIN didn't match. Check the TV and try again."))
            schedule(.user)
        case let .sendRegister(manifest, dropClientKey, pairing):
            handshake.manifest = manifest
            handshake.pairing = pairing
            if dropClientKey {
                forgetClientKey()
            }
            sendRegister()
        case .giveUp:
            emit(.diagnostic("LG registration was rejected."))
            finish(.failed)
        case .ignore:
            break
        }
    }

    private func forgetClientKey() {
        let hadKey = secrets?.string(for: SecretAccount.lgClientKey(deviceID))?.isEmpty == false
        handshake.droppedClientKey = true
        handshake.sentClientKey = false
        secrets?.set(nil, for: SecretAccount.lgClientKey(deviceID))
        if hadKey {
            emit(.diagnostic("LG forgot the saved client key so the TV can pair again."))
        }
    }

    private func runPowerToggle(_ generation: Int) async {
        guard generation == powerGeneration, registered else { return }
        emit(.diagnostic("LG power: reading getPowerState"))
        let stateResponse = await request(id: "lg-power-state", uri: LGSSAP.powerStateURI)
        guard generation == powerGeneration else { return }
        let payload = (stateResponse?["payload"] as? [String: Any]) ?? [:]
        let state = LGSSAP.powerLabel(payload)
        let readable = stateResponse != nil && !LGSSAP.requestFailed(stateResponse)
        emit(.diagnostic("LG power state: \(readable ? state : "no answer")"))
        if readable, LGSSAP.isActivePower(state) {
            emit(.lgPower(.turningOff))
            sendRequest(uri: LGSSAP.turnOffURI, payload: LGPayload())
            return
        }
        let seen = readable ? state : "unknown"
        emit(.lgPower(.turningOn(seen)))
        await wakeAndTurnScreenOn(generation, from: seen)
    }

    private func wakeAndTurnScreenOn(_ generation: Int, from state: String) async {
        if let mac = powerMAC, !mac.isEmpty {
            let delivery = WakeSender.send(mac: mac, host: host)
            emit(.diagnostic("LG wake unicast \(delivery.unicastSent), broadcast \(delivery.broadcastSent) of \(delivery.broadcastAttempts)"))
            if delivery.broadcastBlocked {
                emit(.diagnostic("LG wake broadcast was blocked. This build has no multicast entitlement, so the packet went to the TV's last address."))
            }
        } else {
            emit(.diagnostic("LG wake skipped: no MAC saved yet"))
        }
        guard generation == powerGeneration else { return }
        let turnedOn = await request(id: "lg-power-on", uri: LGSSAP.turnOnScreenURI)
        guard generation == powerGeneration else { return }
        if LGSSAP.requestFailed(turnedOn) {
            emit(.diagnostic("LG turnOnScreen failed. Sending POWER on the button socket."))
            sendPointer("POWER")
        } else {
            emit(.diagnostic("LG turnOnScreen accepted from \(state)."))
        }
        var latest = state
        for attempt in 1...4 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard generation == powerGeneration, registered else { return }
            let poll = await request(id: "lg-power-state-\(attempt)", uri: LGSSAP.powerStateURI)
            guard generation == powerGeneration else { return }
            let payload = (poll?["payload"] as? [String: Any]) ?? [:]
            latest = LGSSAP.powerLabel(payload)
            emit(.diagnostic("LG power state after wake \(attempt): \(poll == nil ? "no answer" : latest)"))
            if poll != nil, LGSSAP.isActivePower(latest) {
                emit(.lgPower(.confirmed(latest)))
                return
            }
        }
        emit(.lgPower(.stillOff(latest)))
    }

    private func request(id: String, uri: String) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            let start = { [weak self] in
                guard let self, self.registered, self.commandSocket != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let once = OnceResume<[String: Any]?>(continuation)
                self.pendingRequests[id] = once
                let data = LGSSAP.requestData(id: id, uri: uri)
                if let text = String(data: data, encoding: .utf8) {
                    self.commandSocket?.send(.string(text)) { _ in }
                }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    DispatchQueue.main.async {
                        self?.pendingRequests.removeValue(forKey: id)?.resume(nil)
                    }
                }
            }
            if Thread.isMainThread {
                start()
            } else {
                DispatchQueue.main.async(execute: start)
            }
        }
    }

    private func perform(_ command: LGCommand) {
        switch command {
        case let .pointer(name):
            sendPointer(name)
        case let .request(uri, payload):
            sendRequest(uri: uri, payload: payload)
        case .unsupported:
            break
        }
    }

    private func sendPointer(_ name: String) {
        let text = LGSSAP.pointerButton(name)
        guard pointerReady, let pointerSocket else {
            if pendingButtons.count < 8 {
                pendingButtons.append(name)
            }
            return
        }
        pointerSocket.send(.string(text)) { _ in }
    }

    private func sendRequest(uri: String, payload: LGPayload) {
        guard registered, let commandSocket else { return }
        nextID += 1
        let data = LGSSAP.requestData(id: "cmd-\(nextID)", uri: uri, payload: payload)
        guard let text = String(data: data, encoding: .utf8) else { return }
        commandSocket.send(.string(text)) { _ in }
    }

    private func receive(_ task: URLSessionWebSocketTask?) {
        task?.receive { [weak self, weak task] result in
            guard let self, !self.stopped else { return }
            switch result {
            case let .success(message):
                let text: String?
                switch message {
                case let .string(value):
                    text = value
                case let .data(value):
                    text = String(data: value, encoding: .utf8)
                }
                if task === self.commandSocket, let text {
                    self.handle(text)
                }
                self.receive(task)
            case .failure:
                if task === self.pointerSocket {
                    self.pointerReady = false
                    return
                }
                guard task === self.commandSocket else { return }
                self.commandSocketClosed()
            }
        }
    }

    private func commandSocketClosed() {
        if registered {
            registered = false
            emit(.connectionLost("LG connection dropped. Reconnecting…"))
            return
        }
        guard !socketEnded else { return }
        socketEnded = true
        if !socketOpened {
            noteSchemeUnreachable()
        }
        if phase == .hello {
            helloRejected = true
        }
        if phase == .user {
            finish(.stop("The LG TV closed the connection before pairing finished. Try again."))
            return
        }
        emit(.diagnostic("LG socket closed before pairing finished."))
        finish(.failed)
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = JSONBox.object(data) else { return }
        let type = (object["type"] as? String ?? "").lowercased()
        if type == "hello" {
            let payload = object["payload"] as? [String: Any] ?? [:]
            let types = payload["pairingTypes"] as? [String] ?? []
            if !types.isEmpty {
                emit(.diagnostic("LG TV pairing types: \(types.joined(separator: ", "))."))
            }
            if let mode = LGSSAP.pairingMode(advertised: types), mode != handshake.pairing, phase == .register, !userPromptVisible {
                handshake.pairing = mode
                sendRegister()
                return
            }
            if let mode = LGSSAP.pairingMode(advertised: types) {
                handshake.pairing = mode
            }
            finishHelloAndRegister()
            return
        }
        if phase == .hello {
            finishHelloAndRegister()
            return
        }
        guard !registered else {
            if let id = object["id"] as? String, let waiter = pendingRequests.removeValue(forKey: id) {
                waiter.resume(object)
            }
            if type == "error" {
                let error = LGHandshake.failureText(object)
                if !error.isEmpty {
                    emit(.diagnostic("LG request failed: \(error)"))
                }
            }
            noteControlMessage(object)
            return
        }
        if phase == .user {
            let move = handshake.consume(object)
            switch move {
            case .giveUp, .sendRegister:
                break
            default:
                apply(move)
            }
            return
        }
        let move = handshake.consume(object)
        if move != .ignore {
            let error = LGHandshake.failureText(object)
            if !error.isEmpty {
                emit(.diagnostic("LG TV said: \(error)"))
            }
            apply(move)
        }
        if registered {
            noteControlMessage(object)
        }
    }

    private func noteControlMessage(_ object: [String: Any]) {
        let payload = object["payload"] as? [String: Any] ?? [:]
        if let socketPath = payload["socketPath"] as? String {
            openPointer(socketPath)
        }
        if let mac = MACAddress.preferred(in: payload) {
            emit(.learnedMAC(mac))
        }
        if let points = payload["launchPoints"] as? [[String: Any]] {
            let parsed: [InstalledApp] = points.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                let title = (item["title"] as? String) ?? id
                return InstalledApp(id: id, name: title)
            }
            if !parsed.isEmpty {
                apps = parsed
                emit(.apps(parsed))
            }
        }
        if let devices = (payload["devices"] as? [[String: Any]]) ?? (payload["inputList"] as? [[String: Any]]) {
            let inputs: [TVInput] = devices.compactMap { item in
                let id = (item["id"] as? String) ?? (item["inputId"] as? String)
                guard let id else { return nil }
                let label = (item["label"] as? String) ?? (item["name"] as? String) ?? id
                if id.hasPrefix("com.webos.app.") {
                    return TVInput(id: id, name: label, route: .launchApp(id))
                }
                return TVInput(id: id, name: label, route: .lgInput(id))
            }
            if !inputs.isEmpty {
                emit(.inputs(inputs))
            }
        }
    }

    private func openPointer(_ socketPath: String) {
        guard let url = URL(string: socketPath), let session else { return }
        let socket = session.webSocketTask(with: url)
        pointerSocket = socket
        socket.resume()
        receive(socket)
    }

    private func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return configuration
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

    private func acceptTrust(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        LocalNetworkTrust.handle(challenge, expectedHost: host, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        acceptTrust(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // WebSocket TLS challenges are delivered here. The session-level method is not enough.
        acceptTrust(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol `protocol`: String?
    ) {
        guard webSocketTask === commandSocket else {
            if webSocketTask === pointerSocket {
                pointerReady = true
                let queued = pendingButtons
                pendingButtons.removeAll()
                for name in queued {
                    sendPointer(name)
                }
            }
            return
        }
        socketOpened = true
        if helloRejected {
            receive(commandSocket)
            sendRegister()
        } else {
            phase = .hello
            receive(commandSocket)
            send(LGSSAP.helloObject())
            schedule(.hello)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask === commandSocket, !stopped else { return }
        commandSocketClosed()
    }
}
