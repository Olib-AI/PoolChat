# Configuration

[Back to README](../README.md)

## Contents

- [PoolChatConfiguration](#poolchatconfiguration)
- [PoolChatLogger Protocol](#poolchatlogger-protocol)
- [SecureStorageProvider Protocol](#securestorageprovider-protocol)

## PoolChatConfiguration

Static configuration point for dependency injection. Set these before using PoolChat services.

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `logger` | `PoolChatLogger?` | `nil` (os.Logger fallback) | Custom logging implementation |
| `storageProvider` | `SecureStorageProvider?` | `nil` | Encrypted storage for chat history |
| `rejectUnencryptedMessages` | `Bool` | `true` | Drop unencrypted messages (security) |
| `enableHistorySync` | `Bool` | `true` | Send chat history to new members |

Leaving `rejectUnencryptedMessages` at `true` is the secure default. See [Security: Encryption Downgrade Prevention](Security.md#encryption-downgrade-prevention).

## PoolChatLogger Protocol

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

## SecureStorageProvider Protocol

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

Your implementation should encrypt all data at rest, for example with AES-256-GCM. PoolChat never writes plaintext messages to disk.
