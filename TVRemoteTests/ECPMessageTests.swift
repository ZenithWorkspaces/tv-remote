import XCTest
@testable import TVRemote

final class ECPMessageTests: XCTestCase {
    func testKeypressPaths() {
        XCTAssertEqual(RokuECP.keypressPath(for: .volumeUp), "/keypress/VolumeUp")
        XCTAssertEqual(RokuECP.keypressPath(for: .channelDown), "/keypress/ChannelDown")
        XCTAssertEqual(RokuECP.keypressPath(for: .fastForward), "/keypress/Fwd")
        XCTAssertEqual(RokuECP.keypressPath(for: .rewind), "/keypress/Rev")
        XCTAssertEqual(RokuECP.keypressPath(named: "InputHDMI1"), "/keypress/InputHDMI1")
        XCTAssertNil(RokuECP.keypressPath(for: .input))
        XCTAssertEqual(RokuECP.launchPath(appID: "12"), "/launch/12")
        XCTAssertEqual(RokuECP.appsPath, "/query/apps")
    }

    func testLiteralKeypressEncoding() {
        XCTAssertEqual(RokuECP.literalPath(for: "r"), "/keypress/Lit_r")
        XCTAssertEqual(RokuECP.literalPath(for: " "), "/keypress/Lit_%20")
        XCTAssertEqual(RokuECP.literalPaths(for: "ok"), ["/keypress/Lit_o", "/keypress/Lit_k"])
        XCTAssertFalse(RokuECP.literalPath(for: "/").contains("Lit_/"))
    }

    func testAppsXMLParser() {
        let xml = """
        <apps>
          <app id="12" type="appl" version="1.0.0">Netflix</app>
          <app id="837">YouTube</app>
        </apps>
        """
        let apps = RokuECP.parseApps(xml)
        XCTAssertEqual(apps.map(\.id), ["12", "837"])
        XCTAssertEqual(apps.map(\.name), ["Netflix", "YouTube"])
    }

    func testDeviceInfoParser() {
        let xml = """
        <device-info>
          <user-device-name>Living Room</user-device-name>
          <model-name>Roku Ultra</model-name>
          <wifi-mac>aa:bb:cc:dd:ee:ff</wifi-mac>
        </device-info>
        """
        let info = RokuECP.parseDeviceInfo(xml)
        XCTAssertEqual(info.name, "Living Room")
        XCTAssertEqual(info.model, "Roku Ultra")
        XCTAssertEqual(info.macAddress, "AA:BB:CC:DD:EE:FF")
    }

    func testSSDPSearchAndParse() {
        let search = SSDPMessage.search(target: SSDPTarget.roku)
        XCTAssertTrue(search.contains("M-SEARCH * HTTP/1.1\r\n"))
        XCTAssertTrue(search.contains("MAN: \"ssdp:discover\""))
        XCTAssertTrue(search.contains("ST: roku:ecp"))
        XCTAssertTrue(search.hasSuffix("\r\n\r\n"))

        let raw = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=3600\r\nST: roku:ecp\r\nLOCATION: http://192.168.1.20:8060/\r\nSERVER: Roku/12.0.0 UPnP/1.0 Roku/12.0.0\r\n\r\n"
        let response = SSDPMessage.parse(raw)
        XCTAssertEqual(response?.host, "192.168.1.20")
        XCTAssertEqual(response?.searchTarget, "roku:ecp")
        XCTAssertEqual(SSDPMessage.brand(searchTarget: "roku:ecp", server: "Roku/12.0 UPnP/1.0"), .roku)
        XCTAssertEqual(
            SSDPMessage.brand(searchTarget: SSDPTarget.lg, server: "WebOS/1.0"),
            .lg
        )
    }

    func testSamsungClickAndURL() throws {
        let data = SamsungRemote.clickData(key: "KEY_VOLUP")
        let object = try XCTUnwrap(JSONBox.object(data))
        XCTAssertEqual(object["method"] as? String, "ms.remote.control")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["DataOfCmd"] as? String, "KEY_VOLUP")
        XCTAssertEqual(params["Cmd"] as? String, "Click")
        XCTAssertEqual(params["TypeOfRemote"] as? String, "SendRemoteKey")

        let url = try XCTUnwrap(SamsungRemote.websocketURL(host: "10.0.0.8", secure: true, name: "TV Remote", token: "abc"))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.port, 8002)
        XCTAssertEqual(url.path, "/api/v2/channels/samsung.remote.control")
        XCTAssertTrue(url.query?.contains("token=abc") == true)

        let plain = try XCTUnwrap(SamsungRemote.websocketURL(host: "10.0.0.8", secure: false, name: "TV Remote", token: nil))
        XCTAssertEqual(plain.scheme, "ws")
        XCTAssertEqual(plain.port, 8001)
        XCTAssertFalse(plain.query?.contains("token=") == true)
    }

    func testSonyEnvelope() {
        let code = "AAAAAQAAAAEAAAASAw=="
        let xml = SonyIRCC.envelope(code: code)
        XCTAssertTrue(xml.contains("<IRCCCode>\(code)</IRCCCode>"))
        XCTAssertTrue(xml.contains("urn:schemas-sony-com:service:IRCC:1"))
        XCTAssertEqual(SonyIRCC.soapAction, "\"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\"")
        XCTAssertEqual(SonyIRCC.path, "/sony/IRCC")
    }

    func testVizioCommandBody() throws {
        let data = VizioSmartCast.commandData(codeset: 5, code: 1)
        let object = try XCTUnwrap(JSONBox.object(data))
        let list = try XCTUnwrap(object["KEYLIST"] as? [[String: Any]])
        XCTAssertEqual(list.first?["CODESET"] as? Int, 5)
        XCTAssertEqual(list.first?["CODE"] as? Int, 1)
        XCTAssertEqual(list.first?["ACTION"] as? String, "KEYPRESS")
        let pairing = VizioSmartCast.finishPairingObject(deviceID: "dev", challengeType: 1, pin: "1234", token: "99")
        XCTAssertEqual(pairing["RESPONSE_VALUE"] as? Int, 1234)
        XCTAssertEqual(pairing["PAIRING_REQ_TOKEN"] as? Int, 99)
    }
}
