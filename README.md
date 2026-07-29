# PoolChat

**End-to-end encrypted mesh chat for iOS and macOS by [Olib AI](https://www.olib.ai)**

Used in [StealthOS](https://www.stealthos.app), the privacy-focused operating environment.

![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange) ![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

PoolChat is a Swift package that provides fully encrypted, serverless group and private messaging, plus voice and video calling, over ConnectionPool networks. It sits on top of [ConnectionPool](https://github.com/Olib-AI/ConnectionPool) and adds Curve25519 key agreement, AES-256-GCM message encryption, Trust-On-First-Use identity verification, rich message types, encrypted history persistence, calling UI, and ready-made SwiftUI views. It works with both local mesh pools and remote ConnectionPool topologies. No internet connection, no chat servers, no accounts, just devices communicating with end-to-end encryption.

## Why PoolChat Exists

Because chat should not require trusting a third party. Every mainstream messenger routes your messages through corporate servers, where they can be stored, analyzed, or handed over on request, even when "end-to-end encrypted." PoolChat removes the server entirely. Messages travel directly between devices over a local mesh network, encrypted before they leave the sender and decryptable only by the intended recipient. There is no metadata to harvest because there is no central point to collect it.

## Documentation

| Document | Contents |
|----------|----------|
| [Features](Docs/Features.md) | Encryption, messaging, calling, and infrastructure capabilities |
| [Architecture](Docs/Architecture.md) | Component layout, send and receive flows, package structure |
| [Security](Docs/Security.md) | Encryption pipeline, TOFU, fingerprints, downgrade prevention, what relays can see |
| [Installation](Docs/Installation.md) | Swift Package Manager, XcodeGen, requirements |
| [Quick Start](Docs/QuickStart.md) | Configure, exchange keys, send a message, drop in the SwiftUI view |
| [Configuration](Docs/Configuration.md) | `PoolChatConfiguration`, logger protocol, storage provider protocol |
| [API Reference](Docs/APIReference.md) | Core, message, content, chat mode, and calling types, plus TOFU events |

## At a Glance

- **End-to-end encrypted**: Curve25519 ECDH, HKDF-SHA256 derivation, AES-256-GCM authenticated encryption, applied before anything leaves the device
- **No server, no account**: messages move directly between devices over the ConnectionPool mesh, locally or through a remote pool
- **Trust-On-First-Use identity**: peer keys recorded on first contact, key changes surfaced as events, fingerprints available for out-of-band verification
- **Encrypted at rest too**: history persists through an injectable `SecureStorageProvider`, and PoolChat never writes plaintext to disk
- **Rich messaging**: text, images with metadata stripped, voice notes, emoji, polls, reactions, replies, @mentions, delivery status
- **Voice and video calling**: encrypted 1:1 and group calls with per-call media keys and ready-made call UI
- **Drop-in UI**: `PoolChatView` gives a complete cross-platform chat surface, or drive `PoolChatViewModel` yourself
- **Swift 6 strict concurrency**: no data races, proper actor isolation, `Sendable` throughout

See [Features](Docs/Features.md) for the complete list.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Olib-AI/PoolChat.git", from: "1.5.0")
]
```

PoolChat depends on [ConnectionPool](https://github.com/Olib-AI/ConnectionPool); SPM resolves it automatically. XcodeGen setup and platform requirements are in [Installation](Docs/Installation.md).

## Hello, Chat

```swift
import PoolChat

// Inject storage and logging once, at startup
PoolChatConfiguration.storageProvider = MySecureStorage()
PoolChatConfiguration.rejectUnencryptedMessages = true

// Then drop in the whole chat UI
struct ChatScreen: View {
    @StateObject private var viewModel = PoolChatViewModel()

    var body: some View {
        PoolChatView(viewModel: viewModel)
    }
}
```

Key exchange, manual encryption, and payload construction are covered in [Quick Start](Docs/QuickStart.md).

## Requirements

iOS 17.0+, macOS 14.0+, Swift 6.0+, Xcode 16+, and ConnectionPool. Details in [Installation](Docs/Installation.md#requirements).

## License

MIT License. Copyright (c) 2025 Olib AI. See [LICENSE](LICENSE) for the full text.

## Credits

- [Olib AI](https://www.olib.ai): package maintainer and [StealthOS](https://www.stealthos.app) developer
- [ConnectionPool](https://github.com/Olib-AI/ConnectionPool): mesh network transport layer
- [Apple CryptoKit](https://developer.apple.com/documentation/cryptokit): Curve25519, AES-GCM, HKDF primitives

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), and please ensure:

1. Code compiles under Swift 6 strict concurrency
2. All public APIs are documented
3. Actor isolation is maintained for thread safety
4. No use of `@preconcurrency` escape hatches
5. Encryption-related changes include a security rationale

## Security

If you discover a security vulnerability, please report it privately to security@olib.ai rather than opening a public issue. See [SECURITY.md](SECURITY.md).
