import CoreGraphics
import Foundation

enum SyntheticLanguage: String, Sendable { case en, es }

enum SyntheticLook: String, Sendable { case outlook, appleMail, teams, slack, web, plain }

struct SyntheticRemote: Sendable {
    let client: String
    var title: String { client == "Citrix" ? "Citrix Workspace - Customer A" : "Remote Desktop Connection - Customer A" }
    var windowApp: String { client == "Citrix" ? "Citrix Viewer" : "Microsoft Remote Desktop" }
    var bundleID: String { client == "Citrix" ? "com.citrix.XenAppViewer" : "com.microsoft.rdc.macos" }
}

/// Everything that decides how a synthetic case looks and what tags it should get.
struct SyntheticSetup: Sendable {
    var name: String
    var look: SyntheticLook
    var application: String?
    var platform: String
    var language = SyntheticLanguage.en
    var clock24: Bool? = true
    var palette: Palette
    /// The zone the dates shown in the picture belong to (the context's, or the Mac's).
    var zone: String
    var context: GoldenContext? = nil
    var capturedAt: Date
    var remote: SyntheticRemote? = nil
    var windowTitle: String
    var features: Set<String> = []
    var macZone = "Europe/Madrid"
    var size = (width: 1600, height: 1000)
}

struct SyntheticDrawing {
    var kind: ScreenKind
    var findings: [ExpectedFinding]
    var extraTags: [ExpectedTag] = []
}

enum SyntheticChrome {
    static let customerA = GoldenContext(name: "Customer A", timezone: "America/New_York",
                                         hints: [GoldenHint(kind: "domain", value: "customer-a.example"), GoldenHint(kind: "window_title", value: "Customer A")])

    /// Draws the window frame the look asks for and hands the rest of the picture to `draw`.
    static func make(_ setup: SyntheticSetup, chrome: Bool = true, draw: (SyntheticCanvas, CGRect) -> SyntheticDrawing) throws -> SyntheticCase {
        let canvas = SyntheticCanvas(width: setup.size.width, height: setup.size.height, background: setup.palette.background)
        var area = CGRect(x: 0, y: 0, width: setup.size.width, height: setup.size.height)
        if chrome, let remote = setup.remote {
            canvas.fill(CGRect(x: 0, y: 0, width: area.width, height: 34), RGB(0x2D2D2D))
            canvas.text(remote.title, x: 16, y: 8, size: 15, color: RGB(0xFFFFFF))
            for i in 0..<3 { canvas.fill(CGRect(x: area.width - 100 + Double(i) * 30, y: 10, width: 14, height: 14), RGB(0x8A8A8A)) }
            canvas.fill(CGRect(x: 0, y: area.height - 40, width: area.width, height: 40), RGB(0x1B1B1B))
            for i in 0..<6 { canvas.fillRounded(CGRect(x: 14 + Double(i) * 44, y: area.height - 32, width: 24, height: 24), radius: 4, RGB(0x5A5A5A)) }
            area = CGRect(x: 0, y: 34, width: area.width, height: area.height - 34 - 40)
        }
        if chrome { area = applicationBar(canvas, setup, in: area) }
        let drawing = draw(canvas, area)

        var tags: [ExpectedTag] = []
        if let application = setup.application { tags.append(ExpectedTag(key: "application", value: application)) }
        tags.append(ExpectedTag(key: "platform_look", value: setup.platform))
        tags.append(ExpectedTag(key: "language", value: setup.language.rawValue))
        tags.append(ExpectedTag(key: "theme", value: setup.palette.dark ? "dark" : "light"))
        if let clock24 = setup.clock24 { tags.append(ExpectedTag(key: "clock_style", value: clock24 ? "24h" : "12h")) }
        if let remote = setup.remote { tags.append(ExpectedTag(key: "remote_session", value: remote.client)) }
        tags.append(contentsOf: drawing.extraTags)

        var features = setup.features
        features.insert("look-" + lookFeature(setup.look))
        features.insert("lang-" + setup.language.rawValue)
        if let clock24 = setup.clock24 { features.insert(clock24 ? "clock-24h" : "clock-12h") }
        if setup.remote != nil { features.insert("remote-frame") }

        let windows: [GoldenWindow]
        let full = [0, 0, setup.size.width, setup.size.height]
        if let remote = setup.remote {
            windows = [GoldenWindow(app: remote.windowApp, bundleID: remote.bundleID, title: remote.title, frame: full)]
        } else {
            let app = appIdentity(setup.look, application: setup.application)
            windows = [GoldenWindow(app: app.name, bundleID: app.bundle, title: setup.windowTitle, frame: full)]
        }
        let meta = GoldenMeta(capturedAt: setup.capturedAt, macTimezone: setup.macZone, context: setup.context, windows: windows,
                              displaySize: [setup.size.width, setup.size.height], scale: 1.0, origin: .synthetic)
        let expected = GoldenExpected(screenKind: drawing.kind.rawValue, tags: tags, context: setup.context?.name,
                                      lines: canvas.lines.isEmpty ? nil : canvas.lines, findings: drawing.findings)
        return SyntheticCase(name: setup.name, meta: meta, expected: expected, picture: try canvas.pngData(), features: features)
    }

    private static func lookFeature(_ look: SyntheticLook) -> String {
        switch look {
        case .outlook: "outlook"
        case .appleMail: "apple-mail"
        case .teams: "teams"
        case .slack: "slack"
        case .web: "web"
        case .plain: "plain"
        }
    }

    private static func appIdentity(_ look: SyntheticLook, application: String?) -> (name: String, bundle: String) {
        switch look {
        case .outlook: ("Microsoft Outlook", "com.microsoft.Outlook")
        case .appleMail: ("Mail", "com.apple.mail")
        case .teams: ("Microsoft Teams", "com.microsoft.teams2")
        case .slack: ("Slack", "com.tinyspeck.slackmacgap")
        case .web: ("Safari", "com.apple.Safari")
        case .plain: (application ?? "TextEdit", "com.apple.TextEdit")
        }
    }

    /// The bar at the top of the application; returns what is left below it.
    private static func applicationBar(_ c: SyntheticCanvas, _ s: SyntheticSetup, in area: CGRect) -> CGRect {
        let p = s.palette
        func below(_ height: Double) -> CGRect { CGRect(x: area.minX, y: area.minY + height, width: area.width, height: area.height - height) }
        switch s.look {
        case .outlook:
            c.fill(CGRect(x: area.minX, y: area.minY, width: area.width, height: 40), p.bar)
            c.text("Outlook", x: area.minX + 16, y: area.minY + 9, size: 19, color: p.barText, bold: true)
            for (i, tab) in ["Home", "View", "Help"].enumerated() {
                c.text(tab, x: area.minX + 130 + Double(i) * 80, y: area.minY + 12, size: 15, color: p.barText)
            }
            return below(40)
        case .appleMail:
            c.fill(CGRect(x: area.minX, y: area.minY, width: area.width, height: 44), p.bar)
            for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                c.fillCircle(center: CGPoint(x: area.minX + 22 + Double(i) * 22, y: area.minY + 22), radius: 6, RGB(UInt32(color)))
            }
            c.text("Mail", x: area.minX + area.width / 2 - 20, y: area.minY + 12, size: 17, color: p.barText, bold: true)
            return below(44)
        case .teams:
            c.fill(CGRect(x: area.minX, y: area.minY, width: area.width, height: 40), p.bar)
            c.text("Microsoft Teams", x: area.minX + 16, y: area.minY + 10, size: 17, color: p.barText, bold: true)
            c.fillRounded(CGRect(x: area.minX + area.width / 2 - 200, y: area.minY + 6, width: 400, height: 28), radius: 6, p.panel)
            c.text("Search", x: area.minX + area.width / 2 - 180, y: area.minY + 12, size: 14, color: p.muted)
            return below(40)
        case .slack:
            c.fill(CGRect(x: area.minX, y: area.minY, width: area.width, height: 40), RGB(0x3F0E40))
            c.text("Slack", x: area.minX + 16, y: area.minY + 9, size: 19, color: RGB(0xFFFFFF), bold: true)
            c.text("Acme Workspace", x: area.minX + 110, y: area.minY + 12, size: 15, color: RGB(0xE0D0E0))
            return below(40)
        case .web:
            c.fill(CGRect(x: area.minX, y: area.minY, width: area.width, height: 44), p.panel)
            for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                c.fillCircle(center: CGPoint(x: area.minX + 22 + Double(i) * 22, y: area.minY + 22), radius: 6, RGB(UInt32(color)))
            }
            c.fillRounded(CGRect(x: area.minX + 140, y: area.minY + 8, width: 900, height: 28), radius: 8, p.background)
            c.text(webAddress(s), x: area.minX + 156, y: area.minY + 13, size: 15, color: p.muted)
            return below(44)
        case .plain:
            c.fill(CGRect(x: area.minX, y: area.minY, width: area.width, height: 36), p.panel)
            c.text(s.windowTitle, x: area.minX + 16, y: area.minY + 9, size: 15, color: p.text, bold: true)
            return below(36)
        }
    }

    private static func webAddress(_ s: SyntheticSetup) -> String {
        s.windowTitle.lowercased().contains("mail") ? "https://mail.example.com/inbox" : "https://calendar.example.com/view"
    }
}
