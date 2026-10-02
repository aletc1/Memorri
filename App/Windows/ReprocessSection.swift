import CoreGraphics
import MemorriCore
import SwiftUI

/// Settings → Analysis → Reprocess (spec 008): read the stored captures with another model, compare with the items, apply what you choose.
struct ReprocessSection: View {
    let environment: AppEnvironment
    @State private var models: [String]?
    @State private var model = ""
    @State private var trials: [TrialRecord] = []
    @State private var history: [TrialHistoryEntry] = []
    @State private var eligible = 0
    @State private var outOfDate = 0
    @State private var message: String?
    @State private var comparing: TrialRecord?
    @State private var starting = false

    private var store: TrialStore? { environment.reprocessing?.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reprocess").font(.headline)
            Text("Read the stored captures again with another model and see what would change. Nothing changes in your items until you apply it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Model", selection: $model) {
                    ForEach(models ?? [], id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 320)
                .help("The model that reads the stored captures in this trial. Only installed models that can read pictures are listed.")
                Text("Prompts: \(ExtractionPrompts.summary)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Start trial on \(eligible) \(eligible == 1 ? "capture" : "captures")") { start() }
                    .disabled(starting || eligible == 0 || model.isEmpty)
                    .help("Reads every stored capture again with the chosen model, in the background, behind new captures")
                Text(TrialWords.outOfDate(outOfDate)).foregroundStyle(.secondary)
            }
            if models == nil {
                Text("The Ollama server cannot be reached, so a trial cannot start.").font(.callout).foregroundStyle(.orange)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            ForEach(trials) { trial in TrialRow(trial: trial, environment: environment, onCompare: { comparing = trial }, onChange: refresh) }
            if !history.isEmpty {
                Text("History").font(.subheadline).bold().padding(.top, 6)
                ForEach(history) { entry in HistoryRow(entry: entry, environment: environment, onChange: refresh) }
            }
        }
        .task {
            await loadModels()
            refresh()
            guard let store else { return }
            for await list in store.observe() { trials = list; refresh() }
        }
        .sheet(item: $comparing) { trial in
            TrialComparisonSheet(environment: environment, trial: trial, others: trials.filter { $0.id != trial.id && $0.counts.read > 0 }, onClose: { comparing = nil; refresh() })
        }
    }

    private func loadModels() async {
        models = await environment.visionModels()
        if model.isEmpty { model = environment.ollamaSettings.model.flatMap { models?.contains($0) == true ? $0 : nil } ?? models?.first ?? "" }
    }

    private func refresh() {
        eligible = (try? store?.eligibleCount()) ?? 0
        outOfDate = environment.outOfDateCaptures()
        history = (try? store?.history()) ?? []
    }

    private func start() {
        starting = true; message = nil
        Task {
            if case .failure(let error) = await environment.startTrial(model: model) { message = error.message }
            starting = false
            refresh()
        }
    }
}

private struct TrialRow: View {
    let trial: TrialRecord
    let environment: AppEnvironment
    let onCompare: () -> Void
    let onChange: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(trial.model) · \(trial.createdAt.formatted(date: .abbreviated, time: .shortened))").fontWeight(.medium)
                Text("\(TrialWords.state(trial)): \(TrialWords.progress(trial))").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if trial.state == .running {
                Button("Cancel") { try? environment.reprocessing?.store.cancel(trial.id, now: Date()); onChange() }
                    .help("Stop reading. What was read stays and can be compared; you can resume later")
            } else if trial.counts.waiting + trial.counts.failed > 0 {
                Button("Resume") { Task { await environment.resumeTrial(trial.id); onChange() } }
                    .help("Read the captures that are left, and retry the ones that failed")
            }
            Button("Compare…", action: onCompare).disabled(trial.counts.read == 0)
                .help("See what this trial would change, and apply the changes you choose")
            Button("Delete", role: .destructive) { try? environment.reprocessing?.store.delete(trial.id); onChange() }
                .help("Delete this trial's results. Your items and the history are not changed")
        }
        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct HistoryRow: View {
    let entry: TrialHistoryEntry
    let environment: AppEnvironment
    let onChange: () -> Void
    @State private var note: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) · applied \(entry.applied) from \(entry.model)")
                if let started = entry.trialStarted {
                    Text("Trial started \(started.formatted(date: .abbreviated, time: .shortened)), \(entry.captures) \(entry.captures == 1 ? "capture" : "captures") read")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(entry.undone ? "Undone" : "\(entry.items) \(entry.items == 1 ? "item" : "items") changed").font(.caption).foregroundStyle(.secondary)
                if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            Button("Undo") {
                Task {
                    switch try? await environment.itemOperations?.undo(entry.id) {
                    case .partly(_, let reason)?: note = "Partly undone: \(reason)"
                    case .impossible(let reason)?: note = "Cannot undo: \(reason)"
                    default: note = nil
                    }
                    onChange()
                }
            }
            .disabled(entry.undone).help("Put the items back as they were before this apply")
        }
    }
}

// MARK: Comparison

struct TrialComparisonSheet: View {
    let environment: AppEnvironment
    let trial: TrialRecord
    let others: [TrialRecord]
    let onClose: () -> Void

    @State private var report: TrialReport?
    @State private var infos: [String: TrialCaptureInfo] = [:]
    @State private var selection: Set<String> = []
    @State private var showUnchanged = false
    @State private var other: String = ""
    @State private var pairs: [TrialPairDifference] = []
    @State private var message: String?
    @State private var lastOperation: String?
    @State private var loading = true

    private var services: ReprocessServices? { environment.reprocessing }

    private var shown: [TrialDifference] { (report?.differences ?? []).filter { showUnchanged || $0.kind != .unchanged || $0.state == .applied } }
    private var applicable: [TrialDifference] { (report?.differences ?? []).filter(\.applicable) }
    private var groups: [(imageID: String, rows: [TrialDifference])] {
        var order: [String] = []
        var byImage: [String: [TrialDifference]] = [:]
        for d in shown { if byImage[d.imageID] == nil { order.append(d.imageID) }; byImage[d.imageID, default: []].append(d) }
        return order.map { ($0, byImage[$0]!) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trial of \(trial.model)").font(.title3).bold()
            Text(report.map { TrialWords.totals($0.totals) } ?? (loading ? "Comparing…" : "")).foregroundStyle(.secondary)
            HStack {
                Toggle("Show unchanged", isOn: $showUnchanged).help("Also list what the trial read the same as it is now")
                if !others.isEmpty {
                    Picker("Compare with", selection: $other) {
                        Text("Items as they are").tag("")
                        ForEach(others) { Text("\($0.model) · \($0.createdAt.formatted(date: .abbreviated, time: .shortened))").tag($0.id) }
                    }
                    .frame(maxWidth: 320).help("Show where this trial and another differ")
                }
            }
            Divider()
            if other.isEmpty { differencesList } else { pairsList }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Button("Apply selected (\(selection.intersection(Set(applicable.map(\.id))).count))") { apply(Array(selection)) }
                    .disabled(selection.intersection(Set(applicable.map(\.id))).isEmpty)
                    .help("Apply the checked differences. They can be undone together")
                Button("Apply all not protected (\(applicable.count))") { apply(applicable.map(\.id)) }
                    .disabled(applicable.isEmpty).help("Apply every difference that does not touch something you set, approved or dismissed")
                if let lastOperation {
                    Button("Undo") { undo(lastOperation) }.help("Put the items back as they were before this apply")
                }
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(minWidth: 720, minHeight: 520)
        .task { await load() }
        .onChange(of: other) { _, id in pairs = id.isEmpty ? [] : ((try? services?.comparison.between(trial.id, id)) ?? []) }
    }

    private var differencesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if loading { ProgressView() }
                else if shown.isEmpty { Text("Nothing to show: the trial read what the items already say.").foregroundStyle(.secondary) }
                ForEach(groups, id: \.imageID) { group in
                    let info = infos[group.imageID]
                    HStack {
                        Text("Capture \(info.map { $0.capturedAt.formatted(date: .abbreviated, time: .shortened) } ?? "")\(info?.displayName.map { " · \($0)" } ?? "")")
                            .font(.subheadline).bold()
                        let open = group.rows.filter(\.applicable).map(\.id)
                        if !open.isEmpty {
                            Button("Select all") { selection.formUnion(open) }.buttonStyle(.link)
                                .help("Tick every difference of this capture that can be applied")
                        }
                    }
                    .padding(.top, 8)
                    ForEach(group.rows) { row in
                        DifferenceRow(difference: row, trial: trial, environment: environment,
                                      checked: Binding(get: { selection.contains(row.id) }, set: { if $0 { selection.insert(row.id) } else { selection.remove(row.id) } }))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pairsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if pairs.isEmpty { Text("The two trials read the same captures the same way.").foregroundStyle(.secondary) }
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.title).fontWeight(.medium)
                        switch pair.kind {
                        case .onlyInFirst: Text("Only in this trial").font(.callout).foregroundStyle(.secondary)
                        case .onlyInSecond: Text("Only in the other trial").font(.callout).foregroundStyle(.secondary)
                        case .differs: ForEach(pair.changes, id: \.field) { Text(TrialWords.change($0)).font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        loading = true
        guard let services else { loading = false; return }
        let result = try? await services.comparison.report(trialID: trial.id)
        report = result
        infos = (try? services.store.captureInfo(imageIDs: Array(Set((result?.differences ?? []).map(\.imageID))))) ?? [:]
        loading = false
    }

    private func apply(_ ids: [String]) {
        Task {
            guard let services else { return }
            message = nil
            do {
                let result = try await services.applier.apply(trialID: trial.id, differenceIDs: ids)
                lastOperation = result.operationID
                var text = "Applied \(result.applied.count)."
                if !result.skipped.isEmpty { text += " Skipped \(result.skipped.count): " + Set(result.skipped.map(\.reason)).sorted().joined(separator: "; ") + "." }
                message = text
                selection = []
            } catch { message = "Applying failed." }
            await load()
        }
    }

    private func undo(_ op: String) {
        Task {
            switch try? await environment.itemOperations?.undo(op) {
            case .partly(_, let reason)?: message = "Partly undone: \(reason)"
            case .impossible(let reason)?: message = "Cannot undo: \(reason)"
            default: message = "Undone."
            }
            lastOperation = nil
            await load()
        }
    }
}

private struct DifferenceRow: View {
    let difference: TrialDifference
    let trial: TrialRecord
    let environment: AppEnvironment
    let checked: Binding<Bool>
    @State private var showEvidence = false
    @State private var cutOut: CGImage?
    @State private var cited: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle("", isOn: checked).labelsHidden().disabled(!difference.applicable)
                    .accessibilityLabel("Select \(difference.title)")
                Text(TrialWords.kind(difference)).font(.caption).bold().padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Text(difference.title).fontWeight(.medium)
                if difference.needsReview, difference.kind == .new || difference.kind == .changed {
                    Image(systemName: "circle.fill").foregroundStyle(.orange).imageScale(.small).help("This reading would need review").accessibilityLabel("Would need review")
                }
                Spacer()
                if difference.findingID != nil {
                    Button(showEvidence ? "Hide evidence" : "Evidence") { showEvidence.toggle() }.buttonStyle(.link)
                        .help("Show the part of the capture the trial read this from")
                }
            }
            ForEach(difference.changes, id: \.field) { Text(TrialWords.change($0)).font(.callout).foregroundStyle(.secondary).padding(.leading, 28) }
            if let protection = difference.protection {
                Label(TrialWords.protection(protection), systemImage: "lock.fill").font(.caption).foregroundStyle(.orange).padding(.leading, 28)
            }
            if showEvidence {
                VStack(alignment: .leading, spacing: 4) {
                    if let cutOut { Image(decorative: cutOut, scale: 1).resizable().scaledToFit().frame(maxHeight: 200).border(.secondary.opacity(0.3)) }
                    if !cited.isEmpty { Text(cited).font(.caption).foregroundStyle(.secondary) }
                    if let confidence = difference.confidence { Text(String(format: "confidence %.2f", confidence)).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.leading, 28)
                .task { await loadEvidence() }
            }
        }
        .padding(6).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .opacity(difference.state == .applied ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }

    private func loadEvidence() async {
        guard cutOut == nil, cited.isEmpty, let findingID = difference.findingID, let services = environment.reprocessing,
              let store = environment.evidenceStore else { return }
        let imageID = difference.imageID, trialID = trial.id
        let loaded: (CGImage?, String) = await Task.detached {
            guard let finding = (try? services.store.findings(trialID: trialID, imageID: imageID))?.first(where: { $0.id == findingID }),
                  let capture = try? store.capture(imageID: imageID) else { return (nil, "") }
            let lines = capture.lines.filter { finding.citedLines.contains($0.n) }
            let text = lines.map(\.text).joined(separator: " / ")
            guard let region = EvidenceGeometry.region(lines: lines.map(\.box), pictureWidth: capture.picture.width, pictureHeight: capture.picture.height),
                  let crop = capture.picture.cropping(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height)) else { return (nil, text) }
            return (crop, text)
        }.value
        cutOut = loaded.0; cited = loaded.1
    }
}
