import XCTest
@testable import Handoff

final class AppLockNavigationPolicyTests: XCTestCase {
    func testBackgroundLockInvalidatesPushedRouteAndUnlockKeepsSafeRoot() {
        var retainedRoutes: [ContentView.Route] = [
            .terminal(session: "main", window: 0, readOnly: false)
        ]
        let background = AppLockNavigationPolicy.decision(
            for: .enteredBackground,
            isPaired: true,
            appLockEnabled: true,
            appLockAvailable: true
        )

        XCTAssertFalse(background.hasUnlockedAppFlow)
        XCTAssertTrue(background.clearsNavigationPath)
        if background.clearsNavigationPath {
            retainedRoutes.removeAll()
        }
        XCTAssertTrue(retainedRoutes.isEmpty)

        let unlock = AppLockNavigationPolicy.decision(
            for: .authenticationSucceeded,
            isPaired: true,
            appLockEnabled: true,
            appLockAvailable: true
        )

        XCTAssertTrue(unlock.hasUnlockedAppFlow)
        XCTAssertFalse(unlock.clearsNavigationPath)
        XCTAssertTrue(retainedRoutes.isEmpty)
    }

    func testBackgroundDoesNotDiscardNavigationWhenLockCannotBeEnforced() {
        let unavailable = AppLockNavigationPolicy.decision(
            for: .enteredBackground,
            isPaired: true,
            appLockEnabled: true,
            appLockAvailable: false
        )
        let disabled = AppLockNavigationPolicy.decision(
            for: .enteredBackground,
            isPaired: true,
            appLockEnabled: false,
            appLockAvailable: true
        )

        XCTAssertFalse(unavailable.clearsNavigationPath)
        XCTAssertFalse(disabled.clearsNavigationPath)
    }

    func testPairingChangeAlwaysInvalidatesPreviousPairingRoute() {
        let decision = AppLockNavigationPolicy.decision(
            for: .pairingChanged,
            isPaired: false,
            appLockEnabled: true,
            appLockAvailable: true
        )

        XCTAssertFalse(decision.hasUnlockedAppFlow)
        XCTAssertTrue(decision.clearsNavigationPath)
    }
}

final class TailscaleLifecyclePolicyTests: XCTestCase {
    func testOnlyExplicitSignOutDeletesPersistedIdentity() {
        XCTAssertFalse(TailscaleLifecycleOperation.start.deletesPersistedIdentity)
        XCTAssertFalse(
            TailscaleLifecycleOperation.retryPreservingIdentity.deletesPersistedIdentity
        )
        XCTAssertFalse(TailscaleLifecycleOperation.stop.deletesPersistedIdentity)
        XCTAssertTrue(
            TailscaleLifecycleOperation.signOutAndForgetIdentity.deletesPersistedIdentity
        )
    }

    func testRetryStartsOnlyAfterCleanupWithoutBecomingDestructive() {
        let retry = TailscaleLifecycleOperation.retryPreservingIdentity

        XCTAssertTrue(retry.startsNodeAfterCleanup)
        XCTAssertFalse(retry.deletesPersistedIdentity)
    }

    func testSupersededLifecycleGenerationCannotPublish() {
        var epoch = TailscaleLifecycleEpoch()
        let staleStart = epoch.begin()
        let currentRetry = epoch.begin()

        XCTAssertFalse(epoch.owns(staleStart))
        XCTAssertTrue(epoch.owns(currentRetry))
    }
}

final class QRCodePayloadTests: XCTestCase {
    func testParsesV1PayloadWithoutChangingFullKey() throws {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        dGVzdA==
        -----END OPENSSH PRIVATE KEY-----

        """
        let encodedPEM = try XCTUnwrap(pem.data(using: .utf8)?.base64EncodedString())
        let payload = try jsonString([
            "v": 1,
            "ip": "100.64.0.10",
            "user": "omri",
            "key": encodedPEM,
            "tmux": "/opt/homebrew/bin/tmux"
        ])

        let config = try QRCodePayload.parse(payload)

        XCTAssertEqual(config.ip, "100.64.0.10")
        XCTAssertEqual(config.user, "omri")
        XCTAssertEqual(config.privateKey, encodedPEM)
        XCTAssertEqual(config.tmuxPath, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(config.protocolVersion, 1)
        XCTAssertEqual(config.nonce, "")
    }

    func testParsesV2AndReconstructsWrappedOpenSSHKey() throws {
        let innerKey = Data((0..<90).map(UInt8.init)).base64EncodedString()
        let payload = try jsonString([
            "v": 2,
            "i": "100.64.0.11",
            "u": "omri",
            "k": innerKey,
            "t": "/usr/local/bin/tmux",
            "n": "abcdef0123456789"
        ])

        let config = try QRCodePayload.parse(payload)
        let reconstructedData = try XCTUnwrap(Data(base64Encoded: config.privateKey))
        let reconstructed = try XCTUnwrap(String(data: reconstructedData, encoding: .utf8))
        let expectedBody = stride(from: 0, to: innerKey.count, by: 70)
            .map { start -> String in
                let lower = innerKey.index(innerKey.startIndex, offsetBy: start)
                let upper = innerKey.index(lower, offsetBy: min(70, innerKey.count - start))
                return String(innerKey[lower..<upper])
            }
            .joined(separator: "\n")
        let expected = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(expectedBody)
        -----END OPENSSH PRIVATE KEY-----

        """

        XCTAssertEqual(reconstructed, expected)
        XCTAssertEqual(config.ip, "100.64.0.11")
        XCTAssertEqual(config.user, "omri")
        XCTAssertEqual(config.tmuxPath, "/usr/local/bin/tmux")
        XCTAssertEqual(config.protocolVersion, 2)
        XCTAssertEqual(config.nonce, "abcdef0123456789")
    }

    func testRejectsUnsupportedVersion() throws {
        let payload = try jsonString(["v": 99])

        XCTAssertThrowsError(try QRCodePayload.parse(payload)) { error in
            guard case QRCodePayload.ParseError.unsupportedVersion(99) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsCorruptJSON() {
        XCTAssertThrowsError(try QRCodePayload.parse("not-json")) { error in
            guard case QRCodePayload.ParseError.invalidJSON = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsCorruptKeysInBothPayloadVersions() throws {
        let v1 = try jsonString([
            "v": 1,
            "ip": "100.64.0.10",
            "user": "omri",
            "key": "not base64!",
            "tmux": "/usr/bin/tmux"
        ])
        let v2 = try jsonString([
            "v": 2,
            "i": "100.64.0.10",
            "u": "omri",
            "k": "not base64!",
            "t": "/usr/bin/tmux"
        ])

        for payload in [v1, v2] {
            XCTAssertThrowsError(try QRCodePayload.parse(payload)) { error in
                guard case QRCodePayload.ParseError.invalidKey = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testRejectsMissingRequiredField() throws {
        let payload = try jsonString([
            "v": 2,
            "i": "100.64.0.10",
            "u": "omri",
            "k": "dGVzdA=="
        ])

        XCTAssertThrowsError(try QRCodePayload.parse(payload)) { error in
            guard case QRCodePayload.ParseError.missingField("t") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

final class PairingDeviceNameTests: XCTestCase {
    func testPreservesOrdinaryASCIIName() {
        XCTAssertEqual(
            PairingDeviceName.sanitize("Omri iPhone-15_Pro.local"),
            "Omri iPhone-15_Pro.local"
        )
    }

    func testRemovesCommandBreakingCharactersAndControls() {
        let sanitized = PairingDeviceName.sanitize("Omri's\\iPhone\npair attacker\t💥")

        XCTAssertEqual(sanitized, "Omri s iPhone pair attacker")
        XCTAssertFalse(sanitized.contains("'"))
        XCTAssertFalse(sanitized.contains("\\"))
        XCTAssertFalse(sanitized.contains("\n"))
        XCTAssertTrue(sanitized.unicodeScalars.allSatisfy(\.isASCII))
    }

    func testFoldsAccentedLatinCharactersToASCII() {
        XCTAssertEqual(PairingDeviceName.sanitize("Élodie's iPhone"), "Elodie s iPhone")
    }

    func testBoundsNameLength() {
        let sanitized = PairingDeviceName.sanitize(String(repeating: "a", count: 100))

        XCTAssertEqual(sanitized.count, PairingDeviceName.maximumLength)
    }

    func testUsesFallbackWhenNoSafeCharactersRemain() {
        XCTAssertEqual(PairingDeviceName.sanitize("💥\n\\''"), "iPhone")
    }
}

final class SSHAuthenticationAttemptTests: XCTestCase {
    func testPublicKeyIsOfferedOnlyOncePerConnectionAttempt() {
        let attempt = PublicKeyAuthenticationAttempt()

        XCTAssertTrue(attempt.claimKeyOffer())
        XCTAssertFalse(attempt.claimKeyOffer())
        XCTAssertFalse(attempt.claimKeyOffer())
    }

    func testRejectedAuthenticationHasActionableDescription() {
        XCTAssertEqual(
            SSHError.authenticationRejected.errorDescription,
            "This pairing key is no longer accepted by the Mac. Unpair and scan a new QR code from handoff pair."
        )
    }
}

final class SSHConnectionLifecycleTests: XCTestCase {
    func testActiveTCPChannelIsNotUsableUntilCurrentAttemptAuthenticates() {
        let lifecycle = SSHConnectionLifecycle()
        let attempt = lifecycle.begin()

        XCTAssertFalse(lifecycle.isUsable(channelIsActive: true))
        XCTAssertTrue(lifecycle.markAuthenticated(attempt))
        XCTAssertTrue(lifecycle.isUsable(channelIsActive: true))
        XCTAssertFalse(lifecycle.isUsable(channelIsActive: false))
    }

    func testStaleAuthenticationCannotClaimNewerConnection() {
        let lifecycle = SSHConnectionLifecycle()
        let oldAttempt = lifecycle.begin()
        let newAttempt = lifecycle.begin()

        XCTAssertFalse(lifecycle.markAuthenticated(oldAttempt))
        XCTAssertFalse(lifecycle.isUsable(channelIsActive: true))
        XCTAssertTrue(lifecycle.markAuthenticated(newAttempt))
        XCTAssertTrue(lifecycle.isUsable(channelIsActive: true))
    }

    func testDisconnectInvalidatesAuthenticatedConnection() {
        let lifecycle = SSHConnectionLifecycle()
        let attempt = lifecycle.begin()
        XCTAssertTrue(lifecycle.markAuthenticated(attempt))

        lifecycle.invalidate()

        XCTAssertFalse(lifecycle.isCurrent(attempt))
        XCTAssertFalse(lifecycle.isUsable(channelIsActive: true))
    }
}

final class SSHExecTerminationPolicyTests: XCTestCase {
    func testCleanZeroExitReturnsCompleteOutput() throws {
        var policy = SSHExecTerminationPolicy()
        policy.recordExitStatus(0)

        let output = try policy.resolve(
            stdout: "main:1\n",
            stderr: "",
            usesGateProtocol: false
        ).get()

        XCTAssertEqual(output, "main:1\n")
    }

    func testTransportCloseWithoutExitStatusIsFailure() {
        let policy = SSHExecTerminationPolicy()

        assertCommandFailure(
            policy.resolve(
                stdout: "main:",
                stderr: "",
                usesGateProtocol: false
            ),
            contains: "closed before"
        )
    }

    func testNormalizedEmptySessionListIsSuccessfulAfterCleanExit() throws {
        var policy = SSHExecTerminationPolicy()
        policy.recordExitStatus(0)

        let output = try policy.resolve(
            stdout: "",
            stderr: "",
            usesGateProtocol: false
        ).get()

        XCTAssertEqual(output, "")
    }

    func testNonZeroRawCommandExitIsFailure() {
        var policy = SSHExecTerminationPolicy()
        policy.recordExitStatus(1)

        assertCommandFailure(
            policy.resolve(
                stdout: "",
                stderr: "tmux failed",
                usesGateProtocol: false
            ),
            contains: "status 1: tmux failed"
        )
    }

    func testGateNonZeroExitPreservesTypedGateError() {
        var policy = SSHExecTerminationPolicy()
        policy.recordExitStatus(1)

        switch policy.resolve(
            stdout: "error:soft_expired\n",
            stderr: "",
            usesGateProtocol: true
        ) {
        case .success:
            XCTFail("Expected gate failure")
        case .failure(let error):
            XCTAssertEqual(error as? GateError, GateError(rawCode: "error:soft_expired"))
        }
    }

    func testExitSignalIsFailureEvenIfAZeroStatusWasObserved() {
        var policy = SSHExecTerminationPolicy()
        policy.recordExitStatus(0)
        policy.recordExitSignal(name: "TERM", message: "stopped")

        assertCommandFailure(
            policy.resolve(
                stdout: "main:1\n",
                stderr: "",
                usesGateProtocol: false
            ),
            contains: "signal TERM: stopped"
        )
    }

    private func assertCommandFailure(
        _ result: Result<String, Error>,
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("Expected command failure", file: file, line: line)
        case .failure(let error):
            guard case SSHError.commandFailed(let reason) = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(expected), "\(reason) does not contain \(expected)", file: file, line: line)
        }
    }
}

final class SSHDiscoveryCommandTests: XCTestCase {
    func testV1ListNormalizesOnlyTmuxNoServerExit() {
        XCTAssertEqual(
            SSHDiscoveryCommand.listSessions(
                protocolVersion: 1,
                tmuxPath: "/opt/homebrew/bin/tmux"
            ),
            "/opt/homebrew/bin/tmux list-sessions -F '#{session_name}:#{session_windows}' 2>/dev/null || true"
        )
    }

    func testV2ListRemainsGateCommand() {
        XCTAssertEqual(
            SSHDiscoveryCommand.listSessions(
                protocolVersion: 2,
                tmuxPath: "/ignored/tmux"
            ),
            "list"
        )
    }
}

final class SessionsRequestEpochTests: XCTestCase {
    func testFullLoadSupersedesSilentRefresh() {
        var epoch = SessionsRequestEpoch()
        let refresh = epoch.beginRefresh()
        let load = epoch.beginLoad()

        XCTAssertFalse(epoch.ownsRefresh(refresh))
        XCTAssertTrue(epoch.ownsLoad(load))
    }

    func testCancelledLoadCannotPublishIntoRetry() {
        var epoch = SessionsRequestEpoch()
        let cancelledLoad = epoch.beginLoad()
        epoch.invalidateAll()
        let retry = epoch.beginLoad()

        XCTAssertFalse(epoch.ownsLoad(cancelledLoad))
        XCTAssertTrue(epoch.ownsLoad(retry))
    }

    func testOldRefreshCleanupCannotClearNewRefresh() {
        var epoch = SessionsRequestEpoch()
        let oldRefresh = epoch.beginRefresh()
        let newRefresh = epoch.beginRefresh()

        XCTAssertFalse(epoch.ownsRefresh(oldRefresh))
        XCTAssertTrue(epoch.ownsRefresh(newRefresh))
    }
}

final class SessionsLoadRetryPolicyTests: XCTestCase {
    func testTransportFailureRetriesSSHExactlyOnceWithoutRestartingTailscale() {
        let firstRecovery = SessionsLoadRetryPolicy.recovery(
            for: .transport,
            attempt: .initial
        )
        guard case .retrySSH(let backoffNanoseconds) = firstRecovery else {
            return XCTFail("Initial transport failure should retry discovery SSH")
        }
        XCTAssertGreaterThanOrEqual(backoffNanoseconds, 500_000_000)
        XCTAssertLessThanOrEqual(backoffNanoseconds, 800_000_000)
        XCTAssertFalse(firstRecovery.restartsTailscaleTransport)

        let retryRecovery = SessionsLoadRetryPolicy.recovery(
            for: .transport,
            attempt: .automaticRetry
        )
        XCTAssertEqual(retryRecovery, .surfaceError)
        XCTAssertFalse(retryRecovery.restartsTailscaleTransport)
    }

    func testStructuredFailuresNeverEnterTransportRecovery() {
        for failure in [
            SessionsLoadRetryPolicy.Failure.gate,
            .hostKeyMismatch
        ] {
            let recovery = SessionsLoadRetryPolicy.recovery(
                for: failure,
                attempt: .initial
            )
            XCTAssertEqual(recovery, .surfaceError)
            XCTAssertFalse(recovery.restartsTailscaleTransport)
        }
    }
}
