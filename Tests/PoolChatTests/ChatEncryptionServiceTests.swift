// ChatEncryptionServiceTests.swift
// PoolChatTests

import XCTest
import CryptoKit
@testable import PoolChat

final class ChatEncryptionServiceTests: XCTestCase {

    // MARK: - Helpers

    /// ChatEncryptionService is a singleton with private init.
    /// All tests share the same instance. We call regenerateKeys() in setUp
    /// to reset state between tests.
    private var sut: ChatEncryptionService { ChatEncryptionService.shared }

    override func setUp() {
        super.setUp()
        sut.regenerateKeys()
    }

    // MARK: - Key Generation

    func testPublicKeyIsNonEmpty() {
        let publicKey = sut.publicKey
        XCTAssertEqual(publicKey.count, 32, "Curve25519 public key must be 32 bytes")
    }

    func testRegenerateKeysProducesNewPublicKey() {
        let firstKey = sut.publicKey
        sut.regenerateKeys()
        let secondKey = sut.publicKey
        XCTAssertNotEqual(firstKey, secondKey, "Regenerated keys should differ from previous keys")
    }

    func testRegenerateKeysClearsPeerKeys() {
        // Establish a peer key first
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPublicKeyData = peerKey.publicKey.rawRepresentation
        let peerID = "peer-1"
        let success = sut.performKeyExchange(peerPublicKeyData: peerPublicKeyData, peerID: peerID)
        XCTAssertTrue(success)
        XCTAssertTrue(sut.hasKeyFor(peerID: peerID))

        sut.regenerateKeys()

        XCTAssertFalse(sut.hasKeyFor(peerID: peerID), "Peer keys must be cleared after regeneration")
        XCTAssertEqual(sut.peerKeyCount, 0)
    }

    // MARK: - Key Exchange

    func testSuccessfulKeyExchange() {
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        let peerID = "peer-exchange"
        let success = sut.performKeyExchange(peerPublicKeyData: peerKey.publicKey.rawRepresentation, peerID: peerID)
        XCTAssertTrue(success)
        XCTAssertTrue(sut.hasKeyFor(peerID: peerID))
        XCTAssertEqual(sut.peerKeyCount, 1)
    }

    func testKeyExchangeRejectsZeroKey() {
        let zeroKey = Data(repeating: 0, count: 32)
        let success = sut.performKeyExchange(peerPublicKeyData: zeroKey, peerID: "zero-peer")
        XCTAssertFalse(success, "Must reject all-zero degenerate key")
        XCTAssertFalse(sut.hasKeyFor(peerID: "zero-peer"))
    }

    func testKeyExchangeRejectsWrongLength() {
        let shortKey = Data(repeating: 1, count: 16)
        let success = sut.performKeyExchange(peerPublicKeyData: shortKey, peerID: "short-peer")
        XCTAssertFalse(success, "Must reject key with incorrect length")
    }

    func testKeyExchangeRejectsOwnPublicKey() {
        let ownPublicKey = sut.publicKey
        let success = sut.performKeyExchange(peerPublicKeyData: ownPublicKey, peerID: "reflection-peer")
        XCTAssertFalse(success, "Must reject own public key (reflection attack)")
    }

    // MARK: - Encrypt / Decrypt Round-Trip

    func testEncryptDecryptRoundTrip() {
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        let peerID = "roundtrip-peer"
        let exchanged = sut.performKeyExchange(peerPublicKeyData: peerKey.publicKey.rawRepresentation, peerID: peerID)
        XCTAssertTrue(exchanged)

        let plaintext = "Hello, encrypted world!"
        let encrypted = sut.encryptMessage(plaintext, for: peerID)
        XCTAssertNotNil(encrypted, "Encryption must succeed after key exchange")

        let decrypted = sut.decryptMessage(encrypted!, from: peerID)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptReturnsNilWithoutKeyExchange() {
        let result = sut.encrypt(Data("test".utf8), for: "unknown-peer")
        XCTAssertNil(result, "Encrypt must return nil for unknown peer")
    }

    func testDecryptReturnsNilWithoutKeyExchange() {
        let result = sut.decrypt(Data(repeating: 0, count: 64), from: "unknown-peer")
        XCTAssertNil(result, "Decrypt must return nil for unknown peer")
    }

    func testEncryptForAllPeers() {
        // Set up two peers
        let peer1Key = Curve25519.KeyAgreement.PrivateKey()
        let peer2Key = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertTrue(sut.performKeyExchange(peerPublicKeyData: peer1Key.publicKey.rawRepresentation, peerID: "peer-a"))
        XCTAssertTrue(sut.performKeyExchange(peerPublicKeyData: peer2Key.publicKey.rawRepresentation, peerID: "peer-b"))

        let data = Data("broadcast".utf8)
        let encrypted = sut.encryptForAllPeers(data)

        XCTAssertEqual(encrypted.count, 2)
        XCTAssertNotNil(encrypted["peer-a"])
        XCTAssertNotNil(encrypted["peer-b"])
    }

    // MARK: - Peer Key Management

    func testRemovePeerKey() {
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        let peerID = "removable-peer"
        XCTAssertTrue(sut.performKeyExchange(peerPublicKeyData: peerKey.publicKey.rawRepresentation, peerID: peerID))
        XCTAssertTrue(sut.hasKeyFor(peerID: peerID))

        sut.removePeerKey(peerID: peerID)
        XCTAssertFalse(sut.hasKeyFor(peerID: peerID))
    }

    func testClearAllPeerKeys() {
        let peer1Key = Curve25519.KeyAgreement.PrivateKey()
        let peer2Key = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertTrue(sut.performKeyExchange(peerPublicKeyData: peer1Key.publicKey.rawRepresentation, peerID: "p1"))
        XCTAssertTrue(sut.performKeyExchange(peerPublicKeyData: peer2Key.publicKey.rawRepresentation, peerID: "p2"))
        XCTAssertEqual(sut.peerKeyCount, 2)

        sut.clearAllPeerKeys()
        XCTAssertEqual(sut.peerKeyCount, 0)
    }

    // MARK: - Key Fingerprints

    func testPublicKeyFingerprintFormat() {
        let fingerprint = sut.publicKeyFingerprint
        // Format: XX:XX:XX:XX:XX:XX:XX:XX (8 hex pairs separated by colons)
        let components = fingerprint.split(separator: ":")
        XCTAssertEqual(components.count, 8, "Fingerprint must have 8 hex pairs")
        for component in components {
            XCTAssertEqual(component.count, 2, "Each fingerprint component must be 2 hex characters")
            XCTAssertNotNil(UInt8(component, radix: 16), "Each component must be valid hex")
        }
    }

    func testSharedKeyFingerprintExistsAfterExchange() {
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        let peerID = "fingerprint-peer"
        XCTAssertTrue(sut.performKeyExchange(peerPublicKeyData: peerKey.publicKey.rawRepresentation, peerID: peerID))

        let fingerprint = sut.sharedKeyFingerprint(for: peerID)
        XCTAssertNotNil(fingerprint)
        let components = fingerprint!.split(separator: ":")
        XCTAssertEqual(components.count, 8)
    }

    func testSharedKeyFingerprintNilForUnknownPeer() {
        let fingerprint = sut.sharedKeyFingerprint(for: "nonexistent")
        XCTAssertNil(fingerprint)
    }

    // MARK: - TOFU

    func testTOFUNewPeerEmitsEvent() {
        let expectation = XCTestExpectation(description: "newPeerTrusted event")
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        let peerID = "tofu-new-peer"

        let cancellable = sut.peerKeyEvents.sink { event in
            if case .newPeerTrusted(let id, _) = event, id == peerID {
                expectation.fulfill()
            }
        }

        XCTAssertTrue(sut.performKeyExchange(peerPublicKeyData: peerKey.publicKey.rawRepresentation, peerID: peerID))

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testTOFUPeerKeyChangedEmitsEvent() {
        let peerKey1 = Curve25519.KeyAgreement.PrivateKey()
        let peerKey2 = Curve25519.KeyAgreement.PrivateKey()
        let peerID = "tofu-changed-peer"

        // First exchange (records the key)
        XCTAssertTrue(sut.performKeyExchange(peerPublicKeyData: peerKey1.publicKey.rawRepresentation, peerID: peerID))

        // Second exchange with different key should emit peerKeyChanged
        let expectation = XCTestExpectation(description: "peerKeyChanged event")
        let cancellable = sut.peerKeyEvents.sink { event in
            if case .peerKeyChanged(let id, _, _) = event, id == peerID {
                expectation.fulfill()
            }
        }

        XCTAssertTrue(sut.performKeyExchange(peerPublicKeyData: peerKey2.publicKey.rawRepresentation, peerID: peerID))
        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    // MARK: - Session Teardown

    func testSessionTeardownClearsEverything() {
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertTrue(sut.performKeyExchange(peerPublicKeyData: peerKey.publicKey.rawRepresentation, peerID: "teardown-peer"))
        let oldPublicKey = sut.publicKey

        sut.sessionTeardown()

        XCTAssertNotEqual(sut.publicKey, oldPublicKey)
        XCTAssertEqual(sut.peerKeyCount, 0)
        XCTAssertFalse(sut.hasKeyFor(peerID: "teardown-peer"))
    }

    // MARK: - Relayed Key Exchange

    func testInitiateRelayedKeyExchange() {
        let payload = sut.initiateRelayedKeyExchange(targetPeerID: "remote-peer", ourPeerID: "local-peer")
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.originPeerID, "local-peer")
        XCTAssertEqual(payload?.targetPeerID, "remote-peer")
        XCTAssertFalse(payload!.isResponse)
        XCTAssertEqual(payload?.publicKey, sut.publicKey)
    }

    func testHandleRelayedKeyExchangeRejectsWrongTarget() {
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        let payload = RelayedKeyExchangePayload(
            publicKey: peerKey.publicKey.rawRepresentation,
            originPeerID: "sender",
            targetPeerID: "someone-else",
            isResponse: false
        )
        let response = sut.handleRelayedKeyExchange(payload, ourPeerID: "not-someone-else")
        XCTAssertNil(response, "Must reject payload not intended for us")
    }
}
