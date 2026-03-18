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
    /// Logger implementation. Falls back to os.Logger if nil.
    /// Uses `nonisolated(unsafe)` because the logger is set once at app startup
    /// before any PoolChat services are used, and the protocol is Sendable.
    nonisolated(unsafe) public static var logger: PoolChatLogger?

    /// Secure storage provider. Must be set before ChatHistoryService is used.
    @MainActor public static var storageProvider: SecureStorageProvider?

    /// When `true` (default), unencrypted `.chat` messages from legacy clients are
    /// silently dropped and logged. When `false`, they are accepted with a warning
    /// marker for backwards compatibility during migration periods.
    ///
    /// SECURITY: Accepting unencrypted messages is an encryption downgrade vector.
    /// Production deployments should keep this set to `true`.
    nonisolated(unsafe) public static var rejectUnencryptedMessages: Bool = true

    /// When `true` (default), the host will send chat history to newly joined peers
    /// upon request. When `false`, history sync requests from peers are silently ignored.
    ///
    /// SECURITY: Disabling history sync prevents a newly connected peer from receiving
    /// the full conversation history, which may be desirable for sensitive conversations
    /// or pools where message ephemerality is preferred.
    nonisolated(unsafe) public static var enableHistorySync: Bool = true
}
