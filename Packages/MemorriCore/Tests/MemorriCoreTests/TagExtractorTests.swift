import Foundation
import Testing
@testable import MemorriCore

@Suite struct TagExtractorTests {
    private func window(_ app: String?, bundle: String? = nil, title: String? = nil) -> WindowInfo {
        WindowInfo(appName: app, bundleID: bundle, title: title, frame: PixelBox(x: 0, y: 0, width: 100, height: 100))
    }
    private func lines(_ texts: [String]) -> [RecognisedLine] {
        texts.enumerated().map { RecognisedLine(n: $0 + 1, text: $1, box: PixelBox(x: 0, y: $0 * 20, width: 100, height: 18), confidence: 0.9) }
    }
    private func value(_ tags: [CaptureTag], _ key: String) -> String? { tags.first { $0.key == key }?.value }
    private func values(_ tags: [CaptureTag], _ key: String) -> [String] { tags.filter { $0.key == key }.map(\.value) }

    @Test func aVisualApplicationNoWindowOrTextConfirmsCountsAsLow() {
        let model = ClassificationResult(kind: .calendarWeek, confidence: 0.9, application: "Thunderbird", platformLook: "linux", isRemote: false,
                                         remoteClient: "", theme: "light", calendarName: "")
        let windows = [window("Microsoft Teams"), window("Code")]
        let tags = TagExtractor.tags(width: 10, height: 10, scale: 1, windows: windows, lines: lines(["Calendar"]), classification: model)
        let application = tags.first { $0.key == "application" }
        #expect(application?.value == "Thunderbird" && application?.isLow == true)
        // No window is a remote client, and none is the system's own, so the remote session is doubted and the platform is not.
        #expect(tags.first { $0.key == "platform_look" }?.isLow == false)
        let remote = ClassificationResult(kind: .calendarWeek, confidence: 0.9, application: "Teams", platformLook: "linux", isRemote: true,
                                          remoteClient: "VNC", theme: "light", calendarName: "")
        let local = TagExtractor.tags(width: 10, height: 10, scale: 1, windows: windows + [window("Finder", bundle: "com.apple.finder")], lines: [], classification: remote)
        #expect(local.first { $0.key == "remote_session" }?.isLow == true && local.first { $0.key == "platform_look" }?.isLow == true)
        let viaClient = TagExtractor.tags(width: 10, height: 10, scale: 1, windows: [window("Microsoft Remote Desktop")], lines: [], classification: remote)
        #expect(viaClient.first { $0.key == "remote_session" }?.isLow == false)
        // Confirmed by a window, by the text, or when no windows are known: unchanged.
        let teams = model.withApplication("Teams")
        #expect(TagExtractor.tags(width: 10, height: 10, scale: 1, windows: windows, lines: [], classification: teams).first { $0.key == "application" }?.isLow == false)
        #expect(TagExtractor.tags(width: 10, height: 10, scale: 1, windows: [], lines: [], classification: model).first { $0.key == "application" }?.isLow == false)
        #expect(TagExtractor.tags(width: 10, height: 10, scale: 1, windows: windows, lines: lines(["Thunderbird"]), classification: model).first { $0.key == "application" }?.isLow == false)
    }

    // MARK: From the capture

    @Test func theDisplayGivesItsSizeAndScale() {
        let tags = TagExtractor.fromCapture(width: 3440, height: 1440, scale: 2, windows: [])
        #expect(value(tags, "display_size") == "3440x1440" && value(tags, "display_scale") == "2x")
        #expect(tags.allSatisfy { $0.confidence == 1 && $0.source == "code" })
        #expect(value(TagExtractor.fromCapture(width: 100, height: 100, scale: 1.5, windows: []), "display_scale") == "1.5x")
        #expect(value(TagExtractor.fromCapture(width: 100, height: 100, scale: nil, windows: []), "display_scale") == nil)
    }

    @Test func eachOwningApplicationIsATagOnce() {
        let tags = TagExtractor.fromCapture(width: 10, height: 10, scale: 1,
                                            windows: [window("Safari"), window("Outlook"), window("Safari"), window(nil, bundle: "com.example.tool")])
        #expect(values(tags, "window_app") == ["Safari", "Outlook", "com.example.tool"])
        #expect(tags.filter { $0.key == "window_app" }.allSatisfy { $0.source == "window" })
    }

    @Test(arguments: [
        ("Citrix Viewer", "com.citrix.XenAppViewer"), ("Microsoft Remote Desktop", "com.microsoft.rdc.macos"), ("Windows App", "com.microsoft.rdc.macos"),
        ("VMware Horizon Client", "com.vmware.horizon"), ("Parallels Client", "com.parallels.client"), ("Jump Desktop", "com.p5sys.jump.mac.viewer"),
    ])
    func aKnownRemoteClientIsATag(app: String, bundle: String) {
        #expect(values(TagExtractor.fromCapture(width: 10, height: 10, scale: 1, windows: [window(app, bundle: bundle)]), "remote_client") == [app])
    }

    @Test(arguments: ["Safari", "Google Chrome", "Microsoft Teams", "Mail", "Outlook", "Slack"])
    func otherApplicationsAreNotRemoteClients(app: String) {
        #expect(values(TagExtractor.fromCapture(width: 10, height: 10, scale: 1, windows: [window(app)]), "remote_client").isEmpty)
    }

    @Test func aClientIsRecognisedByItsBundleEvenWithAnOddName() {
        #expect(values(TagExtractor.fromCapture(width: 10, height: 10, scale: 1, windows: [window("Work PC", bundle: "com.citrix.receiver")]), "remote_client") == ["Work PC"])
    }

    @Test func titleKeywordsAreLongWordsOfTheTitlesWithoutDuplicates() {
        let tags = TagExtractor.fromCapture(width: 10, height: 10, scale: 1,
                                            windows: [window("Outlook", title: "Inbox - Customer A - Outlook"), window("Safari", title: "Customer A budget 2026")])
        #expect(values(tags, "window_title_keywords") == ["inbox", "customer", "outlook", "budget"])
        #expect(tags.filter { $0.key == "window_title_keywords" }.allSatisfy { $0.source == "window" })
    }

    @Test func noMoreThanTwelveKeywordsAreKept() {
        let title = (1...30).map { "keyword\($0)" }.joined(separator: " ")
        #expect(values(TagExtractor.fromCapture(width: 10, height: 10, scale: 1, windows: [window("A", title: title)]), "window_title_keywords").count == 12)
    }

    // MARK: From the lines

    @Test func languageIsEnglishOrSpanishByTheText() {
        let english = TagExtractor.fromLines(lines(["The quarterly budget review is scheduled for Thursday afternoon", "Please confirm whether you can attend the meeting"]))
        let spanish = TagExtractor.fromLines(lines(["La reunión de presupuesto trimestral es el jueves por la tarde", "Por favor confirma si puedes asistir a la reunión"]))
        #expect(value(english, "language") == "en" && value(spanish, "language") == "es")
    }

    @Test func tooLittleTextGivesNoLanguage() {
        #expect(value(TagExtractor.fromLines(lines(["OK", "12"])), "language") == nil)
        #expect(TagExtractor.fromLines([]).isEmpty)
    }

    @Test func clockStyleCountsTimesWithAndWithoutAmPm() {
        #expect(value(TagExtractor.fromLines(lines(["9:00 AM", "10:30 AM", "2:00 PM"])), "clock_style") == "12h")
        #expect(value(TagExtractor.fromLines(lines(["09:00", "13:30", "17:45"])), "clock_style") == "24h")
        #expect(value(TagExtractor.fromLines(lines(["9 AM", "10 AM", "11 AM", "12 PM"])), "clock_style") == "12h")
        #expect(value(TagExtractor.fromLines(lines(["09:00", "10:00", "13:30", "2:00 PM"])), "clock_style") == "24h")         // mixed: the more frequent
        #expect(value(TagExtractor.fromLines(lines(["09:00", "2:00 PM"])), "clock_style") == nil)                               // a tie says nothing
        #expect(value(TagExtractor.fromLines(lines(["Team sync", "Room 4"])), "clock_style") == nil)
    }

    @Test func bareTimesOnlyHintAtA24HourClockAndOnlyWhenNothingHasAmPm() {
        let weak = TagExtractor.fromLines(lines(["9:00", "10:00", "11:00"])).first { $0.key == "clock_style" }
        #expect(weak?.value == "24h" && weak?.confidence == TagExtractor.weakClockConfidence && weak!.confidence < CaptureTag.lowConfidence)
        // With am/pm anywhere in the picture a bare hour proves nothing.
        #expect(value(TagExtractor.fromLines(lines(["9:00", "10:00", "2 PM", "3 PM"])), "clock_style") == "12h")
        #expect(value(TagExtractor.fromLines(lines(["9:00", "10:00", "2 PM"])), "clock_style") == "12h")
    }

    @Test func dateOrderComesFromUnambiguousDatesOnly() {
        #expect(value(TagExtractor.fromLines(lines(["14/10/2026", "03/04/2026"])), "date_order") == "dmy")
        #expect(value(TagExtractor.fromLines(lines(["10/14/2026"])), "date_order") == "mdy")
        #expect(value(TagExtractor.fromLines(lines(["2026-10-14"])), "date_order") == "ymd")
        #expect(value(TagExtractor.fromLines(lines(["03/04/2026"])), "date_order") == nil)
    }

    @Test func emailAddressesGiveAccountsAndDomainsWithTheirLines() {
        let tags = TagExtractor.fromLines(lines(["From: Ana Ruiz <Ana.Ruiz@Customer-A.example>", "Cc: bob@customer-a.example, carol@other.org", "Ana.Ruiz@customer-a.example"]))
        #expect(values(tags, "account") == ["ana.ruiz@customer-a.example", "bob@customer-a.example", "carol@other.org"])
        #expect(values(tags, "domain") == ["customer-a.example", "other.org"])
        #expect(tags.first { $0.key == "account" }?.source == "line:1" && tags.first { $0.key == "domain" && $0.value == "other.org" }?.source == "line:2")
        #expect(tags.filter { $0.key == "account" || $0.key == "domain" }.allSatisfy { $0.confidence == 1 })
    }

    @Test func websiteAddressesGiveDomainsToo() {
        let tags = TagExtractor.fromLines(lines(["Open https://portal.customer-a.example/calendar?x=1 now"]))
        #expect(values(tags, "domain") == ["portal.customer-a.example"] && values(tags, "account").isEmpty)
    }

    @Test func timeZoneLabelsAreRecordedAsWritten() {
        #expect(values(TagExtractor.fromLines(lines(["Meeting 10:00 GMT+2"])), "timezone_label") == ["GMT+2"])
        #expect(values(TagExtractor.fromLines(lines(["Starts 09:30 CEST", "Ends 11:00 CEST"])), "timezone_label") == ["CEST"])
        #expect(values(TagExtractor.fromLines(lines(["14:00 UTC-5"])), "timezone_label") == ["UTC-5"])
        #expect(values(TagExtractor.fromLines(lines(["14:00 UTC +05:30"])), "timezone_label") == ["UTC+05:30"])
        #expect(TagExtractor.fromLines(lines(["The best west coast estimate"])).filter { $0.key == "timezone_label" }.isEmpty)
    }

    // MARK: From the classification

    private func classification(application: String = "Outlook", platform: String = "windows", remote: Bool = false, client: String = "",
                                theme: String = "light", calendar: String = "", confidence: Double = 0.93) -> ClassificationResult {
        ClassificationResult(kind: .calendarWeek, confidence: confidence, application: application, platformLook: platform, isRemote: remote,
                             remoteClient: client, theme: theme, calendarName: calendar)
    }

    @Test func visualTagsCarryTheModelsConfidenceAndTheVisualSource() {
        let tags = TagExtractor.fromClassification(classification(remote: true, client: "Citrix", calendar: "Work"))
        #expect(value(tags, "application") == "Outlook" && value(tags, "platform_look") == "windows" && value(tags, "theme") == "light")
        #expect(value(tags, "remote_session") == "Citrix" && value(tags, "calendar_name") == "Work")
        #expect(tags.allSatisfy { $0.source == "visual" && $0.confidence == 0.93 && !$0.isLow })
    }

    @Test func unknownOrEmptyAnswersAreNotStored() {
        let tags = TagExtractor.fromClassification(classification(application: "", platform: "Unknown", theme: " ", calendar: "none"))
        #expect(tags.isEmpty)
    }

    @Test func aRemoteSessionWithoutAKnownClientIsStillRecorded() {
        #expect(value(TagExtractor.fromClassification(classification(remote: true, client: "")), "remote_session") == "remote")
        #expect(value(TagExtractor.fromClassification(classification(remote: false, client: "Citrix")), "remote_session") == nil)
    }

    @Test func aVisualTagBelowPointSixIsMarkedLow() {
        let tags = TagExtractor.fromClassification(classification(confidence: 0.55))
        #expect(!tags.isEmpty && tags.allSatisfy(\.isLow))
        #expect(CaptureTag(key: "theme", value: "dark", confidence: 0.6, source: "visual").isLow == false)
        #expect(CaptureTag(key: "clock_style", value: "24h", confidence: 0.4, source: "code").isLow == false)        // only what the model saw can be low
    }

    // MARK: Together

    @Test func theTagsOfAPictureAreTheThreeSourcesWithoutDuplicates() {
        let tags = TagExtractor.tags(width: 1600, height: 1000, scale: 1, windows: [window("Outlook", title: "Inbox")],
                                     lines: lines(["09:00", "13:30"]), classification: classification())
        #expect(Set(tags.map(\.key)).isSuperset(of: ["display_size", "window_app", "clock_style", "application", "theme"]))
        #expect(Set(tags.map { "\($0.key)|\($0.value)" }).count == tags.count)
    }
}
