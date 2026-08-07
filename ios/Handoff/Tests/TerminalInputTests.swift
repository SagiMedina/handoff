import XCTest
import SwiftTerm
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

final class RemoteTerminalOutputTests: XCTestCase {
    @MainActor
    func testPTYEchoKeepsVisualCaretAlignedAfterTextAndBackspace() async throws {
        let terminalView = SwiftTerm.TerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 160)
        )
        terminalView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        terminalView.resize(cols: 32, rows: 8)
        terminalView.layoutIfNeeded()

        let caret = try XCTUnwrap(
            terminalView.subviews.first {
                String(reflecting: type(of: $0)).contains("CaretView")
            },
            "SwiftTerm should install its visual caret as a terminal subview"
        )
        let initialX = caret.frame.minX

        RemoteTerminalOutput.feed(Data("abc".utf8), into: terminalView)
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterTextX = caret.frame.minX

        XCTAssertGreaterThan(
            afterTextX,
            initialX,
            "PTY-echoed text must advance SwiftTerm's visual caret"
        )

        // A canonical PTY commonly echoes Backspace as BS, space, BS so the
        // erased cell is cleared while the cursor finishes one column left.
        RemoteTerminalOutput.feed(Data([0x08, 0x20, 0x08]), into: terminalView)
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterBackspaceX = caret.frame.minX

        XCTAssertLessThan(
            afterBackspaceX,
            afterTextX,
            "PTY backspace echo must move SwiftTerm's visual caret left"
        )
        XCTAssertGreaterThan(afterBackspaceX, initialX)
    }

    @MainActor
    func testBackgroundPTYIngressSafelyUpdatesAndHidesCaretInOrder() async throws {
        let terminalView = SwiftTerm.TerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 160)
        )
        terminalView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        terminalView.resize(cols: 32, rows: 8)
        terminalView.layoutIfNeeded()

        let caret = try XCTUnwrap(
            terminalView.subviews.first {
                String(reflecting: type(of: $0)).contains("CaretView")
            }
        )
        let ingressReturned = expectation(description: "background PTY ingress returned")

        DispatchQueue.global(qos: .userInitiated).async {
            RemoteTerminalOutput.feed(Data("abc".utf8), into: terminalView)
            RemoteTerminalOutput.feed(Data([0x08, 0x20, 0x08]), into: terminalView)
            RemoteTerminalOutput.feed(Data("\u{1B}[?25l".utf8), into: terminalView)
            ingressReturned.fulfill()
        }

        await fulfillment(of: [ingressReturned], timeout: 1)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            terminalView.getTerminal().buffer.x,
            2,
            "Background PTY chunks must reach the view-level feed in arrival order"
        )
        XCTAssertNil(
            caret.superview,
            "Cursor-hide output must remove SwiftTerm's UIKit caret on the main thread"
        )
    }
}

final class RemoteTerminalInputTests: XCTestCase {
    func testStickyShiftRewritesKeyboardReturnToLineFeed() {
        let routed = RemoteTerminalInput.route([0x0D][...], stickyShift: true)

        XCTAssertEqual(routed.data, Data([0x0A]))
        XCTAssertTrue(routed.consumedShift)
    }

    func testKeyboardReturnWithoutStickyShiftRemainsCarriageReturn() {
        let routed = RemoteTerminalInput.route([0x0D][...], stickyShift: false)

        XCTAssertEqual(routed.data, Data([0x0D]))
        XCTAssertFalse(routed.consumedShift)
    }

    func testStickyShiftWaitsForReturnInsteadOfRewritingIMEText() {
        let text = Array("a".utf8)
        let routed = RemoteTerminalInput.route(text[...], stickyShift: true)

        XCTAssertEqual(routed.data, Data(text))
        XCTAssertFalse(routed.consumedShift)
    }
}

final class TerminalScreenVisibilityTests: XCTestCase {
    func testCachedTerminalDoesNotKeepIdleTimerDisabledAfterScreenDisappears() {
        var visibility = TerminalScreenVisibility()
        let screenID = UUID()

        visibility.didAppear(screenID)
        XCTAssertTrue(visibility.shouldDisableIdleTimer)

        visibility.didDisappear(screenID)
        XCTAssertFalse(visibility.shouldDisableIdleTimer)
    }

    func testDuplicateAppearAndDisappearAreIdempotent() {
        var visibility = TerminalScreenVisibility()
        let screenID = UUID()

        visibility.didAppear(screenID)
        visibility.didAppear(screenID)
        visibility.didDisappear(screenID)

        XCTAssertFalse(visibility.shouldDisableIdleTimer)
    }
}

final class TerminalPresentationLifecycleTests: XCTestCase {
    func testCurrentVisibleChannelDeathSurfacesReconnectState() {
        let terminalID = UUID()

        XCTAssertTrue(
            TerminalPresentationLifecycle.shouldSurfaceChannelClosure(
                removedCurrentGeneration: true,
                screenIsVisible: true,
                presentedTerminalID: terminalID,
                closedTerminalID: terminalID
            )
        )
    }

    func testDelayedOldGenerationClosureCannotDisturbReplacement() {
        let oldTerminalID = UUID()
        let replacementTerminalID = UUID()

        XCTAssertFalse(
            TerminalPresentationLifecycle.shouldSurfaceChannelClosure(
                removedCurrentGeneration: false,
                screenIsVisible: true,
                presentedTerminalID: replacementTerminalID,
                closedTerminalID: oldTerminalID
            )
        )
        XCTAssertFalse(
            TerminalPresentationLifecycle.shouldSurfaceChannelClosure(
                removedCurrentGeneration: true,
                screenIsVisible: true,
                presentedTerminalID: replacementTerminalID,
                closedTerminalID: oldTerminalID
            )
        )
    }

    func testHiddenCachedTerminalDeathDoesNotMutateDismissedScreen() {
        let terminalID = UUID()

        XCTAssertFalse(
            TerminalPresentationLifecycle.shouldSurfaceChannelClosure(
                removedCurrentGeneration: true,
                screenIsVisible: false,
                presentedTerminalID: terminalID,
                closedTerminalID: terminalID
            )
        )
    }
}

final class TerminalConnectEpochTests: XCTestCase {
    func testNewAttemptRevokesOlderAttemptOwnership() {
        var epoch = TerminalConnectEpoch()
        let oldAttempt = epoch.begin()
        let replacement = epoch.begin()

        XCTAssertFalse(epoch.owns(oldAttempt))
        XCTAssertTrue(epoch.owns(replacement))
    }

    func testCancellationInvalidatesAttemptBeforeAsyncWorkResumes() {
        var epoch = TerminalConnectEpoch()
        let cancelledAttempt = epoch.begin()

        epoch.invalidate()

        XCTAssertFalse(epoch.owns(cancelledAttempt))
    }

    func testDisappearCancelsOnlyUnestablishedAttach() {
        XCTAssertTrue(
            TerminalConnectDisappearPolicy.shouldCancelAttempt(
                hasInFlightAttempt: true,
                hasActiveRetainedTerminal: false
            )
        )
        XCTAssertFalse(
            TerminalConnectDisappearPolicy.shouldCancelAttempt(
                hasInFlightAttempt: false,
                hasActiveRetainedTerminal: false
            )
        )
        XCTAssertFalse(
            TerminalConnectDisappearPolicy.shouldCancelAttempt(
                hasInFlightAttempt: true,
                hasActiveRetainedTerminal: true
            ),
            "An attached cached terminal must survive Back"
        )
    }
}
