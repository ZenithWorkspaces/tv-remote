import Foundation

final class RokuController: TVControlling {
    var onEvent: ((ControllerEvent) -> Void)?

    private var host = ""
    private var apps: [InstalledApp] = []
    private var didConnect = false
    private var failures = 0
    private var stopped = false
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
    }()

    func connect(device: TVDevice, secrets: SecretProviding) {
        host = device.host
        stopped = false
        didConnect = false
        failures = 0
        Task { [weak self] in
            await self?.probe()
        }
    }

    func disconnect() {
        stopped = true
        session.invalidateAndCancel()
    }

    func press(_ key: RemoteKey) {
        guard let path = RokuECP.keypressPath(for: key) else { return }
        post(path)
    }

    func launch(_ shortcut: AppShortcut) {
        let id = AppShortcutResolver.rokuID(for: shortcut, installed: apps)
        post(RokuECP.launchPath(appID: id))
    }

    func sendText(_ text: String) {
        for path in RokuECP.literalPaths(for: text) {
            post(path)
        }
    }

    func deleteBackward() {
        post(RokuECP.keypressPath(named: "Backspace"))
    }

    func refreshInputs() {
        emit(.inputs(RokuECP.defaultInputs))
    }

    func select(input: TVInput) {
        guard case let .rokuKey(name) = input.route else { return }
        post(RokuECP.keypressPath(named: name))
    }

    private func probe() async {
        guard let data = await fetch(RokuECP.deviceInfoPath),
              let xml = String(data: data, encoding: .utf8) else {
            emit(.notFound("Roku not found at \(host). Turn it on, use the same Wi-Fi, and set Control by mobile apps to Enabled."))
            return
        }
        let info = RokuECP.parseDeviceInfo(xml)
        didConnect = true
        failures = 0
        emit(.connected)
        emit(.inputs(RokuECP.defaultInputs))
        if let name = info.name, !name.isEmpty {
            emit(.learnedName(name))
        }
        if let mac = info.macAddress {
            emit(.learnedMAC(mac))
        }
        if let appsData = await fetch(RokuECP.appsPath),
           let appsXML = String(data: appsData, encoding: .utf8) {
            let parsed = RokuECP.parseApps(appsXML)
            apps = parsed
            emit(.apps(parsed))
        }
    }

    private func fetch(_ path: String) async -> Data? {
        guard let url = URL(string: "http://\(host):\(RokuECP.port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private func post(_ path: String) {
        guard !stopped, let url = URL(string: "http://\(host):\(RokuECP.port)\(path)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.timeoutInterval = 2.5
        session.dataTask(with: request) { [weak self] _, response, error in
            self?.note(response: response, error: error)
        }.resume()
    }

    private func note(response: URLResponse?, error: Error?) {
        let ok: Bool
        if error != nil {
            ok = false
        } else if let http = response as? HTTPURLResponse {
            ok = (200...299).contains(http.statusCode)
        } else {
            ok = false
        }
        if ok {
            failures = 0
            return
        }
        guard didConnect else { return }
        failures += 1
        if failures >= 3 {
            didConnect = false
            emit(.connectionLost("The Roku stopped responding."))
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
}
