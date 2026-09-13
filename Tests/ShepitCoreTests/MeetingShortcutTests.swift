import Testing
import ShepitCore

/// Flag values are CGEventFlags masks; key codes are macOS virtual key codes (M = 46, R = 15).
@Suite struct MeetingShortcutTests {
    static let shift: UInt64 = 0x2_0000
    static let control: UInt64 = 0x4_0000
    static let option: UInt64 = 0x8_0000
    static let command: UInt64 = 0x10_0000
    /// Caps Lock and the device-dependent low bits must not affect matching.
    static let capsLockAndDeviceBits: UInt64 = 0x1_0000 | 0x0040

    @Test func controlOptionMMatchesItsChord() {
        #expect(MeetingShortcut.controlOptionM.matches(keyCode: 46, flags: Self.control | Self.option))
        #expect(MeetingShortcut.controlOptionM.matches(keyCode: 46, flags: Self.control | Self.option | Self.capsLockAndDeviceBits))
    }

    @Test func extraOrMissingModifiersDoNotMatch() {
        #expect(!MeetingShortcut.controlOptionM.matches(keyCode: 46, flags: Self.control | Self.option | Self.command))
        #expect(!MeetingShortcut.controlOptionM.matches(keyCode: 46, flags: Self.control | Self.option | Self.shift))
        #expect(!MeetingShortcut.controlOptionM.matches(keyCode: 46, flags: Self.option))
    }

    @Test func otherKeyDoesNotMatch() {
        #expect(!MeetingShortcut.controlOptionM.matches(keyCode: 15, flags: Self.control | Self.option))
        #expect(MeetingShortcut.controlOptionR.matches(keyCode: 15, flags: Self.control | Self.option))
    }

    @Test func disabledShortcutNeverMatches() {
        #expect(!MeetingShortcut.none.matches(keyCode: 46, flags: Self.control | Self.option))
        #expect(!MeetingShortcut.none.matches(keyCode: 0, flags: 0))
    }
}
