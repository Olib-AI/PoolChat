# PoolChat

**End-to-end encrypted mesh chat for iOS and macOS by [Olib AI](https://www.olib.ai)**

Used in [StealthOS](https://www.stealthos.app) - The privacy-focused operating environment.

![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange) ![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

PoolChat is a Swift package that provides fully encrypted, serverless group and private messaging over a local mesh network. It sits on top of [ConnectionPool](https://github.com/Olib-AI/ConnectionPool) and adds Curve25519 key agreement, AES-256-GCM message encryption, Trust-On-First-Use identity verification, rich message types, encrypted history persistence, and ready-made SwiftUI views. No internet connection, no servers, no accounts -- just devices talking directly to each other with end-to-end encryption.

## Why PoolChat Exists

Because chat should not require trusting a third party. Every mainstream messenger routes your messages through corporate servers, where they can be stored, analyzed, or handed over on request -- even when "end-to-end encrypted." PoolChat removes the server entirely. Messages travel directly between devices over a local mesh network, encrypted before they leave the sender and decryptable only by the intended recipient. There is no metadata to harvest because there is no central point to collect it.

## Features

### Encryption & Security
- **End-to-end encryption** -- Curve25519 ECDH key agreement, HKDF-SHA256 key derivation, AES-256-GCM authenticated encryption
- **Trust-On-First-Use (TOFU)** -- Automatically records peer identities on first contact and alerts on key changes
- **Key fingerprint verification** -- Human-readable fingerprints for out-of-band MITM detection
- **Encryption downgrade prevention** -- Unencrypted messages rejected by default (configurable)
- **Image metadata stripping** -- EXIF, GPS, and all metadata stripped from images before transmission
- **Encrypted storage** -- Chat history persisted through an injectable `SecureStorageProvider` (AES-256-GCM)
- **Relay-aware key exchange** -- E2E encryption works across relay hops in the mesh network
- **Session teardown** -- Cryptographic material securely cleared when sessions end

### Messaging
- **Rich message types** -- Text, images, voice notes, emoji, polls, and system messages
- **Message reactions** -- Quick-react with emoji on any message, synced across all peers
- **Polls** -- Create polls with multiple options, optional vote-change policy, live vote counts
- **Replies** -- Reply to specific messages with preview context
- **@Mentions** -- Mention peers by name with autocomplete support and notification triggers
- **Group and private chat** -- Switch between group conversation and 1-on-1 private messaging
- **Message status tracking** -- Sending, sent, delivered, read, and failed states

### Infrastructure
- **Works over ConnectionPool** -- Peer discovery, connection management, and message routing handled by the mesh layer
- **Chat history sync** -- Host sends encrypted history to newly joined peers (configurable)
- **Local notifications** -- Background message notifications with deep link support, reply actions, and thread grouping
- **Notification bridge** -- Notifications work even when the chat window is closed
- **Voice recording** -- AVFoundation-based recording with playback, seek, and progress tracking
- **Configurable logging** -- Inject your own logger or use the built-in `os.Logger` fallback
- **Cross-platform** -- iOS and macOS from a single codebase with platform-adaptive SwiftUI views
- **Swift 6 strict concurrency** -- No data races, proper actor isolation, `Sendable` throughout

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   Your App                       │
├─────────────────────────────────────────────────┤
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │              PoolChatView                  │  │
│  │         (SwiftUI, cross-platform)          │  │
│  └──────────────────┬─────────────────────────┘  │
│                     │                            │
│  ┌──────────────────▼─────────────────────────┐  │
│  │           PoolChatViewModel                │  │
│  │   Messages, UI state, chat mode, polls,    │  │
│  │   reactions, mentions, image/voice send     │  │
│  └──────────────────┬─────────────────────────┘  │
│                     │                            │
│  ┌──────────┬───────┴───────┬──────────────────┐ │
│  │ ChatHist │  ChatEncrypt  │ VoiceRecording   │ │
│  │ oryServ. │  ionService   │ Service          │ │
│  │          │               │                  │ │
│  │ Encrypted│ Curve25519    │ AVFoundation     │ │
│  │ persist. │ + AES-256-GCM │ record/playback  │ │
│  └────┬─────┴───────┬───────┴──────────────────┘ │
│       │             │                            │
│  ┌────▼─────┐  ┌────▼──────────────────────────┐ │
│  │ Secure   │  │      ConnectionPool           │ │
│  │ Storage  │  │  (mesh network transport)      │ │
│  │ Provider │  │                                │ │
│  └──────────┘  └────────────────────────────────┘ │
│                                                  │
└─────────────────────────────────────────────────┘
```

**Message flow (send):**

1. User composes a message in `PoolChatView`
2. `PoolChatViewModel` creates a `RichChatMessage` and strips image metadata if applicable
3. Message is serialized to `RichChatPayload` (or `PrivateChatPayload` for DMs)
4. `ChatEncryptionService` encrypts the payload with the recipient's shared AES-256-GCM key
5. Encrypted payload is wrapped in `EncryptedChatPayload` and sent via `ConnectionPoolManager`
6. `ChatHistoryService` persists the message through `SecureStorageProvider`

**Message flow (receive):**

1. `ConnectionPoolManager` delivers an incoming `PoolMessage`
2. `PoolChatViewModel` unwraps the `EncryptedChatPayload`
3. `ChatEncryptionService` decrypts using the sender's shared key
4. Decrypted payload is deserialized into a `RichChatMessage` and displayed
5. If the chat window is closed, `ChatNotificationBridge` sends a local notification

## Security

### End-to-End Encryption

Every chat message is encrypted before it leaves the sending device. The encryption pipeline:

1. **Key Agreement** -- Each peer generates an ephemeral Curve25519 key pair on session start. Public keys are exchanged over the mesh network.
2. **Shared Secret** -- Curve25519 ECDH produces a shared secret between each pair of peers.
3. **Key Derivation** -- HKDF-SHA256 derives a 256-bit symmetric key from the shared secret. The salt is the SHA-256 hash of both public keys (sorted lexicographically), ensuring both peers derive the same key regardless of who initiated the exchange.
4. **Encryption** -- AES-256-GCM encrypts the message payload. Each message gets a unique nonce. The sealed box (nonce + ciphertext + authentication tag) is transmitted.
5. **Decryption** -- The recipient uses the same derived symmetric key to open the AES-GCM sealed box. Authentication tag verification prevents tampering.

### Trust-On-First-Use (TOFU)

PoolChat implements a TOFU model similar to SSH:

- **First contact**: The peer's public key is recorded as the "known" key. A `newPeerTrusted` event is emitted with the key fingerprint.
- **Subsequent contacts**: The presented key is compared against the stored key. If it matches, the connection proceeds silently.
- **Key change detected**: If a peer presents a different public key, a `peerKeyChanged` event is emitted with both old and new fingerprints. This may indicate a MITM attack or legitimate key regeneration.
- **Explicit verification**: Users can verify fingerprints out-of-band (in person, phone call) and mark peers as explicitly trusted. Verified status is cleared if the key changes.

**Limitation**: TOFU does not protect against MITM during the very first contact. Users who require stronger guarantees should verify fingerprints through a separate channel.

### Key Fingerprint Verification

Both public key fingerprints and shared key fingerprints are available for out-of-band verification:

```swift
// Your public key fingerprint (share with peers)
let myFingerprint = ChatEncryptionService.shared.publicKeyFingerprint
// e.g., "A3:4F:B2:19:CC:87:D1:E6"

// Shared key fingerprint with a specific peer (both sides should match)
let sharedFingerprint = ChatEncryptionService.shared.sharedKeyFingerprint(for: peerID)
```

If both peers see the same shared key fingerprint, no MITM interception occurred during key exchange.

### Encryption Downgrade Prevention

By default, PoolChat rejects unencrypted messages:

```swift
// Default: unencrypted messages are silently dropped
PoolChatConfiguration.rejectUnencryptedMessages = true

// Migration period only: accept with warning marker
PoolChatConfiguration.rejectUnencryptedMessages = false
```

Setting this to `false` is an encryption downgrade vector and should only be used during migration periods when legacy clients are still in the network.

### Image Metadata Stripping

Before any image is sent, PoolChat strips all EXIF metadata, GPS coordinates, camera information, and other embedded metadata. The image is re-encoded as a clean JPEG/PNG with no identifying information.

### Encrypted Storage

Chat history is persisted through the `SecureStorageProvider` protocol. The host application injects its own implementation (e.g., AES-256-GCM encrypted file storage). PoolChat never writes plaintext messages to disk.

Media (images, voice notes) is stored separately from message metadata with independent encryption keys, and referenced by opaque storage keys.

### What Relay Nodes Can See

In a mesh network, messages may travel through relay nodes to reach non-adjacent peers. Here is what relay nodes can and cannot observe:

| Data | Visible to Relay? |
|------|-------------------|
| Message content | No (AES-256-GCM encrypted) |
| Sender/receiver peer IDs | Yes (routing metadata) |
| Message type (chat, reaction, poll) | Yes (envelope metadata) |
| Message size | Yes (encrypted blob size) |
| Timing | Yes (when message transits) |
| Public keys during exchange | Yes (but cannot derive shared secret without private keys) |

Relay nodes forward encrypted blobs. They cannot decrypt content, forge messages, or modify payloads without detection (GCM authentication tag verification will fail).

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Olib-AI/PoolChat.git", from: "1.1.0")
]
```

Then add the dependency to your target:

```swift
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "PoolChat", package: "PoolChat")
        ]
    )
]
```

**Note:** PoolChat depends on [ConnectionPool](https://github.com/Olib-AI/ConnectionPool). SPM will resolve it automatically.

### Local Package (XcodeGen)

If using XcodeGen, add to your `project.yml`:

```yaml
packages:
  PoolChat:
    path: LocalPackages/PoolChat

targets:
  YourApp:
    dependencies:
      - package: PoolChat
        product: PoolChat
```

Then regenerate: `xcodegen generate`

## Quick Start

### 1. Configure PoolChat

Set up logging and storage before using any PoolChat services:

```swift
import PoolChat

// Inject your logger (optional -- falls back to os.Logger)
PoolChatConfiguration.logger = MyAppLogger()

// Inject your encrypted storage provider (required for history persistence)
PoolChatConfiguration.storageProvider = MySecureStorage()

// Security settings (defaults are recommended)
PoolChatConfiguration.rejectUnencryptedMessages = true
PoolChatConfiguration.enableHistorySync = true
```

### 2. Key Exchange

When a peer connects, exchange public keys to establish encryption:

```swift
let encryptionService = ChatEncryptionService.shared

// Get your public key to send to the peer
let myPublicKey = encryptionService.publicKey

// When you receive a peer's public key, perform key exchange
let success = encryptionService.performKeyExchange(
    peerPublicKeyData: peerPublicKeyData,
    peerID: remotePeerID
)

if success {
    print("E2E encryption established with \(remotePeerID)")
}
```

### 3. Encrypt and Send a Message

```swift
// Create a message
let message = RichChatMessage.textMessage(
    from: localPeerID,
    senderName: "Alice",
    text: "Hello from PoolChat!",
    isFromLocalUser: true
)

// Serialize the payload
let payload = RichChatPayload(from: message)
let payloadData = try JSONEncoder().encode(payload)

// Encrypt for a specific peer
if let encrypted = encryptionService.encrypt(payloadData, for: targetPeerID) {
    let envelope = EncryptedChatPayload(
        encryptedData: encrypted,
        senderPeerID: localPeerID,
        isPrivateChat: false,
        targetPeerID: nil,
        messageType: .chatMessage
    )
    // Send via ConnectionPool...
}
```

### 4. Use the Built-in SwiftUI View

For a complete chat UI out of the box:

```swift
import PoolChat
import ConnectionPool

struct ChatScreen: View {
    @StateObject private var viewModel = PoolChatViewModel()

    var body: some View {
        PoolChatView(viewModel: viewModel)
    }
}
```

The view includes message bubbles, emoji picker, voice recording controls, image sending, poll creation, reactions, reply threading, and @mention autocomplete -- all with cross-platform support.

## Configuration

### PoolChatConfiguration

Static configuration point for dependency injection. Set these before using PoolChat services.

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `logger` | `PoolChatLogger?` | `nil` (os.Logger fallback) | Custom logging implementation |
| `storageProvider` | `SecureStorageProvider?` | `nil` | Encrypted storage for chat history |
| `rejectUnencryptedMessages` | `Bool` | `true` | Drop unencrypted messages (security) |
| `enableHistorySync` | `Bool` | `true` | Send chat history to new members |

### PoolChatLogger Protocol

Implement this to integrate PoolChat logging with your app's logging system:

```swift
public protocol PoolChatLogger: Sendable {
    func log(
        _ message: String,
        level: PoolChatLogLevel,
        category: PoolChatLogCategory,
        file: String,
        function: String,
        line: Int
    )
}
```

Log levels: `debug`, `info`, `warning`, `error`, `critical`

Log categories: `general`, `network`, `runtime`, `security`, `ui`, `poolChat`

### SecureStorageProvider Protocol

Implement this to provide encrypted persistence for chat history:

```swift
@MainActor
public protocol SecureStorageProvider: AnyObject {
    func save<T: Codable>(_ object: T, forKey key: String, category: StorageDataCategory) async throws
    func load<T: Codable>(_ type: T.Type, forKey key: String, category: StorageDataCategory) async throws -> T?
    func delete(forKey key: String, category: StorageDataCategory) async throws
    func listKeys(in category: StorageDataCategory) -> [String]
    func saveData(_ data: Data, forKey key: String, category: StorageDataCategory) async throws
    func loadData(forKey key: String, category: StorageDataCategory) async throws -> Data?
}
```

Your implementation should encrypt all data at rest (e.g., AES-256-GCM).

## API Reference

### Core Types

| Type | Description |
|------|-------------|
| `PoolChatView` | Complete SwiftUI chat interface (cross-platform) |
| `PoolChatViewModel` | Chat state management, message send/receive, UI coordination |
| `ChatEncryptionService` | E2E encryption, key exchange, TOFU, fingerprint verification |
| `ChatHistoryService` | Encrypted chat history persistence and retrieval |
| `ChatNotificationService` | Local notification delivery with deep links |
| `ChatNotificationBridge` | Background notification bridge for closed chat windows |
| `VoiceRecordingService` | AVFoundation voice recording and playback |
| `PoolChatConfiguration` | Static dependency injection point |

### Message Types

| Type | Description |
|------|-------------|
| `RichChatMessage` | In-memory chat message with all content types |
| `RichChatPayload` | Codable payload for network transmission |
| `EncryptedChatPayload` | E2E encrypted message envelope |
| `PrivateChatPayload` | Private (1-on-1) message wrapper |
| `ReactionUpdatePayload` | Reaction sync payload |
| `PollVotePayload` | Poll vote sync payload |
| `ChatHistorySyncPayload` | History sync for new members |
| `StoredChatMessage` | Optimized format for persistent storage |

### Content Types

| `ChatContentType` | Description |
|--------------------|-------------|
| `.text` | Plain text message |
| `.image` | Image with metadata stripped |
| `.voice` | Voice recording (AAC, up to 60s) |
| `.emoji` | Single emoji message |
| `.poll` | Interactive poll with options |
| `.system` | System notification message |

### Chat Modes

| `ChatMode` | Description |
|------------|-------------|
| `.group` | Group conversation with all connected peers |
| `.privateChat(peerID:)` | Private 1-on-1 conversation |

### TOFU Events

Subscribe to `ChatEncryptionService.shared.peerKeyEvents` to handle identity changes:

```swift
encryptionService.peerKeyEvents
    .sink { event in
        switch event {
        case .newPeerTrusted(let peerID, let fingerprint):
            // First contact -- show fingerprint for optional verification
        case .peerKeyChanged(let peerID, let old, let new):
            // Identity changed -- warn user of possible MITM
        case .peerVerified(let peerID):
            // User confirmed fingerprint out-of-band
        }
    }
```

## Requirements

- iOS 17.0+
- macOS 14.0+
- Swift 6.0+
- Xcode 16+
- [ConnectionPool](https://github.com/Olib-AI/ConnectionPool) (resolved automatically via SPM)

## Package Structure

```
PoolChat/
├── Package.swift
└── Sources/
    ├── PoolChat.swift                          # Module exports
    ├── Configuration/
    │   └── PoolChatConfiguration.swift         # Dependency injection
    ├── Models/
    │   └── RichChatMessage.swift               # All message & payload types
    ├── Protocols/
    │   ├── PoolChatLogger.swift                # Logging protocol + default
    │   ├── SecureStorageProvider.swift          # Encrypted storage protocol
    │   └── PoolChatAppLifecycle.swift           # App lifecycle management
    ├── Services/
    │   ├── ChatEncryptionService.swift          # E2E encryption + TOFU
    │   ├── ChatHistoryService.swift             # Encrypted history persistence
    │   ├── ChatNotificationService.swift        # Local notification delivery
    │   ├── ChatNotificationBridge.swift         # Background notification bridge
    │   └── VoiceRecordingService.swift          # Voice record & playback
    ├── ViewModels/
    │   └── PoolChatViewModel.swift              # Chat state management
    └── Views/
        └── PoolChatView.swift                   # SwiftUI chat interface
```

## License

MIT License

Copyright (c) 2025 Olib AI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Credits

- [Olib AI](https://www.olib.ai) - Package maintainer and [StealthOS](https://www.stealthos.app) developer
- [ConnectionPool](https://github.com/Olib-AI/ConnectionPool) - Mesh network transport layer
- [Apple CryptoKit](https://developer.apple.com/documentation/cryptokit) - Curve25519, AES-GCM, HKDF primitives

## Contributing

Contributions are welcome! Please ensure:

1. Code compiles under Swift 6 strict concurrency
2. All public APIs are documented
3. Actor isolation is maintained for thread safety
4. No use of `@preconcurrency` escape hatches
5. Encryption-related changes include a security rationale

## Security

If you discover a security vulnerability, please report it privately to security@olib.ai rather than opening a public issue.
