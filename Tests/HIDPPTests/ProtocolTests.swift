import XCTest
@testable import HIDPP

final class ReportTests: XCTestCase {
    func testBuildAndParseLong() {
        let r = Report(kind: .long, deviceIndex: 0xFF, subID: 0x09, address: 0x1E, params: [0x00, 0xC3])
        XCTAssertEqual(r.bytes.count, 20)
        XCTAssertEqual(Array(r.bytes.prefix(6)), [0x11, 0xFF, 0x09, 0x1E, 0x00, 0xC3])
        let p = Report(r.bytes)!
        XCTAssertEqual(p, r)
        XCTAssertEqual(p.function, 1)
        XCTAssertEqual(p.softwareID, 0xE)
    }

    func testRejectsUnknownAndShort() {
        XCTAssertNil(Report([0x02, 0x00, 0x00]))
        XCTAssertNil(Report([0x11, 0xFF, 0x00]))
    }

    func testParamsAccessors() {
        let p = Params([0x00, 0x03, 0xE8, 0x03, 0xE8, 0xFF, 0x9C])
        XCTAssertEqual(p.u16(1), 1000)
        XCTAssertEqual(p.i16(5), -100)
        XCTAssertEqual(p.u8(40), 0)
    }

    func testClassification() {
        var event = [UInt8](repeating: 0, count: 20)
        event[0] = 0x11; event[1] = 0xFF; event[2] = 0x09; event[5] = 0xC3
        XCTAssertTrue(Report(event)!.isFeatureEvent)
        XCTAssertTrue(Report([0x10, 0x01, 0x41, 0x04, 0x02, 0x82, 0x40])!.isHIDPP10Notification)
        XCTAssertTrue(Report([0x10, 0xFF, 0x81, 0x00, 0x00, 0x09, 0x00])!.isRegisterMessage)
    }

    func testFeatureReplyMatching() {
        func long(_ b: [UInt8]) -> Report { Report(b + [UInt8](repeating: 0, count: 20 - b.count))! }
        let m = Matcher.feature(deviceIndex: 0xFF, featureIndex: 0x09, address: 0x1E)
        XCTAssertNotNil(try? m.check(long([0x11, 0xFF, 0x09, 0x1E, 0x00, 0x50]))?.get())
        // Bluetooth quirk: device index 0x00 in replies.
        XCTAssertNotNil(try? m.check(long([0x11, 0x00, 0x09, 0x1E, 0x00, 0x50]))?.get())
        // Another software id, or an event, is not our reply.
        XCTAssertNil(m.check(long([0x11, 0xFF, 0x09, 0x1B, 0x00, 0x50])))
        XCTAssertNil(m.check(long([0x11, 0xFF, 0x09, 0x00, 0x00, 0xC3])))
        guard case .failure(let e)? = m.check(long([0x11, 0xFF, 0xFF, 0x09, 0x1E, 0x02])) else { return XCTFail("no error") }
        XCTAssertEqual(e, .hidpp20(0x02))
    }

    func testPingMatching() {
        let m = Matcher.ping(deviceIndex: 0x02, address: 0x1E, mark: 0x77)
        var ok = [UInt8](repeating: 0, count: 20)
        ok[0] = 0x11; ok[1] = 0x02; ok[3] = 0x1E; ok[4] = 4; ok[5] = 5; ok[6] = 0x77
        XCTAssertNotNil(try? m.check(Report(ok)!)?.get())
        ok[6] = 0x78
        XCTAssertNil(m.check(Report(ok)!))
    }
}

final class FeatureTests: XCTestCase {
    func testMXMaster3SDPIRange() {
        // Real reply from an MX Master 3S (after the sensor byte): 200...8000 step 50.
        let r = DPIRange.parse([0x00, 0xC8, 0xE0, 0x32, 0x1F, 0x40, 0x00, 0x00])
        XCTAssertEqual(r, .range(min: 200, max: 8000, step: 50))
        XCTAssertEqual(r?.snap(1234), 1250)
        XCTAssertEqual(r?.snap(10), 200)
        XCTAssertEqual(r?.snap(9000), 8000)
    }

    func testDPIList() {
        let r = DPIRange.parse([0x01, 0x90, 0x03, 0x20, 0x06, 0x40, 0x00, 0x00])
        XCTAssertEqual(r, .list([400, 800, 1600]))
        XCTAssertEqual(r?.snap(1000), 800)
    }

    func testUnifiedBattery() {
        // MX Master 3S: 80 %, level full, discharging.
        let b = Battery.decodeUnified(Params([0x50, 0x08, 0x00, 0x00]))
        XCTAssertEqual(b.percent, 80)
        XCTAssertEqual(b.level, .full)
        XCTAssertFalse(b.isCharging)
    }

    func testVoltageCurve() {
        XCTAssertEqual(Battery.voltageToPercent(4200), 100)
        XCTAssertEqual(Battery.voltageToPercent(3811), 50)
        XCTAssertEqual(Battery.voltageToPercent(3000), 0)
    }

    func testReprogEvents() {
        XCTAssertEqual(ReprogEvent.decode(function: 0, Params([0x00, 0xC3, 0x00, 0x53, 0, 0, 0, 0])), .divertedButtons([0xC3, 0x53]))
        XCTAssertEqual(ReprogEvent.decode(function: 1, Params([0xFF, 0xFE, 0x00, 0x05])), .rawXY(dx: -2, dy: 5))
    }

    func testControlFlagsOfGestureButton() {
        // Gesture button of an MX Master 3S reports flags 0x0531.
        let f = ControlFlags(rawValue: 0x0531)
        XCTAssertTrue(f.contains([.divertable, .rawXY, .mouseButton, .analyticsKeyEvents]))
        XCTAssertFalse(f.contains(.virtual))
    }

    func testWheelAndThumbwheelEvents() {
        XCTAssertEqual(WheelEvent.decode(function: 0, Params([0x11, 0x00, 0x0F])), .movement(hiRes: true, periods: 1, delta: 15))
        XCTAssertEqual(WheelEvent.decode(function: 1, Params([0x01])), .ratchet(true))
        let t = ThumbwheelEvent.decode(function: 0, Params([0xFF, 0xF6, 0x01, 0x02, 0x02, 0x02]))!
        XCTAssertEqual(t.rotation, -10)
        XCTAssertEqual(t.status, .active)
        XCTAssertTrue(t.touch)
    }

    func testReceiverConnectionNotification() {
        let r = Report([0x10, 0x01, 0x41, 0x04, 0x02, 0x82, 0x40])!
        XCTAssertEqual(ReceiverEvent.decode(r), .connection(slot: 1, online: true, kind: .mouse, wirelessPID: 0x4082))
        let off = Report([0x10, 0x01, 0x41, 0x04, 0x42, 0x82, 0x40])!
        guard case .connection(_, let online, _, _)? = ReceiverEvent.decode(off) else { return XCTFail() }
        XCTAssertFalse(online)
    }

    func testReportDescriptorOfBluetoothMouse() {
        // Vendor page 0xFF43 with report id 0x11 only (HID++ long reports), as on BLE MX mice.
        let desc: [UInt8] = [0x06, 0x43, 0xFF, 0x0A, 0x02, 0x02, 0xA1, 0x01, 0x85, 0x11, 0x75, 0x08, 0x95, 0x13, 0xC0]
        let s = ReportSupport.parse(descriptor: desc)
        XCTAssertTrue(s.long)
        XCTAssertFalse(s.short)
    }
}
