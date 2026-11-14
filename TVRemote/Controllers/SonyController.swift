import Foundation

final class SonyController: TVControlling {
    var onEvent: ((ControllerEvent) -> Void)?

    private var host = ""
    private var deviceID = ""
    private var secrets: SecretProviding?
    private var psk: String?
    private var reachable = false
    private var failures = 0
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
    }()

    func connect(device: TVDevice, secrets: SecretProviding) {
        host = device.host
        deviceID = device.id
        self.secrets = secrets
        reachable = false
        failures = 0
        let stored = secrets.string(for: SecretAccount.sonyPSK(device.id)) ?? ""
        if stored.isEmpty {
            emit(.pairingRequired(.psk("Enter the pre-shared key from the Sony TV: Settings → Network → Home network → IP control.")))
            return
        }
        psk = stored
        Task { [weak self] in
            await self?.probe()
        }
    }

    func disconnect() {
        session.invalidateAndCancel()
    }

    func submitPairing(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            emit(.message("Enter the pre-shared key shown on the Sony TV."))
            return
        }
        psk = trimmed
        secrets?.set(trimmed, for: SecretAccount.sonyPSK(deviceID))
        Task { [weak self] in
            await self?.probe()
        }
    }

    func press(_ key: RemoteKey) {
        guard let code = SonyIRCC.code(for: key) else { return }
        post(code: code)
    }

    func launch(_ shortcut: AppShortcut) {
        emit(.message("App shortcuts on Sony open from the TV home screen. Use Home, then the app."))
    }

    func refreshInputs() {
        emit(.inputs(SonyIRCC.defaultInputs))
    }

    func select(input: TVInput) {
        guard case let .sonyCode(code) = input.route else { return }
        post(code: code)
    }

    private func probe() async {
        guard let psk, let url = URL(string: "http://\(host)/sony/system") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(psk, forHTTPHeaderField: "X-Auth-PSK")
        request.httpBody = Data(#"{"method":"getPowerStatus","params":[],"id":1,"version":"1.0"}"#.utf8)
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                reachable = true
                emit(.connected)
                emit(.inputs(SonyIRCC.defaultInputs))
            } else if status == 401 || status == 403 {
                self.psk = nil
                secrets?.set(nil, for: SecretAccount.sonyPSK(deviceID))
                emit(.pairingRequired(.psk("That pre-shared key was rejected. Enter the key from the Sony IP control menu.")))
            } else {
                emit(.notFound("Sony TV at \(host) answered with an unexpected status. Check IP control is enabled."))
            }
        } catch {
            emit(.notFound("Sony TV not found at \(host). Turn on IP control, then try again."))
        }
    }

    private func post(code: String) {
        guard let psk, let url = URL(string: "http://\(host)\(SonyIRCC.path)") else {
            emit(.pairingRequired(.psk("Enter the Sony pre-shared key to control this TV.")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2.5
        request.setValue("text/xml; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(SonyIRCC.soapAction, forHTTPHeaderField: "SOAPAction")
        request.setValue(psk, forHTTPHeaderField: "X-Auth-PSK")
        request.httpBody = Data(SonyIRCC.envelope(code: code).utf8)
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let ok = error == nil && (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
            if ok {
                self.failures = 0
                return
            }
            guard self.reachable else { return }
            self.failures += 1
            if self.failures >= 3 {
                self.reachable = false
                self.emit(.connectionLost("Sony TV stopped responding."))
            }
        }.resume()
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
