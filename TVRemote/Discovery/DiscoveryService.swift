import Foundation
import Network
import Darwin

/// Finds TVs with Bonjour, multicast SSDP when the entitlement allows it, unicast SSDP, and a /24 port scan.
final class DiscoveryService {
    var onFound: ((TVDevice) -> Void)?
    var onScanning: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private var browsers: [NWBrowser] = []
    private var multicast: NWConnectionGroup?
    private var multicastReady = false
    private var scanTask: Task<Void, Never>?
    private var resolvers: [ObjectIdentifier: NWConnection] = [:]
    private let resolverLock = NSLock()
    private let generationLock = NSLock()
    private var scanGeneration = 0
    /// Long enough for a 2015 Samsung to answer SSDP and for the /24 sweep to finish.
    private let scanWindow: TimeInterval = 12
    private let unicastListen: TimeInterval = 6

    func start() {
        startBonjour()
        startMulticast()
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.run(forcePorts: false)
        }
    }

    func rescan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.run(forcePorts: true)
        }
    }

    func stop() {
        scanTask?.cancel()
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        multicast?.cancel()
        multicast = nil
        multicastReady = false
        resolverLock.lock()
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        resolverLock.unlock()
    }

    private func run(forcePorts: Bool) async {
        let generation = bumpGeneration()
        let started = Date()
        await MainActor.run { self.onScanning?(true) }
        log("Scan started")
        sendSearches()
        defer {
            let elapsed = Date().timeIntervalSince(started)
            let remain = scanWindow - elapsed
            Task { @MainActor in
                if remain > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remain * 1_000_000_000))
                }
                guard self.currentGeneration() == generation else { return }
                self.log(String(format: "Scan finished after %.0fs", Date().timeIntervalSince(started)))
                self.onScanning?(false)
            }
        }
        guard let localIP = LocalIPv4.address() else {
            log("Scan stopped: this phone has no Wi-Fi address")
            return
        }
        let listen = unicastListen
        let responses = await Task.detached(priority: .userInitiated) { [weak self] in
            UnicastSSDP.collect(localIP: localIP, listen: listen) { response in
                self?.ingest(response)
            }
        }.value
        if Task.isCancelled || currentGeneration() != generation { return }
        if responses.isEmpty {
            log("Unicast SSDP: no replies")
        }
        sendSearches()
        let shouldScanPorts = forcePorts || responses.isEmpty
        if shouldScanPorts {
            await portScan(localIP: localIP)
        }
    }

    private func portScan(localIP: String) async {
        log("Port sweep started")
        let hosts = LocalIPv4.subnetHosts(from: localIP)
        var index = 0
        while index < hosts.count {
            if Task.isCancelled { return }
            let end = min(index + 16, hosts.count)
            let batch = Array(hosts[index..<end])
            index = end
            await withTaskGroup(of: PortProbe.Inspection.self) { group in
                for host in batch {
                    group.addTask {
                        await PortProbe.inspect(host: host, timeout: 0.4)
                    }
                }
                for await inspection in group {
                    if !inspection.openPorts.isEmpty {
                        let ports = inspection.openPorts.map(String.init).joined(separator: ",")
                        let brand = inspection.device?.brand.rawValue ?? "unrecognized"
                        self.log("\(inspection.host) open \(ports) \(brand)")
                    }
                    if let device = inspection.device {
                        self.deliver(device)
                    }
                }
            }
        }
    }

    private func bumpGeneration() -> Int {
        generationLock.lock()
        scanGeneration += 1
        let value = scanGeneration
        generationLock.unlock()
        return value
    }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return scanGeneration
    }

    private func ingest(_ response: SSDPResponse) {
        guard let host = response.host, !host.isEmpty else { return }
        let hinted = SSDPMessage.brand(searchTarget: response.searchTarget, server: response.server)
        let target = response.searchTarget.isEmpty ? "-" : response.searchTarget
        log("SSDP \(host) ST=\(target) \(hinted?.rawValue ?? "checking description")")
        if let brand = hinted {
            deliver(TVDevice.make(name: brand.displayName, host: host, brand: brand))
        }
        guard let location = response.location, let url = URL(string: location) else { return }
        Task { [weak self] in
            guard let data = await HTTPProbe.get(url: url, timeout: 2.0, trustHost: nil),
                  let xml = String(data: data, encoding: .utf8) else { return }
            let brand = SSDPMessage.brand(descriptionXML: xml)
                ?? SSDPMessage.brand(searchTarget: response.searchTarget, server: response.server)
            guard let brand else {
                self?.log("SSDP \(host) description unrecognized")
                return
            }
            let friendly = XMLValue.text(xml, tag: "friendlyName")
                ?? XMLValue.text(xml, tag: "friendly-device-name")
                ?? XMLValue.text(xml, tag: "user-device-name")
            let model = XMLValue.text(xml, tag: "modelName") ?? XMLValue.text(xml, tag: "model-name")
            let mac = MACAddress.find(in: xml)
            self?.log("SSDP \(host) description \(brand.rawValue) \(friendly ?? "")")
            self?.deliver(TVDevice.make(
                name: (friendly?.isEmpty == false ? friendly! : brand.displayName),
                host: host,
                brand: brand,
                macAddress: mac,
                modelName: model
            ))
        }
    }

    private func deliver(_ device: TVDevice) {
        guard device.brand.isOffered else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onFound?(device)
        }
    }

    private func log(_ line: String) {
        let callback = onLog
        DispatchQueue.main.async {
            callback?(line)
        }
    }

    private func startBonjour() {
        for type in BonjourServiceType.all {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                for result in results {
                    self?.resolve(result, serviceType: type)
                }
            }
            browser.start(queue: .global(qos: .utility))
            browsers.append(browser)
        }
    }

    private func resolve(_ result: NWBrowser.Result, serviceType: String) {
        let instanceName: String
        if case let .service(name, _, _, _) = result.endpoint {
            instanceName = name
        } else {
            instanceName = ""
        }
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        remember(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                let host = Self.ipv4Host(connection.currentPath?.remoteEndpoint)
                connection.cancel()
                self.forget(connection)
                guard let host else { return }
                Task { [weak self] in
                    guard let self else { return }
                    if let device = await PortProbe.identify(host: host, timeout: 0.45, suggestedName: instanceName) {
                        self.log("Bonjour \(serviceType) \(instanceName) \(host) \(device.brand.rawValue)")
                        self.deliver(device)
                    } else if Self.samsungHint(serviceType: serviceType, name: instanceName) {
                        self.log("Bonjour \(serviceType) \(instanceName) \(host) samsung")
                        let name = instanceName.isEmpty ? "Samsung" : instanceName
                        self.deliver(TVDevice.make(name: name, host: host, brand: .samsung))
                    } else {
                        self.log("Bonjour \(serviceType) \(instanceName) \(host) no brand")
                    }
                }
            case .failed(_):
                self.forget(connection)
            case .cancelled:
                self.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    private func startMulticast() {
        let host = NWEndpoint.Host("239.255.255.250")
        guard let port = NWEndpoint.Port(rawValue: 1900) else { return }
        do {
            let group = try NWMulticastGroup(for: [.hostPort(host: host, port: port)])
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let connection = NWConnectionGroup(with: group, using: parameters)
            connection.setReceiveHandler { [weak self] _, data, _ in
                guard let data, let text = String(data: data, encoding: .utf8),
                      let response = SSDPMessage.parse(text) else { return }
                self?.ingest(response)
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.multicastReady = true
                    self.sendSearches()
                case .failed(let error):
                    self.multicastReady = false
                    self.log("SSDP multicast unavailable (\(error.localizedDescription))")
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            multicast = connection
        } catch {
            multicast = nil
            log("SSDP multicast unavailable")
        }
    }

    private func sendSearches() {
        guard let connection = multicast, multicastReady else { return }
        for target in SSDPTarget.searchTargets {
            let payload = Data(SSDPMessage.search(target: target).utf8)
            connection.send(content: payload) { _ in }
        }
        log("SSDP multicast search sent")
    }

    private static func samsungHint(serviceType: String, name: String) -> Bool {
        let blob = (serviceType + " " + name).lowercased()
        return blob.contains("samsung") || blob.contains("[tv]")
    }

    private func remember(_ connection: NWConnection) {
        resolverLock.lock()
        resolvers[ObjectIdentifier(connection)] = connection
        resolverLock.unlock()
    }

    private func forget(_ connection: NWConnection) {
        resolverLock.lock()
        resolvers.removeValue(forKey: ObjectIdentifier(connection))
        resolverLock.unlock()
    }

    private static func ipv4Host(_ endpoint: NWEndpoint?) -> String? {
        guard let endpoint, case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return "\(address)"
        case .name(let name, _):
            return LocalIPv4.isValidIPv4(name) ? name : nil
        default:
            return nil
        }
    }
}

enum UnicastSSDP {
    static func collect(localIP: String, listen: TimeInterval, onEach: ((SSDPResponse) -> Void)? = nil) -> [SSDPResponse] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        if !bind(fd, address: localIP) {
            _ = bind(fd, address: "0.0.0.0")
        }
        var bufferSize: Int32 = 1_048_576
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.stride))
        }
        let hosts = LocalIPv4.subnetHosts(from: localIP)
        for target in SSDPTarget.searchTargets {
            let payload = Array(SSDPMessage.search(target: target).utf8)
            for host in hosts {
                send(fd, payload: payload, host: host, port: 1900)
            }
        }
        var found: [SSDPResponse] = []
        let deadline = Date().addingTimeInterval(listen)
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Int(recv(fd, base, raw.count, 0))
            }
            guard count > 0 else { continue }
            if let text = String(bytes: buffer.prefix(count), encoding: .utf8),
               let response = SSDPMessage.parse(text) {
                found.append(response)
                onEach?(response)
            }
        }
        return found
    }

    private static func bind(_ fd: Int32, address: String) -> Bool {
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = inet_addr(address)
        return withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func send(_ fd: Int32, payload: [UInt8], host: String, port: UInt16) {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr.s_addr = inet_addr(host)
        guard dest.sin_addr.s_addr != INADDR_NONE else { return }
        _ = payload.withUnsafeBytes { raw in
            withUnsafePointer(to: &dest) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(fd, raw.baseAddress, raw.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
