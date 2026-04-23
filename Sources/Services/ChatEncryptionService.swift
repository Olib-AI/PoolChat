// ChatEncryptionService.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import Combine
import CryptoKit

// MARK: - Peer Key Event

/// Events emitted by the TOFU (Trust-On-First-Use) system when peer key state changes.
///
/// Subscribe to `ChatEncryptionService.peerKeyEvents` to receive these events
/// and present appropriate UI alerts (e.g., "peer identity has changed" warnings).
public enum PeerKeyEvent: Sendable {
    /// A new peer was seen for the first time; its public key has been recorded.
    case newPeerTrusted(peerID: String, fingerprint: String)

    /// A previously seen peer presented a different public key.
    /// This may indicate a MITM attack, or the peer simply regenerated keys.
    case peerKeyChanged(peerID: String, oldFingerprint: String, newFingerprint: String)

    /// A peer's fingerprint was explicitly verified out-of-band.
    case peerVerified(peerID: String)
}

/// Service for end-to-end encryption of chat messages.
///
/// SAFETY: @unchecked Sendable is required because:
/// 1. The service maintains mutable cryptographic state (private key, peer keys)
/// 2. It may be accessed from multiple actors/tasks during chat operations
/// 3. All mutable state is protected by NSLock for thread-safe access
/// 4. The lock guards: _privateKey, _peerKeys dictionary, _knownPeerKeys, _trustedPeerFingerprints
///
/// ## TOFU (Trust-On-First-Use) Model
/// The relayed key exchange is unauthenticated Diffie-Hellman. A malicious relay could
/// substitute its own public key during the first connection (MITM). To mitigate this:
/// - The first public key seen from each peer is stored as the "known" key.
/// - Subsequent key exchanges are compared against the stored key.
/// - If a peer's key changes, a `PeerKeyEvent.peerKeyChanged` event is emitted.
/// - Users can verify fingerprints out-of-band and mark peers as explicitly trusted.
///
/// **Limitation:** TOFU does not protect against MITM during the very first contact.
/// Users who require stronger guarantees should verify fingerprints via a separate channel.
///
/// Alternative considered: Converting to an actor would require all callers to use await,
/// which would be a breaking API change. The lock-based approach maintains synchronous
/// access patterns while ensuring thread safety.
public final class ChatEncryptionService: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = ChatEncryptionService()

    // MARK: - Properties

    private let lock = NSLock()

    /// Our private key for key agreement (protected by lock)
    private var _privateKey: Curve25519.KeyAgreement.PrivateKey

    /// Our public key to share with peers
    public var publicKey: Data {
        lock.withLock { _privateKey.publicKey.rawRepresentation }
    }

    /// Shared symmetric keys per peer (peerID -> symmetric key, protected by lock)
    private var _peerKeys: [String: SymmetricKey] = [:]

    /// TOFU: Known peer public keys (peerID -> first-seen raw public key, protected by lock)
    /// Stores the first public key observed from each peer for MITM detection.
    private var _knownPeerKeys: [String: Data] = [:]

    /// TOFU: Explicitly verified peer fingerprints (peerID -> verified fingerprint string, protected by lock)
    /// Populated when a user confirms a peer's fingerprint via out-of-band verification.
    private var _trustedPeerFingerprints: [String: String] = [:]

    // MARK: - Publishers

    /// Emits TOFU key events for the ViewModel/UI layer to observe.
    /// Subscribe to this publisher to show warnings when a peer's identity changes.
    public let peerKeyEvents = PassthroughSubject<PeerKeyEvent, Never>()

    // MARK: - Thread-Safe Accessors

    private var privateKey: Curve25519.KeyAgreement.PrivateKey {
        get { lock.withLock { _privateKey } }
        set { lock.withLock { _privateKey = newValue } }
    }

    private var peerKeys: [String: SymmetricKey] {
        get { lock.withLock { _peerKeys } }
        set { lock.withLock { _peerKeys = newValue } }
    }

    // MARK: - Initialization

    private init() {
        // Generate a new key pair on initialization
        _privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    /// Regenerate keys (e.g., for a new session).
    ///
    /// **Key Material Lifecycle:** CryptoKit's `Curve25519.KeyAgreement.PrivateKey` and
    /// `SymmetricKey` are opaque types that manage their own memory securely on Apple platforms.
    /// The underlying implementation uses `cc_clear` (via corecrypto) to zero key material
    /// when values are deallocated. Explicit zeroing is not possible through the public API,
    /// nor is it necessary — reassigning `_privateKey` causes the old value to be released
    /// and its backing memory scrubbed by CryptoKit's internal destructor. The same applies
    /// to `SymmetricKey` values removed from `_peerKeys` via `removeAll()`.
    public func regenerateKeys() {
        lock.withLock {
            _privateKey = Curve25519.KeyAgreement.PrivateKey()
            _peerKeys.removeAll()
            _knownPeerKeys.removeAll()
            _trustedPeerFingerprints.removeAll()
        }
        log("Regenerated encryption keys and cleared TOFU state", category: .security)
    }

    /// Full session teardown: regenerates keys AND clears all TOFU peer state.
    ///
    /// Call this when the pool session ends (all peers disconnected, or user explicitly disconnects).
    /// This ensures no stale cryptographic material persists across sessions.
    ///
    /// **Key Material Lifecycle:** CryptoKit manages secure zeroing of key material internally.
    /// When `_privateKey` is reassigned, the previous `Curve25519.KeyAgreement.PrivateKey` is
    /// deallocated and its backing memory is scrubbed via `cc_clear` in corecrypto. Likewise,
    /// `SymmetricKey` values evicted from `_peerKeys` are securely zeroed on deallocation.
    /// Explicit zeroing is not exposed by CryptoKit's opaque key types and is not required
    /// on Apple platforms.
    public func sessionTeardown() {
        lock.withLock {
            _privateKey = Curve25519.KeyAgreement.PrivateKey()
            _peerKeys.removeAll()
            _knownPeerKeys.removeAll()
            _trustedPeerFingerprints.removeAll()
        }
        log("Session teardown: regenerated keys and cleared all peer state", category: .security)
    }

    // MARK: - Key Exchange

    /// Perform key exchange with a peer
    /// - Parameters:
    ///   - peerPublicKeyData: The peer's public key data
    ///   - peerID: Unique identifier for the peer
    /// - Returns: True if key exchange was successful
    public func performKeyExchange(peerPublicKeyData: Data, peerID: String) -> Bool {
        // SECURITY: Validate key data is correct length for Curve25519
        guard peerPublicKeyData.count == 32 else {
            log("[E2E] Invalid peer public key length: \(peerPublicKeyData.count), expected 32", level: .error, category: .security)
            return false
        }

        // SECURITY: Validate key is not all zeros (degenerate key)
        guard peerPublicKeyData != Data(repeating: 0, count: 32) else {
            log("[E2E] Invalid peer public key - all zeros (degenerate)", level: .error, category: .security)
            return false
        }

        // SECURITY: Validate key is not same as our own public key (potential reflection attack)
        let localPublicKeyData = lock.withLock { _privateKey.publicKey.rawRepresentation }
        guard peerPublicKeyData != localPublicKeyData else {
            log("[E2E] Invalid peer public key - same as local key (potential reflection attack)", level: .error, category: .security)
            return false
        }

        // TOFU: Check if we've seen this peer before and compare public keys
        checkTOFU(peerID: peerID, peerPublicKeyData: peerPublicKeyData)

        do {
            let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyData)

            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)

            // SECURITY FIX (V1→V2): Use combination of both public keys as salt for uniqueness.
            // Sort the two 32-byte keys lexicographically (as whole units) so both peers
            // derive the same salt regardless of who initiated the exchange.
            // NOTE: We must NOT sort individual bytes — that destroys key structure and
            // causes collisions between unrelated key pairs whose bytes happen to permute.
            // Reuse localPublicKeyData from the reflection-attack check above.
            let peerKeyRaw = peerPublicKey.rawRepresentation
            let combinedKeys: Data
            if localPublicKeyData.lexicographicallyPrecedes(peerKeyRaw) {
                combinedKeys = localPublicKeyData + peerKeyRaw
            } else {
                combinedKeys = peerKeyRaw + localPublicKeyData
            }
            let saltHash = SHA256.hash(data: combinedKeys)
            let salt = Data(saltHash)

            // Derive a symmetric key from the shared secret using HKDF.
            // Include both peer public keys (sorted for determinism) in sharedInfo
            // to bind the derived key to this specific peer pair, preventing
            // cross-session key confusion.
            let sortedKeys = [localPublicKeyData, peerKeyRaw].sorted { $0.lexicographicallyPrecedes($1) }
            var sharedInfo = Data("E2E-Encryption-v1".utf8)
            sharedInfo.append(sortedKeys[0])
            sharedInfo.append(sortedKeys[1])
            let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: sharedInfo,
                outputByteCount: 32
            )

            lock.withLock {
                _peerKeys[peerID] = symmetricKey
            }

            log("Key exchange completed with peer: \(peerID.prefix(8))...", category: .security)
            return true
        } catch {
            log("Key exchange failed: \(error.localizedDescription)", category: .security)
            return false
        }
    }

    /// Remove a peer's key (when they disconnect)
    public func removePeerKey(peerID: String) {
        _ = lock.withLock {
            _peerKeys.removeValue(forKey: peerID)
        }
        log("Removed key for peer: \(peerID.prefix(8))...", category: .security)
    }

    /// Clear all peer keys
    public func clearAllPeerKeys() {
        lock.withLock {
            _peerKeys.removeAll()
        }
        log("Cleared all peer keys", category: .security)
    }

    // MARK: - Encryption

    /// Encrypt data for a specific peer
    /// - Parameters:
    ///   - data: The data to encrypt
    ///   - peerID: The peer to encrypt for
    /// - Returns: Encrypted data (nonce + ciphertext + tag) or nil if encryption failed
    public func encrypt(_ data: Data, for peerID: String) -> Data? {
        guard let symmetricKey = lock.withLock({ _peerKeys[peerID] }) else {
            log("No key found for peer: \(peerID.prefix(8))...", category: .security)
            return nil
        }

        do {
            let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
            // Combine nonce + ciphertext + tag
            guard let combined = sealedBox.combined else {
                log("Failed to get combined sealed box", category: .security)
                return nil
            }
            return combined
        } catch {
            log("Encryption failed: \(error.localizedDescription)", category: .security)
            return nil
        }
    }

    /// Encrypt data for all connected peers
    /// - Parameter data: The data to encrypt
    /// - Returns: Dictionary of peerID -> encrypted data
    public func encryptForAllPeers(_ data: Data) -> [String: Data] {
        let peers = lock.withLock { Array(_peerKeys.keys) }

        var encrypted: [String: Data] = [:]
        for peerID in peers {
            if let encryptedData = encrypt(data, for: peerID) {
                encrypted[peerID] = encryptedData
            }
        }
        return encrypted
    }

    // MARK: - Decryption

    /// Decrypt data from a specific peer
    /// - Parameters:
    ///   - encryptedData: The encrypted data (nonce + ciphertext + tag)
    ///   - peerID: The peer who sent the data
    /// - Returns: Decrypted data or nil if decryption failed
    public func decrypt(_ encryptedData: Data, from peerID: String) -> Data? {
        guard let symmetricKey = lock.withLock({ _peerKeys[peerID] }) else {
            log("No key found for peer: \(peerID.prefix(8))...", category: .security)
            return nil
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            let decryptedData = try AES.GCM.open(sealedBox, using: symmetricKey)
            return decryptedData
        } catch {
            log("Decryption failed: \(error.localizedDescription)", category: .security)
            return nil
        }
    }

    // MARK: - Convenience Methods

    /// Encrypt a string message
    public func encryptMessage(_ message: String, for peerID: String) -> Data? {
        guard let data = message.data(using: .utf8) else { return nil }
        return encrypt(data, for: peerID)
    }

    /// Decrypt a string message
    public func decryptMessage(_ encryptedData: Data, from peerID: String) -> String? {
        guard let data = decrypt(encryptedData, from: peerID) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Check if we have a key for a peer
    public func hasKeyFor(peerID: String) -> Bool {
        lock.withLock { _peerKeys[peerID] != nil }
    }

    /// Retrieve the shared symmetric key for a peer.
    ///
    /// Used by ``MediaEncryptionService`` to derive per-call media encryption keys
    /// via HKDF without requiring a separate key exchange.
    /// - Parameter peerID: The peer ID to retrieve the key for.
    /// - Returns: The shared symmetric key, or nil if no key exchange has completed.
    public func getSharedKey(for peerID: String) -> SymmetricKey? {
        lock.withLock { _peerKeys[peerID] }
    }

    /// Get the count of established peer keys
    public var peerKeyCount: Int {
        lock.withLock { _peerKeys.count }
    }

    // MARK: - Key Fingerprints (V4: MITM Detection)

    /// Returns a human-readable fingerprint of the local public key for out-of-band verification.
    /// Users can compare fingerprints over a separate channel (phone, in person) to verify
    /// they are communicating with the intended peer without MITM interception.
    public var publicKeyFingerprint: String {
        let keyData = lock.withLock { _privateKey.publicKey.rawRepresentation }
        let hash = SHA256.hash(data: keyData)
        return hash.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Returns a fingerprint of the shared key with a specific peer for verification.
    /// Both peers should see the same fingerprint if the key exchange was not intercepted.
    /// - Parameter peerID: The peer ID to get the shared key fingerprint for
    /// - Returns: A hex-formatted fingerprint string, or nil if no key exists for this peer
    public func sharedKeyFingerprint(for peerID: String) -> String? {
        lock.withLock {
            guard let symmetricKey = _peerKeys[peerID] else { return nil }
            // We can't directly hash SymmetricKey, so we hash a derived HMAC value
            let testData = Data("fingerprint-check".utf8)
            guard let hmac = Optional(HMAC<SHA256>.authenticationCode(for: testData, using: symmetricKey)) else {
                return nil
            }
            return Data(hmac).prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
        }
    }

    // MARK: - Relayed Key Exchange

    /// Initiates key exchange with a peer that is only reachable via relay.
    ///
    /// This method generates a key exchange payload that can be routed through
    /// intermediate relay nodes to reach a peer that is not directly connected.
    /// The E2E security is preserved because only the endpoints have private keys.
    ///
    /// - Parameters:
    ///   - targetPeerID: The peer to establish encryption with
    ///   - ourPeerID: Our local peer ID for routing the response back
    /// - Returns: The encoded payload to send via relay, or nil if generation fails
    public func initiateRelayedKeyExchange(
        targetPeerID: String,
        ourPeerID: String
    ) -> RelayedKeyExchangePayload? {
        let localPublicKey = lock.withLock { _privateKey.publicKey.rawRepresentation }

        log("[E2E] Initiating relayed key exchange with peer: \(targetPeerID.prefix(8))...", category: .security)

        return RelayedKeyExchangePayload(
            publicKey: localPublicKey,
            originPeerID: ourPeerID,
            targetPeerID: targetPeerID,
            isResponse: false
        )
    }

    /// Handles a relayed key exchange request or response.
    ///
    /// When receiving a request (isResponse=false), this method:
    /// 1. Validates the peer's public key
    /// 2. Derives the shared secret and stores it
    /// 3. Returns a response payload with our public key
    ///
    /// When receiving a response (isResponse=true), this method:
    /// 1. Validates the peer's public key
    /// 2. Derives the shared secret and stores it
    /// 3. Returns nil (no further response needed)
    ///
    /// - Parameters:
    ///   - payload: The relayed key exchange payload received via relay
    ///   - ourPeerID: Our local peer ID to verify we are the intended recipient
    /// - Returns: A response payload if this was a request, nil if it was a response or failed
    public func handleRelayedKeyExchange(
        _ payload: RelayedKeyExchangePayload,
        ourPeerID: String
    ) -> RelayedKeyExchangePayload? {
        // Verify this payload is intended for us
        guard payload.targetPeerID == ourPeerID else {
            log("[E2E] Relayed key exchange not intended for us. Target: \(payload.targetPeerID.prefix(8))..., Our ID: \(ourPeerID.prefix(8))...",
                level: .error, category: .security)
            return nil
        }

        // Determine the remote peer ID based on whether this is a request or response
        let remotePeerID = payload.originPeerID

        // Validate the public key
        guard validatePublicKey(payload.publicKey) else {
            log("[E2E] Relayed key exchange failed validation from peer: \(remotePeerID.prefix(8))...",
                level: .error, category: .security)
            return nil
        }

        // Derive and store the shared secret
        guard deriveSharedSecret(from: payload.publicKey, peerID: remotePeerID) else {
            log("[E2E] Failed to derive shared secret for relayed exchange with peer: \(remotePeerID.prefix(8))...",
                level: .error, category: .security)
            return nil
        }

        log("[E2E] Relayed key exchange \(payload.isResponse ? "response" : "request") processed for peer: \(remotePeerID.prefix(8))...",
            category: .security)

        // If this was a request, send back our public key as a response
        if !payload.isResponse {
            let localPublicKey = lock.withLock { _privateKey.publicKey.rawRepresentation }
            return RelayedKeyExchangePayload(
                publicKey: localPublicKey,
                originPeerID: ourPeerID,
                targetPeerID: remotePeerID,
                isResponse: true
            )
        }

        // This was a response, key exchange complete
        return nil
    }

    // MARK: - Private Key Exchange Helpers

    /// Validates a peer's public key for Curve25519 key agreement.
    ///
    /// - Parameter keyData: The raw public key data to validate
    /// - Returns: True if the key is valid, false otherwise
    private func validatePublicKey(_ keyData: Data) -> Bool {
        // SECURITY: Validate key data is correct length for Curve25519
        guard keyData.count == 32 else {
            log("[E2E] Invalid peer public key length: \(keyData.count), expected 32",
                level: .error, category: .security)
            return false
        }

        // SECURITY: Validate key is not all zeros (degenerate key)
        guard keyData != Data(repeating: 0, count: 32) else {
            log("[E2E] Invalid peer public key - all zeros (degenerate)",
                level: .error, category: .security)
            return false
        }

        // SECURITY: Validate key is not same as our own public key (potential reflection attack)
        let localPublicKeyData = lock.withLock { _privateKey.publicKey.rawRepresentation }
        guard keyData != localPublicKeyData else {
            log("[E2E] Invalid peer public key - same as local key (potential reflection attack)",
                level: .error, category: .security)
            return false
        }

        return true
    }

    /// Derives a shared secret from a peer's public key and stores it.
    ///
    /// - Parameters:
    ///   - peerPublicKeyData: The peer's raw public key data
    ///   - peerID: The peer ID to associate with the derived symmetric key
    /// - Returns: True if derivation succeeded, false otherwise
    private func deriveSharedSecret(from peerPublicKeyData: Data, peerID: String) -> Bool {
        // TOFU: Check if we've seen this peer before and compare public keys
        checkTOFU(peerID: peerID, peerPublicKeyData: peerPublicKeyData)

        do {
            let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyData)

            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)

            // Use combination of both public keys as salt for uniqueness.
            // Sort the two 32-byte keys lexicographically (as whole units) so both peers
            // derive the same salt regardless of who initiated the exchange.
            let localPublicKeyData = lock.withLock { _privateKey.publicKey.rawRepresentation }
            let peerPubKeyData = peerPublicKey.rawRepresentation
            let combinedKeys: Data
            if localPublicKeyData.lexicographicallyPrecedes(peerPubKeyData) {
                combinedKeys = localPublicKeyData + peerPubKeyData
            } else {
                combinedKeys = peerPubKeyData + localPublicKeyData
            }
            let saltHash = SHA256.hash(data: combinedKeys)
            let salt = Data(saltHash)

            // Derive a symmetric key from the shared secret using HKDF.
            // Include both peer public keys (sorted for determinism) in sharedInfo
            // to bind the derived key to this specific peer pair, preventing
            // cross-session key confusion.
            let sortedKeysForInfo = [localPublicKeyData, peerPubKeyData].sorted { $0.lexicographicallyPrecedes($1) }
            var sharedInfo = Data("E2E-Encryption-v1".utf8)
            sharedInfo.append(sortedKeysForInfo[0])
            sharedInfo.append(sortedKeysForInfo[1])
            let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: sharedInfo,
                outputByteCount: 32
            )

            lock.withLock {
                _peerKeys[peerID] = symmetricKey
            }

            return true
        } catch {
            log("[E2E] Shared secret derivation failed: \(error.localizedDescription)",
                level: .error, category: .security)
            return false
        }
    }

    // MARK: - TOFU (Trust-On-First-Use)

    /// Checks a peer's public key against TOFU records.
    ///
    /// On first contact, the key is recorded. On subsequent contacts, the key is compared
    /// against the stored value. If it differs, a `peerKeyChanged` event is emitted.
    ///
    /// - Parameters:
    ///   - peerID: The peer identifier.
    ///   - peerPublicKeyData: The raw public key data presented by the peer.
    private func checkTOFU(peerID: String, peerPublicKeyData: Data) {
        let fingerprint = Self.fingerprint(of: peerPublicKeyData)

        let existingKey: Data? = lock.withLock { _knownPeerKeys[peerID] }

        if let existingKey {
            // We have seen this peer before — compare keys
            if existingKey != peerPublicKeyData {
                let oldFingerprint = Self.fingerprint(of: existingKey)
                log("[E2E] TOFU WARNING: Peer \(peerID.prefix(8))... public key changed! Possible MITM or key regeneration.",
                    level: .warning, category: .security)
                peerKeyEvents.send(.peerKeyChanged(peerID: peerID, oldFingerprint: oldFingerprint, newFingerprint: fingerprint))

                // Update stored key to the new one (accept the change, but alert)
                lock.withLock {
                    _knownPeerKeys[peerID] = peerPublicKeyData
                    // Clear any previous explicit trust since the key changed
                    _trustedPeerFingerprints.removeValue(forKey: peerID)
                }
            }
            // Key matches — no action needed
        } else {
            // First time seeing this peer — record the key
            lock.withLock {
                _knownPeerKeys[peerID] = peerPublicKeyData
            }
            log("[E2E] TOFU: New peer \(peerID.prefix(8))... trusted on first use", category: .security)
            peerKeyEvents.send(.newPeerTrusted(peerID: peerID, fingerprint: fingerprint))
        }
    }

    /// Verify a peer's fingerprint against an out-of-band confirmed value.
    ///
    /// Call this when a user has verified a peer's fingerprint through a separate
    /// channel (e.g., comparing fingerprints in person or over phone).
    ///
    /// - Parameters:
    ///   - peerID: The peer whose fingerprint to verify.
    ///   - fingerprint: The fingerprint string confirmed out-of-band.
    /// - Returns: `true` if the fingerprint matches the currently known key for this peer.
    public func verifyPeerFingerprint(peerID: String, fingerprint: String) -> Bool {
        let matches: Bool = lock.withLock {
            guard let knownKey = _knownPeerKeys[peerID] else { return false }
            let currentFingerprint = Self.fingerprint(of: knownKey)
            if currentFingerprint == fingerprint {
                _trustedPeerFingerprints[peerID] = fingerprint
                return true
            }
            return false
        }

        if matches {
            log("[E2E] TOFU: Peer \(peerID.prefix(8))... fingerprint verified successfully", category: .security)
            peerKeyEvents.send(.peerVerified(peerID: peerID))
        } else {
            log("[E2E] TOFU: Peer \(peerID.prefix(8))... fingerprint verification FAILED", level: .warning, category: .security)
        }

        return matches
    }

    /// Check whether a peer has been explicitly verified via out-of-band fingerprint comparison.
    ///
    /// - Parameter peerID: The peer to check.
    /// - Returns: `true` if the peer's fingerprint has been explicitly verified.
    public func isPeerVerified(peerID: String) -> Bool {
        lock.withLock { _trustedPeerFingerprints[peerID] != nil }
    }

    /// Returns the TOFU fingerprint of a peer's known public key.
    ///
    /// - Parameter peerID: The peer to look up.
    /// - Returns: The hex-formatted fingerprint, or nil if this peer has never been seen.
    public func knownPeerFingerprint(for peerID: String) -> String? {
        lock.withLock {
            guard let keyData = _knownPeerKeys[peerID] else { return nil }
            return Self.fingerprint(of: keyData)
        }
    }

    /// Computes a human-readable fingerprint from raw public key data.
    private static func fingerprint(of keyData: Data) -> String {
        let hash = SHA256.hash(data: keyData)
        return hash.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - Key Exchange Message

/// Message for exchanging public keys between peers
public struct KeyExchangePayload: Codable, Sendable {
    public let publicKey: Data
    public let peerID: String

    public init(publicKey: Data, peerID: String) {
        self.publicKey = publicKey
        self.peerID = peerID
    }
}

/// Payload for key exchange that travels through relay nodes.
///
/// This enables E2E encryption between peers that are not directly connected
/// by routing the key exchange through intermediate relay nodes. The security
/// of the key agreement is preserved because only the endpoints possess the
/// private keys - relay nodes only forward the encrypted payloads.
public struct RelayedKeyExchangePayload: Codable, Sendable {
    /// The actual key exchange data (Curve25519 public key)
    public let publicKey: Data

    /// Original sender's peer ID (the one who initiated key exchange)
    public let originPeerID: String

    /// Target peer ID (who should receive and process this)
    public let targetPeerID: String

    /// Whether this is a response (true) or initial request (false)
    public let isResponse: Bool

    public init(publicKey: Data, originPeerID: String, targetPeerID: String, isResponse: Bool) {
        self.publicKey = publicKey
        self.originPeerID = originPeerID
        self.targetPeerID = targetPeerID
        self.isResponse = isResponse
    }
}
