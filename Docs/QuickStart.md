# Quick Start

[Back to README](../README.md)

Install the package first: see [Installation](Installation.md).

## Contents

- [1. Configure PoolChat](#1-configure-poolchat)
- [2. Key Exchange](#2-key-exchange)
- [3. Encrypt and Send a Message](#3-encrypt-and-send-a-message)
- [4. Use the Built-in SwiftUI View](#4-use-the-built-in-swiftui-view)

## 1. Configure PoolChat

Set up logging and storage before using any PoolChat services:

```swift
import PoolChat

// Inject your logger (optional, falls back to os.Logger)
PoolChatConfiguration.logger = MyAppLogger()

// Inject your encrypted storage provider (required for history persistence)
PoolChatConfiguration.storageProvider = MySecureStorage()

// Security settings (defaults are recommended)
PoolChatConfiguration.rejectUnencryptedMessages = true
PoolChatConfiguration.enableHistorySync = true
```

Every knob is documented in [Configuration](Configuration.md).

## 2. Key Exchange

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

First contact records the peer identity under TOFU. See [Security: Trust-On-First-Use](Security.md#trust-on-first-use-tofu).

## 3. Encrypt and Send a Message

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
    // Send via ConnectionPool
}
```

## 4. Use the Built-in SwiftUI View

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

The view includes message bubbles, emoji picker, voice recording controls, image sending, poll creation, reactions, reply threading, @mention autocomplete, and voice/video calling flows, all with cross-platform support.
