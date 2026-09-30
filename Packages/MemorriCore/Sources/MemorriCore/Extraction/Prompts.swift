import Foundation

/// The instructions sent to the model (ADR 0014). Changing one changes its version.
public enum ExtractionPrompts {
    public static let classifyVersion = "classify-v1"

    public static func classifyPrompt() -> String {
        let kinds = ScreenKind.allCases.map(\.rawValue).joined(separator: ", ")
        return "Look at this screenshot. Say which kind of screen it is (\(kinds)), how sure you are (0 to 1), "
            + "the application, whether it looks like macos, windows or linux, "
            + "whether it is shown inside a remote or virtual desktop (and which client), "
            + "the theme (light or dark) and the calendar name if one is visible. "
            + "Use empty strings for what you cannot tell."
    }
}
