import Foundation

/// How much the model thinks before it answers.
public enum ThinkSetting: String, Sendable, CaseIterable {
    case off, low, medium, high
}
