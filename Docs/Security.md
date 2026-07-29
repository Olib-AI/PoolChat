# Security

[Back to README](../README.md)

## Contents

- [End-to-End Encryption](#end-to-end-encryption)
- [Trust-On-First-Use (TOFU)](#trust-on-first-use-tofu)
- [Key Fingerprint Verification](#key-fingerprint-verification)
- [Encryption Downgrade Prevention](#encryption-downgrade-prevention)
- [Image Metadata Stripping](#image-metadata-stripping)
- [Encrypted Storage](#encrypted-storage)
- [What Relay Nodes Can See](#what-relay-nodes-can-see)

## End-to-End Encryption

Every chat message is encrypted before it leaves the sending device. The encryption pipeline:

1. **Key Agreement**: each peer generates an ephemeral Curve25519 key pair on session start. Public keys are exchanged over the mesh network.
2. **Shared Secret**: Curve25519 ECDH produces a shared secret between each pair of peers.
3. **Key Derivation**: HKDF-SHA256 derives a 256-bit symmetric key from the shared secret. The salt is the SHA-256 hash of both public keys (sorted lexicographically), ensuring both peers derive the same key regardless of who initiated the exchange.
4. **Encryption**: AES-256-GCM encrypts the message payload. Each message gets a unique nonce. The sealed box (nonce plus ciphertext plus authentication tag) is transmitted.
5. **Decryption**: the recipient uses the same derived symmetric key to open the AES-GCM sealed box. Authentication tag verification prevents tampering.

## Trust-On-First-Use (TOFU)

PoolChat implements a TOFU model similar to SSH:

- **First contact**: the peer's public key is recorded as the "known" key. A `newPeerTrusted` event is emitted with the key fingerprint.
- **Subsequent contacts**: the presented key is compared against the stored key. If it matches, the connection proceeds silently.
- **Key change detected**: if a peer presents a different public key, a `peerKeyChanged` event is emitted with both old and new fingerprints. This may indicate a MITM attack or legitimate key regeneration.
- **Explicit verification**: users can verify fingerprints out-of-band (in person, phone call) and mark peers as explicitly trusted. Verified status is cleared if the key changes.

**Limitation**: TOFU does not protect against MITM during the very first contact. Users who require stronger guarantees should verify fingerprints through a separate channel.

Wiring the events into your UI is covered in [API Reference: TOFU Events](APIReference.md#tofu-events).

## Key Fingerprint Verification

Both public key fingerprints and shared key fingerprints are available for out-of-band verification:

```swift
// Your public key fingerprint (share with peers)
let myFingerprint = ChatEncryptionService.shared.publicKeyFingerprint
// e.g., "A3:4F:B2:19:CC:87:D1:E6"

// Shared key fingerprint with a specific peer (both sides should match)
let sharedFingerprint = ChatEncryptionService.shared.sharedKeyFingerprint(for: peerID)
```

If both peers see the same shared key fingerprint, no MITM interception occurred during key exchange.

## Encryption Downgrade Prevention

By default, PoolChat rejects unencrypted messages:

```swift
// Default: unencrypted messages are silently dropped
PoolChatConfiguration.rejectUnencryptedMessages = true

// Migration period only: accept with warning marker
PoolChatConfiguration.rejectUnencryptedMessages = false
```

Setting this to `false` is an encryption downgrade vector and should only be used during migration periods when legacy clients are still in the network.

## Image Metadata Stripping

Before any image is sent, PoolChat strips all EXIF metadata, GPS coordinates, camera information, and other embedded metadata. The image is re-encoded as a clean JPEG/PNG with no identifying information.

## Encrypted Storage

Chat history is persisted through the `SecureStorageProvider` protocol. The host application injects its own implementation, for example AES-256-GCM encrypted file storage. PoolChat never writes plaintext messages to disk.

Media (images, voice notes) is stored separately from message metadata with independent encryption keys, and referenced by opaque storage keys.

See [Configuration: SecureStorageProvider](Configuration.md#securestorageprovider-protocol) for the protocol surface.

## What Relay Nodes Can See

In a mesh network, messages may travel through relay nodes to reach non-adjacent peers. Here is what relay nodes can and cannot observe:

| Data | Visible to Relay? |
|------|-------------------|
| Message content | No (AES-256-GCM encrypted) |
| Sender/receiver peer IDs | Yes (routing metadata) |
| Message type (chat, reaction, poll) | Yes (envelope metadata) |
| Message size | Yes (encrypted blob size) |
| Timing | Yes (when message transits) |
| Public keys during exchange | Yes (but cannot derive shared secret without private keys) |

Relay nodes forward encrypted blobs. They cannot decrypt content, forge messages, or modify payloads without detection, because GCM authentication tag verification will fail.

## Reporting a Vulnerability

See [SECURITY.md](../SECURITY.md). Report privately to security@olib.ai rather than opening a public issue.
