import Foundation

/// The exact texts of the first menu line (contracts/ui-contract.md). English and independent of the
/// system language, like the rest of the UI.
public enum LastCaptureLine {
    public static func text(for result: LastCaptureResult?, age seconds: TimeInterval) -> String {
        guard let result else { return "No capture yet" }
        let when = age(seconds)
        switch result {
        case .complete:
            return "Last capture: complete, \(when)"
        case .partial(let captured, let total):
            return "Last capture: \(captured) of \(total) displays captured, \(when)"
        case .failed(let reason):
            return "Last capture failed: \(reason), \(when)"
        }
    }

    public static func age(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(Int(seconds) / 60) min ago"
        case ..<86400: "\(Int(seconds) / 3600) h ago"
        default: "\(Int(seconds) / 86400) d ago"
        }
    }
}
