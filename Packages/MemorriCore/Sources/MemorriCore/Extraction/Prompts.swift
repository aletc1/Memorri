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

    public static func version(for kind: ScreenKind) -> String { "extract-\(kind.rawValue)-v11" }

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

    /// The instructions for one kind of screen: numbered rules, what each field holds, and short examples (none of them from the golden set).
    static func instructions(for kind: ScreenKind) -> String {
        var text = """
        You are given the text lines of a screenshot of a \(description(of: kind)). Each line looks like: L<number> (x%,y%) text.
        List the appointments, tasks, reminders and deadlines that the lines show.

        Rules:
        1. Include an item only if the lines give it a date or a time (a weekday, "tomorrow", "23 Oct" and "10:00" all count), or name who must do it. Skip everything else: menus, headlines, newsletters, advertisements, general advice, requests with no date and no name, and messages about other things. The date a message was sent is not an item. Never invent anything.
        2. For each item give:
           - kind: "appointment" (an event at a date or time), "task" (a named person needs or has to do something, with or without a date), "reminder" (something to be reminded of at a time) or "deadline" (something is due by a date but no person is named, such as "must be submitted by Friday").
           - title: a short name of 2 to 5 words, taken from the lines you cite and in their language, such as "Design review" or "Send the contract". No dates, times or line numbers in it.
           - cited_lines: the numbers of the lines that show the item.
        3. Copy dates and times exactly as written and put each one in its own field. Leave out the fields that do not apply.
           - start_text: when an appointment starts, as written, such as "10:00". For a range like "14:00-15:30" the start is "14:00" and end_text is "15:30".
           - end_text: when it ends, only if it is written.
           - date_text: the day of an appointment, when it is written (in the same line or in a heading) and is not part of start_text.
           - due_text: when a task or deadline is due, such as "Monday" or "23 Oct".
           - remind_text: the time of a reminder.
           A date or time field holds only a date or a time as written, never a sentence.
        4. place: the room or place written with the item (a room name, a street, "Phone", "Online"). Always fill it when one is written. people: the other people the item names. Not the sender of a message, and not "me" or "you".
        """
        text += rules(for: kind)
        if kind != .calendarWeek, kind != .calendarDay, kind != .calendarMonth { text += "\n\n" + examples }
        return text
    }

    private static func rules(for kind: ScreenKind) -> String {
        switch kind {
        case .calendarWeek, .calendarDay:
            return """

            5. Everything in a calendar is an appointment: kind is always "appointment". Each block sits under a date header: give the number of that header's line in column_line.
            6. start_text is the time shown on the block. end_text only if the block itself shows an end, like "09:00 - 10:00"; never take an end time from the hour scale at the side.
            """
        case .calendarMonth:
            return """

            5. Everything in a calendar is an appointment: kind is always "appointment", even a birthday or an all-day entry. Each entry sits in the cell of a day: give the number of the line that shows that cell's day number in column_line.
            6. start_text is the time shown on the entry, if there is one. An entry without a time has no start_text. A day number is never a date or time field.
            """
        case .email:
            return """

            5. Take items from the open message only: the one whose header shows From, To and Date. The list of other messages beside it (their subjects and first lines) is not part of it.
            6. sent_text: the date and time the message was sent, from its header. Words like "tomorrow" or "Friday" are relative to it.
            """
        case .chat:
            return """

            5. Write titles in the language of the messages.
            6. message_time_text: the time shown next to the message that mentions the item. Words like "tomorrow" are relative to it.
            """
        case .document, .other:
            return ""
        }
    }

    /// Short worked examples, with invented content.
    private static let examples = """
    Examples (lines, then the answer):

    L1 (10%,5%) Team notes
    L2 (10%,10%) Nov 3 - Sprint planning 09:30-10:30, Room 2
    L3 (10%,14%) Bring your laptop.
    {"findings":[{"kind":"appointment","title":"Sprint planning","cited_lines":[2],"date_text":"Nov 3","start_text":"09:30","end_text":"10:30","place":"Room 2"}]}

    L1 (5%,5%) Lena needs the invoice totals by Friday 23 October.
    L2 (5%,9%) Please keep the kitchen tidy.
    {"findings":[{"kind":"task","title":"Invoice totals","cited_lines":[1],"people":["Lena"],"due_text":"Friday 23 October"}]}

    L1 (30%,10%) Sam 14:05
    L2 (30%,13%) Dentist next Tuesday at 08:15
    L3 (30%,16%) See you there!
    {"findings":[{"kind":"appointment","title":"Dentist","cited_lines":[2],"start_text":"next Tuesday at 08:15"}]}
    """

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
        let prompt = instructions(for: kind) + "\n\nLines:\n" + list
        return (prompt, capped)
    }
}
