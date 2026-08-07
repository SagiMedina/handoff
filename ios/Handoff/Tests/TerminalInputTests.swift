import XCTest
@testable import Handoff

final class TerminalInputEncoderTests: XCTestCase {
    func testCursorKeysHonorNormalAndApplicationModes() {
        let cases: [(TerminalInputKey, UInt8)] = [
            (.up, 0x41),
            (.down, 0x42),
            (.right, 0x43),
            (.left, 0x44),
            (.home, 0x48),
            (.end, 0x46),
        ]

        for (key, final) in cases {
            XCTAssertEqual(
                TerminalInputEncoder.encode(key, applicationCursor: false),
                [0x1B, 0x5B, final]
            )
            XCTAssertEqual(
                TerminalInputEncoder.encode(key, applicationCursor: true),
                [0x1B, 0x4F, final]
            )
        }
    }

    func testModifiedCursorKeysUseXtermModifierParameters() {
        XCTAssertEqual(
            TerminalInputEncoder.encode(.up, applicationCursor: false, modifiers: .shift),
            Array("\u{1B}[1;2A".utf8)
        )
        XCTAssertEqual(
            TerminalInputEncoder.encode(.left, applicationCursor: true, modifiers: .alt),
            Array("\u{1B}[1;3D".utf8)
        )
        XCTAssertEqual(
            TerminalInputEncoder.encode(.end, applicationCursor: true, modifiers: .control),
            Array("\u{1B}[1;5F".utf8)
        )
        XCTAssertEqual(
            TerminalInputEncoder.encode(
                .right,
                applicationCursor: false,
                modifiers: [.shift, .alt, .control]
            ),
            Array("\u{1B}[1;8C".utf8)
        )
    }

    func testCharacterModifiersAreSemanticRatherThanRawBytePrefixes() {
        XCTAssertEqual(
            TerminalInputEncoder.encode(.slash, applicationCursor: false, modifiers: .shift),
            Array("?".utf8)
        )
        XCTAssertEqual(
            TerminalInputEncoder.encode(.slash, applicationCursor: false, modifiers: .control),
            [0x1F]
        )
        XCTAssertEqual(
            TerminalInputEncoder.encode(.dash, applicationCursor: false, modifiers: .alt),
            [0x1B, 0x2D]
        )
        XCTAssertEqual(
            TerminalInputEncoder.encode(
                .dash,
                applicationCursor: false,
                modifiers: [.shift, .control, .alt]
            ),
            [0x1B, 0x1F]
        )
    }

    func testTabAndEnterMatchTermuxExtraKeySemantics() {
        XCTAssertEqual(
            TerminalInputEncoder.encode(.tab, applicationCursor: false, modifiers: .control),
            [0x09]
        )
        XCTAssertEqual(
            TerminalInputEncoder.encode(.tab, applicationCursor: false, modifiers: .shift),
            Array("\u{1B}[Z".utf8)
        )
        XCTAssertEqual(
            TerminalInputEncoder.encode(
                .tab,
                applicationCursor: false,
                modifiers: [.shift, .alt]
            ),
            Array("\u{1B}\u{1B}[Z".utf8)
        )
        XCTAssertEqual(
            TerminalInputEncoder.encode(.enter, applicationCursor: false, modifiers: .shift),
            [0x0A]
        )
        XCTAssertEqual(
            TerminalInputEncoder.encode(.enter, applicationCursor: false, modifiers: .alt),
            [0x1B, 0x0D]
        )
    }

    func testAndroidLongPressActionsRemainIntrinsic() {
        let cases: [(TerminalInputKey, [UInt8])] = [
            (.interrupt, [0x03]),
            (.pipe, [0x7C]),
            (.pageUp, Array("\u{1B}[5~".utf8)),
            (.pageDown, Array("\u{1B}[6~".utf8)),
            (.wordLeft, [0x1B, 0x62]),
            (.wordRight, [0x1B, 0x66]),
        ]

        for (key, expected) in cases {
            XCTAssertEqual(
                TerminalInputEncoder.encode(key, applicationCursor: true),
                expected
            )
        }
    }

    func testStickyModifiersAreConsumedTogetherByToolbarTap() {
        let state = ModifierState()
        state.ctrl = true
        state.alt = true
        state.shift = true

        XCTAssertEqual(state.consume(), [.control, .alt, .shift])
        XCTAssertFalse(state.ctrl)
        XCTAssertFalse(state.alt)
        XCTAssertFalse(state.shift)
        XCTAssertTrue(state.consume().isEmpty)
    }

    func testToolbarActionIdentitiesAreStableAndUnique() {
        let identifiers = TerminalToolbarActionID.allCases.map(\.rawValue)

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(TerminalToolbarActionID.dismissKeyboard.rawValue, "dismissKeyboard")
        XCTAssertEqual(TerminalToolbarActionID.paste.rawValue, "paste")
    }

    func testToolbarLayoutPinsAndroidCoreRowsAndAppendsIOSUtilities() {
        XCTAssertEqual(
            TerminalToolbarLayout.androidCoreRow1,
            [.escape, .slash, .dash, .home, .up, .end, .shift]
        )
        XCTAssertEqual(
            TerminalToolbarLayout.androidCoreRow2,
            [.tab, .control, .alt, .left, .down, .right, .enter]
        )
        XCTAssertEqual(
            TerminalToolbarLayout.row1,
            TerminalToolbarLayout.androidCoreRow1 + [.paste]
        )
        XCTAssertEqual(
            TerminalToolbarLayout.row2,
            TerminalToolbarLayout.androidCoreRow2 + [.dismissKeyboard]
        )
    }
}
