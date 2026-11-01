import XCTest
@testable import MouseMasterKit

/// Counts at 1000 DPI for a distance in millimetres.
private func mm(_ v: Double) -> Int { Int((v / 25.4 * 1000).rounded()) }

final class GestureTests: XCTestCase {
    private func tracker(_ f: (inout GestureSet) -> Void = { _ in }) -> GestureTracker {
        var set = GestureSet()
        set.thresholdMM = 5
        f(&set)
        return GestureTracker(set: set, skipFirst: false)
    }

    func testClickWithoutMovement() {
        var t = tracker()
        XCTAssertTrue(t.motion(dx: mm(0.5), dy: mm(-0.5), dpi: 1000).isEmpty)
        XCTAssertEqual(t.release(), [.click])
    }

    func testFiresOnceOnThreshold() {
        var t = tracker()
        XCTAssertTrue(t.motion(dx: mm(-3), dy: 0, dpi: 1000).isEmpty)
        XCTAssertEqual(t.motion(dx: mm(-3), dy: 0, dpi: 1000), [.fire(.left)])
        XCTAssertTrue(t.motion(dx: mm(-20), dy: 0, dpi: 1000).isEmpty)
        XCTAssertTrue(t.motion(dx: 0, dy: mm(20), dpi: 1000).isEmpty)
        XCTAssertTrue(t.release().isEmpty)
    }

    func testUpIsNegativeY() {
        var t = tracker()
        XCTAssertEqual(t.motion(dx: mm(1), dy: mm(-8), dpi: 1000), [.fire(.up)])
    }

    func testRepeatVertical() {
        var t = tracker { $0.repeatVertical = true }
        XCTAssertEqual(t.motion(dx: 0, dy: mm(16), dpi: 1000), [.fire(.down), .fire(.down), .fire(.down)])
        XCTAssertEqual(t.motion(dx: 0, dy: mm(-11.5), dpi: 1000), [.fire(.up), .fire(.up)])
        XCTAssertTrue(t.motion(dx: mm(30), dy: 0, dpi: 1000).isEmpty)
    }

    func testReleaseTrigger() {
        var t = tracker { $0.trigger = .release }
        XCTAssertTrue(t.motion(dx: mm(10), dy: mm(2), dpi: 1000).isEmpty)
        XCTAssertEqual(t.release(), [.fire(.right)])
    }

    func testSkipsFirstReport() {
        var set = GestureSet()
        set.thresholdMM = 5
        var t = GestureTracker(set: set, skipFirst: true)
        XCTAssertTrue(t.motion(dx: mm(50), dy: 0, dpi: 1000).isEmpty)
        XCTAssertEqual(t.release(), [.click])
    }

    func testPanScrollsWithTheHand() {
        var t = tracker { $0.mode = .pan }
        var dy = 0.0
        for _ in 0..<10 {
            for o in t.motion(dx: 0, dy: mm(1), dpi: 1000) { if case .scroll(_, let y) = o { dy += y } }
        }
        XCTAssertEqual(dy, 90, accuracy: 3) // 10 mm at 9 points per mm
        XCTAssertTrue(t.release().isEmpty)
    }

    func testZoomIsContinuous() {
        var t = tracker { $0.mode = .zoom }
        var level = 0.0
        for _ in 0..<30 {
            for o in t.motion(dx: 0, dy: mm(-1), dpi: 1000) { if case .magnify(let m) = o { level += m } }
        }
        XCTAssertEqual(exp(level), 2, accuracy: 0.02) // 30 mm up doubles the zoom
        guard case .magnify(let out)? = t.motion(dx: 0, dy: mm(3), dpi: 1000).first else { return XCTFail() }
        XCTAssertLessThan(out, 0)
    }
}

final class ThumbwheelTests: XCTestCase {
    func testScrollFollowsDeviceDirection() {
        // MX Master 3S: 120 units per turn, default direction -1.
        var t = ThumbwheelTracker(binding: .scroll(speed: 1), divertedResolution: 120, defaultDirection: -1, invert: false)
        let out = t.event(ThumbInput(rotation: -12, status: .active, singleTap: false))
        guard case .scroll(let points)? = out.first else { return XCTFail() }
        XCTAssertEqual(points, 52, accuracy: 0.01) // a tenth of a turn to the right
        var inverted = ThumbwheelTracker(binding: .scroll(speed: 1), divertedResolution: 120, defaultDirection: -1, invert: true)
        guard case .scroll(let back)? = inverted.event(ThumbInput(rotation: -12, status: .active, singleTap: false)).first else { return XCTFail() }
        XCTAssertLessThan(back, 0)
    }

    func testActionSteps() {
        var t = ThumbwheelTracker(binding: .actions(left: .builtin("volume-down"), right: .builtin("volume-up"), stepDegrees: 30),
                                  divertedResolution: 120, defaultDirection: -1, invert: false)
        XCTAssertEqual(t.event(ThumbInput(rotation: -25, status: .start, singleTap: false)), [.step(.right), .step(.right)])
        XCTAssertEqual(t.event(ThumbInput(rotation: -5, status: .active, singleTap: false)), [.step(.right)])
    }

    func testSmoothZoomAndItsEnd() {
        var t = ThumbwheelTracker(binding: .zoom(speed: 1), divertedResolution: 120, defaultDirection: -1, invert: false)
        var level = 0.0
        for _ in 0..<12 {
            for o in t.event(ThumbInput(rotation: -10, status: .active, singleTap: false)) { if case .magnify(let m) = o { level += m } }
        }
        XCTAssertEqual(exp(level), 3, accuracy: 0.01) // a full turn to the right zooms in 3×
        XCTAssertEqual(t.event(ThumbInput(rotation: 0, status: .stop, singleTap: false)), [.magnifyEnd])
    }

    func testTap() {
        var t = ThumbwheelTracker(binding: .native, divertedResolution: 120, defaultDirection: -1, invert: false)
        XCTAssertEqual(t.event(ThumbInput(rotation: 0, status: .inactive, singleTap: true)), [.tap])
    }
}

final class ZoomTests: XCTestCase {
    private func run(_ a: inout ZoomAnimator, maxFrames: Int = 1000) -> (total: Double, frames: Int) {
        var total = 0.0, frames = 0
        while !a.isIdle && frames < maxFrames {
            total += a.step(dt: 1.0 / 120)
            frames += 1
        }
        return (total, frames)
    }

    func testAnimatorDeliversEverything() {
        var a = ZoomAnimator()
        a.add(log(2))
        let (total, frames) = run(&a)
        XCTAssertEqual(total, log(2), accuracy: 1e-9)
        XCTAssertLessThan(frames, 40) // a third of a second
    }

    func testTheRestPlaysOutQuicklyOnceTheInputIsOver() {
        var a = ZoomAnimator()
        a.add(0.03)
        _ = a.step(dt: 1.0 / 120)
        a.finish()
        let (_, frames) = run(&a)
        XCTAssertLessThanOrEqual(frames, 5) // the pinch ends within ~40 ms
    }

    func testFlushAndReversal() {
        var a = ZoomAnimator()
        a.add(0.2)
        _ = a.step(dt: 1.0 / 120)
        a.add(-0.05) // reversing drops what was left of the zoom in
        XCTAssertEqual(a.flush(), -0.05, accuracy: 1e-12)
        XCTAssertTrue(a.isIdle)
    }

    /// Chromium's rule: no zoom until the product of the scales leaves (0.667, 1.5).
    private func chromiumZooms(_ steps: [Double]) -> [Bool] {
        var unused = 1.0, reached = false
        return steps.map { m in
            if !reached {
                unused *= 1 + m
                reached = unused < ChromiumPinch.zoomOutThreshold || unused > ChromiumPinch.zoomInThreshold
            }
            return reached
        }
    }

    func testChromiumOpeningStepIsSwallowedAndZoomStartsRightAfter() {
        for zoomingIn in [true, false] {
            let opening = ChromiumPinch.openingStep(zoomingIn: zoomingIn)
            let step = exp(zoomingIn ? 0.009 : -0.009) - 1 // one unit of the thumb wheel
            let zooms = chromiumZooms([opening] + Array(repeating: step, count: 5))
            XCTAssertFalse(zooms[0], "the opening step itself must not zoom")
            XCTAssertTrue(zooms[3], "zooming starts within three steps")
            // A busy browser gets the opening step merged with the next one: still no jump.
            XCTAssertEqual(chromiumZooms([(1 + opening) * (1 + step) - 1]), [false])
        }
        // Without it a third of a turn has no effect.
        XCTAssertFalse(chromiumZooms(Array(repeating: 0.009, count: 40)).contains(true))
    }
}

final class ScrollTests: XCTestCase {
    func testAnimatorDeliversEverything() {
        var a = ScrollAnimator(tau: 0.06)
        a.add(dx: 0, dy: 42)
        var total = 0, frames = 0
        while !a.isIdle && frames < 200 {
            total += a.step(dt: 1.0 / 120).dy
            frames += 1
        }
        XCTAssertEqual(total, 42, accuracy: 1)
        XCTAssertLessThan(frames, 60) // done within half a second
    }

    func testReversingCancelsTheRest() {
        var a = ScrollAnimator()
        a.add(dx: 0, dy: 100)
        _ = a.step(dt: 0.01)
        a.add(dx: 0, dy: -10)
        var total = 0
        while !a.isIdle { total += a.step(dt: 1.0 / 120).dy }
        XCTAssertEqual(total, -10, accuracy: 1)
    }

    func testAccelerationOnlyForFastScrolling() {
        var w = WheelAccelerator(unitsPerNotch: 15, speed: 1, acceleration: 1)
        // Slow, deliberate notches: one notch is the base distance.
        XCTAssertEqual(w.points(delta: 15, time: 0), WheelAccelerator.pointsPerNotch, accuracy: 0.01)
        XCTAssertEqual(w.points(delta: 15, time: 0.5), WheelAccelerator.pointsPerNotch, accuracy: 0.01)
        // A fast flick travels further per notch.
        var t = 1.0
        var last = 0.0
        for _ in 0..<30 {
            t += 0.012
            last = w.points(delta: 15, time: t)
        }
        XCTAssertGreaterThan(last, WheelAccelerator.pointsPerNotch * 2.5)
        // No acceleration means linear.
        var linear = WheelAccelerator(unitsPerNotch: 15, speed: 1, acceleration: 0)
        _ = linear.points(delta: 15, time: 0)
        XCTAssertEqual(linear.points(delta: 15, time: 0.01), WheelAccelerator.pointsPerNotch, accuracy: 0.01)
    }
}

final class ConfigTests: XCTestCase {
    func testRoundTrip() throws {
        var cfg = Config()
        var dev = DeviceConfig()
        dev.name = "MX Master 3S"
        dev.settings.dpi = 1600
        dev.settings.smoothScroll = true
        dev.settings.scrollDirection = .standard
        dev.bindings.buttons["gesture"] = .gestures(GesturePresets.all[0].set)
        dev.bindings.buttons["back"] = .keys(KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command))
        dev.bindings.buttons["forward"] = .macro([.keys(KeyCombo(keyCode: KeyCode.c, modifiers: .command)), .delay(50), .text("hi")])
        dev.bindings.thumbwheel = .actions(left: .builtin("volume-down"), right: .builtin("volume-up"), stepDegrees: 15)
        var p = AppProfile(name: "Safari", apps: ["com.apple.Safari"])
        p.bindings.buttons["middle"] = .builtin("new-tab")
        dev.profiles = [p]
        cfg.devices["b034-5C8F7AF8"] = dev
        let data = try JSONEncoder().encode(cfg)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data), cfg)
    }

    func testLenientDecoding() throws {
        let json = #"{"general":{"osd":false,"unknown":1},"devices":{"x":{"settings":{"dpi":"oops","smoothScroll":false}}}}"#
        let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertFalse(cfg.general.osd)
        XCTAssertTrue(cfg.general.appProfiles)
        XCTAssertNil(cfg.devices["x"]?.settings.dpi)
        XCTAssertEqual(cfg.devices["x"]?.settings.smoothScroll, false)
    }

    func testProfileOverlay() {
        var base = Bindings()
        base.buttons["back"] = .builtin("back")
        base.buttons["forward"] = .nothing
        var over = Bindings()
        over.buttons["back"] = .builtin("copy")
        let merged = base.overlay(over)
        XCTAssertEqual(merged.buttons["back"], .builtin("copy"))
        XCTAssertEqual(merged.buttons["forward"], Action.nothing)
    }

    func testEveryBuiltinHasAUniqueID() {
        XCTAssertEqual(Set(Catalog.actions.map(\.id)).count, Catalog.actions.count)
    }

    func testDefaults() {
        let controls = [ControlInfo(cid: 0xC3, key: "gesture", name: "Gesture button", role: "gesture", gestures: true),
                        ControlInfo(cid: 0x53, key: "back", name: "Back button", role: "back", gestures: true)]
        let b = DefaultBindings.make(controls: controls, thumbwheel: true)
        XCTAssertTrue(b.buttons["gesture"]?.isGestures ?? false)
        XCTAssertEqual(b.buttons["back"], .builtin("back"))
        XCTAssertEqual(b.thumbwheel, .scroll(speed: 1))
    }
}
