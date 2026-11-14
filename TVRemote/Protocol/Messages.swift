import Foundation

enum JSONBox {
    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ object: Any) -> String {
        String(data: data(object), encoding: .utf8) ?? "{}"
    }
}

enum XMLValue {
    static func text(_ xml: String, tag: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tag))[^>]*>([^<]+)</\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: xml) else { return nil }
        let value = String(xml[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum MACAddress {
    static func normalize(_ raw: String) -> String? {
        let hex = raw.filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        var pairs: [String] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            pairs.append(String(hex[index..<next]).uppercased())
            index = next
        }
        return pairs.joined(separator: ":")
    }

    static func find(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return normalize(String(text[swiftRange]))
    }

    static func find(in object: Any) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict where key.lowercased().contains("mac") {
                if let string = value as? String, let mac = normalize(string) {
                    return mac
                }
            }
            for value in dict.values {
                if let nested = find(in: value) { return nested }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = find(in: value) { return nested }
            }
        }
        return nil
    }
}

struct RokuDeviceInfo: Equatable {
    var name: String?
    var model: String?
    var macAddress: String?
}

enum RokuECP {
    static let port = 8060

    static func keyName(for key: RemoteKey) -> String? {
        switch key {
        case .powerOn: return "PowerOn"
        case .powerOff: return "PowerOff"
        case .input: return nil
        case .home: return "Home"
        case .back: return "Back"
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .ok: return "Select"
        case .volumeUp: return "VolumeUp"
        case .volumeDown: return "VolumeDown"
        case .mute: return "VolumeMute"
        case .channelUp: return "ChannelUp"
        case .channelDown: return "ChannelDown"
        case .playPause: return "Play"
        case .rewind: return "Rev"
        case .fastForward: return "Fwd"
        case .menu: return "Info"
        case .backspace: return "Backspace"
        case .enter: return "Enter"
        }
    }

    static func keypressPath(for key: RemoteKey) -> String? {
        guard let name = keyName(for: key) else { return nil }
        return keypressPath(named: name)
    }

    static func keypressPath(named name: String) -> String {
        "/keypress/\(name)"
    }

    static func literalPath(for character: Character) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let raw = String(character)
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
        return "/keypress/Lit_\(encoded)"
    }

    static func literalPaths(for text: String) -> [String] {
        text.map { literalPath(for: $0) }
    }

    static func launchPath(appID: String) -> String {
        let encoded = appID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? appID
        return "/launch/\(encoded)"
    }

    static let appsPath = "/query/apps"
    static let deviceInfoPath = "/query/device-info"

    static func parseApps(_ xml: String) -> [InstalledApp] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<app\b[^>]*\bid\s*=\s*"([^"]+)"[^>]*>([^<]*)</app>"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(xml.startIndex..., in: xml)
        return regex.matches(in: xml, range: range).compactMap { match in
            guard let idRange = Range(match.range(at: 1), in: xml),
                  let nameRange = Range(match.range(at: 2), in: xml) else { return nil }
            let name = String(xml[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return InstalledApp(id: String(xml[idRange]), name: name)
        }
    }

    static func parseDeviceInfo(_ xml: String) -> RokuDeviceInfo {
        let name = XMLValue.text(xml, tag: "user-device-name")
            ?? XMLValue.text(xml, tag: "friendly-device-name")
            ?? XMLValue.text(xml, tag: "friendly-model-name")
        let model = XMLValue.text(xml, tag: "model-name")
        let mac = XMLValue.text(xml, tag: "wifi-mac").flatMap(MACAddress.normalize)
            ?? XMLValue.text(xml, tag: "ethernet-mac").flatMap(MACAddress.normalize)
        return RokuDeviceInfo(name: name, model: model, macAddress: mac)
    }

    static var defaultInputs: [TVInput] {
        [
            TVInput(id: "InputTuner", name: "TV tuner", route: .rokuKey("InputTuner")),
            TVInput(id: "InputHDMI1", name: "HDMI 1", route: .rokuKey("InputHDMI1")),
            TVInput(id: "InputHDMI2", name: "HDMI 2", route: .rokuKey("InputHDMI2")),
            TVInput(id: "InputHDMI3", name: "HDMI 3", route: .rokuKey("InputHDMI3")),
            TVInput(id: "InputHDMI4", name: "HDMI 4", route: .rokuKey("InputHDMI4")),
            TVInput(id: "InputAV1", name: "AV", route: .rokuKey("InputAV1"))
        ]
    }
}

struct LGPayload: Equatable {
    var strings: [String: String] = [:]
    var bools: [String: Bool] = [:]
    var ints: [String: Int] = [:]

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [:]
        strings.forEach { object[$0.key] = $0.value }
        bools.forEach { object[$0.key] = $0.value }
        ints.forEach { object[$0.key] = $0.value }
        return object
    }
}

enum LGCommand: Equatable {
    case pointer(String)
    case request(uri: String, payload: LGPayload)
    case unsupported
}

enum LGSSAP {
    static let securePort = 3001
    static let plainPort = 3000

    /// Signature shipped with the public webOS second-screen registration payload.
    /// The signed block must stay byte-for-byte compatible with what LG TVs already trust.
    static let registrationSignature = "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw=="

    static func pointerButton(_ name: String) -> String {
        "type:button\nname:\(name)\n\n"
    }

    static func command(for key: RemoteKey, muted: Bool = true, playNext: Bool = true) -> LGCommand {
        switch key {
        case .powerOn, .input:
            return .unsupported
        case .powerOff:
            return .request(uri: "ssap://system/turnOff", payload: LGPayload())
        case .home:
            return .pointer("HOME")
        case .back:
            return .pointer("BACK")
        case .up:
            return .pointer("UP")
        case .down:
            return .pointer("DOWN")
        case .left:
            return .pointer("LEFT")
        case .right:
            return .pointer("RIGHT")
        case .ok:
            return .pointer("ENTER")
        case .volumeUp:
            return .request(uri: "ssap://audio/volumeUp", payload: LGPayload())
        case .volumeDown:
            return .request(uri: "ssap://audio/volumeDown", payload: LGPayload())
        case .mute:
            return .request(uri: "ssap://audio/setMute", payload: LGPayload(bools: ["mute": muted]))
        case .channelUp:
            return .request(uri: "ssap://tv/channelUp", payload: LGPayload())
        case .channelDown:
            return .request(uri: "ssap://tv/channelDown", payload: LGPayload())
        case .playPause:
            return .pointer(playNext ? "PLAY" : "PAUSE")
        case .rewind:
            return .pointer("REWIND")
        case .fastForward:
            return .pointer("FASTFORWARD")
        case .menu:
            return .pointer("MENU")
        case .backspace:
            return .request(uri: "ssap://com.webos.service.ime/deleteCharacters", payload: LGPayload(ints: ["count": 1]))
        case .enter:
            return .request(uri: "ssap://com.webos.service.ime/sendEnterKey", payload: LGPayload())
        }
    }

    static func requestObject(id: String, uri: String, payload: LGPayload = LGPayload()) -> [String: Any] {
        [
            "type": "request",
            "id": id,
            "uri": uri,
            "payload": payload.jsonObject()
        ]
    }

    static func requestData(id: String, uri: String, payload: LGPayload = LGPayload()) -> Data {
        JSONBox.data(requestObject(id: id, uri: uri, payload: payload))
    }

    static func launchPayload(appID: String) -> LGPayload {
        LGPayload(strings: ["id": appID])
    }

    static func textPayload(_ text: String) -> LGPayload {
        LGPayload(strings: ["text": text], ints: ["replace": 0])
    }

    enum PairingMode: String {
        case pin = "PIN"
        case prompt = "PROMPT"
    }

    static let setPinURI = "ssap://pairing/setPin"
    static let setPinRequestID = "pairing_pin"

    static func setPinPayload(_ pin: String) -> LGPayload {
        LGPayload(strings: ["pin": pin])
    }

    static func registerObject(clientKey: String?, pairingType: PairingMode = .pin) -> [String: Any] {
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": pairingType.rawValue,
            "manifest": manifest()
        ]
        if let clientKey, !clientKey.isEmpty {
            payload["client-key"] = clientKey
        }
        return [
            "type": "register",
            "id": "register_0",
            "payload": payload
        ]
    }

    static func registerData(clientKey: String?, pairingType: PairingMode = .pin) -> Data {
        JSONBox.data(registerObject(clientKey: clientKey, pairingType: pairingType))
    }

    static var defaultInputs: [TVInput] {
        (1...4).map { index in
            let appID = "com.webos.app.hdmi\(index)"
            return TVInput(id: appID, name: "HDMI \(index)", route: .launchApp(appID))
        } + [
            TVInput(id: "com.webos.app.livetv", name: "Live TV", route: .launchApp("com.webos.app.livetv"))
        ]
    }

    static let pointerSocketURI = "ssap://com.webos.service.networkinput/getPointerInputSocket"
    static let launchPointsURI = "ssap://com.webos.applicationManager/listLaunchPoints"
    static let inputListURI = "ssap://tv/getExternalInputList"
    static let connectionInfoURI = "ssap://com.webos.service.connectionmanager/getinfo"
    static let launchURI = "ssap://system.launcher/launch"
    static let insertTextURI = "ssap://com.webos.service.ime/insertText"

    private static func manifest() -> [String: Any] {
        [
            "manifestVersion": 1,
            "appVersion": "1.1",
            "signed": [
                "created": "20140509",
                "appId": "com.lge.test",
                "vendorId": "com.lge",
                "localizedAppNames": [
                    "": "LG Remote App",
                    "ko-KR": "리모컨 앱",
                    "zxx-XX": "ЛГ Rэмotэ AПП"
                ],
                "localizedVendorNames": [
                    "": "LG Electronics"
                ],
                "permissions": signedPermissions,
                "serial": "2f930e2d2cfe083771f68e4fe7bb07"
            ],
            "permissions": manifestPermissions,
            "signatures": [
                [
                    "signatureVersion": 1,
                    "signature": registrationSignature
                ]
            ]
        ]
    }

    private static let signedPermissions = [
        "TEST_SECURE",
        "CONTROL_INPUT_TEXT",
        "CONTROL_MOUSE_AND_KEYBOARD",
        "READ_INSTALLED_APPS",
        "READ_LGE_SDX",
        "READ_NOTIFICATIONS",
        "SEARCH",
        "WRITE_SETTINGS",
        "WRITE_NOTIFICATION_ALERT",
        "CONTROL_POWER",
        "READ_CURRENT_CHANNEL",
        "READ_RUNNING_APPS",
        "READ_UPDATE_INFO",
        "UPDATE_FROM_REMOTE_APP",
        "READ_LGE_TV_INPUT_EVENTS",
        "READ_TV_CURRENT_TIME"
    ]

    private static let manifestPermissions = [
        "LAUNCH",
        "LAUNCH_WEBAPP",
        "APP_TO_APP",
        "CLOSE",
        "TEST_OPEN",
        "TEST_PROTECTED",
        "CONTROL_AUDIO",
        "CONTROL_DISPLAY",
        "CONTROL_INPUT_JOYSTICK",
        "CONTROL_INPUT_MEDIA_RECORDING",
        "CONTROL_INPUT_MEDIA_PLAYBACK",
        "CONTROL_INPUT_TV",
        "CONTROL_POWER",
        "READ_APP_STATUS",
        "READ_CURRENT_CHANNEL",
        "READ_INPUT_DEVICE_LIST",
        "READ_NETWORK_STATE",
        "READ_RUNNING_APPS",
        "READ_TV_CHANNEL_LIST",
        "WRITE_NOTIFICATION_TOAST",
        "READ_POWER_STATE",
        "READ_COUNTRY_INFO",
        "READ_SETTINGS",
        "CONTROL_TV_SCREEN",
        "CONTROL_TV_STANBY",
        "CONTROL_FAVORITE_GROUP",
        "CONTROL_USER_INFO",
        "CHECK_BLUETOOTH_DEVICE",
        "CONTROL_BLUETOOTH",
        "CONTROL_TIMER_INFO",
        "STB_INTERNAL_CONNECTION",
        "CONTROL_RECORDING",
        "READ_RECORDING_STATE",
        "WRITE_RECORDING_LIST",
        "READ_RECORDING_LIST",
        "READ_RECORDING_SCHEDULE",
        "WRITE_RECORDING_SCHEDULE",
        "READ_STORAGE_DEVICE_LIST",
        "READ_TV_PROGRAM_INFO",
        "CONTROL_BOX_CHANNEL",
        "READ_TV_ACR_AUTH_TOKEN",
        "READ_TV_CONTENT_STATE",
        "READ_TV_CURRENT_TIME",
        "ADD_LAUNCHER_CHANNEL",
        "SET_CHANNEL_SKIP",
        "RELEASE_CHANNEL_SKIP",
        "CONTROL_CHANNEL_BLOCK",
        "DELETE_SELECT_CHANNEL",
        "CONTROL_CHANNEL_GROUP",
        "SCAN_TV_CHANNELS",
        "CONTROL_TV_POWER",
        "CONTROL_WOL"
    ]
}

enum SamsungRemote {
    static func keyName(for key: RemoteKey) -> String? {
        switch key {
        case .powerOn, .powerOff: return "KEY_POWER"
        case .input: return "KEY_SOURCE"
        case .home: return "KEY_HOME"
        case .back: return "KEY_RETURN"
        case .up: return "KEY_UP"
        case .down: return "KEY_DOWN"
        case .left: return "KEY_LEFT"
        case .right: return "KEY_RIGHT"
        case .ok, .enter: return "KEY_ENTER"
        case .volumeUp: return "KEY_VOLUP"
        case .volumeDown: return "KEY_VOLDOWN"
        case .mute: return "KEY_MUTE"
        case .channelUp: return "KEY_CHUP"
        case .channelDown: return "KEY_CHDOWN"
        case .playPause: return "KEY_PLAY"
        case .rewind: return "KEY_REWIND"
        case .fastForward: return "KEY_FF"
        case .menu: return "KEY_MENU"
        case .backspace: return nil
        }
    }

    static func clickObject(key: String) -> [String: Any] {
        [
            "method": "ms.remote.control",
            "params": [
                "Cmd": "Click",
                "DataOfCmd": key,
                "Option": "false",
                "TypeOfRemote": "SendRemoteKey"
            ]
        ]
    }

    static func clickData(key: String) -> Data {
        JSONBox.data(clickObject(key: key))
    }

    static func launchObject(appID: String) -> [String: Any] {
        [
            "method": "ms.channel.emit",
            "params": [
                "event": "ed.apps.launch",
                "to": "host",
                "data": [
                    "appId": appID,
                    "action_type": "DEEP_LINK"
                ]
            ]
        ]
    }

    static func textObject(_ text: String) -> [String: Any] {
        [
            "method": "ms.remote.control",
            "params": [
                "Cmd": Data(text.utf8).base64EncodedString(),
                "DataOfCmd": "base64",
                "TypeOfRemote": "SendInputString"
            ]
        ]
    }

    static func websocketURL(host: String, secure: Bool, name: String, token: String?) -> URL? {
        var components = URLComponents()
        components.scheme = secure ? "wss" : "ws"
        components.host = host
        components.port = secure ? 8002 : 8001
        components.path = "/api/v2/channels/samsung.remote.control"
        var items = [URLQueryItem(name: "name", value: Data(name.utf8).base64EncodedString())]
        if let token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items
        return components.url
    }
}

enum SonyIRCC {
    static let path = "/sony/IRCC"
    static let soapAction = "\"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\""

    static func code(for key: RemoteKey) -> String? {
        switch key {
        case .powerOn: return "AAAAAQAAAAEAAAAVAw=="
        case .powerOff: return "AAAAAQAAAAEAAAAvAw=="
        case .input: return "AAAAAQAAAAEAAAAlAw=="
        case .home: return "AAAAAQAAAAEAAABgAw=="
        case .back: return "AAAAAgAAAJcAAAAjAw=="
        case .up: return "AAAAAQAAAAEAAAB0Aw=="
        case .down: return "AAAAAQAAAAEAAAB1Aw=="
        case .left: return "AAAAAQAAAAEAAAA0Aw=="
        case .right: return "AAAAAQAAAAEAAAAzAw=="
        case .ok, .enter: return "AAAAAQAAAAEAAABlAw=="
        case .volumeUp: return "AAAAAQAAAAEAAAASAw=="
        case .volumeDown: return "AAAAAQAAAAEAAAATAw=="
        case .mute: return "AAAAAQAAAAEAAAAUAw=="
        case .channelUp: return "AAAAAQAAAAEAAAAQAw=="
        case .channelDown: return "AAAAAQAAAAEAAAARAw=="
        case .playPause: return "AAAAAgAAAJcAAAAaAw=="
        case .rewind: return "AAAAAgAAAJcAAAAbAw=="
        case .fastForward: return "AAAAAgAAAJcAAAAcAw=="
        case .menu: return "AAAAAgAAABoAAABhAw=="
        case .backspace: return nil
        }
    }

    static func envelope(code: String) -> String {
        "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:X_SendIRCC xmlns:u=\"urn:schemas-sony-com:service:IRCC:1\"><IRCCCode>\(code)</IRCCCode></u:X_SendIRCC></s:Body></s:Envelope>"
    }

    static var defaultInputs: [TVInput] {
        [
            ("HDMI 1", "AAAAAgAAABoAAABaAw=="),
            ("HDMI 2", "AAAAAgAAABoAAABbAw=="),
            ("HDMI 3", "AAAAAgAAABoAAABcAw=="),
            ("HDMI 4", "AAAAAgAAABoAAABdAw==")
        ].map { name, code in
            TVInput(id: code, name: name, route: .sonyCode(code))
        }
    }
}

enum VizioSmartCast {
    static let securePort = 7345
    static let plainPort = 9000

    static func key(for key: RemoteKey, powerOn: Bool = false, playNext: Bool = true) -> (codeset: Int, code: Int)? {
        switch key {
        case .powerOn: return (11, 1)
        case .powerOff: return powerOn ? (11, 1) : (11, 0)
        case .input: return (7, 1)
        case .home: return (4, 15)
        case .back: return (4, 0)
        case .up: return (3, 8)
        case .down: return (3, 0)
        case .left: return (3, 1)
        case .right: return (3, 7)
        case .ok, .enter: return (3, 2)
        case .volumeUp: return (5, 1)
        case .volumeDown: return (5, 0)
        case .mute: return (5, 4)
        case .channelUp: return (8, 1)
        case .channelDown: return (8, 0)
        case .playPause: return playNext ? (2, 3) : (2, 2)
        case .rewind: return (2, 1)
        case .fastForward: return (2, 0)
        case .menu: return (4, 8)
        case .backspace: return nil
        }
    }

    static func commandObject(codeset: Int, code: Int) -> [String: Any] {
        [
            "KEYLIST": [
                [
                    "CODESET": codeset,
                    "CODE": code,
                    "ACTION": "KEYPRESS"
                ]
            ]
        ]
    }

    static func commandData(codeset: Int, code: Int) -> Data {
        JSONBox.data(commandObject(codeset: codeset, code: code))
    }

    static func startPairingObject(deviceID: String, name: String) -> [String: Any] {
        ["DEVICE_ID": deviceID, "DEVICE_NAME": name]
    }

    static func finishPairingObject(deviceID: String, challengeType: Int, pin: String, token: String) -> [String: Any] {
        var body: [String: Any] = [
            "DEVICE_ID": deviceID,
            "CHALLENGE_TYPE": challengeType
        ]
        if let pinNumber = Int(pin), pin.allSatisfy(\.isNumber) {
            body["RESPONSE_VALUE"] = pinNumber
        } else {
            body["RESPONSE_VALUE"] = pin
        }
        if let tokenNumber = Int(token) {
            body["PAIRING_REQ_TOKEN"] = tokenNumber
        } else {
            body["PAIRING_REQ_TOKEN"] = token
        }
        return body
    }
}

enum WakeOnLAN {
    static func packet(mac: String) -> Data? {
        guard let bytes = macBytes(mac) else { return nil }
        var data = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            data.append(contentsOf: bytes)
        }
        return data
    }

    static func macBytes(_ mac: String) -> [UInt8]? {
        guard let normalized = MACAddress.normalize(mac) else { return nil }
        let parts = normalized.split(separator: ":")
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        return bytes.count == 6 ? bytes : nil
    }
}

enum SSDPTarget {
    static let roku = "roku:ecp"
    static let lg = "urn:lge-com:service:webos-second-screen:1"
    static let dial = "urn:dial-multiscreen-org:service:dial:1"
    static let all = "ssdp:all"
    static let searchTargets = [roku, lg, dial, all]
}

struct SSDPResponse: Equatable {
    var searchTarget: String
    var server: String
    var location: String?
    var headers: [String: String]

    var host: String? {
        guard let location, let url = URL(string: location) else { return nil }
        return url.host
    }
}

enum SSDPMessage {
    static func search(target: String, mx: Int = 2) -> String {
        [
            "M-SEARCH * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            "MAN: \"ssdp:discover\"",
            "MX: \(mx)",
            "ST: \(target)",
            "",
            ""
        ].joined(separator: "\r\n")
    }

    static func parse(_ raw: String) -> SSDPResponse? {
        let folded = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = folded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.first?.uppercased(), start.contains("HTTP/1.1") || start.contains("NOTIFY") else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                headers[name] = value
            }
        }
        guard !headers.isEmpty else { return nil }
        return SSDPResponse(
            searchTarget: headers["st"] ?? headers["nt"] ?? "",
            server: headers["server"] ?? "",
            location: headers["location"],
            headers: headers
        )
    }

    static func brand(searchTarget: String, server: String, body: String = "") -> TVBrand? {
        let blob = (searchTarget + " " + server + " " + body).lowercased()
        if blob.contains("roku:ecp") || blob.contains("roku") { return .roku }
        if blob.contains("webos-second-screen") || blob.contains("webos") || blob.contains("lge") { return .lg }
        if blob.contains("samsung") || blob.contains("tizen") { return .samsung }
        if blob.contains("bravia") || blob.contains("sony") { return .sony }
        if blob.contains("vizio") { return .vizio }
        if blob.contains("fire tv") || blob.contains("amazon fire") || blob.contains("aft") { return .firetv }
        if blob.contains("android tv") || blob.contains("androidtv") || blob.contains("chromecast") || blob.contains("google cast") {
            return .androidtv
        }
        return nil
    }

    static func brand(descriptionXML xml: String) -> TVBrand? {
        let manufacturer = (XMLValue.text(xml, tag: "manufacturer") ?? "").lowercased()
        let model = (XMLValue.text(xml, tag: "modelName") ?? XMLValue.text(xml, tag: "model-name") ?? "").lowercased()
        let name = (XMLValue.text(xml, tag: "friendlyName") ?? XMLValue.text(xml, tag: "friendly-device-name") ?? "").lowercased()
        return brand(searchTarget: "", server: manufacturer, body: model + " " + name + " " + xml.lowercased())
    }
}

enum DiscoveryPorts {
    /// Known TV control ports used when multicast SSDP is unavailable.
    static let scan: [UInt16] = [8060, 3000, 3001, 8001, 8002, 7345, 9000, 6466, 8008]
}

enum BonjourServiceType {
    static let all = [
        "_googlecast._tcp",
        "_androidtvremote2._tcp",
        "_lgsmarttv._tcp",
        "_samsungmsf._tcp",
        "_amzn-wplay._tcp",
        "_viziocast._tcp",
        "_roku._tcp"
    ]
}
