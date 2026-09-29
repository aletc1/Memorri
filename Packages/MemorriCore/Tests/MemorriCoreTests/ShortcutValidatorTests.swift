import Testing
@testable import MemorriCore

@Suite struct ShortcutValidatorTests {
    private let keyM = 46
    private let keyK = 40
    private let f5 = 96
    private let space = 49

    private func combo(_ key: Int, _ modifiers: Set<KeyCombo.Modifier>) -> KeyCombo {
        KeyCombo(keyCode: key, modifiers: modifiers)
    }

    @Test func validComboIsAccepted() {
        let validator = ShortcutValidator(system: FakeSystemShortcuts(), otherActions: [:])
        #expect(validator.validate(combo(keyM, [.control, .option, .command])) == nil)
    }

    @Test func comboWithoutModifierIsRejected() {
        let validator = ShortcutValidator(system: FakeSystemShortcuts(), otherActions: [:])
        #expect(validator.validate(combo(keyK, [])) == .noModifier)
    }

    @Test func functionKeyAloneCountsAsNoModifier() {
        // The recorder library accepts F5 alone; the spec does not.
        let validator = ShortcutValidator(system: FakeSystemShortcuts(), otherActions: [:])
        #expect(validator.validate(combo(f5, [])) == .noModifier)
    }

    @Test func comboUsedByAnotherMemorriActionIsRejected() {
        let taken = combo(keyK, [.command, .option])
        let validator = ShortcutValidator(system: FakeSystemShortcuts(), otherActions: ["Open Inbox": taken])
        #expect(validator.validate(taken) == .usedByMemorriAction("Open Inbox"))
    }

    @Test func comboReservedBySystemIsRejected() {
        let reserved = combo(space, [.command])
        let validator = ShortcutValidator(system: FakeSystemShortcuts(reserved: [reserved]), otherActions: [:])
        #expect(validator.validate(reserved) == .reservedBySystem)
    }

    @Test func noModifierWinsOverEveryOtherRule() {
        let bare = combo(keyK, [])
        let validator = ShortcutValidator(
            system: FakeSystemShortcuts(reserved: [bare]),
            otherActions: ["Other": bare]
        )
        #expect(validator.validate(bare) == .noModifier)
    }

    @Test func memorriConflictWinsOverSystemReserved() {
        let both = combo(space, [.command])
        let validator = ShortcutValidator(
            system: FakeSystemShortcuts(reserved: [both]),
            otherActions: ["Other": both]
        )
        #expect(validator.validate(both) == .usedByMemorriAction("Other"))
    }

    @Test func sameKeyWithDifferentModifiersIsNotAConflict() {
        let other = combo(keyK, [.command])
        let validator = ShortcutValidator(system: FakeSystemShortcuts(), otherActions: ["Other": other])
        #expect(validator.validate(combo(keyK, [.command, .shift])) == nil)
    }
}
