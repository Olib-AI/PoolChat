// PoolChatConfiguration.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

/// Static configuration point for injecting dependencies into the PoolChat package.
/// Must be configured before using any PoolChat services that require logging or storage.
@available(macOS 14.0, iOS 17.0, *)
public enum PoolChatConfiguration {
    private static let _lock = NSLock()

    nonisolated(unsafe) private static var _logger: PoolChatLogger?
    /// Logger implementation. Falls back to os.Logger if nil.
    public static var logger: PoolChatLogger? {
        get { _lock.withLock { _logger } }
        set { _lock.withLock { _logger = newValue } }
    }

    /// Secure storage provider. Must be set before ChatHistoryService is used.
    @MainActor public static var storageProvider: SecureStorageProvider?

    nonisolated(unsafe) private static var _rejectUnencryptedMessages: Bool = true
    /// When `true` (default), unencrypted `.chat` messages from legacy clients are
    /// silently dropped and logged. When `false`, they are accepted with a warning
    /// marker for backwards compatibility during migration periods.
    ///
    /// SECURITY: Accepting unencrypted messages is an encryption downgrade vector.
    /// Production deployments should keep this set to `true`.
    public static var rejectUnencryptedMessages: Bool {
        get { _lock.withLock { _rejectUnencryptedMessages } }
        set { _lock.withLock { _rejectUnencryptedMessages = newValue } }
    }

    nonisolated(unsafe) private static var _enableHistorySync: Bool = true
    /// When `true` (default), the host will send chat history to newly joined peers
    /// upon request. When `false`, history sync requests from peers are silently ignored.
    ///
    /// SECURITY: Disabling history sync prevents a newly connected peer from receiving
    /// the full conversation history, which may be desirable for sensitive conversations
    /// or pools where message ephemerality is preferred.
    public static var enableHistorySync: Bool {
        get { _lock.withLock { _enableHistorySync } }
        set { _lock.withLock { _enableHistorySync = newValue } }
    }
}
