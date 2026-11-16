import XCTest
@testable import TVRemote

final class NewProtocolTests: XCTestCase {
    func testAndroidAndFireMapEveryButton() {
        for key in RemoteKey.allCases {
            XCTAssertNotNil(AndroidTVRemote.keyCode(for: key), "Missing Android TV code for \(key)")
            XCTAssertNotNil(ADBProtocol.keyCode(for: key), "Missing Fire TV code for \(key)")
            XCTAssertNotNil(ADBProtocol.shellCommand(for: key))
        }
        XCTAssertEqual(AndroidTVRemote.keyCode(for: .ok), 23)
        XCTAssertEqual(AndroidTVRemote.keyCode(for: .home), 3)
        XCTAssertEqual(ADBProtocol.shellCommand(for: .ok), "input keyevent 23\n")
        XCTAssertEqual(ADBProtocol.package(for: .named("netflix")), "com.netflix.ninja")
    }

    func testAndroidPairingDigestMatchesPolo() {
        let digest = AndroidTVRemote.pairingDigest(
            clientModulus: Data([0xAB, 0xCD]),
            clientExponent: 3,
            serverModulus: Data([0x12, 0x34]),
            serverExponent: 65537,
            code: "1A2B3C"
        )
        let hex = digest?.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "a39e4ed50b8b21bd57c4511e17c4c743908eaaa415400a9b4aadef54fa433246")
        XCTAssertFalse(AndroidTVRemote.codeMatches(digest: digest ?? Data(), code: "1A2B3C"))
        var matching = Data([0x1A])
        matching.append(digest?.dropFirst() ?? Data())
        XCTAssertTrue(AndroidTVRemote.codeMatches(digest: matching, code: "1A2B3C"))
    }

    func testAndroidPairingRequestFields() {
        let message = AndroidTVRemote.pairingRequest()
        let fields = Proto.fields(message)
        XCTAssertEqual(fields.first { $0.number == 1 }?.varint, 2)
        XCTAssertEqual(fields.first { $0.number == 2 }?.varint, 200)
        let request = fields.first { $0.number == 10 }?.data ?? Data()
        let inner = Proto.fields(request)
        XCTAssertEqual(String(data: inner.first { $0.number == 1 }?.data ?? Data(), encoding: .utf8), "atvremote")
        XCTAssertEqual(AndroidTVRemote.pairingField(AndroidTVRemote.options()), .options)
        let ack = Proto.uint(1, 2) + Proto.uint(2, 200) + Proto.message(11, Data())
        XCTAssertEqual(AndroidTVRemote.pairingField(ack), .requestAck)
        XCTAssertEqual(AndroidTVRemote.pairingStatus(ack), 200)
    }

    func testAndroidKeyInjectAndText() {
        let inject = AndroidTVRemote.keyInject(code: 19)
        let fields = Proto.fields(inject)
        XCTAssertEqual(fields.first?.number, 10)
        let key = Proto.fields(fields.first?.data ?? Data())
        XCTAssertEqual(key.first { $0.number == 1 }?.varint, 19)
        XCTAssertEqual(key.first { $0.number == 2 }?.varint, 3)
        let edit = AndroidTVRemote.textEdit("Hi", imeCounter: 4, fieldCounter: 5)
        XCTAssertEqual(Proto.fields(edit).first?.number, 21)
        let frame = Proto.frame(inject)
        var buffer = frame + frame
        XCTAssertEqual(Proto.popFrame(&buffer), inject)
        XCTAssertEqual(Proto.popFrame(&buffer), inject)
        XCTAssertNil(Proto.popFrame(&buffer))
    }

    func testADBFrameRoundTripAndKeyMath() {
        let packet = ADBProtocol.connectPacket()
        guard case let .ready(decoded, count) = ADBProtocol.intake(packet.encoded) else {
            return XCTFail("Connect packet did not decode")
        }
        XCTAssertEqual(count, packet.encoded.count)
        XCTAssertEqual(decoded.command, ADBProtocol.connect)
        XCTAssertEqual(decoded.arg0, ADBProtocol.version)
        XCTAssertEqual(decoded.payload, Data("host::\0".utf8))
        XCTAssertEqual(ADBProtocol.intake(packet.encoded.prefix(10)), .needMore)
        XCTAssertEqual(ADBProtocol.n0inv(15), 0x11111111)
        XCTAssertEqual(UInt32(15) &* ADBProtocol.n0inv(15), UInt32.max)
        let modulus = Data([0x00, 0x00, 0x00, 0x0F])
        XCTAssertEqual(ADBProtocol.montgomeryRR(modulus: modulus, wordCount: 1), Data([0x00, 0x00, 0x00, 0x01]))
        let blob = ADBProtocol.androidPublicKey(modulus: modulus, exponent: 3)
        let suffix = Data(" noads\0".utf8)
        XCTAssertEqual(blob?.suffix(suffix.count), suffix)
    }

    func testSamsungAppListAndMissingSkip() {
        let json = #"{"data":[{"appId":"11101200001","name":"Netflix"},{"appId":"11101200001","name":"Netflix"}]}"#.data(using: .utf8)!
        let apps = SamsungRemote.parseApplications(json)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.name, "Netflix")
        XCTAssertNil(SamsungRemote.keyName(for: .skipNext))
        XCTAssertNil(SamsungRemote.keyName(for: .skipPrevious))
        XCTAssertEqual(SamsungRemote.keyName(for: .menu), "KEY_MENU")
        let url = SamsungRemote.websocketURL(host: "10.0.0.8", secure: true, name: "No Ads Remote", token: "abc")
        XCTAssertEqual(url?.port, 8002)
        XCTAssertEqual(url?.scheme, "wss")
        XCTAssertTrue(url?.query?.contains("token=abc") == true)
    }

    func testVizioLaunchAndMissingSkip() {
        let netflix = VizioSmartCast.app(for: .named("netflix"))
        XCTAssertEqual(netflix?.id, "1")
        XCTAssertEqual(netflix?.nameSpace, 3)
        XCTAssertNil(VizioSmartCast.app(for: .named("spotify")))
        XCTAssertNil(VizioSmartCast.key(for: .skipNext))
        let body = VizioSmartCast.launchObject(appID: "1", nameSpace: 3)
        let value = body["VALUE"] as? [String: Any]
        XCTAssertEqual(value?["APP_ID"] as? String, "1")
        XCTAssertEqual(value?["NAME_SPACE"] as? Int, 3)
        XCTAssertTrue(value?["MESSAGE"] is NSNull)
    }

    func testOfferedBrandsExcludeSonyOnly() {
        XCTAssertTrue(TVBrand.samsung.isOffered)
        XCTAssertTrue(TVBrand.androidtv.isOffered)
        XCTAssertTrue(TVBrand.vizio.isOffered)
        XCTAssertTrue(TVBrand.firetv.isOffered)
        XCTAssertFalse(TVBrand.sony.isOffered)
        XCTAssertEqual(TVBrand.lg.support, .supported)
        XCTAssertEqual(TVBrand.roku.support, .supported)
        XCTAssertTrue(DiscoveryPorts.scan.contains(5555))
        XCTAssertTrue(DiscoveryPorts.scan.contains(6466))
        XCTAssertEqual(TVDisplayName.suggestion(brand: .samsung, discovered: "amzn.dmgr:abc"), "Samsung TV")
        XCTAssertEqual(TVDisplayName.suggestion(brand: .firetv, discovered: "Living Room"), "Living Room")
        XCTAssertEqual(TVDisplayName.suggestion(brand: .samsung, discovered: "[TV]Samsung LED55"), "Samsung LED55")
        XCTAssertEqual(TVDisplayName.withoutTVTag("[TV]Samsung LED55"), "Samsung LED55")
        XCTAssertEqual(AddTVCopy.instruction(brand: .roku, samsungShowsPIN: false), AddTVCopy.roku)
        XCTAssertEqual(AddTVCopy.instruction(brand: .lg, samsungShowsPIN: false), AddTVCopy.allow)
        XCTAssertEqual(AddTVCopy.instruction(brand: .samsung, samsungShowsPIN: false), AddTVCopy.allow)
        XCTAssertEqual(AddTVCopy.instruction(brand: .samsung, samsungShowsPIN: true), AddTVCopy.pin)
        XCTAssertEqual(AddTVCopy.instruction(brand: .vizio, samsungShowsPIN: false), AddTVCopy.pin)
        XCTAssertEqual(AddTVCopy.instruction(brand: .androidtv, samsungShowsPIN: false), AddTVCopy.pin)
        XCTAssertEqual(AddTVCopy.instruction(brand: .firetv, samsungShowsPIN: false), AddTVCopy.allow)
    }

    func testSamsungEncryptedVectors() {
        XCTAssertEqual(SamsungEncrypted.publicKey.count, 128)
        let hello = SamsungEncrypted.serverHello(pin: "1234")
        XCTAssertEqual(HexBytes.encode(hello?.serverHello ?? Data()), "010200000000000000008a00000006363534333231c0dee54ed567f0310a5185dbcdcb0c3e8753b342409786699d343060ab8200afce6bb581e3b60779fe88f1b1bd7c39a0b14898b34f8dfa058e9d377e7050e97d51e18937f04a936b76e00cacbd95b4f5353d8a716b7ab76ec85fc0d3e75cd242e909698ed6f4ba8a3ea5ff33a232400d07cb659f496aa631b5df86253dece96a0000000000")
        XCTAssertEqual(HexBytes.encode(hello?.aesKey ?? Data()), "7110eda4d09e062aa5e4a390b0a572ac")
        XCTAssertEqual(AES128.ecb(Data((0..<16).map { UInt8($0) }), key: SamsungEncrypted.wbKey, encrypt: true).map(HexBytes.encode), "de5d917550f71ac31fe1c94a6b025340")
        let client = "000000000000000000009e000000063635343332316902409ff088c2193a95e83a6e6a254205c1bc2df030724712c06d8631049f5ed1193a17ed19fa31e5f2969b631a3979750ca376fd733d7df70f6ac5540cc0f5251df28041594a268a5c013c6d6b8465bc97daa036b8c9ccd9a812b99fec5cea45b17f84d15585681b6734007a5d75aa18283515e874339f10ff0c56342aaf64e065f3e11b5a488795cb8e67c1471671466b0c400000000000"
        let session = SamsungEncrypted.parseClientHello(client, hash: hello?.hash ?? Data(), aesKey: hello?.aesKey ?? Data())
        XCTAssertEqual(HexBytes.encode(session?.context ?? Data()), "05462a5275bcb5c1edbab7c20d61c3ed")
        XCTAssertEqual(SamsungEncrypted.serverAcknowledge(skPrime: session?.skPrime ?? Data()), "01030000000000000000143F0CF8077AC7900307B6192C63F43CB62D360C420000000000")
        XCTAssertEqual(SamsungEncrypted.commandPlaintext(key: "KEY_VOLUP"), "{\"method\": \"POST\", \"body\": {\"plugin\": \"RemoteControl\", \"param1\": \"uuid:12345\", \"param2\": \"Click\", \"param3\": \"KEY_VOLUP\", \"param4\": false, \"api\": \"SendRemoteKey\", \"version\": \"1.000\"}}")
        XCTAssertEqual(SamsungEncrypted.keyName(for: .home), "KEY_CONTENTS")
        XCTAssertEqual(SamsungEncrypted.keyName(for: .powerOff), "KEY_POWEROFF")
        XCTAssertEqual(SamsungEncrypted.keyName(for: .back), "KEY_RETURN")
        XCTAssertNil(SamsungEncrypted.keyName(for: .powerOn))
    }

    func testSamsungDiscoveryRecognizesJSeries() {
        XCTAssertTrue(SSDPTarget.searchTargets.contains(SSDPTarget.samsungRemote))
        XCTAssertTrue(SSDPTarget.searchTargets.contains(SSDPTarget.mediaRenderer))
        XCTAssertTrue(SSDPTarget.searchTargets.contains(SSDPTarget.dial))
        XCTAssertTrue(SSDPTarget.searchTargets.contains(SSDPTarget.roku))
        XCTAssertTrue(SSDPTarget.searchTargets.contains(SSDPTarget.lg))
        XCTAssertEqual(SSDPMessage.brand(searchTarget: SSDPTarget.samsungRemote, server: ""), .samsung)
        XCTAssertNil(SSDPMessage.brand(searchTarget: SSDPTarget.mediaRenderer, server: "Linux UPnP/1.0"))
        XCTAssertEqual(SSDPMessage.brand(searchTarget: SSDPTarget.lg, server: ""), .lg)
        XCTAssertEqual(SSDPMessage.brand(searchTarget: SSDPTarget.roku, server: ""), .roku)
        let xml = "<root><device><manufacturer>Samsung Electronics</manufacturer><friendlyName>[TV]Samsung LED55</friendlyName></device></root>"
        XCTAssertEqual(SSDPMessage.brand(descriptionXML: xml), .samsung)
        for port: UInt16 in [8001, 8080, 8000, 7676, 9197, 55000] {
            XCTAssertTrue(DiscoveryPorts.scan.contains(port))
            XCTAssertTrue(DiscoveryPorts.samsung.contains(port))
        }
        XCTAssertTrue(BonjourServiceType.all.contains("_dmr._tcp"))
        XCTAssertTrue(BonjourServiceType.all.contains("_lgsmarttv._tcp"))
        XCTAssertTrue(BonjourServiceType.all.contains("_roku._tcp"))
    }

    func testPINSheetWaitsUntilThePageIsOpen() {
        XCTAssertFalse(SamsungPINPage.isShowing(nil))
        XCTAssertFalse(SamsungPINPage.isShowing(""))
        XCTAssertFalse(SamsungPINPage.isShowing("<service><state>stopped</state></service>"))
        XCTAssertTrue(SamsungPINPage.isShowing("<service><state>running</state></service>"))
        XCTAssertEqual(SamsungPINPage.state(in: "<state>RUNNING</state>"), "running")
        XCTAssertTrue(SamsungPINPage.closedMessage.contains("Device Connection Manager"))
        XCTAssertTrue(SamsungPINPage.closedMessage.contains("Access Notification"))
        XCTAssertFalse(SamsungPINPage.closedMessage.lowercased().contains("zenith"))
    }

    func testSamsungLegacyPackets() {
        XCTAssertEqual(HexBytes.encode(SamsungLegacy.handshake(description: "iPhone", id: "654321", name: "No Ads Remote")), "0000002c00640008006156426f6232356c08004e6a55304d7a49781400546d38675157527a49464a6c625739305a513d3d")
        XCTAssertEqual(HexBytes.encode(SamsungLegacy.keyPacket("KEY_VOLUP")), "00000011000000000c005330565a58315a5054465651")
        let two = BigUInt.modPow(base: BigUInt(bigEndian: Data([2])), exponent: BigUInt(bigEndian: Data([10])), modulus: BigUInt(bigEndian: Data([0x03, 0xE8])))
        XCTAssertEqual(two.bigEndian(paddedTo: 1), Data([24]))
    }
}
