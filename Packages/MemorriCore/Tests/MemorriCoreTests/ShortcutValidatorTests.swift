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

@Suite struct SearchShortcutValidatorTests {
    @Test func aSearchShortcutEqualToTheCaptureShortcutIsRefusedWithTheActionsName() {
        let capture = KeyCombo(keyCode: 46, modifiers: [.control, .option, .command])
        let validator = ShortcutValidator(system: FakeSystemShortcuts(), otherActions: ["Capture now": capture])
        #expect(validator.validate(capture) == .usedByMemorriAction("Capture now"))
        #expect(validator.validate(KeyCombo(keyCode: 3, modifiers: [.control, .option, .command])) == nil)       // the default search shortcut
    }

    @Test func aSystemReservedSearchShortcutIsRefusedAndNoShortcutNeedsNoValidation() {
        let reserved = KeyCombo(keyCode: 49, modifiers: [.command])
        #expect(ShortcutValidator(system: FakeSystemShortcuts(reserved: [reserved]), otherActions: [:]).validate(reserved) == .reservedBySystem)
    }
}

/// The capture, window-capture and search shortcuts are checked against each other (spec 013 FR-003).
@Suite struct ShortcutThreeActionsTests {
    private func combo(_ key: Int, _ modifiers: Set<KeyCombo.Modifier>) -> KeyCombo { KeyCombo(keyCode: key, modifiers: modifiers) }
    private let keyM = 46

    private let keyW = 13, keyF = 3

    @Test func theThreeDefaultsAreDistinctAndEachIsAcceptedAgainstTheOtherTwo() {
        let capture = combo(keyM, [.control, .option, .command]), window = combo(keyW, [.control, .option, .command]), search = combo(keyF, [.control, .option, .command])
        #expect(Set([capture, window, search]).count == 3)
        #expect(ShortcutValidator(system: FakeSystemShortcuts(), otherActions: ["Capture window": window, "Search": search]).validate(capture) == nil)
        #expect(ShortcutValidator(system: FakeSystemShortcuts(), otherActions: ["Capture now": capture, "Search": search]).validate(window) == nil)
        #expect(ShortcutValidator(system: FakeSystemShortcuts(), otherActions: ["Capture now": capture, "Capture window": window]).validate(search) == nil)
    }

    @Test func aComboUsedByEitherOtherActionIsRefusedNamingThatAction() {
        let capture = combo(keyM, [.control, .option, .command]), search = combo(keyF, [.control, .option, .command])
        let validator = ShortcutValidator(system: FakeSystemShortcuts(), otherActions: ["Capture now": capture, "Search": search])
        #expect(validator.validate(capture) == .usedByMemorriAction("Capture now"))
        #expect(validator.validate(search) == .usedByMemorriAction("Search"))
    }

    @Test func theWindowShortcutIsRefusedWhenMacOSReservesIt() {
        let reserved = combo(keyW, [.command])
        #expect(ShortcutValidator(system: FakeSystemShortcuts(reserved: [reserved]), otherActions: [:]).validate(reserved) == .reservedBySystem)
    }
}
