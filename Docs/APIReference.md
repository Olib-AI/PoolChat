# API Reference

[Back to README](../README.md)

## Contents

- [Core Types](#core-types)
- [Message Types](#message-types)
- [Content Types](#content-types)
- [Chat Modes](#chat-modes)
- [Calling Types](#calling-types)
- [TOFU Events](#tofu-events)

## Core Types

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

## Message Types

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

## Content Types

Cases of `ChatContentType`:

| Case | Description |
|------|-------------|
| `.text` | Plain text message |
| `.image` | Image with metadata stripped |
| `.voice` | Voice recording (AAC, up to 60s) |
| `.emoji` | Single emoji message |
| `.poll` | Interactive poll with options |
| `.system` | System notification message |

## Chat Modes

Cases of `ChatMode`:

| Case | Description |
|------|-------------|
| `.group` | Group conversation with all connected peers |
| `.privateChat(peerID:)` | Private 1-on-1 conversation |

## Calling Types

| Type | Description |
|------|-------------|
| `CallManager` | Call lifecycle coordination, `ObservableObject`. Reports through `CallManagerDelegate`. |
| `CallSession` | Observable state for one active call: participants, media flags, identity. |
| `CallState` | Call lifecycle state, `Sendable` and `Equatable`. |
| `CallEndReason` | Why a call ended, string-backed. |
| `RemoteParticipantState` | Per-participant remote state within a session. |
| `CallSignal` / `CallSignalType` | Signaling frame and its discriminator, carried over the pool transport. |
| `MediaControlPayload` | Mute, camera, and other in-call control changes. |
| `MediaFrameHeader` / `CallMediaType` / `MediaFrameCodec` | Media frame envelope, track kind, and codec identification. |
| `MediaEncryptionService` | Per-call media key derivation and frame encryption. |
| `AudioCallService` | Audio capture, encode, and playback path. |
| `VideoCallService` | Video capture and render path. |
| `ActiveCallView` / `IncomingCallView` / `VideoTileView` / `AudioCallBannerView` | Ready-made call UI. |

## TOFU Events

Subscribe to `ChatEncryptionService.shared.peerKeyEvents` to handle identity changes:

```swift
encryptionService.peerKeyEvents
    .sink { event in
        switch event {
        case .newPeerTrusted(let peerID, let fingerprint):
            // First contact, show fingerprint for optional verification
        case .peerKeyChanged(let peerID, let old, let new):
            // Identity changed, warn user of possible MITM
        case .peerVerified(let peerID):
            // User confirmed fingerprint out-of-band
        }
    }
```

Background on the trust model is in [Security: Trust-On-First-Use](Security.md#trust-on-first-use-tofu).
