#if DEBUG
import Foundation
import MemorriCore
import os

/// Debug builds only. `--ingest-picture <png>` (with optional `--ingest-windows <json>`) stores that picture as if it had
/// been captured and queues its analysis, so a synthetic picture can go through the real pipeline without the screen.
/// `<json>` is either a list of windows or a golden case's `meta.json`. `--ingest-case <folder>` (repeatable) stores the
/// `screenshot.png` of a golden case with the windows of its `meta.json`. Compiled out of Release builds.
enum DebugIngest {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "extraction")

    private static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func values(after flag: String) -> [String] {
        let arguments = CommandLine.arguments
        return arguments.indices.filter { arguments[$0] == flag && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
    }

    static func runIfRequested(storage: StorageContext?, analysis: AnalysisQueue?, settingsStore: any SettingsStore) async {
        var requests: [(picture: String, windows: String?)] = []
        if let picture = value(after: "--ingest-picture") { requests.append((picture, value(after: "--ingest-windows"))) }
        for folder in values(after: "--ingest-case") {
            requests.append((folder + "/" + GoldenCase.pictureFile, folder + "/meta.json"))
        }
        guard !requests.isEmpty else { return }
        guard let context = storage, let store = context.store, let analysis else {
            logger.error("ingest refused: storage unavailable")
            return
        }
        let ingest = PictureIngest(paths: context.paths, files: context.files, store: store,
                                   modelLongEdge: StorageSettings(store: settingsStore).modelLongEdge)
        for request in requests {
            do {
                let png = try Data(contentsOf: URL(fileURLWithPath: request.picture))
                let windows = try request.windows.map(loadWindows) ?? []
                let imageID = try ingest.store(png: png, windows: windows)
                try await analysis.enqueue(kind: ImageAnalysisJobRunner.analyseKind, imageID: imageID)
                logger.info("ingested picture image=\(imageID, privacy: .public) windows=\(windows.count)")
            } catch {
                logger.error("ingest failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func loadWindows(_ path: String) throws -> [WindowInfo] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let windows: [GoldenWindow]
        if let list = try? decoder.decode([GoldenWindow].self, from: data) { windows = list }
        else { windows = try decoder.decode(GoldenMeta.self, from: data).windows }
        return windows.map { window in
            let f = window.frame
            return WindowInfo(appName: window.app, bundleID: window.bundleID, title: window.title,
                              frame: PixelBox(x: f.count > 0 ? f[0] : 0, y: f.count > 1 ? f[1] : 0,
                                              width: f.count > 2 ? f[2] : 0, height: f.count > 3 ? f[3] : 0),
                              stack: window.stack)
        }
    }
}
#endif
