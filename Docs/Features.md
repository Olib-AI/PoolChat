# Features

[Back to README](../README.md)

## Contents

- [Encryption and Security](#encryption-and-security)
- [Messaging](#messaging)
- [Calling](#calling)
- [Infrastructure](#infrastructure)

## Encryption and Security

- **End-to-end encryption**: Curve25519 ECDH key agreement, HKDF-SHA256 key derivation, AES-256-GCM authenticated encryption
- **Trust-On-First-Use (TOFU)**: automatically records peer identities on first contact and alerts on key changes
- **Key fingerprint verification**: human-readable fingerprints for out-of-band MITM detection
- **Encryption downgrade prevention**: unencrypted messages rejected by default (configurable)
- **Image metadata stripping**: EXIF, GPS, and all metadata stripped from images before transmission
- **Encrypted storage**: chat history persisted through an injectable `SecureStorageProvider` (AES-256-GCM)
- **Relay-aware key exchange**: E2E encryption works across relay hops in the mesh network
- **Session teardown**: cryptographic material securely cleared when sessions end

Details in [Security](Security.md).

## Messaging

- **Rich message types**: text, images, voice notes, emoji, polls, and system messages
- **Message reactions**: quick-react with emoji on any message, synced across all peers
- **Polls**: create polls with multiple options, optional vote-change policy, live vote counts
- **Replies**: reply to specific messages with preview context
- **@Mentions**: mention peers by name with autocomplete support and notification triggers
- **Group and private chat**: switch between group conversation and 1-on-1 private messaging
- **Message status tracking**: sending, sent, delivered, read, and failed states

## Calling

- **Voice and video calling**: encrypted 1:1 and group calling over local and remote ConnectionPool connectivity
- **Call signaling over the pool**: `CallSignal` rides the same transport as chat, so calls need no separate infrastructure
- **Per-call media keys**: `MediaEncryptionService` derives call keys from the established chat keys, so media inherits the chat trust model
- **Ready-made call UI**: `ActiveCallView`, `IncomingCallView`, `CallButtonsView`, and `VideoTileView` ship with the package

## Infrastructure

- **Works over ConnectionPool**: peer discovery, connection management, chat routing, and call signaling handled by the transport layer
- **Local and remote pool support**: operates across nearby mesh peers and remote ConnectionPool-backed sessions
- **Chat history sync**: host sends encrypted history to newly joined peers (configurable)
- **Local notifications**: background message notifications with deep link support, reply actions, and thread grouping
- **Notification bridge**: notifications work even when the chat window is closed
- **Voice recording**: AVFoundation-based recording with playback, seek, and progress tracking
- **Configurable logging**: inject your own logger or use the built-in `os.Logger` fallback
- **Cross-platform**: iOS and macOS from a single codebase with platform-adaptive SwiftUI views
- **Swift 6 strict concurrency**: no data races, proper actor isolation, `Sendable` throughout
