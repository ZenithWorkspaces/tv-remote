import XCTest
@testable import TVRemote

final class SSAPMessageTests: XCTestCase {
    func testPointerButtonFraming() {
        XCTAssertEqual(LGSSAP.pointerButton("HOME"), "type:button\nname:HOME\n\n")
        XCTAssertEqual(LGSSAP.pointerButton("ENTER"), "type:button\nname:ENTER\n\n")
        XCTAssertEqual(LGSSAP.pointerButton("FASTFORWARD"), "type:button\nname:FASTFORWARD\n\n")
    }

    func testVolumeRequestJSON() throws {
        let data = LGSSAP.requestData(id: "7", uri: "ssap://audio/volumeUp")
        let object = try XCTUnwrap(JSONBox.object(data))
        XCTAssertEqual(object["type"] as? String, "request")
        XCTAssertEqual(object["id"] as? String, "7")
        XCTAssertEqual(object["uri"] as? String, "ssap://audio/volumeUp")
        XCTAssertNotNil(object["payload"] as? [String: Any])
    }

    func testLaunchAndTextPayloads() throws {
        let launch = LGSSAP.requestData(id: "1", uri: LGSSAP.launchURI, payload: LGSSAP.launchPayload(appID: "netflix"))
        let launchObject = try XCTUnwrap(JSONBox.object(launch))
        XCTAssertEqual(launchObject["uri"] as? String, "ssap://system.launcher/launch")
        let launchPayload = try XCTUnwrap(launchObject["payload"] as? [String: Any])
        XCTAssertEqual(launchPayload["id"] as? String, "netflix")

        let text = LGSSAP.requestData(id: "2", uri: LGSSAP.insertTextURI, payload: LGSSAP.textPayload("hi"))
        let textObject = try XCTUnwrap(JSONBox.object(text))
        let textPayload = try XCTUnwrap(textObject["payload"] as? [String: Any])
        XCTAssertEqual(textPayload["text"] as? String, "hi")
        XCTAssertEqual(textPayload["replace"] as? Int, 0)
    }

    func testRegisterOmitsClientKeyUntilPaired() throws {
        let fresh = try XCTUnwrap(JSONBox.object(LGSSAP.registerData(clientKey: nil)))
        XCTAssertEqual(fresh["type"] as? String, "register")
        XCTAssertEqual(fresh["id"] as? String, "register_0")
        let payload = try XCTUnwrap(fresh["payload"] as? [String: Any])
        XCTAssertNil(payload["client-key"])
        XCTAssertEqual(payload["pairingType"] as? String, "PIN")
        XCTAssertEqual(payload["forcePairing"] as? Bool, false)

        let saved = try XCTUnwrap(JSONBox.object(LGSSAP.registerData(clientKey: "abc-key")))
        let savedPayload = try XCTUnwrap(saved["payload"] as? [String: Any])
        XCTAssertEqual(savedPayload["client-key"] as? String, "abc-key")
        XCTAssertEqual(savedPayload["pairingType"] as? String, "PIN")

        let prompt = try XCTUnwrap(JSONBox.object(LGSSAP.registerData(clientKey: nil, pairingType: .prompt)))
        let promptPayload = try XCTUnwrap(prompt["payload"] as? [String: Any])
        XCTAssertEqual(promptPayload["pairingType"] as? String, "PROMPT")
    }

    func testSetPinRequest() throws {
        let data = LGSSAP.requestData(id: LGSSAP.setPinRequestID, uri: LGSSAP.setPinURI, payload: LGSSAP.setPinPayload("482913"))
        let object = try XCTUnwrap(JSONBox.object(data))
        XCTAssertEqual(object["type"] as? String, "request")
        XCTAssertEqual(object["id"] as? String, "pairing_pin")
        XCTAssertEqual(object["uri"] as? String, "ssap://pairing/setPin")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["pin"] as? String, "482913")
    }

    func testRegisterManifestKeepsSignedIdentity() throws {
        let object = try XCTUnwrap(JSONBox.object(LGSSAP.registerData(clientKey: nil)))
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        let manifest = try XCTUnwrap(payload["manifest"] as? [String: Any])
        let signed = try XCTUnwrap(manifest["signed"] as? [String: Any])
        XCTAssertEqual(signed["appId"] as? String, "com.lge.test")
        XCTAssertEqual(signed["vendorId"] as? String, "com.lge")
        XCTAssertEqual(signed["serial"] as? String, "2f930e2d2cfe083771f68e4fe7bb07")
        let names = try XCTUnwrap(signed["localizedAppNames"] as? [String: Any])
        XCTAssertEqual(names[""] as? String, "LG Remote App")
        XCTAssertEqual(names["ko-KR"] as? String, "리모컨 앱")
        let signatures = try XCTUnwrap(manifest["signatures"] as? [[String: Any]])
        let signature = try XCTUnwrap(signatures.first?["signature"] as? String)
        XCTAssertTrue(signature.hasPrefix("eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2"))
        XCTAssertTrue(signature.hasSuffix("oa7NQnAtw=="))
        let permissions = try XCTUnwrap(manifest["permissions"] as? [String])
        XCTAssertTrue(permissions.contains("CONTROL_POWER"))
        XCTAssertTrue(permissions.contains("CONTROL_AUDIO"))
    }

    func testUnsignedRegisterDropsBlacklistedSignature() throws {
        let fresh = try XCTUnwrap(JSONBox.object(LGSSAP.registerData(clientKey: nil, manifest: .unsigned)))
        let payload = try XCTUnwrap(fresh["payload"] as? [String: Any])
        XCTAssertNil(payload["client-key"])
        XCTAssertEqual(payload["pairingType"] as? String, "PIN")
        let manifest = try XCTUnwrap(payload["manifest"] as? [String: Any])
        XCTAssertNil(manifest["signatures"])
        let permissions = try XCTUnwrap(manifest["permissions"] as? [String])
        XCTAssertTrue(permissions.contains("CONTROL_AUDIO"))
        XCTAssertTrue(permissions.contains("CONTROL_MOUSE_AND_KEYBOARD"))
        XCTAssertTrue(permissions.contains("CONTROL_INPUT_TEXT"))
        XCTAssertTrue(permissions.contains("CONTROL_INPUT_JOYSTICK"))
        XCTAssertTrue(permissions.contains("READ_POWER_STATE"))
        let signed = try XCTUnwrap(manifest["signed"] as? [String: Any])
        XCTAssertEqual(signed["appId"] as? String, "com.lge.test")
        XCTAssertEqual(signed["serial"] as? String, "2f930e2d2cfe083771f68e4fe7bb07")
        let names = try XCTUnwrap(signed["localizedAppNames"] as? [String: Any])
        XCTAssertEqual(names[""] as? String, "LG Remote App")

        let saved = try XCTUnwrap(JSONBox.object(
            LGSSAP.registerData(clientKey: "stored-key", pairingType: .prompt, manifest: .unsigned)
        ))
        let savedPayload = try XCTUnwrap(saved["payload"] as? [String: Any])
        XCTAssertEqual(savedPayload["client-key"] as? String, "stored-key")
        XCTAssertEqual(savedPayload["pairingType"] as? String, "PROMPT")
    }

    func testBlacklistedCertificateRetriesUnsignedAndKeepsTheKey() {
        var handshake = LGHandshake(manifest: .signed)
        handshake.sentClientKey = true
        let move = handshake.consume([
            "type": "error",
            "id": "register_0",
            "error": "403 Pairing rejected: blacklisted certificate detected",
            "payload": [String: Any]()
        ] as [String: Any])
        XCTAssertEqual(move, .sendRegister(.unsigned, dropClientKey: false, pairing: .pin))
        XCTAssertFalse(handshake.droppedClientKey)
        XCTAssertEqual(handshake.manifest, .unsigned)
    }

    func testRejectedClientKeyIsDroppedBeforeTheNextRegister() {
        var handshake = LGHandshake(manifest: .unsigned)
        handshake.sentClientKey = true
        let move = handshake.consume([
            "type": "error",
            "id": "register_0",
            "error": "401 insufficient permissions (not registered)",
            "payload": [String: Any]()
        ] as [String: Any])
        XCTAssertEqual(move, .sendRegister(.unsigned, dropClientKey: true, pairing: .pin))
        XCTAssertTrue(handshake.droppedClientKey)
        XCTAssertFalse(handshake.sentClientKey)
    }

    func testPairingResponsesShowPINOrPrompt() {
        var pin = LGHandshake(manifest: .unsigned)
        XCTAssertEqual(pin.consume([
            "type": "response",
            "id": "register_0",
            "payload": ["pairingType": "PIN", "returnValue": true] as [String: Any]
        ]), .showPIN)

        var magic = LGHandshake(manifest: .unsigned)
        XCTAssertEqual(magic.consume([
            "type": "response",
            "id": "register_0",
            "payload": ["pairingType": "LGSWITCH-PIN", "returnValue": true] as [String: Any]
        ]), .showPIN)

        var prompt = LGHandshake(manifest: .signed)
        XCTAssertEqual(prompt.consume([
            "type": "response",
            "id": "register_0",
            "payload": ["pairingType": "PROMPT", "returnValue": true] as [String: Any]
        ]), .showPrompt)
        XCTAssertEqual(prompt.pairing, .prompt)

        var registered = LGHandshake(manifest: .unsigned)
        XCTAssertEqual(registered.consume([
            "type": "registered",
            "id": "register_0",
            "payload": ["client-key": "fresh-key"] as [String: Any]
        ]), .saveKeyAndConnect("fresh-key"))
    }

    func testWrongPINDoesNotDropTheSession() {
        var handshake = LGHandshake(manifest: .unsigned, pairing: .pin)
        handshake.waitingForPIN = true
        let move = handshake.consume([
            "type": "error",
            "id": LGSSAP.setPinRequestID,
            "error": "wrong pin",
            "payload": ["returnValue": false] as [String: Any]
        ])
        XCTAssertEqual(move, .wrongPIN)
        XCTAssertFalse(handshake.droppedClientKey)
    }

    func testRegisterTimeoutFallsThroughThenStops() {
        var handshake = LGHandshake(manifest: .signed)
        XCTAssertEqual(
            handshake.timedOutWaitingForRegister(),
            .sendRegister(.unsigned, dropClientKey: false, pairing: .pin)
        )
        XCTAssertEqual(
            handshake.timedOutWaitingForRegister(),
            .sendRegister(.unsigned, dropClientKey: false, pairing: .prompt)
        )
        XCTAssertEqual(handshake.timedOutWaitingForRegister(), .giveUp)
    }

    func testAdvertisedPairingPrefersAPIN() {
        XCTAssertEqual(LGSSAP.pairingMode(advertised: ["PROMPT", "PIN", "COMBINED", "LGSWITCH-PIN"]), .pin)
        XCTAssertEqual(LGSSAP.pairingMode(advertised: ["PROMPT"]), .prompt)
        XCTAssertNil(LGSSAP.pairingMode(advertised: []))
    }

    func testLocalTrustStaysOnTheTV() {
        XCTAssertTrue(LocalNetworkTrust.accepts("192.168.1.20", expectedHost: "192.168.1.20"))
        XCTAssertTrue(LocalNetworkTrust.accepts("TV.local", expectedHost: "tv.local"))
        XCTAssertTrue(LocalNetworkTrust.accepts("10.0.0.8", expectedHost: "192.168.1.20"))
        XCTAssertFalse(LocalNetworkTrust.accepts("8.8.8.8", expectedHost: "192.168.1.20"))
        XCTAssertFalse(LocalNetworkTrust.accepts("example.com", expectedHost: "192.168.1.20"))
        XCTAssertTrue(LocalNetworkTrust.isLocal("10.1.2.3"))
        XCTAssertTrue(LocalNetworkTrust.isLocal("fe80::1"))
        XCTAssertFalse(LocalNetworkTrust.isLocal("8.8.4.4"))
    }

    func testChannelAndMediaCommands() {
        guard case let .request(up, _) = LGSSAP.command(for: .channelUp) else {
            return XCTFail("channel up")
        }
        XCTAssertEqual(up, "ssap://tv/channelUp")
        guard case let .request(down, _) = LGSSAP.command(for: .volumeDown) else {
            return XCTFail("volume down")
        }
        XCTAssertEqual(down, "ssap://audio/volumeDown")
        XCTAssertEqual(LGSSAP.command(for: .rewind), .pointer("REWIND"))
        XCTAssertEqual(LGSSAP.command(for: .fastForward), .pointer("FASTFORWARD"))
        XCTAssertEqual(LGSSAP.command(for: .menu), .pointer("MENU"))
        guard case let .request(enter, _) = LGSSAP.command(for: .enter) else {
            return XCTFail("enter")
        }
        XCTAssertEqual(enter, "ssap://com.webos.service.ime/sendEnterKey")
    }
}
