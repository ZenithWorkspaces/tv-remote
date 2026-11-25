import Foundation

enum LGHandshakeMove: Equatable {
    case saveKeyAndConnect(String?)
    case showPIN
    case showPrompt
    case wrongPIN
    /// Send `register` again. `dropClientKey` means the saved key was rejected.
    case sendRegister(LGSSAP.Manifest, dropClientKey: Bool, pairing: LGSSAP.PairingMode)
    case giveUp
    case ignore
}

/// Decides the next SSAP registration step from one TV message.
struct LGHandshake: Equatable {
    var manifest: LGSSAP.Manifest
    var pairing: LGSSAP.PairingMode
    var sentClientKey: Bool
    var droppedClientKey: Bool
    var triedPrompt: Bool
    var waitingForPIN: Bool

    init(manifest: LGSSAP.Manifest, pairing: LGSSAP.PairingMode = .pin) {
        self.manifest = manifest
        self.pairing = pairing
        sentClientKey = false
        droppedClientKey = false
        triedPrompt = false
        waitingForPIN = false
    }

    mutating func consume(_ object: [String: Any]) -> LGHandshakeMove {
        let type = (object["type"] as? String ?? "").lowercased()
        let id = object["id"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]
        let errorText = Self.failureText(object)

        if Self.isRegistered(type: type, payload: payload) {
            let key = payload["client-key"] as? String
            let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .saveKeyAndConnect(trimmed.isEmpty ? nil : trimmed)
        }
        if Self.isWrongPIN(
            type: type,
            id: id,
            payload: payload,
            errorText: errorText,
            waitingForPIN: waitingForPIN
        ) {
            return .wrongPIN
        }
        if let pairingType = (payload["pairingType"] as? String)?.uppercased(),
           type == "response" || type == "registered" {
            return show(pairingType)
        }
        let failed = type == "error"
            || (type == "response" && payload["returnValue"] as? Bool == false && (id == "register_0" || id == nil))
        guard failed else { return .ignore }
        return fail(errorText)
    }

    /// The TV never answered `register`. Walk the same fallbacks as an error frame.
    mutating func timedOutWaitingForRegister() -> LGHandshakeMove {
        fail("")
    }

    private mutating func show(_ pairingType: String) -> LGHandshakeMove {
        switch pairingType {
        case "PIN", "LGSWITCH-PIN":
            pairing = .pin
            return .showPIN
        case "PROMPT", "COMBINED":
            pairing = .prompt
            return .showPrompt
        default:
            if pairingType.contains("PIN") {
                pairing = .pin
                return .showPIN
            }
            pairing = .prompt
            return .showPrompt
        }
    }

    private mutating func fail(_ errorText: String) -> LGHandshakeMove {
        if Self.isClientKeyRejection(errorText, sentClientKey: sentClientKey), !droppedClientKey {
            droppedClientKey = true
            sentClientKey = false
            return .sendRegister(manifest, dropClientKey: true, pairing: pairing)
        }
        if manifest == .signed {
            manifest = .unsigned
            return .sendRegister(.unsigned, dropClientKey: false, pairing: pairing)
        }
        if pairing == .pin, !triedPrompt {
            triedPrompt = true
            pairing = .prompt
            return .sendRegister(manifest, dropClientKey: false, pairing: .prompt)
        }
        return .giveUp
    }

    static func isRegistered(type: String, payload: [String: Any]) -> Bool {
        if type == "registered" { return true }
        guard type == "response", payload["pairingType"] == nil else { return false }
        guard payload["returnValue"] as? Bool != false else { return false }
        let key = payload["client-key"] as? String ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isWrongPIN(
        type: String,
        id: String?,
        payload: [String: Any],
        errorText: String,
        waitingForPIN: Bool
    ) -> Bool {
        guard waitingForPIN || id == LGSSAP.setPinRequestID else { return false }
        if isCertificateRejection(errorText) { return false }
        let failed = type == "error" || payload["returnValue"] as? Bool == false
        guard failed else { return false }
        if id == LGSSAP.setPinRequestID { return true }
        let text = errorText.lowercased()
        if text.contains("not support") { return false }
        return text.contains("pin")
    }

    static func isCertificateRejection(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.contains("blacklist") || value.contains("certificate") || value.contains("signature")
    }

    static func isClientKeyRejection(_ text: String, sentClientKey: Bool) -> Bool {
        guard sentClientKey, !isCertificateRejection(text) else { return false }
        let value = text.lowercased()
        if value.contains("client-key") || value.contains("client key") || value.contains("invalid key") || value.contains("not registered") {
            return true
        }
        return value.contains("401") || value.contains("403")
    }

    static func failureText(_ object: [String: Any]) -> String {
        var parts: [String] = []
        if let error = object["error"] as? String { parts.append(error) }
        let payload = object["payload"] as? [String: Any] ?? [:]
        if let text = payload["errorText"] as? String { parts.append(text) }
        if let text = payload["error"] as? String { parts.append(text) }
        if let code = payload["errorCode"] as? Int { parts.append(String(code)) }
        if let code = payload["errorCode"] as? String { parts.append(code) }
        return parts.joined(separator: " ")
    }
}
