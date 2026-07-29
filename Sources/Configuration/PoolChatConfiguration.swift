// PoolChatConfiguration.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import SwiftUI
import ConnectionPool

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

    // MARK: - UI design injection seams
    //
    // PoolChat cannot import the app's ThemeKit / IconKit / LanguageKit. The host
    // wires these seams from `App/Integration/PoolChatBridge.swift`. They delegate
    // to the shared `PoolDesign` store (defined in ConnectionPool) that both pool
    // apps observe, so a single injection styles chat + calling UI too. When unset
    // the package falls back to neutral colors, English strings, and SF Symbols.

    /// Resolves a `PoolThemeSnapshot` of the live theme tokens for a color scheme.
    @MainActor public static var themeResolver: (@MainActor (ColorScheme) -> PoolThemeSnapshot)? {
        get { PoolDesign.shared.themeResolver }
        set { PoolDesign.shared.themeResolver = newValue }
    }

    /// Resolves a LanguageKit key (+ optional interpolation args) to a string.
    @MainActor public static var stringProvider: (@MainActor (String, [String: String]?) -> String)? {
        get { PoolDesign.shared.stringProvider }
        set { PoolDesign.shared.stringProvider = newValue }
    }

    /// Renders an FA icon name at a point size + weight (host uses IconKit).
    @MainActor public static var iconRenderer: (@MainActor (String, CGFloat, PoolIconWeight) -> AnyView)? {
        get { PoolDesign.shared.iconRenderer }
        set { PoolDesign.shared.iconRenderer = newValue }
    }

    /// Notify the pool UI that the theme, appearance, or language changed.
    @MainActor public static func notifyDesignChanged() {
        PoolDesign.shared.invalidate()
    }
}
