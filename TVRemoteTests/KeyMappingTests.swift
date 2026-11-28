import XCTest
@testable import TVRemote

final class KeyMappingTests: XCTestCase {
    func testEveryRokuKeyExceptInputHasAName() {
        for key in RemoteKey.allCases {
            if key == .input || key == .skipNext {
                XCTAssertNil(RokuECP.keyName(for: key))
            } else {
                XCTAssertNotNil(RokuECP.keyName(for: key), "Missing Roku key for \(key)")
            }
        }
    }

    func testRokuNavigationAndTransportNames() {
        XCTAssertEqual(RokuECP.keyName(for: .ok), "Select")
        XCTAssertEqual(RokuECP.keyName(for: .home), "Home")
        XCTAssertEqual(RokuECP.keyName(for: .back), "Back")
        XCTAssertEqual(RokuECP.keyName(for: .rewind), "Rev")
        XCTAssertEqual(RokuECP.keyName(for: .fastForward), "Fwd")
        XCTAssertEqual(RokuECP.keyName(for: .playPause), "Play")
        XCTAssertEqual(RokuECP.keyName(for: .skipPrevious), "InstantReplay")
        XCTAssertNil(RokuECP.keyName(for: .skipNext))
        XCTAssertEqual(RokuECP.keyName(for: .volumeUp), "VolumeUp")
        XCTAssertEqual(RokuECP.keyName(for: .mute), "VolumeMute")
        XCTAssertEqual(RokuECP.keyName(for: .powerOn), "PowerOn")
        XCTAssertEqual(RokuECP.keyName(for: .powerOff), "PowerOff")
        XCTAssertEqual(RokuECP.keyName(for: .menu), "Info")
    }

    func testLGNavigationIsPointerAndVolumeIsSSAP() {
        XCTAssertEqual(LGSSAP.command(for: .home), .pointer("HOME"))
        XCTAssertEqual(LGSSAP.command(for: .ok), .pointer("ENTER"))
        XCTAssertEqual(LGSSAP.command(for: .back), .pointer("BACK"))
        XCTAssertEqual(LGSSAP.command(for: .up), .pointer("UP"))
        XCTAssertEqual(LGSSAP.command(for: .playPause, playNext: true), .pointer("PLAY"))
        XCTAssertEqual(LGSSAP.command(for: .playPause, playNext: false), .pointer("PAUSE"))
        XCTAssertEqual(LGSSAP.command(for: .rewind), .pointer("REWIND"))
        XCTAssertEqual(LGSSAP.command(for: .fastForward), .pointer("FASTFORWARD"))
        XCTAssertEqual(LGSSAP.command(for: .skipPrevious), .pointer("PREVIOUS"))
        XCTAssertEqual(LGSSAP.command(for: .skipNext), .pointer("NEXT"))
        XCTAssertEqual(LGSSAP.command(for: .powerOn), .unsupported)
        guard case let .request(uri, _) = LGSSAP.command(for: .volumeUp) else {
            return XCTFail("Volume up should be an SSAP request")
        }
        XCTAssertEqual(uri, "ssap://audio/volumeUp")
        guard case let .request(powerURI, _) = LGSSAP.command(for: .powerOff) else {
            return XCTFail("Power off should be an SSAP request")
        }
        XCTAssertEqual(powerURI, "ssap://system/turnOff")
    }

    func testLGMutePayload() {
        guard case let .request(uri, payload) = LGSSAP.command(for: .mute, muted: true) else {
            return XCTFail("Mute should be an SSAP request")
        }
        XCTAssertEqual(uri, "ssap://audio/setMute")
        XCTAssertEqual(payload.bools["mute"], true)
    }

    func testSamsungKeyNames() {
        XCTAssertEqual(SamsungRemote.keyName(for: .volumeUp), "KEY_VOLUP")
        XCTAssertEqual(SamsungRemote.keyName(for: .ok), "KEY_ENTER")
        XCTAssertEqual(SamsungRemote.keyName(for: .back), "KEY_RETURN")
        XCTAssertEqual(SamsungRemote.keyName(for: .powerOff), "KEY_POWER")
        XCTAssertEqual(SamsungRemote.keyName(for: .input), "KEY_SOURCE")
    }

    func testSonyVolumeCode() {
        XCTAssertEqual(SonyIRCC.code(for: .volumeUp), "AAAAAQAAAAEAAAASAw==")
        XCTAssertEqual(SonyIRCC.code(for: .home), "AAAAAQAAAAEAAABgAw==")
        XCTAssertEqual(SonyIRCC.code(for: .ok), "AAAAAQAAAAEAAABlAw==")
    }

    func testVizioVolumeCode() {
        let volume = VizioSmartCast.key(for: .volumeUp)
        XCTAssertEqual(volume?.codeset, 5)
        XCTAssertEqual(volume?.code, 1)
        XCTAssertEqual(VizioSmartCast.key(for: .home)?.code, 15)
    }

    func testYouTubeDoesNotStealYouTubeTV() {
        let installed = [
            InstalledApp(id: "1", name: "YouTube"),
            InstalledApp(id: "2", name: "YouTube TV")
        ]
        XCTAssertEqual(AppShortcutResolver.rokuID(for: .named("youtube"), installed: installed), "1")
        XCTAssertEqual(AppShortcutResolver.rokuID(for: .named("youtube-tv"), installed: installed), "2")
        XCTAssertEqual(AppShortcutResolver.lgID(for: .named("youtube"), installed: installed), "1")
    }

    func testInstalledNameBeatsFallback() {
        let installed = [InstalledApp(id: "999", name: "Netflix")]
        XCTAssertEqual(AppShortcutResolver.rokuID(for: .named("netflix"), installed: installed), "999")
        XCTAssertEqual(AppShortcutResolver.rokuID(for: .named("netflix"), installed: []), "12")
        XCTAssertEqual(AppShortcutResolver.lgID(for: .named("netflix"), installed: []), "netflix")
        XCTAssertEqual(AppShortcutResolver.rokuID(for: .named("disney"), installed: []), "291097")
        XCTAssertEqual(AppShortcutResolver.rokuID(for: .named("max"), installed: []), "61322")
    }

    func testWakeOnLANPacket() throws {
        let packet = try XCTUnwrap(WakeOnLAN.packet(mac: "aa:bb:cc:dd:ee:ff"))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: UInt8(0xFF), count: 6))
        XCTAssertEqual(packet[6], UInt8(0xAA))
        XCTAssertEqual(packet[11], UInt8(0xFF))
        let repeated = packet.subdata(in: 6..<12)
        for index in 0..<16 {
            let start = 6 + index * 6
            XCTAssertEqual(packet.subdata(in: start..<(start + 6)), repeated)
        }
        XCTAssertEqual(WakeOnLAN.packet(mac: "aa-bb-cc-dd-ee-ff"), packet)
        XCTAssertNil(WakeOnLAN.packet(mac: "not-a-mac"))
        XCTAssertEqual(WakeOnLAN.ports, [9, 7])
        XCTAssertEqual(
            WakeOnLAN.targets(host: "192.168.1.20", localAddress: "192.168.1.8"),
            ["255.255.255.255", "192.168.1.255", "192.168.1.20"]
        )
        XCTAssertTrue(WakeOnLAN.isBroadcast("255.255.255.255"))
        XCTAssertTrue(WakeOnLAN.isBroadcast("192.168.1.255"))
        XCTAssertFalse(WakeOnLAN.isBroadcast("192.168.1.20"))
    }

    func testLGPowerStateTreatsStandbyAsOff() {
        XCTAssertTrue(LGSSAP.isActivePower("Active"))
        XCTAssertTrue(LGSSAP.isActivePower(" active "))
        XCTAssertFalse(LGSSAP.isActivePower("Active Standby"))
        XCTAssertFalse(LGSSAP.isActivePower("Screen Off"))
        XCTAssertFalse(LGSSAP.isActivePower("Suspend"))
        XCTAssertFalse(LGSSAP.isActivePower("unknown"))
        let screenOff = LGPowerReading(state: "Active", processing: "Not Ready", reason: "Screen Off")
        XCTAssertFalse(screenOff.screenIsOn)
        let standby = LGPowerReading.parse(payload: ["state": "Active Standby", "processing": "Request Power Off"])
        XCTAssertFalse(standby.screenIsOn)
        XCTAssertFalse(LGPowerReading.parse(payload: ["state": "Suspend"]).screenIsOn)
        XCTAssertFalse(LGPowerReading.parse(payload: ["state": "Screen Off"]).screenIsOn)
        let pictureOn = LGPowerReading(state: "Active", processing: "Not Ready", reason: "")
        XCTAssertTrue(pictureOn.screenIsOn)
        XCTAssertEqual(LGSSAP.powerLabel(["state": "Screen Off"]), "Screen Off")
        XCTAssertTrue(LGSSAP.requestFailed(["type": "error", "payload": [String: Any]()]))
        XCTAssertTrue(LGSSAP.requestFailed([
            "type": "response",
            "payload": ["returnValue": false] as [String: Any]
        ]))
        XCTAssertFalse(LGSSAP.requestFailed([
            "type": "response",
            "payload": ["returnValue": true, "state": "Active"] as [String: Any]
        ]))
        let info: [String: Any] = [
            "wired": ["macAddress": "11:11:11:11:11:11"] as [String: Any],
            "wifi": ["macAddress": "aa:bb:cc:dd:ee:ff"] as [String: Any]
        ]
        XCTAssertEqual(MACAddress.preferred(in: info), "AA:BB:CC:DD:EE:FF")
    }

    func testDiscoveryPortsIncludeKnownTVPorts() {
        XCTAssertTrue(DiscoveryPorts.scan.contains(8060))
        XCTAssertTrue(DiscoveryPorts.scan.contains(3000))
        XCTAssertTrue(DiscoveryPorts.scan.contains(3001))
        XCTAssertTrue(DiscoveryPorts.scan.contains(8001))
        XCTAssertTrue(DiscoveryPorts.scan.contains(8002))
        XCTAssertTrue(DiscoveryPorts.scan.contains(7345))
        XCTAssertTrue(SSDPTarget.searchTargets.contains(SSDPTarget.roku))
        XCTAssertTrue(SSDPTarget.searchTargets.contains(SSDPTarget.lg))
    }
}
