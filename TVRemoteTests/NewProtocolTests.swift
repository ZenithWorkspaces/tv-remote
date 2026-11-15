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
    }
}
