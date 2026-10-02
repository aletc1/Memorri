import MemorriCore
import SwiftUI
import os

/// Creates the shared services once at launch and connects them to their system adapters.
@MainActor
final class AppEnvironment {
    /// One environment for the whole app; the app delegate and the SwiftUI scene both use it.
    static let shared = AppEnvironment()

    let state = AppState()
    let screenRecording = ScreenRecordingAdapter()
    let settingsStore: any SettingsStore = UserDefaultsSettingsStore()
    let feedbackSettings: CaptureFeedbackSettings
    let ollamaSettings: OllamaSettings
    /// Knows whether the local model server and the chosen model are usable.
    let ollama: OllamaService
    let permission: PermissionMonitor
    let windows = WindowCoordinator()
    let feedback: FeedbackAdapter
    let captureService: CaptureRequestService
    let shortcuts: ShortcutAdapter
    /// `nil` when the storage could not be opened at all.
    let storage: StorageContext?
    /// The figures and clean-up shown in Settings; `nil` when the storage is unavailable.
    let storageServices: StorageServices?
    /// The background queue for the model's jobs; `nil` when the storage is unavailable.
    let analysis: AnalysisQueue?
    /// Read access to the jobs and their runs for the settings block.
    let analysisJobs: AnalysisStore?
    /// Whether new captures are analysed on their own.
    let analysisSettings: AnalysisSettings
    /// What the Analysis settings list shows; `nil` when the storage is unavailable.
    let captureOverview: CaptureOverview?
    /// The user's contexts and the context chosen for each picture; `nil` when the storage is unavailable.
    let contexts: ContextStore?
    /// The list of items and what the user can do to them; `nil` when the storage is unavailable.
    let items: ItemStore?
    let itemOperations: ItemOperations?
    /// Every operation on items, for `Undo last`; `nil` when the storage is unavailable.
    let operationLog: OperationLog?
    /// The saved cut-outs that prove items, and the writer that makes them; `nil` when the storage is unavailable.
    let evidenceStore: EvidenceStore?
    let evidenceWriter: EvidenceWriter?
    /// Reprocessing trials, their comparison and apply (spec 008).
    let reprocessing: ReprocessServices?
    /// Search over items and captures (spec 007); `nil` when the storage is unavailable.
    let search: SearchService?
    let searchIndex: SearchIndex?
    /// The floating quick-search panel.
    lazy var searchPanel = SearchPanelController(environment: self)
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "storage")

    init() {
        feedbackSettings = CaptureFeedbackSettings(store: settingsStore)
        ollamaSettings = OllamaSettings(store: settingsStore)
        ollama = OllamaService.live(settings: ollamaSettings)
        permission = PermissionMonitor(checker: screenRecording)
        feedback = FeedbackAdapter(state: state)
        let windows = self.windows
        let state = self.state
        analysisSettings = AnalysisSettings(store: settingsStore)
        let context = Self.openStorage()
        storage = context
        if let context, let store = context.store {
            let cleanup = CleanupService(paths: context.paths, store: store, files: context.files)
            let settings = StorageSettings(store: settingsStore)
            storageServices = StorageServices(
                stats: StorageStats(paths: context.paths, store: store), cleanup: cleanup, settings: settings,
                retention: RetentionService(cleanup: cleanup, settings: settings, store: settingsStore))
        } else {
            storageServices = nil
        }
        if let context, let database = context.database, let captures = context.store {
            let jobs = AnalysisStore(database: database)
            let pictures = StoredPictureProvider(paths: context.paths, store: captures)
            let testRunner = ModelTestJobRunner(
                service: ollama, store: jobs, pictures: pictures, settings: ollamaSettings, time: SystemTimeSource())
            let pipeline = AnalysisPipeline(recogniser: TiledTextRecogniser(base: VisionTextRecogniser()), model: ServiceModelChatting(service: ollama),
                                            time: SystemTimeSource())
            let reconciler = Reconciler(database: database, judge: LiveMeaningJudge(service: ollama, settings: ollamaSettings, database: database,
                                                                                   time: SystemTimeSource()))
            let evidence = EvidenceWriter(paths: context.paths, database: database, pictures: pictures)
            evidenceWriter = evidence
            evidenceStore = EvidenceStore(database: database, paths: context.paths, pictures: pictures)
            let analyseRunner = ImageAnalysisJobRunner(
                service: ollama, pipeline: pipeline, pictures: pictures, fullPictures: pictures, ocr: OCRStore(database: database),
                results: AnalysisResultStore(database: database), jobs: jobs, settings: ollamaSettings, time: SystemTimeSource(),
                contexts: ContextStore(database: database), windows: CaptureStore(database: database), reconciler: reconciler, evidence: evidence)
            let trialStore = TrialStore(database: database, paths: context.paths)
            let trialRunner = TrialJobRunner(service: ollama, pipeline: pipeline, pictures: pictures, fullPictures: pictures, ocr: OCRStore(database: database),
                                             store: trialStore, settings: ollamaSettings, time: SystemTimeSource(), windows: CaptureStore(database: database))
            reprocessing = ReprocessServices(store: trialStore, comparison: TrialComparison(database: database, reconciler: reconciler, store: trialStore),
                                             applier: TrialApplier(database: database, reconciler: reconciler, store: trialStore, evidence: evidence))
            let runner = CompositeJobRunner(runners: [
                "test": testRunner,
                TrialStore.jobKind: trialRunner,
                ImageAnalysisJobRunner.analyseKind: analyseRunner,
                ImageAnalysisJobRunner.forceKind: analyseRunner,
                ImageAnalysisJobRunner.rereadKind: analyseRunner,
            ])
            analysis = AnalysisQueue(store: jobs, runner: runner, ready: { [ollama] in await ollama.check() },
                                     settings: ollamaSettings, results: AnalysisResultStore(database: database))
            analysisJobs = jobs
            captureOverview = CaptureOverview(database: database)
            contexts = ContextStore(database: database)
            items = ItemStore(database: database)
            itemOperations = ItemOperations(database: database, reconciler: reconciler)
            operationLog = OperationLog(database: database)
            search = SearchService(database: database)
            searchIndex = SearchIndex(database: database)
        } else {
            analysis = nil
            analysisJobs = nil
            captureOverview = nil
            contexts = nil
            items = nil
            itemOperations = nil
            operationLog = nil
            evidenceStore = nil
            evidenceWriter = nil
            reprocessing = nil
            search = nil
            searchIndex = nil
        }
        captureService = CaptureRequestService(
            runner: Self.makeCaptureRunner(context: context, settingsStore: settingsStore, enqueuer: analysis, analysisSettings: analysisSettings),
            permission: permission,
            feedback: feedback,
            settings: feedbackSettings,
            onOutcome: { outcome in Task { @MainActor in state.record(outcome) } },
            onNeedsOnboarding: { Task { @MainActor in windows.show(.onboarding) } }
        )
        shortcuts = ShortcutAdapter(onCapture: { [captureService] in
            Task { await captureService.request(.shortcut) }
        })
        self.windows.contentProvider = { [unowned self] id in self.content(for: id) }
        shortcuts.onSearch = { [unowned self] in self.searchPanel.toggle() }

        Task { [state, permission] in
            for await status in await permission.statusUpdates() {
                state.permissionStatus = status
                Logger(subsystem: MemorriCore.subsystem, category: "permission")
                    .notice("permission status: \(status.rawValue, privacy: .public)")
            }
        }
        startPermissionPolling()
        startClockTick()
        let rereadSource = context?.database.map { ($0, context!.paths) }
        Task { [ollama, analysis, storage, settingsStore] in
            // The recommended model is chosen without opening Settings (FR-006), then one check,
            // and only then does the queue start, so its first look at the server sees the choice.
            await ollama.applyDefaultModelIfNeeded()
            await ollama.check()
            await analysis?.start()
            // After an update that changes how pictures are read, the library is read again in the background, behind new captures (spec 011).
            if let rereadSource, let analysis,
               let added = try? LibraryReread(database: rereadSource.0, settings: settingsStore, paths: rereadSource.1).enqueueIfNeeded(now: Date()), added > 0 {
                await analysis.jobsAdded()
            }
            #if DEBUG
            await DebugIngest.runIfRequested(storage: storage, analysis: analysis, settingsStore: settingsStore)
            if let text = DebugIngest.searchTextIfRequested() { await MainActor.run { [weak self] in self?.searchPanel.show(prefill: text) } }
            #endif
        }
        followAnalysisProgress()
        followReviewCount()
        prepareSearchIndex()
        // Sightings from before evidence existed get their cut-outs a few at a time, newest first.
        if let evidenceWriter { Task.detached(priority: .utility) { _ = await evidenceWriter.backfill(limit: 200) } }
        if let storage { StartupAlerts.showIfNeeded(for: storage) }
        startRetention()
    }

    /// Builds the search index in the background when it is missing or outdated (spec 007); the panel says it is being prepared meanwhile.
    private func prepareSearchIndex() {
        guard let searchIndex else { return }
        let state = self.state
        if let current = try? searchIndex.state() { state.searchState = current }
        Task.detached(priority: .utility) {
            try? await searchIndex.prepare { progress in Task { @MainActor in state.searchState = progress } }
            let final = (try? searchIndex.state()) ?? .ready          // the last word, whatever order the progress updates arrived in
            await MainActor.run { state.searchState = final }
        }
    }

    /// Keeps the menu's `Inbox (N)` current.
    private func followReviewCount() {
        guard let items else { return }
        let stream = items.observeReviewCount()
        Task { [state] in
            for await count in stream { state.reviewCount = count }
        }
    }

    /// Opens the Items window on a scope (the menu's `Inbox` opens it on the Inbox).
    func showItems(scope: ItemScope) {
        state.itemsScopeRequest = AppState.ScopeRequest(scope: scope)
        windows.show(.items)
    }

    /// Opens the Items window with `id` selected, on the filter that lists it (a search result was chosen).
    func showItem(id: String, status: ItemStatus) {
        state.itemsScopeRequest = AppState.ScopeRequest(scope: .all, itemID: id, status: status)
        windows.show(.items)
    }

    /// Opens the capture window on a capture a search result named, with the matching lines outlined.
    func showCapture(_ hit: CaptureHit, query: SearchQuery) {
        let when = SearchPanelModel.dateText(hit.capturedAt)
        let header = [when, hit.displayName, SearchPanelModel.windowText(app: hit.windowApp, title: hit.windowTitle)].compactMap { $0 }.joined(separator: " · ")
        state.captureRequest = CaptureRequest(imageID: hit.id, query: query, header: header)
        windows.show(.capture)
    }

    /// Keeps the menu line and the settings block current.
    private func followAnalysisProgress() {
        guard let analysis else { return }
        Task { [state] in
            for await progress in await analysis.progressUpdates() {
                state.analysisProgress = progress
            }
        }
    }

    /// Queues the model test on the newest capture, or on the built-in sample when there is none.
    /// Returns the job and whether the newest capture was used; `nil` when the queue is unavailable.
    func enqueueModelTest() async -> (jobID: String, usedNewestCapture: Bool)? {
        guard let analysis else { return nil }
        let newest = (try? storage?.store?.newestImageID()) ?? nil
        guard let id = try? await analysis.enqueueTest(imageID: newest) else { return nil }
        return (id, newest != nil)
    }

    /// Adds every stored picture that was never analysed to the queue, oldest first. Returns how many.
    @discardableResult
    func analyseStoredCaptures() async -> Int { await analysis?.enqueueBacklog() ?? 0 }

    /// The installed models that can read pictures, for the trial's model picker; nil when the server cannot be reached.
    func visionModels() async -> [String]? {
        guard let models = try? await ollama.client().models() else { return nil }
        return models.filter(\.readsImages).map(\.name).sorted()
    }

    /// Starts a trial over every stored capture with the model; says why when it cannot (spec 008, FR-014).
    func startTrial(model: String) async -> Result<TrialRecord, ReprocessError> {
        guard let reprocessing else { return .failure(ReprocessError("The capture storage is not available.")) }
        guard let installed = await visionModels() else { return .failure(ReprocessError("The Ollama server cannot be reached.")) }
        guard installed.contains(model) else { return .failure(ReprocessError("\(model) is not installed or cannot read pictures.")) }
        do {
            let trial = try reprocessing.store.create(model: model, promptVersion: ExtractionPrompts.summary, think: ollamaSettings.think.rawValue, now: Date())
            await analysis?.jobsAdded()
            return .success(trial)
        } catch TrialError.nothingToRead {
            return .failure(ReprocessError("There are no analysed captures to read again."))
        } catch {
            return .failure(ReprocessError("The trial could not be started."))
        }
    }

    func resumeTrial(_ id: String) async {
        try? reprocessing?.store.resume(id, now: Date())
        await analysis?.jobsAdded()
    }

    /// How many analysed captures were read with another model or prompt than the current ones.
    func outOfDateCaptures() -> Int {
        (try? reprocessing?.store.outOfDateCount(model: ollamaSettings.model, currentPromptVersions: ExtractionPrompts.currentVersions)) ?? 0
    }

    /// The user picks another context for a picture: its findings are matched again among the items of that context.
    func changeContext(imageID: String, to contextID: String?) async {
        _ = try? await itemOperations?.changeContext(imageID: imageID, to: contextID)
    }

    /// Asks for a fresh analysis of one picture.
    @discardableResult
    func reanalyse(imageID: String) async -> Bool { await analysis?.reanalyse(imageID: imageID) ?? false }

    /// How many stored pictures have no analysis and no pending job.
    func unanalysedCount() -> Int {
        guard let database = storage?.database else { return 0 }
        return (try? AnalysisResultStore(database: database).unanalysedImageIDs().count) ?? 0
    }

    /// The retention policy is applied at start and then checked every hour; it runs about daily.
    private func startRetention() {
        guard let retention = storageServices?.retention else { return }
        Task.detached {
            _ = try? retention.runNow(now: Date())
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                _ = try? retention.runIfDue(now: Date())
            }
        }
    }

    /// Opens the storage. `nil` when it cannot be opened at all.
    private static func openStorage() -> StorageContext? {
        do { return try StorageBootstrap.start(paths: try AppPaths.standard()) }
        catch {
            logger.error("storage unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The capture pipeline, which queues each new capture for analysis when the switch is on. When the storage cannot
    /// be used, capturing reports why instead of crashing.
    private static func makeCaptureRunner(context: StorageContext?, settingsStore: any SettingsStore, enqueuer: AnalysisQueue?,
                                          analysisSettings: AnalysisSettings) -> any CaptureRunning {
        guard let context else { return UnavailableCaptureRunner(reason: "could not open the capture storage") }
        guard let store = context.store else {
            return UnavailableCaptureRunner(reason: context.capturingDisabledReason ?? "could not open the capture storage")
        }
        return CapturePipeline(capturer: ScreenCaptureKitCapturer(), encoder: HEICImageEncoder(), disk: DiskSpaceAdapter(),
                               files: context.files, store: store, paths: context.paths,
                               settings: StorageSettings(store: settingsStore), enqueuer: enqueuer, analysisSettings: analysisSettings)
    }

    private func startClockTick() {
        Task { @MainActor [state] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                state.now = Date()
            }
        }
    }

    /// Follows the permission for as long as the app runs. A running process keeps the answer it
    /// had at launch and cannot see a grant or a revocation made afterwards, so every 2 seconds
    /// (and whenever the app becomes active) a freshly started copy of the app is asked what macOS
    /// says now. Each probe costs about 20 ms and a millisecond of CPU.
    private func startPermissionPolling() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.probePermission()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.probePermission() }
        }
    }

    private func probePermission() async {
        guard let granted = await screenRecording.isGrantedInFreshProcess() else { return }
        await permission.observeFreshProcess(granted: granted)
    }

    func checkPermission() {
        Task { await probePermission() }
    }

    /// Asks macOS for access first (shows the prompt and adds the app to the Screen Recording
    /// list, spike R5), then opens the System Settings pane.
    func openScreenRecordingSettings() {
        let granted = screenRecording.requestAccess()
        Logger(subsystem: MemorriCore.subsystem, category: "permission")
            .notice("requestAccess returned \(granted, privacy: .public)")
        // Give the system prompt a moment to appear before the pane takes the focus.
        Task { [screenRecording] in
            try? await Task.sleep(for: .seconds(1.5))
            screenRecording.openSystemSettings()
        }
    }

    /// Starts a new copy once this one has quit, so the single-instance check in the new copy
    /// does not see this one still running. Waits for this process to exit (at most 10 seconds).
    func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let script = "i=0; while kill -0 \"$2\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; /usr/bin/open -n \"$1\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", path, pid]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    func requestCapture(_ trigger: CaptureTrigger) {
        Task { [captureService] in await captureService.request(trigger) }
    }

    /// The SwiftUI content of each window.
    private func content(for id: WindowID) -> AnyView {
        switch id {
        case .items: AnyView(ItemsView(environment: self))
        case .capture: AnyView(CaptureViewerView(environment: self))
        case .settings: AnyView(SettingsView(environment: self))
        case .onboarding: AnyView(OnboardingView(environment: self))
        }
    }
}

/// What the Reprocess section needs of the core (spec 008).
struct ReprocessServices {
    let store: TrialStore
    let comparison: TrialComparison
    let applier: TrialApplier
}

struct ReprocessError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
