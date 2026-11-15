import Foundation
import Darwin
import Network

enum LocalIPv4 {
    static func address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var fallback: String?
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostBuffer)
            guard ip != "127.0.0.1", isPrivate(ip) else { continue }
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }

    static func isPrivate(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }

    static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value), !part.isEmpty else { return false }
            return part.allSatisfy(\.isNumber)
        }
    }

    static func subnetHosts(from ip: String) -> [String] {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, let own = Int(parts[3]) else { return [] }
        let prefix = parts.prefix(3).joined(separator: ".")
        return (1...254).compactMap { last in
            last == own ? nil : "\(prefix).\(last)"
        }
    }

    static func subnetBroadcast(from ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts.prefix(3).joined(separator: ".")).255"
    }
}

enum WakeSender {
    static func send(mac: String, host: String?) {
        guard let packet = WakeOnLAN.packet(mac: mac) else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        func blast(_ address: String, _ port: UInt16) {
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = port.bigEndian
            dest.sin_addr.s_addr = inet_addr(address)
            // 255.255.255.255 is a valid broadcast target and inet_addr reports it as INADDR_NONE.
            packet.withUnsafeBytes { raw in
                _ = withUnsafePointer(to: &dest) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        sendto(fd, raw.baseAddress, raw.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        blast("255.255.255.255", 9)
        blast("255.255.255.255", 7)
        if let host {
            blast(host, 9)
            blast(host, 7)
            if let broadcast = LocalIPv4.subnetBroadcast(from: host) {
                blast(broadcast, 9)
            }
        }
    }
}

enum TCPProbe {
    static func isOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let once = OnceResume(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    once.resume(true)
                case .failed(_):
                    connection.cancel()
                    once.resume(false)
                case .cancelled:
                    once.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                once.resume(false)
            }
        }
    }
}

enum HTTPProbe {
    static func get(url: URL, timeout: TimeInterval, trustHost: String?) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        let delegate = trustHost.map { LocalTLSTrust(host: $0) }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

enum PortProbe {
    static func identify(host: String, timeout: TimeInterval, suggestedName: String? = nil) async -> TVDevice? {
        async let open8060 = TCPProbe.isOpen(host: host, port: 8060, timeout: timeout)
        async let open3000 = TCPProbe.isOpen(host: host, port: 3000, timeout: timeout)
        async let open3001 = TCPProbe.isOpen(host: host, port: 3001, timeout: timeout)
        async let open8001 = TCPProbe.isOpen(host: host, port: 8001, timeout: timeout)
        async let open8002 = TCPProbe.isOpen(host: host, port: 8002, timeout: timeout)
        async let open7345 = TCPProbe.isOpen(host: host, port: 7345, timeout: timeout)
        async let open9000 = TCPProbe.isOpen(host: host, port: 9000, timeout: timeout)
        async let open6466 = TCPProbe.isOpen(host: host, port: 6466, timeout: timeout)
        async let open8008 = TCPProbe.isOpen(host: host, port: 8008, timeout: timeout)
        async let open5555 = TCPProbe.isOpen(host: host, port: ADBProtocol.port, timeout: timeout)
        let ports = await (open8060, open3000, open3001, open8001, open8002, open7345, open9000, open6466, open8008, open5555)

        if ports.0, let url = URL(string: "http://\(host):8060\(RokuECP.deviceInfoPath)"),
           let data = await HTTPProbe.get(url: url, timeout: timeout + 0.4, trustHost: nil),
           let xml = String(data: data, encoding: .utf8),
           xml.lowercased().contains("roku") || xml.contains("<power-mode>") || xml.contains("<model-name>") {
            let info = RokuECP.parseDeviceInfo(xml)
            let name = preferred(suggestedName, info.name, fallback: "Roku")
            return TVDevice.make(name: name, host: host, brand: .roku, macAddress: info.macAddress, modelName: info.model)
        }

        if ports.3 || ports.4, let url = URL(string: "http://\(host):8001/api/v2/"),
           let data = await HTTPProbe.get(url: url, timeout: timeout + 0.4, trustHost: nil),
           let text = String(data: data, encoding: .utf8)?.lowercased(),
           text.contains("samsung") || text.contains("tizen") || text.contains("\"device\"") || text.contains("devicename") {
            let name = preferred(suggestedName, nil, fallback: "Samsung")
            return TVDevice.make(name: name, host: host, brand: .samsung)
        }

        if ports.2 {
            return TVDevice.make(name: preferred(suggestedName, nil, fallback: "LG TV"), host: host, brand: .lg)
        }

        if ports.5 || ports.6 {
            return TVDevice.make(name: preferred(suggestedName, nil, fallback: "Vizio"), host: host, brand: .vizio)
        }

        if ports.7 {
            return TVDevice.make(name: preferred(suggestedName, nil, fallback: "Android TV"), host: host, brand: .androidtv)
        }

        if ports.8, let url = URL(string: "http://\(host):8008/ssdp/device-description.xml"),
           let data = await HTTPProbe.get(url: url, timeout: timeout + 0.4, trustHost: nil),
           let xml = String(data: data, encoding: .utf8),
           let brand = SSDPMessage.brand(descriptionXML: xml) {
            let friendly = XMLValue.text(xml, tag: "friendlyName")
            let model = XMLValue.text(xml, tag: "modelName")
            return TVDevice.make(
                name: preferred(suggestedName, friendly, fallback: brand.displayName),
                host: host,
                brand: brand,
                modelName: model
            )
        }

        if ports.9, looksLikeFire(suggestedName) {
            return TVDevice.make(
                name: preferred(suggestedName, nil, fallback: "Fire TV"),
                host: host,
                brand: .firetv
            )
        }
        return nil
    }

    private static func looksLikeFire(_ name: String?) -> Bool {
        guard let name else { return false }
        let lower = name.lowercased()
        return lower.contains("fire") || lower.contains("amazon") || lower.contains("amzn") || lower.contains("aft")
    }

    private static func preferred(_ suggested: String?, _ discovered: String?, fallback: String) -> String {
        if let suggested, !suggested.isEmpty, suggested != fallback { return suggested }
        if let discovered, !discovered.isEmpty { return discovered }
        if let suggested, !suggested.isEmpty { return suggested }
        return fallback
    }
}
