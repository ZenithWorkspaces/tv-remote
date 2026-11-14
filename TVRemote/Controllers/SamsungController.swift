import Foundation

final class SamsungController: NSObject, TVControlling, URLSessionDelegate, URLSessionWebSocketDelegate {
    var onEvent: ((ControllerEvent) -> Void)?

    private let remoteName = "TV Remote"
    private var host = ""
    private var deviceID = ""
    private var secrets: SecretProviding?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var connected = false
    private var stopped = false
    private var apps: [InstalledApp] = []
    private var attemptToken = 0
    private var openOnce: OnceResume<Bool>?
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
        timeoutTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        socket = nil
        connected = false
    }

    func press(_ key: RemoteKey) {
        guard let name = SamsungRemote.keyName(for: key) else { return }
        send(SamsungRemote.clickObject(key: name))
    }

    func launch(_ shortcut: AppShortcut) {
        let id = AppShortcutResolver.samsungID(for: shortcut, installed: apps)
        send(SamsungRemote.launchObject(appID: id))
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        send(SamsungRemote.textObject(text))
    }

    func select(input: TVInput) {
        guard case let .samsungKey(name) = input.route else { return }
        send(SamsungRemote.clickObject(key: name))
    }

    private func open() async {
        let stored = secrets?.string(for: SecretAccount.samsungToken(deviceID))
        if await attempt(secure: true, token: stored) { return }
        if stopped || connected { return }
        if await attempt(secure: true, token: nil) { return }
        if stopped || connected { return }
        if await attempt(secure: false, token: nil) { return }
        if !stopped && !connected {
            emit(.notFound("Samsung TV not found at \(host). Turn it on and allow TV Remote if the TV asks."))
        }
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
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled, let self, self.attemptToken == tokenNumber, !self.connected else { return }
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
            }
            return
        }
        if event == "ms.channel.unauthorized" || event == "ms.channel.timeOut" {
            secrets?.set(nil, for: SecretAccount.samsungToken(deviceID))
            if allowFallback {
                allowFallback = false
                connected = false
                openOnce?.resume(false)
                emit(.pairingRequired(.acceptOnTV("Allow TV Remote on the Samsung screen, then it will connect.")))
            }
        }
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
        guard webSocketTask === socket else { return }
        let saved = secrets?.string(for: SecretAccount.samsungToken(deviceID)) ?? ""
        if saved.isEmpty {
            emit(.pairingRequired(.acceptOnTV("Allow TV Remote on the Samsung TV.")))
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
