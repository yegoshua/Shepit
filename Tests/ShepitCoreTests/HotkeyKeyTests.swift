import Testing
import ShepitCore

/// Flag values are the device-specific modifier masks from IOKit's IOLLEvent.h (NX_DEVICE*KEYMASK).
@Suite struct HotkeyKeyTests {
    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040
    static let rightControl: UInt64 = 0x0000_2000

    static let cases: [(HotkeyKey, left: UInt64, right: UInt64)] = [
        (.rightOption, leftOption, rightOption),
        (.rightCommand, leftCommand, rightCommand),
        (.rightShift, leftShift, rightShift),
        (.rightControl, leftControl, rightControl),
    ]

    @Test(arguments: cases)
    func rightModifierDownIsPressed(key: HotkeyKey, left: UInt64, right: UInt64) {
        #expect(key.isPressed(flags: right))
    }

    @Test(arguments: cases)
    func leftModifierAloneIsNotPressed(key: HotkeyKey, left: UInt64, right: UInt64) {
        #expect(!key.isPressed(flags: left))
    }

    @Test(arguments: cases)
    func bothModifiersDownIsPressed(key: HotkeyKey, left: UInt64, right: UInt64) {
        #expect(key.isPressed(flags: left | right))
    }

    @Test(arguments: cases)
    func noModifiersIsNotPressed(key: HotkeyKey, left: UInt64, right: UInt64) {
        #expect(!key.isPressed(flags: 0))
    }

    @Test func keyCodesMatchMacVirtualKeys() {
        #expect(HotkeyKey.rightCommand.keyCode == 54)
        #expect(HotkeyKey.rightShift.keyCode == 60)
        #expect(HotkeyKey.rightOption.keyCode == 61)
        #expect(HotkeyKey.rightControl.keyCode == 62)
    }
}
