import CoreGraphics
import MemorriCore
import SwiftUI

/// One sighting of an item with the part of the capture it was read from (spec 006, US1).
struct EvidenceCardView: View {
    let entry: EvidenceEntry
    let model: ItemsViewModel
    let isChecked: Binding<Bool>?
    /// This sighting gave the item's current title (FR-005).
    var isTitleSource = false
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
                if isTitleSource {
                    Label("Source of the current title", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
                }
                Text(when)
                if let window = ItemListModel.windowText(entry) {
                    Label(window, systemImage: "macwindow").font(.callout).foregroundStyle(.secondary)
                        .accessibilityLabel("Window: \(window)")
                }
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
                .frame(maxWidth: 460, maxHeight: 220, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))
                .contentShape(Rectangle())
                .onTapGesture { onShowWhole() }
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                .help("Show the whole capture")
                .accessibilityLabel("Cut-out of the capture where \(entry.title) was read. Opens the whole capture.")
                .accessibilityAddTraits(.isButton)
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
    @State private var zoom = PictureZoom()

    private var cited: Set<Int> { Set(entry.sighting?.citedLines ?? entry.evidence?.citedLines ?? []) }

    /// Most of the screen, so a large display can be read without zooming.
    private var sheetSize: CGSize {
        let area = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        return CGSize(width: max(720, area.width * 0.8), height: max(480, area.height * 0.8))
    }

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let capture {
                    OutlinedPicture(capture: capture, outlined: cited, region: entry.evidence?.region,
                                    label: "The whole capture with the cited lines outlined. Zoom with the buttons or pinch, scroll to move.", zoom: $zoom)
                } else if loaded {
                    Text("The capture is no longer stored.").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                Text("\(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))\(entry.displayName.map { " · \($0)" } ?? "")")
                    .foregroundStyle(.secondary)
                Spacer()
                if capture != nil { ZoomButtons(zoom: $zoom) }
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: sheetSize.width, height: sheetSize.height)
        .task {
            let imageID = entry.sighting?.imageID ?? entry.evidence?.imageID ?? ""
            capture = await model.wholeCapture(imageID: imageID)
            loaded = true
        }
    }
}
