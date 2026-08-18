import Foundation
import OSLog

/// Scheduled Routine configuration
struct Routine: Codable, Identifiable {
    var id: UUID
    var name: String
    var prompts: [String]           // Multiple prompts separated by &&
    var intervalSeconds: TimeInterval
    var targetTerminalId: UUID
    var isActive: Bool
    var createdAt: Date

    init(id: UUID = UUID(), name: String, prompt: String, intervalSeconds: TimeInterval, targetTerminalId: UUID) {
        self.id = id
        self.name = name
        // Parsing && delimiters
        self.prompts = prompt.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
        self.intervalSeconds = intervalSeconds
        self.targetTerminalId = targetTerminalId
        self.isActive = true
        self.createdAt = Date()
    }
}

struct RoutinesContainer: Codable {
    var routines: [Routine]
    init() { self.routines = [] }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Compatible with two types of field names: routines for the new format, payload for the old format (Maestri native)
        if let r = try? container.decode([Routine].self, forKey: .routines) {
            self.routines = r
        } else if let p = try? container.decode([Routine].self, forKey: .payload) {
            self.routines = p
        } else {
            self.routines = []
        }
    }
    private enum CodingKeys: String, CodingKey { case routines, payload }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(routines, forKey: .payload)  // Use payload consistent with Maestri format when writing
    }
}

/// Routine timing scheduler (FR56-58)
/// - Support chain prompts (separated by &&, the next one will be sent after the previous one is completed)
/// - Active Routine displays green pulsing indicator
@MainActor
final class RoutineScheduler {
    static let shared = RoutineScheduler()
    private let logger = Logger.make(category: "RoutineScheduler")
    private var timers: [UUID: Timer] = [:]
    private(set) var routines: [Routine] = []
    private let pm = PersistenceManager.shared

    private init() {}

    // MARK: - Persistence

    func loadRoutines() throws {
        let container = (try? pm.load(RoutinesContainer.self, from: pm.routinesURL)) ?? RoutinesContainer()
        routines = container.routines
        // Restore active routine
        for routine in routines where routine.isActive {
            startTimer(for: routine)
        }
    }

    func saveRoutines() throws {
        var container = RoutinesContainer()
        container.routines = routines
        try pm.saveSync(container, to: pm.routinesURL)
    }

    // MARK: - Routine management

    func addRoutine(_ routine: Routine) throws {
        routines.append(routine)
        if routine.isActive { startTimer(for: routine) }
        try saveRoutines()
    }

    func removeRoutine(id: UUID) throws {
        stopTimer(for: id)
        routines.removeAll { $0.id == id }
        try saveRoutines()
    }

    func pause(id: UUID) {
        stopTimer(for: id)
        if let idx = routines.firstIndex(where: { $0.id == id }) {
            routines[idx].isActive = false
        }
    }

    func resume(id: UUID) {
        if let idx = routines.firstIndex(where: { $0.id == id }) {
            routines[idx].isActive = true
            startTimer(for: routines[idx])
        }
    }

    // MARK: - Timer

    private func startTimer(for routine: Routine) {
        let timer = Timer.scheduledTimer(withTimeInterval: routine.intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.executeRoutine(routine)
            }
        }
        timers[routine.id] = timer
        logger.debug("Routine '\(routine.name)' started, interval: \(routine.intervalSeconds)s")
    }

    private func stopTimer(for id: UUID) {
        timers[id]?.invalidate()
        timers.removeValue(forKey: id)
    }

    /// Stop all Routine timers (called when the application exits to avoid Timer callbacks from blocking the main thread)
    func stopAllTimers() {
        for (_, timer) in timers { timer.invalidate() }
        timers.removeAll()
    }

    // MARK: - Execute (chain: wait for the Agent to be idle before sending the next one)

    private func executeRoutine(_ routine: Routine) async {
        logger.debug("Executing routine '\(routine.name)' — \(routine.prompts.count) prompt(s)")
        let tm = TerminalManager.shared
        for (i, prompt) in routine.prompts.enumerated() {
            guard let session = tm.terminals[routine.targetTerminalId] else { break }
            tm.writeLine(to: routine.targetTerminalId, text: prompt)
            logger.debug("Routine '\(routine.name)' sent prompt \(i+1)/\(routine.prompts.count)")

            // Wait for Agent to become idle (5 minutes maximum)
            if i < routine.prompts.count - 1 {
                await waitForIdle(session: session, timeout: 300)
            }
        }
    }

    /// Waiting for TerminalSession to return to idle state
    private func waitForIdle(session: TerminalSession, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        // Wait for the Agent to start responding (up to 3s)
        try? await Task.sleep(for: .seconds(3))
        // Then wait for Agent to complete (output is static)
        while Date() < deadline {
            if session.isIdle { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        logger.warning("Routine: Agent idle timeout after \(timeout)s, proceeding anyway")
    }
}
