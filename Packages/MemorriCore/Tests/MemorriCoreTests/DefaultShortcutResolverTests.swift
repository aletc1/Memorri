import Testing
@testable import MemorriCore

@Suite struct DefaultShortcutResolverTests {
    private let defaultCombo = KeyCombo(keyCode: 13, modifiers: [.control, .option, .command])
    private let capture = KeyCombo(keyCode: 46, modifiers: [.control, .option, .command])
    private let search = KeyCombo(keyCode: 3, modifiers: [.control, .option, .command])

    @Test func theDefaultIsKeptWhenNoOtherActionUsesIt() {
        let decision = DefaultShortcutResolver.resolve(default: defaultCombo, current: defaultCombo, others: ["Capture now": capture, "Search": search])
        #expect(decision == .keep)
    }

    @Test func theDefaultIsDroppedWhenTheCaptureShortcutAlreadyUsesIt() {
        let decision = DefaultShortcutResolver.resolve(default: defaultCombo, current: defaultCombo, others: ["Capture now": defaultCombo, "Search": search])
        #expect(decision == .unassign(usedBy: "Capture now"))
    }

    @Test func theDefaultIsDroppedWhenTheSearchShortcutAlreadyUsesIt() {
        let decision = DefaultShortcutResolver.resolve(default: defaultCombo, current: defaultCombo, others: ["Capture now": capture, "Search": defaultCombo])
        #expect(decision == .unassign(usedBy: "Search"))
    }

    @Test func aShortcutTheUserChoseIsNeverTouched() {
        let chosen = KeyCombo(keyCode: 13, modifiers: [.control, .option])
        #expect(DefaultShortcutResolver.resolve(default: defaultCombo, current: chosen, others: ["Capture now": chosen]) == .keep)
        #expect(DefaultShortcutResolver.resolve(default: defaultCombo, current: nil, others: ["Capture now": defaultCombo]) == .keep)
    }

    @Test func anotherActionWithoutAShortcutIsNoConflict() {
        #expect(DefaultShortcutResolver.resolve(default: defaultCombo, current: defaultCombo, others: [:]) == .keep)
    }

    @Test func theMessageNamesTheActionAndTheMenu() {
        let text = DefaultShortcutResolver.message(usedBy: "Capture now")
        #expect(text.contains("Capture now") && text.contains("menu"))
    }
}
