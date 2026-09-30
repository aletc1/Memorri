import Foundation

/// The instructions sent to the model (ADR 0014). Changing one changes its version.
public enum ExtractionPrompts {
    public static let classifyVersion = "classify-v2"
    /// More lines than this are cut before they go to the model; the smallest boxes go first (research R4).
    public static let maxLines = 600

    public static func classifyPrompt() -> String {
        let kinds = ScreenKind.allCases.map(\.rawValue).joined(separator: ", ")
        return "Look at this screenshot. Say which kind of screen it is (\(kinds)), how sure you are (0 to 1), "
            + "the application as people call it, such as Outlook, Teams, Apple Mail or Slack (say Web calendar or Web mail for a page in a browser), "
            + "whether the operating system it shows looks like macos, windows or linux "
            + "(for a remote or virtual desktop, the system of the desktop inside the window, not of the Mac around it), "
            + "whether it is shown inside a remote or virtual desktop (and which client), "
            + "the theme (light or dark) and the calendar name if one is visible. "
            + "Use empty strings for what you cannot tell."
    }

    public static func version(for kind: ScreenKind) -> String { "extract-\(kind.rawValue)-v3" }

    private static func description(of kind: ScreenKind) -> String {
        switch kind {
        case .calendarMonth: "month calendar"
        case .calendarWeek: "week calendar"
        case .calendarDay: "day calendar"
        case .email: "email"
        case .chat: "chat conversation"
        case .document: "document"
        case .other: "screen"
        }
    }

    private static func hint(for kind: ScreenKind) -> String {
        switch kind {
        case .calendarWeek, .calendarDay:
            return " Everything in a calendar view is an appointment. Each block sits under a date header. "
                + "Give the number of that header line in column_line. "
                + "Put the start time shown on the block in start_text and its end time, if shown, in end_text."
        case .calendarMonth:
            return " Everything in a calendar view is an appointment. Each entry sits in the cell of a day. "
                + "Give the number of the line that shows that cell's day number in column_line, "
                + "and put the time shown on the entry, if any, in start_text."
        case .email:
            return " Take items from the open message, not from the list of other messages beside it. "
                + "Put the date and time the message was sent (from its header) in sent_text, because words like "
                + "\"tomorrow\" or \"Friday\" are relative to it."
        case .chat:
            return " Write the title in the language of the messages. "
                + "Put the time shown next to the message that mentions the item in message_time_text, because words "
                + "like \"tomorrow\" are relative to when the message was sent."
        case .document, .other:
            return ""
        }
    }

    /// `lines` are the recognised lines of the full-resolution picture of size `pictureSize`. They are given as
    /// `L<n> (x%,y%) text`, the position being the top-left corner of the line as a percentage of the picture.
    public static func extractPrompt(kind: ScreenKind, lines: [RecognisedLine], pictureSize: (width: Int, height: Int))
        -> (prompt: String, capApplied: Bool) {
        var kept = lines
        let capped = lines.count > maxLines
        if capped {
            let keep = Set(lines.sorted { ($0.box.width * $0.box.height, $1.n) > ($1.box.width * $1.box.height, $0.n) }.prefix(maxLines).map(\.n))
            kept = lines.filter { keep.contains($0.n) }
        }
        let width = Double(max(1, pictureSize.width)), height = Double(max(1, pictureSize.height))
        let list = kept.map { line in
            "L\(line.n) (\(Int((Double(line.box.x) / width * 100).rounded(.down)))%,\(Int((Double(line.box.y) / height * 100).rounded(.down)))%) \(line.text)"
        }.joined(separator: "\n")
        let prompt = "This screenshot shows a \(description(of: kind)). Below are the text lines read from it, numbered L<n>. "
            + "List the appointments, tasks, reminders and deadlines the screen shows. Use only what is on screen and do not invent anything. "
            + "Only list something that has a date or a time, or that says a person needs or has to do something; "
            + "leave out headlines, newsletters and text about other things. "
            + "For each one give the numbers of the lines that show it in cited_lines. "
            + "The title is a short name for it made of words from those lines: no line numbers, no labels like (L5) and no dates. "
            + "Keep the wording of the text: from \"Submit the grant proposal by 2026-11-06.\" the title is \"Submit the grant proposal\"; "
            + "from \"Please send me the report by tomorrow\" it is \"Send the report\". "
            + "Copy dates and times exactly as written into start_text, end_text, date_text, due_text and remind_text. "
            + "A sentence like \"Maria needs the budget figures by Friday 23 October\" is a task: title \"Budget figures\", "
            + "people [\"Maria\"], due_text \"Friday 23 October\". "
            + "A deadline is something due by a date: put the date in due_text, and a reminder time only if the text gives one."
            + hint(for: kind) + "\n\nLines:\n" + list
        return (prompt, capped)
    }
}
