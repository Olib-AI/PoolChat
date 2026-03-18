// ChatHistoryService.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

/// Service for encrypted chat history persistence.
///
/// Storage structure:
/// - Group chats: `chat_group_{poolSessionID}`
/// - Private chats: `chat_private_{peerID1}_{peerID2}` (sorted)
/// - Media files: `chat_media_{messageID}_{type}`
///
/// All data is AES-256-GCM encrypted via SecureDataStore.
///
/// The host maintains authoritative chat history and syncs to new members.
/// History is keyed by pool session ID, persisting across window close/reopen
/// as long as the pool connection remains active.
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class ChatHistoryService: ObservableObject {

    // MARK: - Singleton

    public static let shared = ChatHistoryService()

    // MARK: - Constants

    private static let maxMessagesPerConversation = 1000
    private static let chatDataCategory: StorageDataCategory = .chat

    // MARK: - Published Properties

    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var error: String?

    // MARK: - Private Properties

    private var secureDataStore: SecureStorageProvider? {
        PoolChatConfiguration.storageProvider
    }

    /// In-memory cache of loaded conversations for faster access
    private var conversationCache: [String: ChatConversation] = [:]

    /// Track which session IDs are currently active
    private var activeSessionIDs: Set<String> = []

    // MARK: - Initialization

    private init() {}

    // MARK: - Session Management

    /// Mark a session as active (prevents history from being cleared)
    public func markSessionActive(_ sessionID: String) {
        activeSessionIDs.insert(sessionID)
        log("Marked session active: \(sessionID)", category: .network)
    }

    /// Mark a session as inactive (allows history to be cleared on explicit request)
    public func markSessionInactive(_ sessionID: String) {
        activeSessionIDs.remove(sessionID)
        log("Marked session inactive: \(sessionID)", category: .network)
    }

    /// Check if a session is active
    public func isSessionActive(_ sessionID: String) -> Bool {
        activeSessionIDs.contains(sessionID)
    }

    // MARK: - Public API: Conversations

    /// Load a conversation by ID (uses cache for performance)
    public func loadConversation(id: String) async -> ChatConversation? {
        // Check cache first
        if let cached = conversationCache[id] {
            return cached
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let key = conversationKey(for: id)
            if let conversation = try await secureDataStore?.load(ChatConversation.self, forKey: key, category: Self.chatDataCategory) {
                conversationCache[id] = conversation
                return conversation
            }
            return nil
        } catch {
            log("Failed to load conversation \(id): \(error)", level: .error, category: .security)
            self.error = "Failed to load conversation"
            return nil
        }
    }

    /// Load group conversation for a session
    public func loadGroupConversation(sessionID: String) async -> ChatConversation? {
        let conversationID = ChatConversation.groupConversationID(sessionID: sessionID)
        return await loadConversation(id: conversationID)
    }

    /// Load private conversation between two peers
    public func loadPrivateConversation(localPeerID: String, remotePeerID: String) async -> ChatConversation? {
        let conversationID = ChatConversation.privateConversationID(localPeerID: localPeerID, remotePeerID: remotePeerID)
        return await loadConversation(id: conversationID)
    }

    /// Save a conversation (updates cache and persists to disk)
    public func saveConversation(_ conversation: ChatConversation) async {
        do {
            var trimmedConversation = conversation

            // Trim old messages if over limit
            if trimmedConversation.messages.count > Self.maxMessagesPerConversation {
                let excess = trimmedConversation.messages.count - Self.maxMessagesPerConversation
                trimmedConversation.messages.removeFirst(excess)
            }

            // Update cache
            conversationCache[conversation.id] = trimmedConversation

            let key = conversationKey(for: conversation.id)
            try await secureDataStore?.save(trimmedConversation, forKey: key, category: Self.chatDataCategory)
            log("Saved conversation \(conversation.id) with \(trimmedConversation.messages.count) messages", level: .debug, category: .security)
        } catch {
            log("Failed to save conversation: \(error)", level: .error, category: .security)
            self.error = "Failed to save conversation"
        }
    }

    /// Invalidate cache for a conversation (forces reload from disk)
    public func invalidateCache(for conversationID: String) {
        conversationCache.removeValue(forKey: conversationID)
    }

    /// Clear all cached conversations
    public func clearCache() {
        conversationCache.removeAll()
    }

    /// Delete a conversation
    public func deleteConversation(id: String) async {
        // Remove from cache first to ensure consistency
        conversationCache.removeValue(forKey: id)

        do {
            let key = conversationKey(for: id)
            try await secureDataStore?.delete(forKey: key, category: Self.chatDataCategory)
            log("Deleted conversation \(id)", category: .security)
        } catch {
            log("Failed to delete conversation: \(error)", level: .error, category: .security)
        }
    }

    // MARK: - Public API: Messages

    /// Add a message to a conversation
    /// Includes deduplication to prevent storing duplicate messages
    public func addMessage(_ message: RichChatMessage, to conversationID: String, isGroupChat: Bool, participantIDs: [String]) async {
        // Load existing conversation or create new
        var conversation = await loadConversation(id: conversationID) ?? ChatConversation(
            id: conversationID,
            participantIDs: participantIDs,
            isGroupChat: isGroupChat
        )

        // Check for duplicate message by ID (O(n) but persistence is less frequent)
        if conversation.messages.contains(where: { $0.id == message.id }) {
            log("[DEDUP] Skipping duplicate message in persistence: \(message.id)", level: .debug, category: .security)
            return
        }

        // Store media separately if present
        var imageDataKey: String?
        var voiceDataKey: String?

        if let imageData = message.imageData {
            imageDataKey = "media_\(message.id)_image"
            await saveMediaData(imageData, key: imageDataKey!)
        }

        if let voiceData = message.voiceData {
            voiceDataKey = "media_\(message.id)_voice"
            await saveMediaData(voiceData, key: voiceDataKey!)
        }

        // Create stored message
        let storedMessage = StoredChatMessage(
            from: message,
            imageDataKey: imageDataKey,
            voiceDataKey: voiceDataKey
        )

        // Add to conversation
        conversation.messages.append(storedMessage)
        conversation.lastUpdated = message.timestamp

        // Increment unread count if not from local user
        if !message.isFromLocalUser {
            conversation.unreadCount += 1
        }

        await saveConversation(conversation)
    }

    /// Mark conversation as read
    public func markAsRead(conversationID: String) async {
        guard var conversation = await loadConversation(id: conversationID) else { return }
        conversation.unreadCount = 0
        await saveConversation(conversation)
    }

    /// Get messages for a conversation with loaded media
    public func getMessages(for conversationID: String) async -> [RichChatMessage] {
        log("[HISTORY] getMessages called for conversationID: \(conversationID)", category: .network)
        guard let conversation = await loadConversation(id: conversationID) else {
            log("[HISTORY] No conversation found for: \(conversationID)", level: .warning, category: .network)
            return []
        }
        log("[HISTORY] Found conversation with \(conversation.messages.count) stored messages", category: .network)

        var messages: [RichChatMessage] = []

        for stored in conversation.messages {
            // Load media data if present
            var imageData: Data?
            var voiceData: Data?

            if let imageKey = stored.imageDataKey {
                imageData = await loadMediaData(key: imageKey)
            }

            if let voiceKey = stored.voiceDataKey {
                voiceData = await loadMediaData(key: voiceKey)
            }

            messages.append(stored.toRichChatMessage(imageData: imageData, voiceData: voiceData))
        }

        return messages
    }

    // MARK: - Public API: Private Chats List

    /// Get list of all private chat infos for a local peer
    public func getPrivateChatInfos(localPeerID: String, onlinePeerIDs: Set<String>) async -> [PrivateChatInfo] {
        let keys = secureDataStore?.listKeys(in: Self.chatDataCategory) ?? []
        let privateKeys = keys.filter { $0.hasPrefix("chat_private_") }

        var infos: [PrivateChatInfo] = []

        for key in privateKeys {
            guard let conversation = await loadConversation(id: key.replacingOccurrences(of: "chat_", with: "")) else {
                continue
            }

            // Find the remote peer ID
            guard let remotePeerID = conversation.participantIDs.first(where: { $0 != localPeerID }) else {
                continue
            }

            // Get last message preview
            let lastMessage = conversation.messages.last
            var lastMessagePreview: String?

            switch lastMessage?.contentType {
            case .text:
                lastMessagePreview = lastMessage?.text
            case .image:
                lastMessagePreview = "Photo"
            case .voice:
                lastMessagePreview = "Voice message"
            case .emoji:
                lastMessagePreview = lastMessage?.emoji
            case .system:
                lastMessagePreview = lastMessage?.text
            case .poll:
                lastMessagePreview = "Poll: \(lastMessage?.pollData?.question ?? "")"
            case .none:
                lastMessagePreview = nil
            }

            // FIX: Get the OTHER peer's name from THEIR messages, not from the last message sender
            // The last message could be sent BY us, in which case senderName would be OUR name.
            // We need to find a message from the remote peer to get their display name.
            let remotePeerName: String = {
                // Find any message FROM the remote peer to get their actual display name
                if let messageFromRemotePeer = conversation.messages.last(where: { $0.senderID == remotePeerID }) {
                    return messageFromRemotePeer.senderName
                }
                // Fallback to remote peer ID if no messages from them exist yet
                return remotePeerID
            }()

            let info = PrivateChatInfo(
                peerID: remotePeerID,
                peerName: remotePeerName,
                avatarColorIndex: abs(remotePeerID.hashValue) % 8,
                lastMessage: lastMessagePreview,
                lastMessageTime: conversation.lastUpdated,
                unreadCount: conversation.unreadCount,
                isOnline: onlinePeerIDs.contains(remotePeerID)
            )

            infos.append(info)
        }

        // Sort by last message time (most recent first)
        infos.sort { ($0.lastMessageTime ?? .distantPast) > ($1.lastMessageTime ?? .distantPast) }

        return infos
    }

    /// Get total unread count across all private chats
    public func getTotalUnreadCount(localPeerID: String) async -> Int {
        let infos = await getPrivateChatInfos(localPeerID: localPeerID, onlinePeerIDs: [])
        return infos.reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: - Public API: Group Chats (Host-Based)

    private static let groupMetadataKey = "pool_groups"

    /// Load all group chat metadata
    public func loadGroupChatInfos() async -> [GroupChatInfo] {
        do {
            if let groups = try await secureDataStore?.load([GroupChatInfo].self, forKey: Self.groupMetadataKey, category: Self.chatDataCategory) {
                return groups
            }
            return []
        } catch {
            log("Failed to load group chat infos: \(error)", level: .error, category: .security)
            return []
        }
    }

    /// Save all group chat metadata
    public func saveGroupChatInfos(_ groups: [GroupChatInfo]) async {
        do {
            try await secureDataStore?.save(groups, forKey: Self.groupMetadataKey, category: Self.chatDataCategory)
            log("Saved \(groups.count) group chat infos", level: .debug, category: .security)
        } catch {
            log("Failed to save group chat infos: \(error)", level: .error, category: .security)
        }
    }

    /// Update or add a single group chat info
    public func upsertGroupChatInfo(_ info: GroupChatInfo) async {
        var groups = await loadGroupChatInfos()

        if let index = groups.firstIndex(where: { $0.id == info.id }) {
            groups[index] = info
        } else {
            groups.insert(info, at: 0)
        }

        await saveGroupChatInfos(groups)
    }

    /// Update group chat info with latest message preview
    public func updateGroupChatLastMessage(hostPeerID: String, message: String, timestamp: Date, incrementUnread: Bool = false) async {
        var groups = await loadGroupChatInfos()

        if let index = groups.firstIndex(where: { $0.id == hostPeerID }) {
            groups[index].lastMessage = message
            groups[index].lastMessageTime = timestamp
            if incrementUnread {
                groups[index].unreadCount += 1
            }
            await saveGroupChatInfos(groups)
        }
    }

    /// Mark a group chat as read
    public func markGroupAsRead(hostPeerID: String) async {
        var groups = await loadGroupChatInfos()

        if let index = groups.firstIndex(where: { $0.id == hostPeerID }) {
            groups[index].unreadCount = 0
            await saveGroupChatInfos(groups)
        }
    }

    /// Update host connection status for all groups
    public func updateGroupHostStatus(hostPeerID: String, isConnected: Bool) async {
        var groups = await loadGroupChatInfos()

        if let index = groups.firstIndex(where: { $0.id == hostPeerID }) {
            groups[index].isHostConnected = isConnected
            await saveGroupChatInfos(groups)
        }
    }

    /// Delete a group chat and its messages
    public func deleteGroupChat(hostPeerID: String) async {
        // Remove from group list
        var groups = await loadGroupChatInfos()
        groups.removeAll { $0.id == hostPeerID }
        await saveGroupChatInfos(groups)

        // Delete conversation messages
        let conversationID = ChatConversation.hostBasedGroupConversationID(hostPeerID: hostPeerID)
        await deleteConversation(id: conversationID)

        log("Deleted group chat for host: \(hostPeerID)", category: .security)
    }

    /// Load group conversation by host peer ID (host-based storage)
    public func loadHostBasedGroupConversation(hostPeerID: String) async -> ChatConversation? {
        let conversationID = ChatConversation.hostBasedGroupConversationID(hostPeerID: hostPeerID)
        return await loadConversation(id: conversationID)
    }

    /// Get messages for a host-based group conversation
    public func getHostBasedGroupMessages(hostPeerID: String) async -> [RichChatMessage] {
        let conversationID = ChatConversation.hostBasedGroupConversationID(hostPeerID: hostPeerID)
        return await getMessages(for: conversationID)
    }

    /// Get all messages for a host-based group (for history sync)
    public func getHostBasedGroupMessagesForSync(hostPeerID: String) async -> [RichChatPayload] {
        let conversationID = ChatConversation.hostBasedGroupConversationID(hostPeerID: hostPeerID)
        guard let conversation = await loadConversation(id: conversationID) else {
            return []
        }

        var payloads: [RichChatPayload] = []
        var seenIDs: Set<UUID> = []

        for stored in conversation.messages {
            guard stored.contentType != .system else { continue }
            guard !seenIDs.contains(stored.id) else { continue }
            seenIDs.insert(stored.id)

            var imageData: Data?
            var voiceData: Data?

            if let imageKey = stored.imageDataKey {
                imageData = await loadMediaData(key: imageKey)
            }

            if let voiceKey = stored.voiceDataKey {
                voiceData = await loadMediaData(key: voiceKey)
            }

            let message = stored.toRichChatMessage(imageData: imageData, voiceData: voiceData)
            payloads.append(RichChatPayload(from: message))
        }

        return payloads
    }

    // MARK: - Public API: Cleanup

    /// Clear all chat history
    public func clearAllChatHistory() async {
        let keys = secureDataStore?.listKeys(in: Self.chatDataCategory) ?? []
        let chatKeys = keys.filter { $0.hasPrefix("chat_") || $0.hasPrefix("media_") }

        for key in chatKeys {
            do {
                try await secureDataStore?.delete(forKey: key, category: Self.chatDataCategory)
            } catch {
                log("Failed to delete chat key \(key): \(error)", level: .warning, category: .security)
            }
        }

        // Clear cache
        conversationCache.removeAll()

        log("Cleared all chat history", category: .security)
    }

    /// Clear history for a specific session (group chat)
    /// - Parameters:
    ///   - sessionID: The pool session ID
    ///   - force: If true, clears even if session is active
    public func clearSessionHistory(sessionID: String, force: Bool = false) async {
        guard force || !activeSessionIDs.contains(sessionID) else {
            log("Cannot clear history for active session: \(sessionID)", level: .warning, category: .security)
            return
        }

        let conversationID = ChatConversation.groupConversationID(sessionID: sessionID)
        await deleteConversation(id: conversationID)

        // Note: We can't easily filter media by session without loading all conversations,
        // so we rely on the conversation deletion and let orphaned media be cleaned up separately

        log("Cleared session history: \(sessionID)", category: .security)
    }

    /// Clear group chat history using stable conversation ID
    /// - Parameters:
    ///   - stableConversationID: The stable conversation ID (from stableGroupConversationID)
    ///   - force: If true, clears even if session is active
    public func clearGroupHistoryByStableID(_ stableConversationID: String, force: Bool = false) async {
        await deleteConversation(id: stableConversationID)
        log("Cleared group history for stableID: \(stableConversationID)", category: .security)
    }

    /// Get all messages for a session (for host to send to new members)
    /// Returns RichChatPayload array suitable for transmission
    /// Ensures unique messages by ID (no duplicates)
    public func getSessionMessagesForSync(sessionID: String) async -> [RichChatPayload] {
        let conversationID = ChatConversation.groupConversationID(sessionID: sessionID)
        guard let conversation = await loadConversation(id: conversationID) else {
            return []
        }

        // Convert stored messages to payloads, ensuring uniqueness by ID
        var payloads: [RichChatPayload] = []
        var seenIDs: Set<UUID> = []

        for stored in conversation.messages {
            // Skip system messages for sync
            guard stored.contentType != .system else { continue }

            // Skip duplicates (shouldn't happen but extra safety)
            guard !seenIDs.contains(stored.id) else {
                log("[DEDUP] getSessionMessagesForSync: skipping duplicate stored message: \(stored.id)", level: .debug, category: .security)
                continue
            }
            seenIDs.insert(stored.id)

            // Load media data if present (for full sync)
            var imageData: Data?
            var voiceData: Data?

            if let imageKey = stored.imageDataKey {
                imageData = await loadMediaData(key: imageKey)
            }

            if let voiceKey = stored.voiceDataKey {
                voiceData = await loadMediaData(key: voiceKey)
            }

            let message = stored.toRichChatMessage(imageData: imageData, voiceData: voiceData)
            let payload = RichChatPayload(from: message)
            payloads.append(payload)
        }

        log("[DEDUP] getSessionMessagesForSync: returning \(payloads.count) unique messages for session \(sessionID)", level: .debug, category: .security)
        return payloads
    }

    // MARK: - Private Helpers

    private func conversationKey(for id: String) -> String {
        "chat_\(id)"
    }

    private func saveMediaData(_ data: Data, key: String) async {
        do {
            try await secureDataStore?.saveData(data, forKey: key, category: Self.chatDataCategory)
        } catch {
            log("Failed to save media data: \(error)", level: .error, category: .security)
        }
    }

    private func loadMediaData(key: String) async -> Data? {
        do {
            return try await secureDataStore?.loadData(forKey: key, category: Self.chatDataCategory)
        } catch {
            log("Failed to load media data: \(error)", level: .error, category: .security)
            return nil
        }
    }
}
