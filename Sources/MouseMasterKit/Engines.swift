import Foundation

// MARK: - Gestures

/// What a gesture produces.
public enum GestureOutput: Equatable, Sendable {
    case fire(Direction)
    case click
    /// Pan mode: scroll by points (positive x reveals content to the right, positive y content below).
    case scroll(dx: Double, dy: Double)
    /// Zoom mode: change of the zoom level on a log scale (positive zooms in).
    case magnify(Double)
}

/// Turns raw pointer motion reported while a gesture button is held into
/// directions, clicks, scrolling or zoom steps.
public struct GestureTracker: Sendable {
    static let mmPerInch = 25.4
    /// Pan mode: points scrolled per millimetre of mouse movement at speed 1.
    static let panPointsPerMM = 9.0
    /// Movement below this is still a click in pan and zoom mode.
    static let clickSlopMM = 2.0
    /// Zoom mode: millimetres of movement that double the zoom at speed 1.
    static let zoomMMPerDoubling = 30.0

    public let set: GestureSet
    private var accX = 0.0, accY = 0.0
    private var travel = 0.0
    private var fired = false
    private var lockedVertical: Bool?
    private var skipNext: Bool

    /// `skipFirst`: ignore the first motion report, which some devices (MX Master 3S) fill with stale data.
    public init(set: GestureSet, skipFirst: Bool) {
        self.set = set
        skipNext = skipFirst
    }

    private var threshold: Double { min(max(set.thresholdMM, 1), 50) }

    public mutating func motion(dx: Int, dy: Int, dpi: Int) -> [GestureOutput] {
        if skipNext {
            skipNext = false
            return []
        }
        let scale = Self.mmPerInch / Double(max(dpi, 100))
        let mx = Double(dx) * scale, my = Double(dy) * scale
        travel += (mx * mx + my * my).squareRoot()
        switch set.mode {
        case .pan:
            let k = Self.panPointsPerMM * min(max(set.panSpeed, 0.1), 10)
            let sign = set.panInvert ? -1.0 : 1.0
            return [.scroll(dx: mx * k * sign, dy: my * k * sign)]
        case .zoom:
            // Moving the mouse away from you (negative y) zooms in.
            guard my != 0 else { return [] }
            let speed = min(max(set.zoomSpeed, 0.1), 10)
            return [.magnify(-my / Self.zoomMMPerDoubling * speed * log(2))]
        case .directional:
            accX += mx
            accY += my
            return set.trigger == .move ? directional() : []
        }
    }

    private static func direction(_ x: Double, _ y: Double) -> (Direction, vertical: Bool) {
        if abs(x) > abs(y) { return (x > 0 ? .right : .left, false) }
        // Screen coordinates: moving the mouse away from you is negative y.
        return (y > 0 ? .down : .up, true)
    }

    private mutating func directional() -> [GestureOutput] {
        var out: [GestureOutput] = []
        let t = threshold
        while true {
            let (dir, vertical) = Self.direction(accX, accY)
            let along = vertical ? abs(accY) : abs(accX)
            if along < t { break }
            if fired && (!set.repeats(dir) || lockedVertical != vertical) {
                // Swallow movement so that a later reversal does not fire again.
                accX = 0
                accY = 0
                break
            }
            out.append(.fire(dir))
            fired = true
            lockedVertical = vertical
            if vertical {
                accY -= t * (accY > 0 ? 1 : -1)
                accX = 0
            } else {
                accX -= t * (accX > 0 ? 1 : -1)
                accY = 0
            }
            if !set.repeats(dir) {
                accX = 0
                accY = 0
                break
            }
        }
        return out
    }

    /// The button was released.
    public mutating func release() -> [GestureOutput] {
        let t = threshold
        switch set.mode {
        case .pan, .zoom:
            return travel < Self.clickSlopMM ? [.click] : []
        case .directional:
            switch set.trigger {
            case .release:
                let magnitude = (accX * accX + accY * accY).squareRoot()
                if magnitude >= t { return [.fire(Self.direction(accX, accY).0)] }
                return travel < t * 1.5 ? [.click] : []
            case .move:
                return !fired && travel < t * 1.5 ? [.click] : []
            }
        }
    }
}

// MARK: - Thumb wheel

public enum ThumbOutput: Equatable, Sendable {
    /// Horizontal scrolling in points (positive reveals content to the right).
    case scroll(Double)
    /// One step of an action binding.
    case step(Direction)
    /// Change of the zoom level on a log scale (positive zooms in).
    case magnify(Double)
    /// The wheel stopped turning: the pinch is over.
    case magnifyEnd
    case tap
}

public struct ThumbInput: Sendable {
    public enum Status: Sendable { case inactive, start, active, stop }
    public var rotation: Int
    public var status: Status
    public var singleTap: Bool

    public init(rotation: Int, status: Status, singleTap: Bool) {
        self.rotation = rotation
        self.status = status
        self.singleTap = singleTap
    }
}

/// Processes a diverted thumb wheel.
public struct ThumbwheelTracker: Sendable {
    /// Points per full turn at speed 1.
    static let pointsPerTurn = 520.0
    /// Zoom factor of a full turn at speed 1 (on a log scale: one turn zooms 3×).
    static let zoomPerTurn = log(3.0)

    public let binding: ThumbwheelBinding
    let divertedResolution: Double
    let direction: Double
    let invert: Bool
    private var acc = 0.0

    public init(binding: ThumbwheelBinding, divertedResolution: Int, defaultDirection: Int, invert: Bool) {
        self.binding = binding
        self.divertedResolution = Double(max(divertedResolution, 1))
        direction = defaultDirection >= 0 ? 1 : -1
        self.invert = invert
    }

    public mutating func event(_ e: ThumbInput) -> [ThumbOutput] {
        var out: [ThumbOutput] = []
        if e.singleTap { out.append(.tap) }
        if e.status == .start { acc = 0 }
        if case .zoom = binding, e.status == .stop { out.append(.magnifyEnd) }
        guard e.rotation != 0 else { return out }
        // Positive means "to the right" after the device's default direction.
        let units = Double(e.rotation) * direction * (invert ? -1 : 1)
        let turns = units / divertedResolution
        switch binding {
        case .native:
            break
        case .scroll(let speed):
            out.append(.scroll(turns * Self.pointsPerTurn * min(max(speed, 0.1), 10)))
        case .zoom(let speed):
            out.append(.magnify(turns * Self.zoomPerTurn * min(max(speed, 0.1), 10)))
        case .actions(_, _, let stepDegrees):
            let step = max(min(max(stepDegrees, 3), 180) / 360, 1 / divertedResolution)
            acc += turns
            while abs(acc) >= step {
                out.append(.step(acc > 0 ? .right : .left))
                acc -= step * (acc > 0 ? 1 : -1)
            }
        }
        return out
    }
}

// MARK: - Smooth scrolling

/// Converts high resolution wheel movement into a scroll distance, with acceleration
/// based on how fast the wheel turns.
public struct WheelAccelerator: Sendable {
    /// Points per ratchet notch at speed 1, before acceleration.
    public static let pointsPerNotch = 42.0

    public var unitsPerNotch: Double
    public var speed: Double
    public var acceleration: Double
    private var lastTime: Double?
    private var lastSign = 0.0
    /// Notches per second, smoothed.
    public private(set) var velocity = 0.0

    public init(unitsPerNotch: Int, speed: Double, acceleration: Double) {
        self.unitsPerNotch = Double(max(unitsPerNotch, 1))
        self.speed = speed
        self.acceleration = acceleration
    }

    /// Distance in points for `delta` wheel units received at `time` (seconds).
    public mutating func points(delta: Int, time: Double) -> Double {
        let notches = Double(delta) / unitsPerNotch
        let sign: Double = notches >= 0 ? 1 : -1
        if let last = lastTime, time - last < 0.3, sign == lastSign {
            let dt = max(time - last, 0.004)
            let instant = abs(notches) / dt
            velocity = velocity * 0.55 + instant * 0.45
        } else {
            // A fresh start: the first notch is never accelerated.
            velocity = 0
        }
        lastTime = time
        lastSign = sign
        return notches * Self.pointsPerNotch * speed * gain
    }

    /// Multiplier for the current wheel speed: 1 for slow, deliberate scrolling, rising
    /// smoothly for fast flicks and free spinning.
    public var gain: Double {
        guard acceleration > 0 else { return 1 }
        let x = min(max((velocity - 6) / 34, 0), 1)
        return 1 + acceleration * 4.5 * pow(x, 1.35)
    }
}

/// Spreads scroll distance over time with an exponential ease-out, emitting whole points.
public struct ScrollAnimator: Sendable {
    /// Time constant of the ease-out in seconds.
    public var tau: Double
    private var remainingX = 0.0, remainingY = 0.0
    private var carryX = 0.0, carryY = 0.0

    public init(tau: Double = 0.06) {
        self.tau = tau
    }

    public var isIdle: Bool { abs(remainingX) < 0.5 && abs(remainingY) < 0.5 }

    public mutating func add(dx: Double, dy: Double) {
        // Reversing direction cancels whatever was still to come.
        if dx != 0 && remainingX * dx < 0 { remainingX = 0; carryX = 0 }
        if dy != 0 && remainingY * dy < 0 { remainingY = 0; carryY = 0 }
        remainingX += dx
        remainingY += dy
    }

    public mutating func stop() {
        remainingX = 0
        remainingY = 0
        carryX = 0
        carryY = 0
    }

    /// Advances by `dt` seconds; returns whole points to scroll now.
    public mutating func step(dt: Double) -> (dx: Int, dy: Int) {
        let f = 1 - exp(-max(dt, 0) / tau)
        func take(_ remaining: inout Double, _ carry: inout Double) -> Int {
            guard remaining != 0 else { return 0 }
            var d = remaining * f
            // Finish the tail promptly instead of creeping forever.
            if abs(remaining) < 1.5 || abs(d) < 0.35 { d = remaining }
            remaining -= d
            carry += d
            let whole = carry.rounded(.towardZero)
            carry -= whole
            return Int(whole)
        }
        let x = take(&remainingX, &carryX)
        let y = take(&remainingY, &carryY)
        if abs(remainingX) < 0.01 { remainingX = 0 }
        if abs(remainingY) < 0.01 { remainingY = 0 }
        return (x, y)
    }
}
