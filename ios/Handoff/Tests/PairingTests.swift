import XCTest
@testable import Handoff

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
