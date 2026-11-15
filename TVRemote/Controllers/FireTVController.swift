import Foundation
import Network
import Security

/// Fire TV has no supported key API that works with developer options left off.
/// This speaks ADB on port 5555. The TV asks once to allow the phone.
final class FireTVController: TVControlling {
    var onEvent: ((ControllerEvent) -> Void)?

    private let queue = DispatchQueue(label: "tvremote.firetv")
    private var host = ""
    private var deviceID = ""
    private var stopped = false
    private var connection: NWConnection?
    private var buffer = Data()
    private var packetWaiter: OnceResume<ADBProtocol.Packet?>?
    private var key: SecKey?
    private var shellReady = false
    private var remoteID: UInt32 = 0
    private let localID: UInt32 = 1
    private var writeChain: Task<Void, Never>?
    private var generation = 0

    func connect(device: TVDevice, secrets: SecretProviding) {
        host = device.host
        deviceID = device.id
        stopped = false
        _ = secrets
        Task { [weak self] in
            await self?.open()
        }
    }

    func disconnect() {
        stopped = true
        packetWaiter?.resume(nil)
        packetWaiter = nil
        connection?.cancel()
        connection = nil
        shellReady = false
    }

    func press(_ key: RemoteKey) {
        guard let command = ADBProtocol.shellCommand(for: key) else {
            emit(.message("This Fire TV doesn't use that button."))
            return
        }
        enqueue(command)
    }

    func launch(_ shortcut: AppShortcut) {
        guard let package = ADBProtocol.package(for: shortcut) else {
            emit(.message("Open \(shortcut.title) from the Fire TV home screen."))
            return
        }
        enqueue(ADBProtocol.launchCommand(package: package))
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        enqueue(ADBProtocol.textCommand(text))
    }

    func deleteBackward() {
        press(.backspace)
    }

    func select(input: TVInput) {
        press(.input)
    }

    private func open() async {
        let tag = "adb.key.\(deviceID)"
        guard let key = PersistentRSAKey.loadOrCreate(tag: tag) else {
            emit(.notFound("Couldn't prepare a key for this Fire TV."))
            return
        }
        self.key = key
        if await session(key) { return }
        guard !stopped else { return }
        emit(.pairingRequired(.acceptOnTV(Self.setupText)))
        for _ in 0..<12 {
            if stopped { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if stopped { return }
            if await session(key) { return }
        }
        if !stopped {
            emit(.notFound("Fire TV not found at \(host). Turn on ADB debugging, then try again."))
        }
    }

    private func session(_ key: SecKey) async -> Bool {
        guard await connectSocket() else { return false }
        send(ADBProtocol.connectPacket())
        var signed = false
        while !stopped {
            guard let packet = await nextPacket() else { return false }
            switch packet.command {
            case ADBProtocol.connect:
                guard await openShell() else { return false }
                emit(.connected)
                return true
            case ADBProtocol.auth where packet.arg0 == ADBProtocol.authToken && !signed:
                guard let signature = PersistentRSAKey.signRaw(packet.payload, key: key) else { return false }
                send(ADBProtocol.authSignature(signature))
                signed = true
            case ADBProtocol.auth:
                guard let numbers = PersistentRSAKey.modulusAndExponent(key),
                      let blob = ADBProtocol.androidPublicKey(modulus: padded(numbers.0), exponent: UInt32(numbers.1)) else {
                    return false
                }
                emit(.pairingRequired(.acceptOnTV(Self.allowText)))
                send(ADBProtocol.authKey(blob))
            default:
                break
            }
        }
        return false
    }

    private func openShell() async -> Bool {
        send(ADBProtocol.openShell(localID: localID))
        while !stopped {
            guard let packet = await nextPacket() else { return false }
            if packet.command == ADBProtocol.okay && packet.arg1 == localID {
                remoteID = packet.arg0
                shellReady = true
                return true
            }
            if packet.command == ADBProtocol.close { return false }
            acknowledge(packet)
        }
        return false
    }

    private func enqueue(_ text: String) {
        let previous = writeChain
        writeChain = Task { [weak self] in
            _ = await previous?.value
            await self?.write(text)
        }
    }

    private func write(_ text: String) async {
        guard shellReady, !stopped else { return }
        send(ADBProtocol.write(text, localID: localID, remoteID: remoteID))
        while !stopped {
            guard let packet = await nextPacket() else {
                shellReady = false
                return
            }
            if packet.command == ADBProtocol.okay && packet.arg1 == localID { return }
            if packet.command == ADBProtocol.close {
                shellReady = false
                _ = await openShell()
                return
            }
            acknowledge(packet)
        }
    }

    private func acknowledge(_ packet: ADBProtocol.Packet) {
        guard packet.command == ADBProtocol.write else { return }
        send(ADBProtocol.okay(localID: localID, remoteID: packet.arg0))
    }

    private func connectSocket() async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: ADBProtocol.port) else { return false }
        generation += 1
        let token = generation
        connection?.cancel()
        packetWaiter?.resume(nil)
        packetWaiter = nil
        buffer.removeAll()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
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
        receive(token)
        return true
    }

    private func receive(_ token: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, self.generation == token else { return }
            if let data { self.buffer.append(data) }
            self.drain()
            if error != nil || isComplete {
                self.packetWaiter?.resume(nil)
                self.packetWaiter = nil
                return
            }
            self.receive(token)
        }
    }

    private func drain() {
        guard packetWaiter != nil else { return }
        switch ADBProtocol.intake(buffer) {
        case .needMore:
            return
        case .bad:
            packetWaiter?.resume(nil)
            packetWaiter = nil
        case let .ready(packet, count):
            buffer.removeFirst(count)
            let waiter = packetWaiter
            packetWaiter = nil
            waiter?.resume(packet)
        }
    }

    private func nextPacket() async -> ADBProtocol.Packet? {
        if case let .ready(packet, count) = ADBProtocol.intake(buffer) {
            buffer.removeFirst(count)
            return packet
        }
        return await withCheckedContinuation { continuation in
            packetWaiter = OnceResume(continuation)
            drain()
        }
    }

    private func send(_ packet: ADBProtocol.Packet) {
        connection?.send(content: packet.encoded, completion: .contentProcessed { _ in })
    }

    private func padded(_ modulus: Data) -> Data {
        var bytes = [UInt8](modulus)
        while bytes.first == 0 { bytes.removeFirst() }
        let size = ((max(bytes.count, 1) + 3) / 4) * 4
        if bytes.count < size {
            bytes.insert(contentsOf: repeatElement(0, count: size - bytes.count), at: 0)
        }
        return Data(bytes)
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

    private static let setupText = "Fire TV control uses network ADB, which is off until you turn it on. On the TV open Settings, My Fire TV, About, and select the device name seven times if Developer options is hidden. Then open Developer options and turn on ADB debugging. Allow this phone when the TV asks. This is only needed once."

    private static let allowText = "Allow this phone on the Fire TV. Check the box to always allow it, then this remote connects by itself."
}
