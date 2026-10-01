import Foundation
import NaturalLanguage

/// What the environment of a picture looks like, as tags (research R8): read from the capture, from the recognised text, and
/// from what the first model call saw. Code-derived tags are exact; a tag never carries a value the picture does not show,
/// and what is unknown is not stored.
public enum TagExtractor {
    /// Applications that show another computer's desktop. Browsers, Teams and Mail are not among them.
    private static let remoteClientNames = ["citrix viewer", "citrix workspace", "microsoft remote desktop", "windows app", "vmware horizon",
                                            "parallels", "jump desktop"]
    private static let remoteClientBundlePrefixes = ["com.citrix.", "com.microsoft.rdc", "com.vmware.horizon", "com.parallels.", "com.p5sys.jump"]
    /// A language the recogniser is less sure of is not recorded: a wrong `language` would put the wrong names first when reading dates.
    static let minimumLanguageConfidence = 0.9
    static let maximumKeywords = 12
    static let maximumAddresses = 10
    private static let unknownAnswers: Set<String> = ["", "unknown", "none", "n/a", "na"]

    /// Everything known about one picture, without duplicates.
    public static func tags(width: Int, height: Int, scale: Double?, windows: [WindowInfo], lines: [RecognisedLine],
                            classification: ClassificationResult) -> [CaptureTag] {
        var seen = Set<String>()
        return (fromCapture(width: width, height: height, scale: scale, windows: windows) + fromLines(lines)
                + fromClassification(classification).map { doubted($0, windows: windows, lines: lines) })
            .filter { seen.insert("\($0.key)|\($0.value)").inserted }
    }

    /// The model names an application, a platform and a remote session from the look of the picture and can be wrong (a calendar in
    /// Teams read as Thunderbird on Linux over VNC). When the windows of the capture are known, a claim they contradict is kept but
    /// counts as low confidence: an application that no window or text on screen carries, a remote session when no window is a
    /// remote client, and a platform other than macOS when a window of the system itself (Finder, a `com.apple.` app) is there.
    static func doubted(_ tag: CaptureTag, windows: [WindowInfo], lines: [RecognisedLine]) -> CaptureTag {
        guard !windows.isEmpty else { return tag }
        let apps = windows.flatMap { [$0.appName, $0.bundleID] }.compactMap { $0?.lowercased() }
        let contradicted: Bool
        switch tag.key {
        case "application":
            let name = tag.value.lowercased()
            contradicted = !apps.contains { $0.contains(name) || name.contains($0) } && !lines.contains { $0.text.lowercased().contains(name) }
        case "remote_session":
            contradicted = !windows.contains { isRemoteClient(name: $0.appName, bundleID: $0.bundleID) }
        case "platform_look":
            contradicted = tag.value.lowercased() != "macos" && windows.contains { $0.bundleID?.lowercased().hasPrefix("com.apple.") == true }
        default:
            contradicted = false
        }
        return contradicted ? CaptureTag(key: tag.key, value: tag.value, confidence: min(tag.confidence, 0.4), source: tag.source) : tag
    }

    // MARK: From the capture

    public static func fromCapture(width: Int, height: Int, scale: Double?, windows: [WindowInfo]) -> [CaptureTag] {
        var tags = [CaptureTag(key: "display_size", value: "\(width)x\(height)", confidence: 1, source: "code")]
        if let scale, scale > 0 { tags.append(CaptureTag(key: "display_scale", value: String(format: "%gx", scale), confidence: 1, source: "code")) }

        var apps: [String] = [], clients: [String] = []
        for window in windows {
            guard let name = window.appName ?? window.bundleID else { continue }
            if !apps.contains(name) { apps.append(name) }
            if isRemoteClient(name: window.appName, bundleID: window.bundleID), !clients.contains(name) { clients.append(name) }
        }
        tags += apps.map { CaptureTag(key: "window_app", value: $0, confidence: 1, source: "window") }
        tags += clients.map { CaptureTag(key: "remote_client", value: $0, confidence: 1, source: "window") }

        var keywords: [String] = []
        for title in windows.compactMap(\.title) {
            for word in title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
                guard word.count >= 4, !word.allSatisfy(\.isNumber), !keywords.contains(word), keywords.count < maximumKeywords else { continue }
                keywords.append(word)
            }
        }
        tags += keywords.map { CaptureTag(key: "window_title_keywords", value: $0, confidence: 1, source: "window") }
        return tags
    }

    static func isRemoteClient(name: String?, bundleID: String?) -> Bool {
        if let name = name?.lowercased(), remoteClientNames.contains(where: name.contains) { return true }
        if let bundle = bundleID?.lowercased(), remoteClientBundlePrefixes.contains(where: bundle.hasPrefix) { return true }
        return false
    }

    // MARK: From the lines

    public static func fromLines(_ lines: [RecognisedLine]) -> [CaptureTag] {
        var tags: [CaptureTag] = []
        let texts = lines.map(\.text)
        if let language = language(of: texts) { tags.append(language) }
        if let clock = clockStyle(of: texts) { tags.append(clock) }
        if let order = DateParser.dateOrder(ofUnambiguous: texts) { tags.append(CaptureTag(key: "date_order", value: order.rawValue, confidence: 1, source: "code")) }
        tags += addresses(in: lines)
        tags += timeZoneLabels(in: lines)
        return tags
    }

    private static func language(of texts: [String]) -> CaptureTag? {
        let text = texts.joined(separator: "\n")
        guard text.filter(\.isLetter).count >= 12 else { return nil }
        let recogniser = NLLanguageRecognizer()
        // The languages people read calendars in here; without the limit a short English text can come out as Portuguese.
        recogniser.languageConstraints = [.english, .spanish, .french, .german, .italian, .portuguese, .dutch, .catalan]
        recogniser.processString(text)
        guard let best = recogniser.languageHypotheses(withMaximum: 1).first, best.value >= minimumLanguageConfidence else { return nil }
        return CaptureTag(key: "language", value: best.key.rawValue, confidence: best.value, source: "code")
    }

    private static let twelveHour = try! NSRegularExpression(pattern: #"\b\d{1,2}(?::\d{2})?\s?[AaPp]\.?[Mm]\b"#)
    private static let bareTime = try! NSRegularExpression(pattern: #"\b(\d{1,2}):\d{2}\b(?!\s?[AaPp]\.?[Mm])"#)

    /// 12 h: times with am or pm. 24 h: times without it that only a 24 hour clock writes (a leading zero, or 13 to 23). Other bare
    /// times (`10:12`) point to 24 h only weakly, and only when nothing in the picture has am or pm, because 12 hour clocks
    /// write it nearly everywhere. The more frequent style wins; a tie says nothing.
    private static func clockStyle(of texts: [String]) -> CaptureTag? {
        var twelve = 0, twentyFour = 0, bare = 0
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            twelve += twelveHour.numberOfMatches(in: text, range: range)
            for match in bareTime.matches(in: text, range: range) {
                guard let hourRange = Range(match.range(at: 1), in: text), let hour = Int(text[hourRange]) else { continue }
                if hour >= 13 && hour <= 23 || (text[hourRange].count == 2 && text[hourRange].hasPrefix("0")) { twentyFour += 1 } else { bare += 1 }
            }
        }
        if twelve == 0, twentyFour == 0, bare > 0 { return CaptureTag(key: "clock_style", value: "24h", confidence: weakClockConfidence, source: "code") }
        guard twelve != twentyFour else { return nil }
        let style = twelve > twentyFour ? "12h" : "24h"
        return CaptureTag(key: "clock_style", value: style, confidence: Double(max(twelve, twentyFour)) / Double(twelve + twentyFour), source: "code")
    }
    /// Below `CaptureTag.lowConfidence`, so a weak guess is never "wrong with high confidence".
    static let weakClockConfidence = 0.55

    private static let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,})"#)
    private static let website = try! NSRegularExpression(pattern: #"https?://([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+)"#, options: .caseInsensitive)

    private static func addresses(in lines: [RecognisedLine]) -> [CaptureTag] {
        var accounts: [CaptureTag] = [], domains: [CaptureTag] = []
        func add(_ key: String, _ value: String, line: Int, to list: inout [CaptureTag]) {
            guard list.count < maximumAddresses, !list.contains(where: { $0.value == value }) else { return }
            list.append(CaptureTag(key: key, value: value, confidence: 1, source: "line:\(line.description)"))
        }
        for line in lines {
            let text = line.text
            let range = NSRange(text.startIndex..., in: text)
            for match in email.matches(in: text, range: range) {
                guard let whole = Range(match.range, in: text), let domain = Range(match.range(at: 1), in: text) else { continue }
                add("account", text[whole].lowercased(), line: line.n, to: &accounts)
                add("domain", text[domain].lowercased(), line: line.n, to: &domains)
            }
            for match in website.matches(in: text, range: range) {
                guard let host = Range(match.range(at: 1), in: text) else { continue }
                add("domain", text[host].lowercased(), line: line.n, to: &domains)
            }
        }
        return accounts + domains
    }

    private static let zoneOffset = try! NSRegularExpression(pattern: #"\b(?:GMT|UTC)(?:\s?[+\-]\d{1,2}(?::\d{2})?)?(?![A-Za-z0-9])"#)
    private static let zoneAbbreviation = try! NSRegularExpression(
        pattern: #"\b(?:CEST|CET|EEST|EET|EST|EDT|CST|CDT|MST|MDT|PST|PDT|BST|IST|JST|AEST|AEDT)\b"#)

    /// Zone labels as written (`GMT+2`, `CEST`, `UTC-5`). Only recorded: the picture's dates are not moved by them.
    private static func timeZoneLabels(in lines: [RecognisedLine]) -> [CaptureTag] {
        var tags: [CaptureTag] = []
        for line in lines {
            let range = NSRange(line.text.startIndex..., in: line.text)
            for expression in [zoneOffset, zoneAbbreviation] {
                for match in expression.matches(in: line.text, range: range) {
                    guard let found = Range(match.range, in: line.text) else { continue }
                    let label = line.text[found].filter { !$0.isWhitespace }
                    if !tags.contains(where: { $0.value == label }) {
                        tags.append(CaptureTag(key: "timezone_label", value: label, confidence: 1, source: "line:\(line.n)"))
                    }
                }
            }
        }
        return tags
    }

    // MARK: From the classification

    public static func fromClassification(_ result: ClassificationResult) -> [CaptureTag] {
        func known(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return unknownAnswers.contains(trimmed.lowercased()) ? nil : trimmed
        }
        func tag(_ key: String, _ value: String?) -> CaptureTag? {
            value.map { CaptureTag(key: key, value: $0, confidence: result.confidence, source: "visual") }
        }
        let remote = result.isRemote ? (known(result.remoteClient) ?? "remote") : nil
        return [tag("application", known(result.application)), tag("platform_look", known(result.platformLook)),
                tag("remote_session", remote), tag("theme", known(result.theme)), tag("calendar_name", known(result.calendarName))]
            .compactMap { $0 }
    }
}

extension CaptureTag {
    /// A value only the model saw, and it was not sure (below 0.6).
    public static let lowConfidence = 0.6
    public var isLow: Bool { source == "visual" && confidence < Self.lowConfidence }
}
