import Foundation
import Network
import Security

final class AndroidTVController: TVControlling {
    var onEvent: ((ControllerEvent) -> Void)?

    private let queue = DispatchQueue(label: "tvremote.androidtv")
    private var host = ""
    private var deviceID = ""
    private var secrets: SecretProviding?
    private var stopped = false
    private var stream: FramedTLS?
    private var codeWaiter: OnceResume<String>?
    private var pendingCode: String?
    private var imeCounter = 0
    private var fieldCounter = 0
    private var features = AndroidTVRemote.Feature.client

    func connect(device: TVDevice, secrets: SecretProviding) {
        host = device.host
        deviceID = device.id
        self.secrets = secrets
        stopped = false
        Task { [weak self] in
            await self?.open()
        }
    }

    func disconnect() {
        stopped = true
        codeWaiter?.resume("")
        codeWaiter = nil
        stream?.close()
        stream = nil
    }

    func press(_ key: RemoteKey) {
        guard let code = AndroidTVRemote.keyCode(for: key) else {
            emit(.message("This Google TV doesn't use that button."))
            return
        }
        send(AndroidTVRemote.keyInject(code: code))
    }

    func launch(_ shortcut: AppShortcut) {
        send(AndroidTVRemote.appLinkLaunch(AndroidTVRemote.appLink(for: shortcut)))
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        send(AndroidTVRemote.textEdit(text, imeCounter: imeCounter, fieldCounter: fieldCounter))
    }

    func deleteBackward() {
        press(.backspace)
    }

    func select(input: TVInput) {
        press(.input)
    }

    func submitPairing(_ value: String) {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let waiter = codeWaiter {
            codeWaiter = nil
            waiter.resume(code)
        } else {
            pendingCode = code
        }
    }

    private func open() async {
        guard let material = loadIdentity() else {
            emit(.notFound("Couldn't prepare a certificate for this Google TV."))
            return
        }
        if secrets?.string(for: SecretAccount.androidPaired(deviceID)) == "1" {
            if await runCommands(material) {
                if !stopped { emit(.connectionLost("Google TV connection dropped. Reconnecting…")) }
                return
            }
            secrets?.set(nil, for: SecretAccount.androidPaired(deviceID))
        }
        guard !stopped else { return }
        if await pair(material), await runCommands(material) {
            if !stopped { emit(.connectionLost("Google TV connection dropped. Reconnecting…")) }
            return
        }
        if !stopped {
            emit(.notFound("Google TV not found at \(host). Turn it on and stay on the same Wi-Fi."))
        }
    }

    private func pair(_ material: TLSMaterial) async -> Bool {
        let link = FramedTLS()
        stream = link
        guard await link.open(host: host, port: AndroidTVRemote.pairingPort, identity: material.identity) else {
            return false
        }
        link.send(Proto.frame(AndroidTVRemote.pairingRequest()))
        while !stopped {
            guard let message = await link.readMessage() else { return false }
            if AndroidTVRemote.pairingStatus(message) != 200 { return false }
            switch AndroidTVRemote.pairingField(message) {
            case .requestAck:
                link.send(Proto.frame(AndroidTVRemote.options()))
            case .options:
                link.send(Proto.frame(AndroidTVRemote.configuration()))
            case .configurationAck:
                var accepted = false
                while !stopped && !accepted {
                    emit(.pairingRequired(.code("Enter the 6-character code shown on the TV.")))
                    let code = await nextCode()
                    guard !stopped, !code.isEmpty else { return false }
                    guard let digest = digest(for: code, client: material.certificate, server: link.peerCertificate),
                          AndroidTVRemote.codeMatches(digest: digest, code: code) else {
                        emit(.pairingRejected("That code didn't match. Read the 6 characters on the TV and try again."))
                        continue
                    }
                    link.send(Proto.frame(AndroidTVRemote.secret(digest)))
                    accepted = true
                }
            case .secretAck:
                secrets?.set("1", for: SecretAccount.androidPaired(deviceID))
                link.close()
                return true
            case nil:
                return false
            }
        }
        return false
    }

    private func runCommands(_ material: TLSMaterial) async -> Bool {
        let link = FramedTLS()
        stream = link
        guard await link.open(host: host, port: AndroidTVRemote.commandPort, identity: material.identity) else {
            return false
        }
        var announced = false
        while !stopped {
            guard let message = await link.readMessage() else { return announced }
            switch AndroidTVRemote.commandField(message) {
            case .configure:
                let server = AndroidTVRemote.configureCode(message)
                features = server & AndroidTVRemote.Feature.client
                link.send(Proto.frame(AndroidTVRemote.configure(features: features)))
            case .setActive:
                link.send(Proto.frame(AndroidTVRemote.setActive(features: features)))
            case .ping:
                link.send(Proto.frame(AndroidTVRemote.pingResponse(AndroidTVRemote.pingValue(message))))
            case .imeBatch:
                let counters = AndroidTVRemote.imeCounters(message)
                imeCounter = counters.0
                fieldCounter = counters.1
            case .start:
                if !announced {
                    announced = true
                    emit(.connected)
                }
            case nil:
                break
            }
        }
        return announced
    }

    private func digest(for code: String, client: Data, server: Data?) -> Data? {
        guard let server,
              let clientNumbers = ASN1.rsaNumbers(in: client),
              let serverNumbers = ASN1.rsaNumbers(in: server),
              let clientExponent = smallInteger(clientNumbers.exponent),
              let serverExponent = smallInteger(serverNumbers.exponent) else { return nil }
        return AndroidTVRemote.pairingDigest(
            clientModulus: clientNumbers.modulus,
            clientExponent: clientExponent,
            serverModulus: serverNumbers.modulus,
            serverExponent: serverExponent,
            code: code
        )
    }

    private func loadIdentity() -> TLSMaterial? {
        let tag = "android.key.\(deviceID)"
        guard let key = PersistentRSAKey.loadOrCreate(tag: tag) else { return nil }
        let account = SecretAccount.androidCert(deviceID)
        let der: Data
        if let saved = secrets?.string(for: account), let decoded = Data(base64Encoded: saved),
           SecCertificateCreateWithData(nil, decoded as CFData) != nil {
            der = decoded
        } else if let created = ClientCertificate.certificateDER(key: key) {
            secrets?.set(created.base64EncodedString(), for: account)
            der = created
        } else {
            return nil
        }
        guard let identity = ClientCertificate.identity(certificateDER: der, key: key) else { return nil }
        return TLSMaterial(identity: identity, certificate: der)
    }

    private func nextCode() async -> String {
        if let pending = pendingCode {
            pendingCode = nil
            return pending
        }
        return await withCheckedContinuation { continuation in
            codeWaiter = OnceResume(continuation)
        }
    }

    private func send(_ message: Data) {
        stream?.send(Proto.frame(message))
    }

    private func smallInteger(_ magnitude: Data) -> Int? {
        guard magnitude.count <= 4 else { return nil }
        var value = 0
        for byte in magnitude { value = (value << 8) | Int(byte) }
        return value
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

private struct TLSMaterial {
    var identity: sec_identity_t
    var certificate: Data
}

final class FramedTLS {
    private let queue = DispatchQueue(label: "tvremote.framed-tls")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var buffer = Data()
    private var inbox: [Data] = []
    private var reader: OnceResume<Data?>?
    private var failed = false
    private(set) var peerCertificate: Data?

    func open(host: String, port: UInt16, identity: sec_identity_t) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first {
                self?.peerCertificate = SecCertificateCopyData(leaf) as Data
            }
            complete(true)
        }, queue)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: tls))
        self.connection = connection
        let ready: Bool = await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(true)
                case .failed, .cancelled:
                    once.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        guard ready else { return false }
        receive()
        return true
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func readMessage() async -> Data? {
        lock.lock()
        if !inbox.isEmpty {
            let message = inbox.removeFirst()
            lock.unlock()
            return message
        }
        if failed {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            lock.lock()
            if !inbox.isEmpty {
                let message = inbox.removeFirst()
                lock.unlock()
                once.resume(message)
                return
            }
            if failed {
                lock.unlock()
                once.resume(nil)
                return
            }
            reader = once
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        failed = true
        let pending = reader
        reader = nil
        lock.unlock()
        connection?.cancel()
        pending?.resume(nil)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.lock()
            if let data { self.buffer.append(data) }
            while let message = Proto.popFrame(&self.buffer) {
                self.inbox.append(message)
            }
            let pending = self.reader
            if pending != nil, !self.inbox.isEmpty {
                let message = self.inbox.removeFirst()
                self.reader = nil
                if error != nil || isComplete { self.failed = true }
                self.lock.unlock()
                pending?.resume(message)
            } else if error != nil || isComplete {
                self.failed = true
                self.reader = nil
                self.lock.unlock()
                pending?.resume(nil)
                return
            } else {
                self.lock.unlock()
            }
            self.receive()
        }
    }
}
