import Foundation
import CoreGraphics

// MARK: - Rope (physical state of a single rope)

/// Single physics rope: stores 21 particle positions and previous frame position (required for Verlet integration)
final class Rope {
    let id: UUID
    /// The position of each particle in the current frame (canvas coordinates)
    var points: [CGPoint]
    /// Position of each particle in the previous frame (Verlet integral is used to calculate velocity)
    var prevPoints: [CGPoint]
    /// Anchor points at both ends of the rope (connected to the center of the node)
    var anchorA: CGPoint
    var anchorB: CGPoint
    /// Rest length of rope segment (ideal distance between every two adjacent mass points)
    var segmentLength: CGFloat

    init(id: UUID, anchorA: CGPoint, anchorB: CGPoint, pointCount: Int = Constants.ropeControlPointCount) {
        self.id = id
        self.anchorA = anchorA
        self.anchorB = anchorB

        // Initialize to straight line equalization
        var pts: [CGPoint] = []
        for i in 0..<pointCount {
            let t = CGFloat(i) / CGFloat(pointCount - 1)
            pts.append(CGPoint(
                x: anchorA.x + (anchorB.x - anchorA.x) * t,
                y: anchorA.y + (anchorB.y - anchorA.y) * t
            ))
        }
        self.points = pts
        self.prevPoints = pts

        // Rope segment length = total rope length / (points - 1), total rope length = straight line distance * bendRatio
        let dist = hypot(anchorB.x - anchorA.x, anchorB.y - anchorA.y)
        let bendRatio = (Constants.ropeBendRatioMin + Constants.ropeBendRatioMax) / 2.0
        let ropeLength = max(dist * bendRatio, 20.0)  // Minimum rope length, avoid zero length
        self.segmentLength = ropeLength / CGFloat(pointCount - 1)
    }

    /// Reset rope to new end position (straight line initialization)
    func reset(anchorA: CGPoint, anchorB: CGPoint) {
        self.anchorA = anchorA
        self.anchorB = anchorB
        let count = points.count
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let pt = CGPoint(
                x: anchorA.x + (anchorB.x - anchorA.x) * t,
                y: anchorA.y + (anchorB.y - anchorA.y) * t
            )
            points[i] = pt
            prevPoints[i] = pt
        }
        updateSegmentLength()
    }

    /// Recalculate the length of the rope segment after updating the endpoint (maintaining the natural sagging ratio)
    func updateSegmentLength() {
        let dist = hypot(anchorB.x - anchorA.x, anchorB.y - anchorA.y)
        let bendRatio = (Constants.ropeBendRatioMin + Constants.ropeBendRatioMax) / 2.0
        let ropeLength = max(dist * bendRatio, 20.0)
        segmentLength = ropeLength / CGFloat(points.count - 1)
    }
}

// MARK: - RopeSimulation (physics simulation engine)

/// Catenary physical simulator (compared to Maestri RopeSimulation)
/// - Verlet integral + spring distance constraint + gravity
/// - Timer drives 60fps physical tick (Timer hangs in RunLoop.main, callback is always in the main thread)
/// - Auto sleep: Stop simulation when motion amount < threshold, save CPU
/// - Wakeup: Restart simulation when endpoint position changes
///
/// Threading model: All accesses are on the main thread, @MainActor enables the compiler to statically verify this constraint.
@MainActor
final class RopeSimulation {
    static let controlPointCount = Constants.ropeControlPointCount

    // MARK: - Physical parameters

    /// Gravity acceleration (canvas coordinate units/frame²), Y+ down
    private static let gravity: CGFloat = 0.8
    /// Damping coefficient (0~1, the larger the faster the decay, 0.98 = 2% speed loss per frame)
    private static let damping: CGFloat = 0.98
    /// Number of distance constraint iterations (the more, the more rigid it is, 3 to 5 times is better)
    private static let constraintIterations = 5
    /// Sleep threshold: Enter sleep when the total movement of all particles in a single frame < this value
    private static let sleepThreshold: CGFloat = 0.1
    /// Wake-up threshold: wake when endpoint offset > this value
    private static let wakeThreshold: CGFloat = 0.5
    /// Physical tick interval (seconds), about 60fps
    private static let tickInterval: TimeInterval = 1.0 / 60.0

    // MARK: - Status

    /// All ropes participating in the physics simulation
    private(set) var ropes: [UUID: Rope] = [:]
    /// Physical timer (nonisolated for deinit access)
    nonisolated(unsafe) private var timer: Timer?
    /// Whether in sleep state (all ropes are still)
    private(set) var isSleeping: Bool = true
    /// Total motion amount of current frame
    private var totalMovement: CGFloat = 0
    /// Sleep callback (called after physical stop, used to persist ropePoints)
    var onSleep: (([UUID: [CGPoint]]) -> Void)?
    /// Each frame update callback (used to update the rendering layer in real time)
    var onTick: (([UUID: [CGPoint]]) -> Void)?

    /// Cached allPoints dictionary (avoid allocating new dictionary every frame, only rebuild keys when number of ropes changes)
    private var _cachedAllPoints: [UUID: [CGPoint]] = [:]
    private var _cachedAllPointsDirty: Bool = true

    /// Multiplexed pre-constraint position buffer (avoids allocating new arrays per frame per rope)
    private var _preConstraintBuffer: [CGPoint] = []

    // MARK: - Life cycle

    deinit {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Public interface

    /// Add rope (called when creating connection)
    func addRope(id: UUID, anchorA: CGPoint, anchorB: CGPoint) {
        let rope = Rope(id: id, anchorA: anchorA, anchorB: anchorB)
        ropes[id] = rope
        _cachedAllPointsDirty = true
        wake()
    }

    /// Restore rope from existing control point (when loading workspace)
    func addRope(id: UUID, anchorA: CGPoint, anchorB: CGPoint, existingPoints: [CGPoint]) {
        let rope = Rope(id: id, anchorA: anchorA, anchorB: anchorB)
        if existingPoints.count == rope.points.count {
            rope.points = existingPoints
            rope.prevPoints = existingPoints
        }
        ropes[id] = rope
        // Do not wake up immediately on recovery (assumes steady state already)
    }

    /// Remove rope (called when disconnecting)
    func removeRope(id: UUID) {
        ropes.removeValue(forKey: id)
        _cachedAllPointsDirty = true
        if ropes.isEmpty {
            sleep()
        }
    }

    /// Update rope endpoint (called in real time when the node is dragged)
    /// Wake up physics simulation when endpoint changes exceed threshold
    func updateAnchors(id: UUID, anchorA: CGPoint, anchorB: CGPoint) {
        guard let rope = ropes[id] else { return }
        let movedA = hypot(rope.anchorA.x - anchorA.x, rope.anchorA.y - anchorA.y)
        let movedB = hypot(rope.anchorB.x - anchorB.x, rope.anchorB.y - anchorB.y)

        rope.anchorA = anchorA
        rope.anchorB = anchorB
        // Immediately synchronize the position of the first and last particles to the new anchor point (make sure the endpoints are close to the edge of the node when rendering)
        rope.points[0] = anchorA
        rope.prevPoints[0] = anchorA
        rope.points[rope.points.count - 1] = anchorB
        rope.prevPoints[rope.points.count - 1] = anchorB
        rope.updateSegmentLength()

        // Wake up physics simulation when endpoint moves
        if movedA > Self.wakeThreshold || movedB > Self.wakeThreshold {
            wake()
        }
    }

    /// Batch update the endpoints of multiple ropes (efficient path: when node dragging affects multiple connections)
    func updateAnchors(updates: [(id: UUID, anchorA: CGPoint, anchorB: CGPoint)]) {
        var needWake = false
        for update in updates {
            guard let rope = ropes[update.id] else { continue }
            let movedA = hypot(rope.anchorA.x - update.anchorA.x, rope.anchorA.y - update.anchorA.y)
            let movedB = hypot(rope.anchorB.x - update.anchorB.x, rope.anchorB.y - update.anchorB.y)
            rope.anchorA = update.anchorA
            rope.anchorB = update.anchorB
            // Immediately synchronize the head and tail particle positions to the new anchor point
            rope.points[0] = update.anchorA
            rope.prevPoints[0] = update.anchorA
            rope.points[rope.points.count - 1] = update.anchorB
            rope.prevPoints[rope.points.count - 1] = update.anchorB
            rope.updateSegmentLength()
            if movedA > Self.wakeThreshold || movedB > Self.wakeThreshold {
                needWake = true
            }
        }
        if needWake { wake() }
    }

    /// Get the current control point of the specified rope (for rendering)
    func points(for id: UUID) -> [CGPoint]? {
        ropes[id]?.points
    }

    /// Get the current control points of all ropes (reuse internal cache dictionaries to avoid allocating new dictionaries every frame)
    func allPoints() -> [UUID: [CGPoint]] {
        if _cachedAllPointsDirty {
            _cachedAllPoints.removeAll(keepingCapacity: true)
            for (id, rope) in ropes {
                _cachedAllPoints[id] = rope.points
            }
            _cachedAllPointsDirty = false
        } else {
            // The number of ropes has not changed, only the point position reference of each rope is updated.
            for (id, rope) in ropes {
                _cachedAllPoints[id] = rope.points
            }
        }
        return _cachedAllPoints
    }

    /// Forced wake-up (can be called externally when needed, such as the connection has just been created)
    func wake() {
        guard isSleeping else { return }
        isSleeping = false
        startTimer()
    }

    /// Force stop all simulations
    func stopAll() {
        sleep()
        ropes.removeAll()
    }

    // MARK: - Static calculation (for scenes that do not require animation, such as screenshots/initialization)

    /// Static calculation of catenary control points (no physical animation, instant return)
    /// Used for: screenshot rendering, temporary connection (drag and drop creation)
    ///
    /// - Important: The sag direction is fixed to Y+ (assuming isFlipped = true, i.e. Y-axis downward).
    ///   Droop needs to be negated if used in non-flipped coordinate systems.
    static func computeStaticCatenary(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let count = controlPointCount
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dist = hypot(dx, dy)

        let bendRatio = (Constants.ropeBendRatioMin + Constants.ropeBendRatioMax) / 2.0
        let sag = dist * (bendRatio - 1.0) * 1.5  // Natural sagging range

        guard dist > 1 else {
            return Array(repeating: start, count: count)
        }

        return (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            let x = start.x + dx * t
            let y = start.y + dy * t
            // Parabolic sag: 4*sag*t*(1-t) has a maximum value of sag at t=0.5
            let droop = 4.0 * sag * t * (1.0 - t)
            return CGPoint(x: x, y: y + droop)
        }
    }

    // MARK: - Serialization

    /// Serialize control point array to [[Double]] format (for workspace.json)
    func serialize(_ points: [CGPoint]) -> [[Double]] {
        points.map { [Double($0.x), Double($0.y)] }
    }

    /// Deserializing from [[Double]]
    func deserialize(_ raw: [[Double]]) -> [CGPoint] {
        raw.compactMap { arr in
            guard arr.count >= 2 else { return nil }
            return CGPoint(x: arr[0], y: arr[1])
        }
    }

    // MARK: - Physics simulation core

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func sleep() {
        isSleeping = true
        stopTimer()
        // Notify external persistence of current status
        onSleep?(allPoints())
    }

    /// One frame of physical simulation
    private func tick() {
        totalMovement = 0

        for (_, rope) in ropes {
            simulateRope(rope)
        }

        // Notify rendering layer of updates
        onTick?(allPoints())

        // Check if sleep can be entered
        if totalMovement < Self.sleepThreshold {
            sleep()
        }
    }

    /// Physical simulation steps of a single rope
    private func simulateRope(_ rope: Rope) {
        let count = rope.points.count
        guard count >= 2 else { return }

        // --- Step 1: Record the position before restraint (used in Step 4 to accurately calculate the amount of motion) ---
        // Reuse _preConstraintBuffer to avoid allocating new arrays per rope per frame
        if _preConstraintBuffer.count != count {
            _preConstraintBuffer = rope.points
        } else {
            for i in 0..<count {
                _preConstraintBuffer[i] = rope.points[i]
            }
        }
        let preConstraintPositions = _preConstraintBuffer

        // --- Step 2: Verlet integration (displacement = current position - previous frame position + acceleration) ---
        for i in 1..<(count - 1) {
            let current = rope.points[i]
            let prev = rope.prevPoints[i]

            // Speed = Current - Previous Frame (Verlet Implicit Speed)
            let vx = (current.x - prev.x) * Self.damping
            let vy = (current.y - prev.y) * Self.damping

            // New position = current + velocity + gravity
            let newX = current.x + vx
            let newY = current.y + vy + Self.gravity

            rope.prevPoints[i] = current
            rope.points[i] = CGPoint(x: newX, y: newY)
        }

        // --- Step 3: Fixed endpoint (anchored to node center) ---
        rope.points[0] = rope.anchorA
        rope.prevPoints[0] = rope.anchorA
        rope.points[count - 1] = rope.anchorB
        rope.prevPoints[count - 1] = rope.anchorB

        // --- Step 4: Distance constraint (spring, maintain distance between adjacent particles = segmentLength) ---
        for _ in 0..<Self.constraintIterations {
            applyDistanceConstraints(rope)
            // Repin endpoints after each iteration
            rope.points[0] = rope.anchorA
            rope.points[count - 1] = rope.anchorB
        }

        // --- Step 5: Accumulated motion amount (final position after constraints vs starting position of this frame) ---
        // This accurately reflects the actual distance moved by each particle in this frame.
        for i in 1..<(count - 1) {
            let dx = rope.points[i].x - preConstraintPositions[i].x
            let dy = rope.points[i].y - preConstraintPositions[i].y
            totalMovement += abs(dx) + abs(dy)
        }
    }

    /// Distance constraint: Jakobsen method
    /// Traverse adjacent pairs of particles and push/pull them to the desired distance
    private func applyDistanceConstraints(_ rope: Rope) {
        let count = rope.points.count
        let restLength = rope.segmentLength

        for i in 0..<(count - 1) {
            let p1 = rope.points[i]
            let p2 = rope.points[i + 1]

            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let dist = hypot(dx, dy)

            guard dist > 0.001 else { continue }

            let diff = (restLength - dist) / dist
            let offsetX = dx * diff * 0.5
            let offsetY = dy * diff * 0.5

            // Endpoint does not move (judged by i==0 and i==count-2)
            if i != 0 {
                rope.points[i] = CGPoint(x: p1.x - offsetX, y: p1.y - offsetY)
            }
            if i + 1 != count - 1 {
                rope.points[i + 1] = CGPoint(x: p2.x + offsetX, y: p2.y + offsetY)
            }
        }
    }

    // MARK: - Old interface compatible (for use by CanvasNodeRenderer in scenes without animation)

    /// Compute catenary control points (static, no physics animation)
    /// This method is reserved for compatibility with callers that do not require animation
    func compute(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        Self.computeStaticCatenary(from: start, to: end)
    }
}
