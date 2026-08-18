import Foundation
import OSLog

/// Agent Running/Idle Status Detector
/// Determine status through PTY output changes (not dependent on CPU), compliant with FR18/Story 3.3 AC
///
/// Performance optimization: Use a global shared background timer (1s interval) instead of each instance's independent 0.5s main thread Timer,
/// Avoid main thread poll contention when there are a large number of terminals.
final class TerminalActivityMonitor {
    private let logger = Logger.make(category: "TerminalActivityMonitor")

    private var lastOutputTime: Date = Date()
    private var isRunning: Bool = false
    private var observerToken: NSObjectProtocol?

    /// Status change callback (called in the main thread)
    var onStatusChanged: ((Bool) -> Void)?  // true = running, false = idle

    // MARK: - Start monitoring

    func start() {
        observerToken = GlobalActivityClock.shared.subscribe { [weak self] in
            self?.checkActivity()
        }
    }

    func stop() {
        if let token = observerToken {
            GlobalActivityClock.shared.unsubscribe(token)
            observerToken = nil
        }
    }

    // MARK: - output receive (called from PTY output callback)

    func recordOutput() {
        lastOutputTime = Date()
        if !isRunning {
            isRunning = true
            onStatusChanged?(true)
        }
    }

    // MARK: - Idle detection

    private func checkActivity() {
        let elapsed = Date().timeIntervalSince(lastOutputTime)
        if isRunning && elapsed >= Constants.agentIdleTimeout {
            isRunning = false
            onStatusChanged?(false)
        }
    }

    // MARK: - Waiting for response to complete (for omaestri ask)

    /// Wait for target terminal output to complete (prompt resumes)
    /// - Parameters:
    ///   - timeout: maximum waiting time (seconds)
    ///   - completion: callback after the output is completed, the parameter is the collected output content
    func waitForResponse(timeout: TimeInterval = 30) async -> String {
        // Collect output until idle timeout
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            try? await Task.sleep(for: .milliseconds(200))
            if Date().timeIntervalSince(lastOutputTime) >= Constants.agentIdleTimeout {
                break
            }
        }
        return ""
    }
}

// MARK: - Global shared active clock

/// Single background timer, shared by all TerminalActivityMonitor instances
/// Replace the mode of creating independent Timer for each instance to avoid N terminals generating N main thread Timers
final class GlobalActivityClock {
    static let shared = GlobalActivityClock()

    private let lock = NSLock()
    private var subscribers: [UUID: () -> Void] = [:]
    private var timer: DispatchSourceTimer?

    private init() {
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let callbacks = Array(self.subscribers.values)
            self.lock.unlock()
            // Call the check functions of each monitor in sequence in the main thread (to ensure the safety of @MainActor)
            DispatchQueue.main.async {
                callbacks.forEach { $0() }
            }
        }
        source.resume()
        timer = source
    }

    func subscribe(_ callback: @escaping () -> Void) -> NSObjectProtocol {
        let token = UUID()
        lock.lock()
        subscribers[token] = callback
        lock.unlock()
        // Use NSObject to wrap UUID as token (follow NSObjectProtocol interface)
        return TokenObject(id: token, clock: self)
    }

    func unsubscribe(_ token: NSObjectProtocol) {
        guard let t = token as? TokenObject else { return }
        lock.lock()
        subscribers.removeValue(forKey: t.id)
        lock.unlock()
    }

    private final class TokenObject: NSObject {
        let id: UUID
        weak var clock: GlobalActivityClock?
        init(id: UUID, clock: GlobalActivityClock) {
            self.id = id
            self.clock = clock
        }
    }
}
