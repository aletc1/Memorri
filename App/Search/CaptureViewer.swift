import CoreGraphics
import MemorriCore
import SwiftUI

/// Zoom state shared by the whole-capture views: 1 shows the whole picture in the window, more zooms in and the picture scrolls.
struct PictureZoom {
    static let maxZoom: CGFloat = 16
    var zoom: CGFloat = 1
    var atGestureStart: CGFloat = 1
    var fitScale: CGFloat = 1

    mutating func set(_ value: CGFloat) {
        zoom = min(max(value, 1), Self.maxZoom)
        atGestureStart = zoom
    }
}

/// The whole capture with some lines outlined and, optionally, a dashed region (the cut-out of an item's evidence).
struct OutlinedPicture: View {
    let capture: WholeCapture
    let outlined: Set<Int>
    var region: PixelRegion?
    let label: String
    @Binding var zoom: PictureZoom

    var body: some View {
        GeometryReader { geometry in
            let width = CGFloat(capture.picture.width), height = CGFloat(capture.picture.height)
            let fit = min(geometry.size.width / width, geometry.size.height / height)
            let scale = fit * zoom.zoom
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Image(decorative: capture.picture, scale: 1).resizable().interpolation(.high).frame(width: width * scale, height: height * scale)
                    if let region {
                        Rectangle().stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
                            .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
                    }
                    ForEach(capture.lines.filter { outlined.contains($0.n) }, id: \.n) { line in
                        Rectangle().stroke(Color.blue, lineWidth: 2)
                            .frame(width: CGFloat(line.box.width) * scale, height: CGFloat(line.box.height) * scale)
                            .offset(x: CGFloat(line.box.x) * scale, y: CGFloat(line.box.y) * scale)
                    }
                }
                .frame(width: width * scale, height: height * scale)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)       // centred while it is smaller than the window
            }
            .gesture(MagnifyGesture()
                .onChanged { zoom.zoom = min(max(zoom.atGestureStart * $0.magnification, 1), PictureZoom.maxZoom) }
                .onEnded { _ in zoom.atGestureStart = zoom.zoom })
            .onChange(of: geometry.size, initial: true) { zoom.fitScale = fit }
            .accessibilityLabel(label)
        }
    }
}

/// The zoom buttons of the whole-capture views.
struct ZoomButtons: View {
    @Binding var zoom: PictureZoom

    var body: some View {
        Button { zoom.set(zoom.zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
            .keyboardShortcut("-", modifiers: .command).disabled(zoom.zoom <= 1)
            .help("Zoom out").accessibilityLabel("Zoom out")
        Button("Fit") { zoom.set(1) }.disabled(zoom.zoom == 1)
            .help("Show the whole picture in the window").accessibilityLabel("Fit the picture to the window")
        Button("100%") { zoom.set(1 / zoom.fitScale) }
            .help("One picture pixel per point").accessibilityLabel("Show the picture at its own size")
        Button { zoom.set(zoom.zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
            .keyboardShortcut("=", modifiers: .command).disabled(zoom.zoom >= PictureZoom.maxZoom)
            .help("Zoom in").accessibilityLabel("Zoom in")
    }
}

/// What a search result asks the capture window to show.
struct CaptureRequest: Equatable {
    let id = UUID()
    let imageID: String
    let query: SearchQuery
    /// When and where it was taken, as one line.
    let header: String
}

/// The window a capture result opens: the picture with the matching lines outlined, and the text of the capture with the matches marked;
/// when the picture is gone, the text and a note.
struct CaptureViewerView: View {
    let environment: AppEnvironment
    @State private var model: CaptureViewerModel?
    @State private var capture: WholeCapture?
    @State private var loaded = false
    @State private var zoom = PictureZoom()

    var body: some View {
        let request = environment.state.captureRequest
        VStack(spacing: 8) {
            if let request, let model {
                HStack {
                    Text(request.header).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.heading).foregroundStyle(.secondary)
                }
                if let note = model.note { Text(note).foregroundStyle(.secondary).accessibilityLabel(note) }
                HSplitView {
                    if let capture {
                        VStack(spacing: 6) {
                            OutlinedPicture(capture: capture, outlined: Set(model.matchingNumbers), label: "The whole capture with the matching lines outlined. Zoom with the buttons or pinch, scroll to move.", zoom: $zoom)
                            HStack(spacing: 8) { Spacer(); ZoomButtons(zoom: $zoom) }
                        }
                        .frame(minWidth: 360)
                    }
                    ScrollViewReader { proxy in
                        List(model.textLines, id: \.number) { line in
                            Text(line.text.attributed).font(.callout).textSelection(.enabled)
                                .accessibilityLabel(line.text.marks.isEmpty ? line.text.text : "Matching line: \(line.text.text)")
                        }
                        .onAppear { if let first = model.matchingNumbers.first { proxy.scrollTo(first, anchor: .center) } }
                    }
                    .frame(minWidth: 240)
                }
            } else if loaded {
                Text("There is nothing to show.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .task(id: request?.id) { await load(request) }
    }

    private func load(_ request: CaptureRequest?) async {
        guard let request, let database = environment.storage?.database, let evidence = environment.evidenceStore else { loaded = true; return }
        zoom = PictureZoom()
        loaded = false
        let imageID = request.imageID, query = request.query
        let (lines, picture) = await Task.detached { () -> ([RecognisedLine], CGImage?) in
            let lines = (try? OCRStore(database: database).lines(imageID: imageID)) ?? []
            let picture = (try? evidence.capture(imageID: imageID))?.picture
            return (lines, picture)
        }.value
        model = CaptureViewerModel(lines: lines, query: query, pictureStored: picture != nil)
        capture = picture.map { WholeCapture(picture: $0, lines: lines) }
        loaded = true
    }
}
