import Foundation

final class LGController: NSObject, TVControlling, URLSessionDelegate, URLSessionWebSocketDelegate {
    var onEvent: ((ControllerEvent) -> Void)?

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
    private var openOnce: OnceResume<Bool>?
    private var timeoutTask: Task<Void, Never>?

    func connect(device: TVDevice, secrets: SecretProviding) {
        host = device.host
        deviceID = device.id
        self.secrets = secrets
        stopped = false
        registered = false
        Task { [weak self] in
            await self?.open()
        }
    }

    func disconnect() {
        stopped = true
        timeoutTask?.cancel()
        commandSocket?.cancel(with: .goingAway, reason: nil)
        pointerSocket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        commandSocket = nil
        pointerSocket = nil
        pointerReady = false
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
        let key = secrets?.string(for: SecretAccount.lgClientKey(deviceID))
        if await attempt(scheme: "wss", port: LGSSAP.securePort, clientKey: key) { return }
        if stopped { return }
        if await attempt(scheme: "ws", port: LGSSAP.plainPort, clientKey: key) { return }
        if !stopped && !registered {
            emit(.notFound("LG webOS TV not found at \(host). Turn it on and accept the connection prompt if it appears."))
        }
    }

    private func attempt(scheme: String, port: Int, clientKey: String?) async -> Bool {
        attemptToken += 1
        let token = attemptToken
        teardownSocket()
        let trustSession = URLSession(
            configuration: ephemeralConfiguration(),
            delegate: self,
            delegateQueue: .main
        )
        session = trustSession
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else { return false }
        let socket = trustSession.webSocketTask(with: url)
        commandSocket = socket
        return await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            openOnce = once
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 75_000_000_000)
                guard !Task.isCancelled, let self, self.attemptToken == token, !self.registered else { return }
                once.resume(false)
                self.commandSocket?.cancel(with: .goingAway, reason: nil)
            }
            socket.resume()
            _ = clientKey
        }
    }

    private func teardownSocket() {
        commandSocket?.cancel(with: .goingAway, reason: nil)
        pointerSocket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        commandSocket = nil
        pointerSocket = nil
        pointerReady = false
        session = nil
    }

    private func sendRegister() {
        let key = secrets?.string(for: SecretAccount.lgClientKey(deviceID))
        guard let text = String(data: LGSSAP.registerData(clientKey: key), encoding: .utf8) else { return }
        commandSocket?.send(.string(text)) { _ in }
        receive(commandSocket)
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
                if case let .string(text) = message {
                    self.handle(text)
                }
                self.receive(task)
            case .failure:
                if task === self.pointerSocket {
                    self.pointerReady = false
                    return
                }
                guard task === self.commandSocket else { return }
                if self.registered {
                    self.registered = false
                    self.emit(.connectionLost("LG connection dropped. Reconnecting…"))
                } else {
                    self.openOnce?.resume(false)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = JSONBox.object(data) else { return }
        let type = object["type"] as? String ?? ""
        let payload = object["payload"] as? [String: Any] ?? [:]
        if payload["pairingType"] as? String == "PROMPT" {
            emit(.pairingRequired(.acceptOnTV("Look at the LG TV and allow No Ads Remote.")))
        }
        if type == "registered" || payload["client-key"] != nil && type == "response" && object["id"] as? String == "register_0" {
            if let key = payload["client-key"] as? String, !key.isEmpty {
                secrets?.set(key, for: SecretAccount.lgClientKey(deviceID))
            }
            if !registered {
                registered = true
                timeoutTask?.cancel()
                emit(.connected)
                emit(.inputs(LGSSAP.defaultInputs))
                openOnce?.resume(true)
                sendRequest(uri: LGSSAP.pointerSocketURI, payload: LGPayload())
                sendRequest(uri: LGSSAP.connectionInfoURI, payload: LGPayload())
                sendRequest(uri: LGSSAP.launchPointsURI, payload: LGPayload())
            }
        }
        if let socketPath = payload["socketPath"] as? String {
            openPointer(socketPath)
        }
        if let mac = MACAddress.find(in: payload) {
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
        if type == "error", !registered {
            openOnce?.resume(false)
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

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              challenge.protectionSpace.host == host else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol `protocol`: String?
    ) {
        if webSocketTask === commandSocket {
            sendRegister()
        } else if webSocketTask === pointerSocket {
            pointerReady = true
            let queued = pendingButtons
            pendingButtons.removeAll()
            for name in queued {
                sendPointer(name)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask === commandSocket, !stopped else { return }
        if registered {
            registered = false
            emit(.connectionLost("LG connection dropped. Reconnecting…"))
        } else {
            openOnce?.resume(false)
        }
    }
}
