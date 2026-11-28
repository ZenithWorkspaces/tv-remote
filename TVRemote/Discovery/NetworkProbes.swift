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

struct WakeDelivery: Equatable {
    var unicastSent = 0
    var broadcastSent = 0
    var broadcastAttempts = 0
    var broadcastError: String?
    var unicastError: String?
    var broadcastBlocked: Bool { broadcastAttempts > 0 && broadcastSent == 0 }

    var line: String {
        var parts = ["bsd unicast \(unicastSent), broadcast \(broadcastSent)/\(broadcastAttempts)"]
        if let broadcastError { parts.append("broadcast error \(broadcastError)") }
        if let unicastError { parts.append("unicast error \(unicastError)") }
        if broadcastBlocked { parts.append("broadcast blocked") }
        return parts.joined(separator: "; ")
    }
}

enum WakeSender {
    /// Three bursts. Each burst goes to ports 9 and 7 on the global broadcast,
    /// the subnet broadcast, and the TV's last address.
    @discardableResult
    static func send(mac: String, host: String?, repeats: Int = 3) -> WakeDelivery {
        guard let packet = WakeOnLAN.packet(mac: mac) else { return WakeDelivery() }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return WakeDelivery() }
        defer { close(fd) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        let targets = WakeOnLAN.targets(host: host, localAddress: LocalIPv4.address())
        var delivery = WakeDelivery()
        let bursts = max(repeats, 1)
        for _ in 0..<bursts {
            for address in targets {
                for port in WakeOnLAN.ports {
                    let error = blast(packet, address: address, port: port, fd: fd)
                    if WakeOnLAN.isBroadcast(address) {
                        delivery.broadcastAttempts += 1
                        if error == nil {
                            delivery.broadcastSent += 1
                        } else if delivery.broadcastError == nil {
                            delivery.broadcastError = error
                        }
                    } else if error == nil {
                        delivery.unicastSent += 1
                    } else if delivery.unicastError == nil {
                        delivery.unicastError = error
                    }
                }
            }
        }
        return delivery
    }

    /// nil means the kernel accepted the datagram.
    private static func blast(_ packet: Data, address: String, port: UInt16, fd: Int32) -> String? {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr.s_addr = inet_addr(address)
        // 255.255.255.255 is a valid broadcast target and inet_addr reports it as INADDR_NONE.
        let result = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &dest) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(fd, raw.baseAddress, raw.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard result == packet.count else {
            let code = errno
            return "\(address):\(port) errno \(code) \(String(cString: strerror(code)))"
        }
        return nil
    }
}

/// Same magic packet through Network.framework, so a blocked broadcast shows up as an error instead of a silent drop.
enum WakeLink {
    static func deliver(mac: String?, host: String?) async -> String {
        guard let mac, !mac.isEmpty, let packet = WakeOnLAN.packet(mac: mac) else {
            return "NW wake skipped: no MAC"
        }
        let targets = WakeOnLAN.targets(host: host, localAddress: LocalIPv4.address())
        var lines: [String] = []
        await withTaskGroup(of: String.self) { group in
            for address in targets {
                for port in WakeOnLAN.ports {
                    group.addTask {
                        await send(packet, address: address, port: port)
                    }
                }
            }
            for await line in group {
                lines.append(line)
            }
        }
        return lines.sorted().joined(separator: "; ")
    }

    private static func send(_ packet: Data, address: String, port: UInt16) async -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return "NW \(address):\(port) bad port"
        }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: .udp)
        return await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    sendBurst(packet, over: connection, address: address, port: port, once: once)
                case .failed(let error):
                    connection.cancel()
                    once.resume("NW \(address):\(port) failed \(error.localizedDescription)")
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) {
                connection.cancel()
                once.resume("NW \(address):\(port) timed out")
            }
        }
    }

    private static func sendBurst(
        _ packet: Data,
        over connection: NWConnection,
        address: String,
        port: UInt16,
        once: OnceResume<String>,
        remaining: Int = 3
    ) {
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                connection.cancel()
                once.resume("NW \(address):\(port) send \(error.localizedDescription)")
                return
            }
            if remaining <= 1 {
                connection.cancel()
                once.resume("NW \(address):\(port) sent 3")
            } else {
                sendBurst(packet, over: connection, address: address, port: port, once: once, remaining: remaining - 1)
            }
        })
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
    struct Inspection: Equatable {
        var host: String
        var openPorts: [UInt16]
        var device: TVDevice?
    }

    static func identify(host: String, timeout: TimeInterval, suggestedName: String? = nil) async -> TVDevice? {
        await inspect(host: host, timeout: timeout, suggestedName: suggestedName).device
    }

    static func inspect(host: String, timeout: TimeInterval, suggestedName: String? = nil) async -> Inspection {
        var open: [UInt16] = []
        await withTaskGroup(of: (UInt16, Bool).self) { group in
            for port in DiscoveryPorts.scan {
                group.addTask {
                    let isOpen = await TCPProbe.isOpen(host: host, port: port, timeout: timeout)
                    return (port, isOpen)
                }
            }
            for await (port, isOpen) in group where isOpen {
                open.append(port)
            }
        }
        open.sort()
        let device = await classify(host: host, open: Set(open), timeout: timeout, suggestedName: suggestedName)
        return Inspection(host: host, openPorts: open, device: device)
    }

    private static func classify(host: String, open: Set<UInt16>, timeout: TimeInterval, suggestedName: String?) async -> TVDevice? {
        if open.contains(8060), let url = URL(string: "http://\(host):8060\(RokuECP.deviceInfoPath)"),
           let data = await HTTPProbe.get(url: url, timeout: timeout + 0.4, trustHost: nil),
           let xml = String(data: data, encoding: .utf8),
           xml.lowercased().contains("roku") || xml.contains("<power-mode>") || xml.contains("<model-name>") {
            let info = RokuECP.parseDeviceInfo(xml)
            let name = preferred(suggestedName, info.name, fallback: "Roku")
            return TVDevice.make(name: name, host: host, brand: .roku, macAddress: info.macAddress, modelName: info.model)
        }

        if !open.isDisjoint(with: DiscoveryPorts.samsung) {
            return TVDevice.make(name: preferred(suggestedName, nil, fallback: "Samsung"), host: host, brand: .samsung)
        }

        if open.contains(3001) {
            return TVDevice.make(name: preferred(suggestedName, nil, fallback: "LG TV"), host: host, brand: .lg)
        }

        if open.contains(7345) || open.contains(9000) {
            return TVDevice.make(name: preferred(suggestedName, nil, fallback: "Vizio"), host: host, brand: .vizio)
        }

        if open.contains(6466) {
            return TVDevice.make(name: preferred(suggestedName, nil, fallback: "Android TV"), host: host, brand: .androidtv)
        }

        if open.contains(8008), let url = URL(string: "http://\(host):8008/ssdp/device-description.xml"),
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

        if open.contains(ADBProtocol.port), looksLikeFire(suggestedName) {
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
