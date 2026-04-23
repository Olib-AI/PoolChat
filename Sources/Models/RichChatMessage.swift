// RichChatMessage.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import SwiftUI

/// Types of chat message content
public enum ChatContentType: String, Codable, Sendable {
    case text = "text"
    case image = "image"
    case voice = "voice"
    case emoji = "emoji"
    case system = "system"
    case poll = "poll"
}

// MARK: - Poll Data

/// Poll data for poll messages
public struct PollData: Codable, Sendable, Equatable {
    public let question: String
    public let options: [String]
    public var votes: [String: [String]] // option -> list of peerIDs who voted
    public let allowVoteChange: Bool // ISSUE 5: Whether users can change their vote

    public init(question: String, options: [String], votes: [String: [String]] = [:], allowVoteChange: Bool = true) {
        self.question = question
        self.options = options
        self.allowVoteChange = allowVoteChange
        // Initialize votes dictionary with empty arrays for each option
        var initialVotes = votes
        for option in options {
            if initialVotes[option] == nil {
                initialVotes[option] = []
            }
        }
        self.votes = initialVotes
    }

    /// Total number of votes
    public var totalVotes: Int {
        votes.values.reduce(0) { $0 + $1.count }
    }

    /// Get vote count for a specific option
    public func voteCount(for option: String) -> Int {
        votes[option]?.count ?? 0
    }

    /// Get vote percentage for a specific option
    public func votePercentage(for option: String) -> Double {
        let total = totalVotes
        guard total > 0 else { return 0 }
        return Double(voteCount(for: option)) / Double(total)
    }

    /// Check if a peer has voted for a specific option
    public func hasVoted(peerID: String, for option: String) -> Bool {
        votes[option]?.contains(peerID) ?? false
    }

    /// Get the option a peer voted for (if any)
    public func votedOption(for peerID: String) -> String? {
        for (option, voters) in votes {
            if voters.contains(peerID) {
                return option
            }
        }
        return nil
    }

    /// Check if a peer has already voted (on any option)
    public func hasVoted(peerID: String) -> Bool {
        for voters in votes.values {
            if voters.contains(peerID) {
                return true
            }
        }
        return false
    }

    /// Check if a peer can vote (either hasn't voted, or vote change is allowed)
    public func canVote(peerID: String) -> Bool {
        if !hasVoted(peerID: peerID) {
            return true // Never voted, can always vote
        }
        return allowVoteChange // Already voted, depends on allowVoteChange setting
    }

    /// Create a new PollData with an updated vote
    /// Returns nil if the peer cannot vote (already voted and vote change not allowed)
    public func withVote(from peerID: String, for option: String) -> PollData? {
        // ISSUE 5: Check if vote is allowed
        let alreadyVoted = hasVoted(peerID: peerID)
        if alreadyVoted && !allowVoteChange {
            return nil // Cannot change vote
        }

        var newVotes = votes

        // Remove previous vote if exists (only matters if allowVoteChange is true)
        if alreadyVoted {
            for (opt, var voters) in newVotes {
                if let index = voters.firstIndex(of: peerID) {
                    voters.remove(at: index)
                    newVotes[opt] = voters
                }
            }
        }

        // Add new vote
        if newVotes[option] != nil {
            newVotes[option]?.append(peerID)
        } else {
            newVotes[option] = [peerID]
        }

        return PollData(question: question, options: options, votes: newVotes, allowVoteChange: allowVoteChange)
    }
}

// MARK: - Reply Preview

/// Preview data for replied messages
public struct ReplyPreview: Codable, Sendable, Equatable {
    public let messageID: UUID
    public let senderName: String
    public let previewText: String

    public init(messageID: UUID, senderName: String, previewText: String) {
        self.messageID = messageID
        self.senderName = senderName
        self.previewText = previewText
    }
}

/// A rich chat message that can contain text, images, voice, emojis, or polls
public struct RichChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let senderID: String
    public let senderName: String
    public let contentType: ChatContentType
    public let timestamp: Date
    public let isFromLocalUser: Bool

    // Content based on type
    public var text: String?
    public var imageData: Data?
    public var voiceData: Data?
    public var voiceDuration: TimeInterval?
    public var emoji: String?

    // Poll content
    public var pollData: PollData?

    // Reactions: emoji -> list of peerIDs who reacted
    public var reactions: [String: [String]]

    // Reply to another message
    public var replyTo: ReplyPreview?

    // Mentions: list of peer IDs mentioned in this message
    public var mentions: [String]

    // Message status
    public var status: MessageStatus
    public var isEncrypted: Bool

    // Profile information from sender (optional, for display)
    public var senderAvatarEmoji: String?
    public var senderAvatarColorIndex: Int?

    public init(
        id: UUID = UUID(),
        senderID: String,
        senderName: String,
        contentType: ChatContentType,
        timestamp: Date = Date(),
        isFromLocalUser: Bool,
        text: String? = nil,
        imageData: Data? = nil,
        voiceData: Data? = nil,
        voiceDuration: TimeInterval? = nil,
        emoji: String? = nil,
        pollData: PollData? = nil,
        reactions: [String: [String]] = [:],
        replyTo: ReplyPreview? = nil,
        mentions: [String] = [],
        status: MessageStatus = .sent,
        isEncrypted: Bool = true,
        senderAvatarEmoji: String? = nil,
        senderAvatarColorIndex: Int? = nil
    ) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.contentType = contentType
        self.timestamp = timestamp
        self.isFromLocalUser = isFromLocalUser
        self.text = text
        self.imageData = imageData
        self.voiceData = voiceData
        self.voiceDuration = voiceDuration
        self.emoji = emoji
        self.pollData = pollData
        self.reactions = reactions
        self.replyTo = replyTo
        self.mentions = mentions
        self.status = status
        self.isEncrypted = isEncrypted
        self.senderAvatarEmoji = senderAvatarEmoji
        self.senderAvatarColorIndex = senderAvatarColorIndex
    }

    /// Quick reaction emojis
    public static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

    /// Check if a peer has reacted with a specific emoji
    public func hasReacted(peerID: String, emoji: String) -> Bool {
        reactions[emoji]?.contains(peerID) ?? false
    }

    /// Get all reactions as sorted pairs (emoji, count) for display
    public var sortedReactions: [(emoji: String, peerIDs: [String])] {
        reactions
            .filter { !$0.value.isEmpty }
            .sorted { $0.value.count > $1.value.count }
            .map { (emoji: $0.key, peerIDs: $0.value) }
    }

    /// Create a copy with an added/removed reaction
    public func withReaction(_ emoji: String, from peerID: String) -> RichChatMessage {
        var newReactions = reactions

        if let existing = newReactions[emoji], existing.contains(peerID) {
            // Remove reaction
            newReactions[emoji] = existing.filter { $0 != peerID }
            if newReactions[emoji]?.isEmpty == true {
                newReactions.removeValue(forKey: emoji)
            }
        } else {
            // Add reaction
            if newReactions[emoji] != nil {
                newReactions[emoji]?.append(peerID)
            } else {
                newReactions[emoji] = [peerID]
            }
        }

        var copy = self
        copy.reactions = newReactions
        return copy
    }

    /// Create a copy with updated poll data
    /// Create a copy with updated poll vote
    /// Returns nil if the vote is not allowed (already voted and vote change disabled)
    public func withPollVote(from peerID: String, for option: String) -> RichChatMessage? {
        guard let poll = pollData else { return nil }
        guard let updatedPoll = poll.withVote(from: peerID, for: option) else {
            return nil // Vote not allowed
        }
        var copy = self
        copy.pollData = updatedPoll
        return copy
    }

    /// Avatar color index - uses profile color if available, otherwise hash-based fallback
    public var avatarColorIndex: Int {
        senderAvatarColorIndex ?? abs(senderID.hashValue) % 8
    }

    /// Avatar emoji - uses profile emoji if available
    public var avatarEmoji: String? {
        senderAvatarEmoji
    }

    /// Check if a specific peer is mentioned in this message
    public func isMentioning(peerID: String) -> Bool {
        mentions.contains(peerID)
    }

    /// Create a text message
    public static func textMessage(
        from senderID: String,
        senderName: String,
        text: String,
        isFromLocalUser: Bool,
        replyTo: ReplyPreview? = nil,
        mentions: [String] = []
    ) -> RichChatMessage {
        RichChatMessage(
            senderID: senderID,
            senderName: senderName,
            contentType: .text,
            isFromLocalUser: isFromLocalUser,
            text: text,
            replyTo: replyTo,
            mentions: mentions
        )
    }

    /// Create a poll message
    public static func pollMessage(
        from senderID: String,
        senderName: String,
        question: String,
        options: [String],
        isFromLocalUser: Bool,
        allowVoteChange: Bool = true
    ) -> RichChatMessage {
        let pollData = PollData(question: question, options: options, allowVoteChange: allowVoteChange)
        return RichChatMessage(
            senderID: senderID,
            senderName: senderName,
            contentType: .poll,
            isFromLocalUser: isFromLocalUser,
            pollData: pollData
        )
    }

    /// Get a preview text for this message (for reply preview)
    public var previewText: String {
        switch contentType {
        case .text:
            let text = self.text ?? ""
            return text.count > 50 ? String(text.prefix(50)) + "..." : text
        case .image:
            return "[Photo]"
        case .voice:
            return "[Voice message]"
        case .emoji:
            return emoji ?? ""
        case .system:
            return text ?? ""
        case .poll:
            return "[Poll] \(pollData?.question ?? "")"
        }
    }

    /// Create an image message
    public static func imageMessage(
        from senderID: String,
        senderName: String,
        imageData: Data,
        isFromLocalUser: Bool
    ) -> RichChatMessage {
        RichChatMessage(
            senderID: senderID,
            senderName: senderName,
            contentType: .image,
            isFromLocalUser: isFromLocalUser,
            imageData: imageData
        )
    }

    /// Create a voice message
    public static func voiceMessage(
        from senderID: String,
        senderName: String,
        voiceData: Data,
        duration: TimeInterval,
        isFromLocalUser: Bool
    ) -> RichChatMessage {
        RichChatMessage(
            senderID: senderID,
            senderName: senderName,
            contentType: .voice,
            isFromLocalUser: isFromLocalUser,
            voiceData: voiceData,
            voiceDuration: duration
        )
    }

    /// Create an emoji message
    public static func emojiMessage(
        from senderID: String,
        senderName: String,
        emoji: String,
        isFromLocalUser: Bool
    ) -> RichChatMessage {
        RichChatMessage(
            senderID: senderID,
            senderName: senderName,
            contentType: .emoji,
            isFromLocalUser: isFromLocalUser,
            emoji: emoji
        )
    }

    /// Create a system message
    public static func systemMessage(text: String) -> RichChatMessage {
        RichChatMessage(
            senderID: "system",
            senderName: "System",
            contentType: .system,
            isFromLocalUser: false,
            text: text,
            isEncrypted: false
        )
    }

    public static func == (lhs: RichChatMessage, rhs: RichChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

/// Message delivery status
public enum MessageStatus: String, Codable, Sendable {
    case sending = "sending"
    case sent = "sent"
    case delivered = "delivered"
    case read = "read"
    case failed = "failed"

    public var iconName: String {
        switch self {
        case .sending: return "clock"
        case .sent: return "checkmark"
        case .delivered: return "checkmark.circle"
        case .read: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        }
    }
}

// MARK: - Private Chat Payload

/// Extended payload for private chat messages
public struct PrivateChatPayload: Codable, Sendable {
    public let chatPayload: RichChatPayload
    public let isPrivate: Bool
    public let targetPeerID: String?

    public init(chatPayload: RichChatPayload, isPrivate: Bool, targetPeerID: String?) {
        self.chatPayload = chatPayload
        self.isPrivate = isPrivate
        self.targetPeerID = targetPeerID
    }
}

// MARK: - Codable Payload for Transmission

/// Payload for transmitting chat messages over the network
public struct RichChatPayload: Codable, Sendable {
    public let messageID: UUID
    public let senderID: String
    public let senderName: String
    public let contentType: ChatContentType
    public let timestamp: Date

    // Content (only one will be set based on contentType)
    public var text: String?
    public var imageData: Data?
    public var voiceData: Data?
    public var voiceDuration: TimeInterval?
    public var emoji: String?

    // Poll data
    public var pollData: PollData?

    // Reactions
    public var reactions: [String: [String]]

    // Reply reference
    public var replyTo: ReplyPreview?

    // Mentions
    public var mentions: [String]

    public var isEncrypted: Bool

    // Profile information from sender
    public var senderAvatarEmoji: String?
    public var senderAvatarColorIndex: Int?

    public init(from message: RichChatMessage) {
        self.messageID = message.id
        self.senderID = message.senderID
        self.senderName = message.senderName
        self.contentType = message.contentType
        self.timestamp = message.timestamp
        self.text = message.text
        self.imageData = message.imageData
        self.voiceData = message.voiceData
        self.voiceDuration = message.voiceDuration
        self.emoji = message.emoji
        self.pollData = message.pollData
        self.reactions = message.reactions
        self.replyTo = message.replyTo
        self.mentions = message.mentions
        self.isEncrypted = message.isEncrypted
        self.senderAvatarEmoji = message.senderAvatarEmoji
        self.senderAvatarColorIndex = message.senderAvatarColorIndex
    }

    public func toMessage(isFromLocalUser: Bool) -> RichChatMessage {
        RichChatMessage(
            id: messageID,
            senderID: senderID,
            senderName: senderName,
            contentType: contentType,
            timestamp: timestamp,
            isFromLocalUser: isFromLocalUser,
            text: text,
            imageData: imageData,
            voiceData: voiceData,
            voiceDuration: voiceDuration,
            emoji: emoji,
            pollData: pollData,
            reactions: reactions,
            replyTo: replyTo,
            mentions: mentions,
            status: .delivered,
            isEncrypted: isEncrypted,
            senderAvatarEmoji: senderAvatarEmoji,
            senderAvatarColorIndex: senderAvatarColorIndex
        )
    }
}

// MARK: - Reaction Update Payload

/// Payload for syncing reaction updates to peers
public struct ReactionUpdatePayload: Codable, Sendable {
    public let messageID: UUID
    public let emoji: String
    public let peerID: String
    public let isAdding: Bool // true = add, false = remove

    public init(messageID: UUID, emoji: String, peerID: String, isAdding: Bool) {
        self.messageID = messageID
        self.emoji = emoji
        self.peerID = peerID
        self.isAdding = isAdding
    }
}

// MARK: - Poll Vote Payload

/// Payload for syncing poll votes to peers
public struct PollVotePayload: Codable, Sendable {
    public let messageID: UUID
    public let option: String
    public let voterID: String

    public init(messageID: UUID, option: String, voterID: String) {
        self.messageID = messageID
        self.option = option
        self.voterID = voterID
    }
}

// MARK: - Chat History Sync Payload

/// Payload for syncing chat history to newly joined members
public struct ChatHistorySyncPayload: Codable, Sendable {
    public let messages: [RichChatPayload]
    public let isGroupChat: Bool

    public init(messages: [RichChatPayload], isGroupChat: Bool) {
        self.messages = messages
        self.isGroupChat = isGroupChat
    }
}

/// Payload for requesting chat history from host
public struct ChatHistoryRequestPayload: Codable, Sendable {
    public let requestID: UUID
    public let requestingPeerID: String

    public init(requestID: UUID = UUID(), requestingPeerID: String = "") {
        self.requestID = requestID
        self.requestingPeerID = requestingPeerID
    }
}

/// Payload for clearing chat history (broadcast by host)
public struct ClearHistoryPayload: Codable, Sendable {
    public let sessionID: String
    public let clearedBy: String
    public let timestamp: Date

    public init(sessionID: String, clearedBy: String, timestamp: Date = Date()) {
        self.sessionID = sessionID
        self.clearedBy = clearedBy
        self.timestamp = timestamp
    }
}

// MARK: - Encrypted Chat Payload

/// Wrapper for E2E encrypted chat messages.
/// This payload is used to transport encrypted data over the network.
/// The actual message content (PrivateChatPayload, ReactionUpdatePayload, etc.)
/// is encrypted inside `encryptedData`.
public struct EncryptedChatPayload: Codable, Sendable {
    /// The encrypted message data (nonce + ciphertext + tag from AES-GCM)
    public let encryptedData: Data

    /// Sender's peer ID for key lookup during decryption
    public let senderPeerID: String

    /// Whether this is a private chat message (vs group)
    public let isPrivateChat: Bool

    /// Target peer ID for private chat (nil for group chat)
    public let targetPeerID: String?

    /// Message type identifier to help with decoding after decryption
    public let messageType: EncryptedMessageType

    public init(
        encryptedData: Data,
        senderPeerID: String,
        isPrivateChat: Bool,
        targetPeerID: String?,
        messageType: EncryptedMessageType
    ) {
        self.encryptedData = encryptedData
        self.senderPeerID = senderPeerID
        self.isPrivateChat = isPrivateChat
        self.targetPeerID = targetPeerID
        self.messageType = messageType
    }
}

/// Types of encrypted messages for routing after decryption
public enum EncryptedMessageType: String, Codable, Sendable {
    case chatMessage = "chat_message"
    case reaction = "reaction"
    case pollVote = "poll_vote"
    case historySync = "history_sync"
    case clearHistory = "clear_history"
    /// Call signaling messages (offer, answer, reject, end, media control).
    case callSignal = "call_signal"
    /// Real-time media frames (audio/video) for active calls.
    case mediaFrame = "media_frame"
}

// MARK: - Chat Mode

/// Mode of chat communication
public enum ChatMode: Equatable, Hashable, Sendable, Codable {
    case group
    case privateChat(peerID: String)

    public var isGroup: Bool {
        if case .group = self { return true }
        return false
    }

    public var privatePeerID: String? {
        if case .privateChat(let peerID) = self { return peerID }
        return nil
    }
}

// MARK: - Chat Conversation

/// Represents a chat conversation (group or private)
public struct ChatConversation: Identifiable, Codable, Sendable {
    public let id: String
    public let participantIDs: [String]
    public let isGroupChat: Bool
    public var messages: [StoredChatMessage]
    public var lastUpdated: Date
    public var unreadCount: Int

    /// The peer ID for private chats (nil for group)
    public var privatePeerID: String? {
        isGroupChat ? nil : participantIDs.first { $0 != "local" }
    }

    public init(
        id: String,
        participantIDs: [String],
        isGroupChat: Bool,
        messages: [StoredChatMessage] = [],
        lastUpdated: Date = Date(),
        unreadCount: Int = 0
    ) {
        self.id = id
        self.participantIDs = participantIDs
        self.isGroupChat = isGroupChat
        self.messages = messages
        self.lastUpdated = lastUpdated
        self.unreadCount = unreadCount
    }

    /// Create a group conversation ID from session ID
    /// NOTE: This uses the session UUID which changes every pool recreation.
    /// For persistent history across pool reconnections, use stableGroupConversationID instead.
    public static func groupConversationID(sessionID: String) -> String {
        "group_\(sessionID)"
    }

    /// Create a STABLE group conversation ID that persists across pool reconnections.
    /// Uses pool name and host peer ID to create a consistent identifier.
    /// - Parameters:
    ///   - poolName: The name of the pool
    ///   - hostPeerID: The host's peer ID
    /// - Returns: A stable conversation ID for the group chat
    @available(*, deprecated, message: "Use hostBasedGroupConversationID instead for simpler, host-based identification")
    public static func stableGroupConversationID(poolName: String, hostPeerID: String) -> String {
        // Create a stable hash from pool name and host ID
        // This ensures the same pool (by name + host) always maps to the same conversation
        let combined = "\(poolName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))_\(hostPeerID)"
        let hash = combined.hashValue
        // Use absolute value and take last 16 characters to keep it manageable
        let stableHash = String(format: "%016llx", abs(Int64(hash)))
        return "group_stable_\(stableHash)"
    }

    /// Create a HOST-BASED group conversation ID that persists forever.
    /// The group is identified purely by the host's peer ID - no pool name needed.
    /// This matches WhatsApp-style groups where each host has ONE persistent group.
    /// - Parameter hostPeerID: The host's peer ID (stable identifier)
    /// - Returns: A stable conversation ID in the format `group_<hostPeerID>`
    public static func hostBasedGroupConversationID(hostPeerID: String) -> String {
        "group_\(hostPeerID)"
    }

    /// Create a private conversation ID from two peer IDs
    public static func privateConversationID(localPeerID: String, remotePeerID: String) -> String {
        // Sort to ensure consistent ID regardless of direction
        let sorted = [localPeerID, remotePeerID].sorted()
        return "private_\(sorted[0])_\(sorted[1])"
    }
}

// MARK: - Stored Chat Message

/// A chat message optimized for persistent storage (no large binary data inline)
public struct StoredChatMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let senderID: String
    public let senderName: String
    public let contentType: ChatContentType
    public let timestamp: Date
    public let isFromLocalUser: Bool

    // Text content
    public var text: String?
    public var emoji: String?

    // Media references (stored separately to manage size)
    public var imageDataKey: String?
    public var voiceDataKey: String?
    public var voiceDuration: TimeInterval?

    // Poll data
    public var pollData: PollData?

    // Reactions
    public var reactions: [String: [String]]

    // Reply reference
    public var replyTo: ReplyPreview?

    // Mentions
    public var mentions: [String]

    public init(from message: RichChatMessage, imageDataKey: String? = nil, voiceDataKey: String? = nil) {
        self.id = message.id
        self.senderID = message.senderID
        self.senderName = message.senderName
        self.contentType = message.contentType
        self.timestamp = message.timestamp
        self.isFromLocalUser = message.isFromLocalUser
        self.text = message.text
        self.emoji = message.emoji
        self.imageDataKey = message.imageData != nil ? imageDataKey : nil
        self.voiceDataKey = message.voiceData != nil ? voiceDataKey : nil
        self.voiceDuration = message.voiceDuration
        self.pollData = message.pollData
        self.reactions = message.reactions
        self.replyTo = message.replyTo
        self.mentions = message.mentions
    }

    public init(
        id: UUID = UUID(),
        senderID: String,
        senderName: String,
        contentType: ChatContentType,
        timestamp: Date = Date(),
        isFromLocalUser: Bool,
        text: String? = nil,
        emoji: String? = nil,
        imageDataKey: String? = nil,
        voiceDataKey: String? = nil,
        voiceDuration: TimeInterval? = nil,
        pollData: PollData? = nil,
        reactions: [String: [String]] = [:],
        replyTo: ReplyPreview? = nil,
        mentions: [String] = []
    ) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.contentType = contentType
        self.timestamp = timestamp
        self.isFromLocalUser = isFromLocalUser
        self.text = text
        self.emoji = emoji
        self.imageDataKey = imageDataKey
        self.voiceDataKey = voiceDataKey
        self.voiceDuration = voiceDuration
        self.pollData = pollData
        self.reactions = reactions
        self.replyTo = replyTo
        self.mentions = mentions
    }

    /// Convert to RichChatMessage (without media data - caller must load separately)
    public func toRichChatMessage(imageData: Data? = nil, voiceData: Data? = nil) -> RichChatMessage {
        RichChatMessage(
            id: id,
            senderID: senderID,
            senderName: senderName,
            contentType: contentType,
            timestamp: timestamp,
            isFromLocalUser: isFromLocalUser,
            text: text,
            imageData: imageData,
            voiceData: voiceData,
            voiceDuration: voiceDuration,
            emoji: emoji,
            pollData: pollData,
            reactions: reactions,
            replyTo: replyTo,
            mentions: mentions,
            status: .delivered,
            isEncrypted: true
        )
    }
}

// MARK: - Private Chat Info

/// Summary info for displaying private chat list
public struct PrivateChatInfo: Identifiable, Sendable {
    public let id: String
    public let peerID: String
    public let peerName: String
    public let avatarColorIndex: Int
    public var lastMessage: String?
    public var lastMessageTime: Date?
    public var unreadCount: Int
    public var isOnline: Bool

    public init(
        peerID: String,
        peerName: String,
        avatarColorIndex: Int,
        lastMessage: String? = nil,
        lastMessageTime: Date? = nil,
        unreadCount: Int = 0,
        isOnline: Bool = false
    ) {
        self.id = peerID
        self.peerID = peerID
        self.peerName = peerName
        self.avatarColorIndex = avatarColorIndex
        self.lastMessage = lastMessage
        self.lastMessageTime = lastMessageTime
        self.unreadCount = unreadCount
        self.isOnline = isOnline
    }
}

// MARK: - Group Chat Info

/// Metadata for a host-based group chat (like WhatsApp groups)
/// Each group is identified by the host's peer ID and persists across sessions
public struct GroupChatInfo: Identifiable, Codable, Sendable {
    /// Unique identifier - the host's peer ID (stable, never changes)
    public let id: String

    /// The host's peer ID (same as id, for clarity)
    public var hostPeerID: String { id }

    /// Display name of the host (used as group name)
    public var hostDisplayName: String

    /// Pool name associated with this group
    public var poolName: String

    /// Avatar color index for the group (based on host)
    public var avatarColorIndex: Int

    /// Avatar emoji for the group (optional, from host profile)
    public var avatarEmoji: String?

    /// Preview of the last message in the group
    public var lastMessage: String?

    /// Timestamp of the last message
    public var lastMessageTime: Date?

    /// Number of unread messages in this group
    public var unreadCount: Int

    /// Whether the host is currently connected/online
    public var isHostConnected: Bool

    /// The stable conversation ID used for message storage
    /// Format: `group_<hostPeerID>` - never changes for a given host
    public var conversationID: String {
        "group_\(id)"
    }

    public init(
        hostPeerID: String,
        hostDisplayName: String,
        poolName: String,
        avatarColorIndex: Int = 0,
        avatarEmoji: String? = nil,
        lastMessage: String? = nil,
        lastMessageTime: Date? = nil,
        unreadCount: Int = 0,
        isHostConnected: Bool = false
    ) {
        self.id = hostPeerID
        self.hostDisplayName = hostDisplayName
        self.poolName = poolName
        self.avatarColorIndex = avatarColorIndex
        self.avatarEmoji = avatarEmoji
        self.lastMessage = lastMessage
        self.lastMessageTime = lastMessageTime
        self.unreadCount = unreadCount
        self.isHostConnected = isHostConnected
    }

    /// Create a GroupChatInfo from host peer ID
    /// Uses the host's peer ID as the stable identifier
    public static func create(
        hostPeerID: String,
        hostDisplayName: String,
        poolName: String,
        avatarColorIndex: Int? = nil,
        avatarEmoji: String? = nil
    ) -> GroupChatInfo {
        GroupChatInfo(
            hostPeerID: hostPeerID,
            hostDisplayName: hostDisplayName,
            poolName: poolName,
            avatarColorIndex: avatarColorIndex ?? abs(hostPeerID.hashValue) % 8,
            avatarEmoji: avatarEmoji
        )
    }
}

// MARK: - Mention Info

/// Information about a mention in chat (used for UI)
public struct MentionInfo: Identifiable, Sendable {
    public let id: String // peerID
    public let displayName: String
    public let avatarColorIndex: Int

    public init(peerID: String, displayName: String, avatarColorIndex: Int) {
        self.id = peerID
        self.displayName = displayName
        self.avatarColorIndex = avatarColorIndex
    }
}

// MARK: - Mention Parsing

/// Utility for parsing and extracting mentions from text
public enum MentionParser {
    /// Pattern to match @mentions (alphanumeric and underscores)
    private static let mentionPattern = try! NSRegularExpression(pattern: "@([\\w]+)", options: [])

    /// Extract all @usernames from text
    public static func extractMentionUsernames(from text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = mentionPattern.matches(in: text, options: [], range: range)

        return matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    /// Find peer IDs from mention usernames
    public static func findMentionedPeerIDs(
        text: String,
        availablePeers: [(id: String, displayName: String)]
    ) -> [String] {
        let usernames = extractMentionUsernames(from: text)
        var mentionedIDs: [String] = []

        for username in usernames {
            // Match username case-insensitively against display names
            if let peer = availablePeers.first(where: {
                $0.displayName.lowercased().replacingOccurrences(of: " ", with: "_") == username.lowercased() ||
                $0.displayName.lowercased() == username.lowercased()
            }) {
                if !mentionedIDs.contains(peer.id) {
                    mentionedIDs.append(peer.id)
                }
            }
        }

        return mentionedIDs
    }

    /// Check if text has an active mention being typed (ends with @ or @partial)
    public static func getActiveMentionQuery(from text: String) -> String? {
        // Find if we're in the middle of typing a mention
        guard let atIndex = text.lastIndex(of: "@") else { return nil }

        let afterAt = text[text.index(after: atIndex)...]

        // If there's a space after @, no active mention
        if afterAt.contains(" ") || afterAt.contains("\n") { return nil }

        return String(afterAt)
    }

    /// Replace @query with @displayName in text
    public static func replaceMentionQuery(in text: String, with displayName: String) -> String {
        guard let atIndex = text.lastIndex(of: "@") else { return text }

        let beforeAt = text[..<atIndex]
        // Use displayName with underscores for spaces
        let formattedName = displayName.replacingOccurrences(of: " ", with: "_")
        return "\(beforeAt)@\(formattedName) "
    }
}

// MARK: - Emoji Categories

/// Categories of emojis for the picker
public enum EmojiCategory: String, CaseIterable, Identifiable {
    case smileys = "Smileys"
    case gestures = "Gestures"
    case hearts = "Hearts"
    case animals = "Animals"
    case food = "Food"
    case activities = "Activities"
    case objects = "Objects"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .smileys: return "face.smiling"
        case .gestures: return "hand.wave"
        case .hearts: return "heart"
        case .animals: return "hare"
        case .food: return "fork.knife"
        case .activities: return "sportscourt"
        case .objects: return "lightbulb"
        }
    }

    public var emojis: [String] {
        switch self {
        case .smileys:
            return ["😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "😊",
                    "😇", "🥰", "😍", "🤩", "😘", "😗", "😚", "😙", "🥲", "😋",
                    "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭", "🤫", "🤔", "😐",
                    "😑", "😶", "😏", "😒", "🙄", "😬", "😮‍💨", "🤥", "😌", "😔",
                    "😪", "🤤", "😴", "😷", "🤒", "🤕", "🤢", "🤮", "🤧", "🥵"]
        case .gestures:
            return ["👋", "🤚", "🖐️", "✋", "🖖", "👌", "🤌", "🤏", "✌️", "🤞",
                    "🤟", "🤘", "🤙", "👈", "👉", "👆", "🖕", "👇", "☝️", "👍",
                    "👎", "✊", "👊", "🤛", "🤜", "👏", "🙌", "👐", "🤲", "🤝",
                    "🙏", "💪", "🦾", "🦿", "🦵", "🦶", "👂", "🦻", "👃", "👀"]
        case .hearts:
            return ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔",
                    "❤️‍🔥", "❤️‍🩹", "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝",
                    "💟", "♥️", "😻", "💑", "👩‍❤️‍👨", "👨‍❤️‍👨", "👩‍❤️‍👩", "💏", "👩‍❤️‍💋‍👨", "👨‍❤️‍💋‍👨"]
        case .animals:
            return ["🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐻‍❄️", "🐨",
                    "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🙈", "🙉", "🙊", "🐔",
                    "🐧", "🐦", "🐤", "🦆", "🦅", "🦉", "🦇", "🐺", "🐗", "🐴",
                    "🦄", "🐝", "🪱", "🐛", "🦋", "🐌", "🐞", "🐜", "🪰", "🪲"]
        case .food:
            return ["🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍈",
                    "🍒", "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🍆", "🥑", "🥦",
                    "🌮", "🌯", "🥗", "🍕", "🍔", "🍟", "🌭", "🍿", "🧂", "🥓",
                    "🍳", "🥞", "🧇", "🥐", "🍞", "🥖", "🥨", "🧀", "🍖", "🍗"]
        case .activities:
            return ["⚽", "🏀", "🏈", "⚾", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱",
                    "🪀", "🏓", "🏸", "🏒", "🏑", "🥍", "🏏", "🪃", "🥅", "⛳",
                    "🪁", "🏹", "🎣", "🤿", "🥊", "🥋", "🎽", "🛹", "🛼", "🛷",
                    "⛸️", "🥌", "🎿", "⛷️", "🏂", "🪂", "🏋️", "🤺", "🏇", "⛹️"]
        case .objects:
            return ["💡", "🔦", "🕯️", "🪔", "💰", "💳", "💎", "⚖️", "🔧", "🔨",
                    "⚒️", "🛠️", "⛏️", "🔩", "⚙️", "🔗", "📎", "🖇️", "📏", "📐",
                    "✂️", "🗃️", "📦", "📫", "📪", "📬", "📭", "📮", "🗳️", "✏️",
                    "🖊️", "🖋️", "🖌️", "🖍️", "📝", "💼", "📁", "📂", "🗂️", "📅"]
        }
    }
}
