import CoreGraphics
import MemorriCore
import SwiftUI

/// One sighting of an item with the part of the capture it was read from (spec 006, US1).
struct EvidenceCardView: View {
    let entry: EvidenceEntry
    let model: ItemsViewModel
    let isChecked: Binding<Bool>?
    let onShowWhole: () -> Void
    @State private var cutOut: CGImage?
    @State private var loaded = false

    private var when: String {
        "\(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))\(entry.displayName.map { " · \($0)" } ?? "")"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let isChecked {
                Toggle("", isOn: isChecked).labelsHidden()
                    .accessibilityLabel("Select the sighting from \(when)")
            }
            VStack(alignment: .leading, spacing: 6) {
                cutOutView
                Text(when)
                Text(details).font(.callout).foregroundStyle(.secondary)
                if let sighting = entry.sighting {
                    let why = ItemListModel.whyText(decisionJSON: sighting.decisionJSON)
                    if !why.isEmpty { Text("why: \(why)").font(.caption).foregroundStyle(.secondary) }
                }
                Button("Show whole capture", action: onShowWhole)
                    .controlSize(.small)
                    .accessibilityLabel("Show the whole capture of \(when) with the cited lines marked")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
        .task(id: entry.evidence?.id) {
            guard let record = entry.evidence else { loaded = true; return }
            cutOut = await model.cutOut(record)
            loaded = true
        }
    }

    private var details: String {
        let confidence = entry.sighting.map { " · confidence \(String(format: "%.2f", $0.confidence))" } ?? ""
        return "\(entry.title)\(confidence)"
    }

    @ViewBuilder
    private var cutOutView: some View {
        if let cutOut {
            Image(decorative: cutOut, scale: 1)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 420, maxHeight: 130, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))
                .accessibilityLabel("Cut-out of the capture where \(entry.title) was read")
        } else if loaded {
            Text(ItemListModel.missingCutOutText(entry.evidence)).font(.callout).foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// The whole capture with the lines the sighting cited outlined, and the cut-out's region dashed.
struct WholeCaptureSheet: View {
    let entry: EvidenceEntry
    let model: ItemsViewModel
    let onClose: () -> Void
    @State private var capture: WholeCapture?
    @State private var loaded = false

    private var cited: Set<Int> { Set(entry.sighting?.citedLines ?? entry.evidence?.citedLines ?? []) }

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let capture {
                    outlined(capture)
                } else if loaded {
                    Text("The capture is no longer stored.").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("\(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))\(entry.displayName.map { " · \($0)" } ?? "")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 480)
        .task {
            let imageID = entry.sighting?.imageID ?? entry.evidence?.imageID ?? ""
            capture = await model.wholeCapture(imageID: imageID)
            loaded = true
        }
    }

    private func outlined(_ capture: WholeCapture) -> some View {
        GeometryReader { geometry in
            let width = CGFloat(capture.picture.width), height = CGFloat(capture.picture.height)
            let scale = min(geometry.size.width / width, geometry.size.height / height)
            ZStack(alignment: .topLeading) {
                Image(decorative: capture.picture, scale: 1).resizable().frame(width: width * scale, height: height * scale)
                if let region = entry.evidence?.region {
                    Rectangle().stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
                        .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
                }
                ForEach(capture.lines.filter { cited.contains($0.n) }, id: \.n) { line in
                    Rectangle().stroke(Color.blue, lineWidth: 2)
                        .frame(width: CGFloat(line.box.width) * scale, height: CGFloat(line.box.height) * scale)
                        .offset(x: CGFloat(line.box.x) * scale, y: CGFloat(line.box.y) * scale)
                }
            }
            .frame(width: width * scale, height: height * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("The whole capture with the cited lines outlined")
        }
    }
}
