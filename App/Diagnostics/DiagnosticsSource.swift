import Foundation
import MemorriCore
import OSLog

/// Gathers a diagnostic report for Settings > Diagnostics (spec 010): the library's figures, the permission states and this process's recent log.
@MainActor
struct DiagnosticsSource {
    let environment: AppEnvironment

    func report() async -> DiagnosticsReport? {
        guard let storage = environment.storage, let database = storage.database else { return nil }
        let permissions = await permissionStates()
        let log = await Self.recentLog()
        let facts = AppFacts(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                             build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                             system: ProcessInfo.processInfo.operatingSystemVersionString)
        let paths = storage.paths
        return await Task.detached {
            let gatherer = DiagnosticsGatherer(database: database, paths: paths)
            guard let inputs = try? gatherer.inputs(app: facts, permissions: permissions, now: Date()) else { return nil }
            return DiagnosticsReport.build(inputs, log: log, sensitive: (try? gatherer.sensitiveStrings()) ?? [])
        }.value
    }

    private func permissionStates() async -> [PermissionState] {
        func text(_ access: SyncAccess) -> String { access == .allowed ? "allowed" : (access == .denied ? "not allowed" : "not asked yet") }
        let screen = environment.state.permissionStatus == .granted ? "allowed" : "not allowed"
        var states = [PermissionState(name: "Screen Recording", state: screen)]
        if let sync = environment.sync {
            states.append(PermissionState(name: "Calendar", state: text(sync.eventKit.access(for: .event))))
            states.append(PermissionState(name: "Reminders", state: text(sync.eventKit.access(for: .reminder))))
        }
        if let centre = environment.notifications?.centre { states.append(PermissionState(name: "Notifications", state: text(await centre.permission()))) }
        return states
    }

    /// The last 200 lines this process wrote to the log in the last hour, from Memorri's own subsystem.
    nonisolated static func recentLog() async -> [LogLine] {
        await Task.detached {
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
            let start = store.position(date: Date().addingTimeInterval(-3600))
            let predicate = NSPredicate(format: "subsystem == %@", MemorriCore.subsystem)
            guard let entries = try? store.getEntries(at: start, matching: predicate) else { return [] }
            let lines = entries.compactMap { $0 as? OSLogEntryLog }.map { entry -> LogLine in
                let level: String
                switch entry.level {
                case .error, .fault: level = "error"
                case .notice: level = "notice"
                default: level = "info"
                }
                return LogLine(category: entry.category, level: level, text: entry.composedMessage, date: entry.date)
            }
            return Array(lines.suffix(200))
        }.value
    }
}
