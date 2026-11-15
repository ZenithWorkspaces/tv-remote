import Foundation
import Network
import Darwin

/// Finds TVs with Bonjour, multicast SSDP when the entitlement allows it, unicast SSDP, and a /24 port scan.
final class DiscoveryService {
    var onFound: ((TVDevice) -> Void)?
    var onScanning: ((Bool) -> Void)?

    private var browsers: [NWBrowser] = []
    private var multicast: NWConnectionGroup?
    private var scanTask: Task<Void, Never>?
    private var resolvers: [ObjectIdentifier: NWConnection] = [:]
    private let resolverLock = NSLock()

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
        resolverLock.lock()
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        resolverLock.unlock()
    }

    private func run(forcePorts: Bool) async {
        await MainActor.run { self.onScanning?(true) }
        defer { Task { @MainActor in self.onScanning?(false) } }
        guard let localIP = LocalIPv4.address() else { return }
        let responses = await Task.detached(priority: .userInitiated) {
            UnicastSSDP.collect(localIP: localIP, listen: 2.4)
        }.value
        if Task.isCancelled { return }
        for response in responses {
            ingest(response)
        }
        let shouldScanPorts = forcePorts || responses.isEmpty
        if shouldScanPorts {
            await portScan(localIP: localIP)
        }
    }

    private func portScan(localIP: String) async {
        let hosts = LocalIPv4.subnetHosts(from: localIP)
        var index = 0
        while index < hosts.count {
            if Task.isCancelled { return }
            let end = min(index + 16, hosts.count)
            let batch = Array(hosts[index..<end])
            index = end
            await withTaskGroup(of: TVDevice?.self) { group in
                for host in batch {
                    group.addTask {
                        await PortProbe.identify(host: host, timeout: 0.28)
                    }
                }
                for await device in group {
                    if let device {
                        self.deliver(device)
                    }
                }
            }
        }
    }

    private func ingest(_ response: SSDPResponse) {
        guard let host = response.host, !host.isEmpty else { return }
        if let brand = SSDPMessage.brand(searchTarget: response.searchTarget, server: response.server) {
            deliver(TVDevice.make(name: brand.displayName, host: host, brand: brand))
        }
        guard let location = response.location, let url = URL(string: location) else { return }
        Task { [weak self] in
            guard let data = await HTTPProbe.get(url: url, timeout: 2.0, trustHost: nil),
                  let xml = String(data: data, encoding: .utf8) else { return }
            let brand = SSDPMessage.brand(descriptionXML: xml)
                ?? SSDPMessage.brand(searchTarget: response.searchTarget, server: response.server)
            guard let brand else { return }
            let friendly = XMLValue.text(xml, tag: "friendlyName")
                ?? XMLValue.text(xml, tag: "friendly-device-name")
                ?? XMLValue.text(xml, tag: "user-device-name")
            let model = XMLValue.text(xml, tag: "modelName") ?? XMLValue.text(xml, tag: "model-name")
            let mac = MACAddress.find(in: xml)
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
                        self.deliver(device)
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
                    for target in SSDPTarget.searchTargets {
                        let payload = Data(SSDPMessage.search(target: target).utf8)
                        connection.send(content: payload) { _ in }
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            multicast = connection
        } catch {
            multicast = nil
        }
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
    static func collect(localIP: String, listen: TimeInterval) -> [SSDPResponse] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        if !bind(fd, address: localIP) {
            _ = bind(fd, address: "0.0.0.0")
        }
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
