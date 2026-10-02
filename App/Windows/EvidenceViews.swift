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
    /// 1 shows the whole picture in the window; more zooms in and the picture scrolls.
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat = 1
    @State private var fitScale: CGFloat = 1

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
                    outlined(capture)
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
                if capture != nil {
                    Button { setZoom(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                        .keyboardShortcut("-", modifiers: .command).disabled(zoom <= 1)
                        .help("Zoom out").accessibilityLabel("Zoom out")
                    Button("Fit") { setZoom(1) }.disabled(zoom == 1)
                        .help("Show the whole picture in the window").accessibilityLabel("Fit the picture to the window")
                    Button("100%") { setZoom(1 / fitScale) }
                        .help("One picture pixel per point").accessibilityLabel("Show the picture at its own size")
                    Button { setZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                        .keyboardShortcut("=", modifiers: .command).disabled(zoom >= Self.maxZoom)
                        .help("Zoom in").accessibilityLabel("Zoom in")
                }
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

    private static let maxZoom: CGFloat = 16

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 1), Self.maxZoom)
        zoomAtGestureStart = zoom
    }

    private func outlined(_ capture: WholeCapture) -> some View {
        GeometryReader { geometry in
            let width = CGFloat(capture.picture.width), height = CGFloat(capture.picture.height)
            let fit = min(geometry.size.width / width, geometry.size.height / height)
            let scale = fit * zoom
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Image(decorative: capture.picture, scale: 1).resizable().interpolation(.high).frame(width: width * scale, height: height * scale)
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
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)       // centred while it is smaller than the window
            }
            .gesture(MagnifyGesture()
                .onChanged { zoom = min(max(zoomAtGestureStart * $0.magnification, 1), Self.maxZoom) }
                .onEnded { _ in zoomAtGestureStart = zoom })
            .onChange(of: geometry.size, initial: true) { fitScale = fit }
            .accessibilityLabel("The whole capture with the cited lines outlined. Zoom with the buttons or pinch, scroll to move.")
        }
    }
}
