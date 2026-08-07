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

    func testToolbarActionIdentitiesAreStableAndUnique() {
        let identifiers = TerminalToolbarActionID.allCases.map(\.rawValue)

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(TerminalToolbarActionID.dismissKeyboard.rawValue, "dismissKeyboard")
        XCTAssertEqual(TerminalToolbarActionID.paste.rawValue, "paste")
    }
}
