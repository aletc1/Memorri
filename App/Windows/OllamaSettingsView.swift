import MemorriCore
import SwiftUI

/// Settings → Ollama (contracts/ui-contract.md): the connection to the local model server.
struct OllamaSettingsView: View {
    let environment: AppEnvironment

    @State private var addressText = ""
    @State private var addressMessage: String?
    @State private var status: ServerStatus = .unchecked
    @State private var isChecking = false
    @State private var models: ModelList?
    @State private var modelsFailed = false
    @State private var chosenModel: String?
    @State private var testNote: String?
    @State private var testLine: String?
    @State private var isTesting = false
    @State private var failures: [AnalysisJobRecord] = []

    var body: some View {
        ScrollView {
            content.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            addressText = environment.ollamaSettings.address.text
            chosenModel = environment.ollamaSettings.model
            runCheck()
            loadModels()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            connectionSection
            Divider()
            modelSection
            Divider()
            testSection
            Divider()
            queueSection
        }
    }

    // MARK: Connection (user story 1)

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection").font(.headline)
            HStack {
                Text("Server address")
                TextField("http://localhost:11434", text: $addressText)
                    .frame(width: 260)
                    .onSubmit { applyAddress() }
                Button("Apply") { applyAddress() }
            }
            if let addressMessage {
                Text(addressMessage).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(isChecking ? "Checking…" : status.message)
                    .foregroundStyle(status.isUsable ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check connection") { runCheck() }
                    .disabled(isChecking)
            }
        }
    }

    // MARK: Model (user story 2)

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model").font(.headline)
            HStack {
                Picker("Model", selection: Binding(get: { chosenModel ?? "" }, set: { chooseModel($0) })) {
                    if chosenModel == nil { Text("Choose a model…").tag("") }
                    if let chosen = chosenModel, !(models?.usable.contains { $0.name == chosen } ?? false) {
                        Text(chosen).tag(chosen)        // kept even when it is gone
                    }
                    ForEach(models?.usable ?? [], id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .frame(width: 280)
                Button { loadModels(); runCheck() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh the list of installed models")
            }
            if modelsFailed {
                Text("The list of models could not be read.").font(.callout).foregroundStyle(.secondary)
            }
            if let hidden = models?.hiddenCount, hidden > 0 {
                Text("\(hidden) installed \(hidden == 1 ? "model is" : "models are") hidden because \(hidden == 1 ? "it cannot" : "they cannot") read images.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let chosen = chosenModel, case .modelMissing = status {
                Text("The chosen model \(chosen) is no longer installed.").font(.callout).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Test the model and the queue (user story 4)

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test the model").font(.headline)
            HStack {
                Button("Test the model") { runTest() }
                    .disabled(isTesting || environment.analysis == nil)
                if isTesting { ProgressView().controlSize(.small) }
            }
            if let testNote { Text(testNote).font(.callout).foregroundStyle(.secondary) }
            if let testLine {
                Text(testLine).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var queueSection: some View {
        let progress = environment.state.analysis
        let counts = progress.counts
        return VStack(alignment: .leading, spacing: 8) {
            Text("Analysis queue").font(.headline)
            Text("Waiting \(counts.waiting) · Running \(counts.running) · Finished \(counts.finished) · Failed \(counts.failed)")
            if let reason = progress.holdingReason {
                Text("Waiting: \(reason)").font(.callout).foregroundStyle(.orange)
            }
            ForEach(failures, id: \.id) { job in
                Text("\(job.updatedAt.formatted(date: .omitted, time: .shortened)) \(job.failureReason ?? "failed")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Retry failed") { Task { try? await environment.analysis?.retryFailed(); loadFailures() } }
                    .disabled(counts.failed == 0)
                Button("Clear finished") { Task { try? await environment.analysis?.clearFinished(); loadFailures() } }
                    .disabled(counts.finished + counts.failed == 0)
                Button(progress.paused ? "Resume analysis" : "Pause analysis") {
                    Task { await environment.analysis?.pause(!progress.paused) }
                }
            }
        }
        .onChange(of: counts) { loadFailures() }
        .onAppear { loadFailures() }
    }

    private func loadFailures() {
        failures = (try? environment.analysisJobs?.recentFailures(limit: 5)) ?? []
    }

    /// Queues the test and follows its job until it finishes or fails.
    private func runTest() {
        isTesting = true
        testLine = nil
        Task {
            defer { isTesting = false }
            guard let queued = await environment.enqueueModelTest() else {
                testLine = "Failed: the capture storage is not available"
                return
            }
            testNote = queued.usedNewestCapture ? "Using the newest capture." : "Using the built-in sample picture."
            while !Task.isCancelled {
                if let job = try? environment.analysisJobs?.job(id: queued.jobID) {
                    let run = try? environment.analysisJobs?.latestRun(jobID: queued.jobID)
                    if let line = ModelTestResultLine.text(job: job, run: run) { testLine = line; return }
                    if let reason = environment.state.analysis.holdingReason {
                        testLine = "Waiting: \(reason)"
                    } else if environment.state.analysis.paused {
                        testLine = "Waiting: analysis is paused"
                    } else {
                        testLine = nil
                    }
                } else {
                    testLine = "Failed: the test was cleared"
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func chooseModel(_ name: String) {
        guard !name.isEmpty else { return }
        environment.ollamaSettings.setModel(name)
        chosenModel = name
        runCheck()
    }

    /// Off the main actor; the recommended model is chosen first when nothing is chosen (FR-006).
    private func loadModels() {
        let service = environment.ollama
        Task {
            await service.applyDefaultModelIfNeeded()
            chosenModel = environment.ollamaSettings.model
            do {
                models = try await service.modelList()
                modelsFailed = false
            } catch {
                modelsFailed = true
            }
        }
    }

    private func applyAddress() {
        if environment.ollamaSettings.setAddress(addressText) {
            addressMessage = nil
            addressText = environment.ollamaSettings.address.text
            runCheck()
            loadModels()
        } else {
            addressMessage = "Memorri only talks to Ollama on this Mac. Use localhost, 127.0.0.1 or ::1."
            addressText = environment.ollamaSettings.address.text        // keep the previous value
        }
    }

    /// Never on the main actor; a second press while one runs joins it.
    private func runCheck() {
        isChecking = true
        let service = environment.ollama
        Task {
            let result = await service.check()
            status = result
            isChecking = false
        }
    }
}
