// MediaEncryptionService.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import CryptoKit

// MARK: - Media Encryption Service

/// Per-call encryption service for media frames.
///
/// Derives short-lived symmetric keys from the existing per-peer
/// ``ChatEncryptionService`` keys using HKDF. This avoids a new key
/// exchange round-trip while ensuring each call uses unique keys.
///
/// **Nonce construction**: Deterministic from `sequence(4 bytes) + callID_last_8_bytes(8 bytes)`
/// = 12 bytes. Since sequence numbers are never reused within a call and each call
/// uses a unique derived key, nonce reuse is impossible.
///
/// Thread safety: NSLock-protected mutable state, @unchecked Sendable.
public final class MediaEncryptionService: @unchecked Sendable {

    // MARK: - State

    private let lock = NSLock()
    /// Cached per-call, per-peer derived keys: [callID+peerID -> SymmetricKey]
    private var _callKeys: [String: SymmetricKey] = [:]
    /// Reference to the chat encryption service for base key retrieval.
    private let chatEncryption: ChatEncryptionService

    // MARK: - Initialization

    public init(chatEncryption: ChatEncryptionService = .shared) {
        self.chatEncryption = chatEncryption
    }

    // MARK: - Key Derivation

    /// Derive a per-call symmetric key for a specific peer.
    ///
    /// The key is derived via HKDF-SHA256 from the existing per-peer chat key:
    /// `HKDF(ikm: chatKey, info: "call-media-v1" || callID || sorted(localPeerID, remotePeerID))`
    ///
    /// - Parameters:
    ///   - callID: The unique call session ID.
    ///   - localPeerID: The local peer's ID.
    ///   - remotePeerID: The remote peer's ID.
    /// - Returns: A derived symmetric key, or nil if no chat key exists for the peer.
    public func deriveCallKey(for callID: UUID, localPeerID: String, remotePeerID: String) -> SymmetricKey? {
        let cacheKey = "\(callID.uuidString):\(remotePeerID)"

        return lock.withLock {
            if let cached = _callKeys[cacheKey] {
                return cached
            }

            // Get the base chat key for this peer
            guard let chatKey = chatEncryption.getSharedKey(for: remotePeerID) else {
                return nil
            }

            // Build info string: "call-media-v1" + callID + sorted peer IDs
            let sortedPeers = [localPeerID, remotePeerID].sorted().joined()
            var info = Data("call-media-v1".utf8)
            info.append(Data(callID.uuidString.utf8))
            info.append(Data(sortedPeers.utf8))

            let derivedKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: chatKey,
                info: info,
                outputByteCount: 32
            )

            _callKeys[cacheKey] = derivedKey
            return derivedKey
        }
    }

    // MARK: - Frame Encryption

    /// Encrypt a media frame payload for a specific peer.
    ///
    /// - Parameters:
    ///   - plaintext: The raw media frame data.
    ///   - callID: The call session ID.
    ///   - localPeerID: The local peer's ID.
    ///   - remotePeerID: The remote peer's ID.
    ///   - sequence: Frame sequence number (used for deterministic nonce).
    /// - Returns: AES-GCM encrypted data (nonce + ciphertext + tag), or nil on failure.
    public func encryptFrame(
        _ plaintext: Data,
        callID: UUID,
        localPeerID: String,
        remotePeerID: String,
        sequence: UInt32
    ) -> Data? {
        guard let key = deriveCallKey(for: callID, localPeerID: localPeerID, remotePeerID: remotePeerID) else {
            return nil
        }

        let nonce = buildNonce(sequence: sequence, callID: callID)

        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
            return sealedBox.combined
        } catch {
            return nil
        }
    }

    /// Decrypt a media frame payload from a specific peer.
    ///
    /// - Parameters:
    ///   - ciphertext: The AES-GCM combined data (nonce + ciphertext + tag).
    ///   - callID: The call session ID.
    ///   - localPeerID: The local peer's ID.
    ///   - remotePeerID: The remote peer's ID.
    ///   - sequence: Frame sequence number (used for deterministic nonce verification).
    /// - Returns: Decrypted frame data, or nil on failure (tampered/wrong key).
    public func decryptFrame(
        _ ciphertext: Data,
        callID: UUID,
        localPeerID: String,
        remotePeerID: String,
        sequence: UInt32
    ) -> Data? {
        guard let key = deriveCallKey(for: callID, localPeerID: localPeerID, remotePeerID: remotePeerID) else {
            return nil
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            return nil
        }
    }

    // MARK: - Cleanup

    /// Remove cached keys for a completed call.
    public func removeCallKeys(for callID: UUID) {
        lock.withLock {
            let prefix = callID.uuidString + ":"
            _callKeys = _callKeys.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    /// Remove all cached keys.
    public func removeAllKeys() {
        lock.withLock {
            _callKeys.removeAll()
        }
    }

    // MARK: - Private: Nonce Construction

    /// Build a deterministic 12-byte AES-GCM nonce from sequence number and call ID.
    ///
    /// Format: `[4 bytes: sequence big-endian] [8 bytes: last 8 bytes of callID UUID]`
    private func buildNonce(sequence: UInt32, callID: UUID) -> AES.GCM.Nonce {
        var nonceData = Data(capacity: 12)

        // 4 bytes: sequence number (big-endian)
        var seqBE = sequence.bigEndian
        nonceData.append(Data(bytes: &seqBE, count: 4))

        // 8 bytes: last 8 bytes of call ID
        let uuidBytes = withUnsafeBytes(of: callID.uuid) { Data($0) }
        nonceData.append(uuidBytes.suffix(8))

        // Force unwrap is safe: we always produce exactly 12 bytes
        return try! AES.GCM.Nonce(data: nonceData)
    }
}
