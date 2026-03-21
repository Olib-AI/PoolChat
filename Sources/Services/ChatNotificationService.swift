// ChatNotificationService.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
@preconcurrency import UserNotifications

/// Types of chat notifications
public enum ChatNotificationType: Sendable {
    case privateMessage
    case mention
    case groupMessage
}

/// Data for deep linking from chat notifications
public struct ChatNotificationDeepLink: Codable, Sendable {
    /// Type of chat: "private", "group", or "mention"
    public let chatType: String
    /// Sender's peer ID for private chats
    public let senderID: String?
    /// Sender's display name
    public let senderName: String
    /// Message ID for navigation
    public let messageID: String?

    public init(chatType: String, senderID: String?, senderName: String, messageID: String? = nil) {
        self.chatType = chatType
        self.senderID = senderID
        self.senderName = senderName
        self.messageID = messageID
    }
}

/// Notification name for Pool Chat deep link events
public extension Notification.Name {
    static let poolChatDeepLink = Notification.Name("poolChatDeepLink")
}

/// Service for handling chat notifications (local notifications)
public actor ChatNotificationService {

    // MARK: - Singleton

    /// Shared instance for app-wide notification management
    public static let shared = ChatNotificationService()

    // MARK: - Properties

    private var isAuthorized: Bool = false
    private var categoriesRegistered: Bool = false

    // MARK: - Initialization

    public init() {
        Task {
            await requestAuthorization()
            await registerNotificationCategories()
        }
    }

    // MARK: - Authorization

    /// Request notification authorization
    public func requestAuthorization() async {
        do {
            let options: UNAuthorizationOptions = [.alert, .sound, .badge]
            isAuthorized = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
            log("Notification authorization: \(isAuthorized)", category: .runtime)
        } catch {
            log("Failed to request notification authorization: \(error)", level: .error, category: .runtime)
            isAuthorized = false
        }
    }

    /// Check current authorization status
    public func checkAuthorizationStatus() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
        return isAuthorized
    }

    // MARK: - Notification Categories

    /// Register notification categories with actions
    public func registerNotificationCategories() async {
        guard !categoriesRegistered else { return }

        // Reply action for messages
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY_ACTION",
            title: "Reply",
            options: [.authenticationRequired],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a message..."
        )

        // Mark as read action
        let markReadAction = UNNotificationAction(
            identifier: "MARK_READ_ACTION",
            title: "Mark as Read",
            options: []
        )

        // Private message category
        let privateMessageCategory = UNNotificationCategory(
            identifier: "PRIVATE_MESSAGE",
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Group message category
        let groupMessageCategory = UNNotificationCategory(
            identifier: "GROUP_MESSAGE",
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Mention category
        let mentionCategory = UNNotificationCategory(
            identifier: "MENTION",
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let categories: Set<UNNotificationCategory> = [
            privateMessageCategory,
            groupMessageCategory,
            mentionCategory
        ]

        UNUserNotificationCenter.current().setNotificationCategories(categories)
        categoriesRegistered = true
        log("Registered chat notification categories", category: .runtime)
    }

    // MARK: - Send Notifications

    /// Send a chat notification with deep link support
    /// - Parameters:
    ///   - type: The type of chat notification
    ///   - senderID: The sender's peer ID (required for private messages)
    ///   - senderName: The sender's display name
    ///   - messagePreview: Preview text of the message
    ///   - messageID: Optional message ID for navigation
    public func sendChatNotification(
        type: ChatNotificationType,
        senderID: String? = nil,
        senderName: String,
        messagePreview: String,
        messageID: String? = nil
    ) async {
        log("[NOTIFICATION] sendChatNotification called - type: \(type), sender: \(senderName), isAuthorized: \(isAuthorized)", category: .runtime)

        // Check authorization, try to get it if not authorized
        if !isAuthorized {
            log("[NOTIFICATION] Not authorized, requesting authorization...", category: .runtime)
            await requestAuthorization()
            guard isAuthorized else {
                log("[NOTIFICATION] Authorization denied, cannot send notification", level: .warning, category: .runtime)
                return
            }
        }

        // Ensure categories are registered
        if !categoriesRegistered {
            await registerNotificationCategories()
        }

        let content = UNMutableNotificationContent()

        // Build deep link data
        // SECURITY: Never include actual message content in notification body to prevent
        // plaintext leakage via Notification Center and lock screen.
        let chatType: String
        switch type {
        case .privateMessage:
            content.title = senderName
            content.body = "New message"
            content.categoryIdentifier = "PRIVATE_MESSAGE"
            chatType = "private"

        case .mention:
            content.title = "\(senderName) mentioned you"
            content.body = "New message"
            content.categoryIdentifier = "MENTION"
            chatType = "mention"

        case .groupMessage:
            content.title = "Pool Chat"
            content.subtitle = senderName
            content.body = "New message"
            content.categoryIdentifier = "GROUP_MESSAGE"
            chatType = "group"
        }

        content.sound = .default
        content.interruptionLevel = .active

        // Add deep link data to userInfo
        let deepLink = ChatNotificationDeepLink(
            chatType: chatType,
            senderID: senderID,
            senderName: senderName,
            messageID: messageID
        )

        if let deepLinkData = try? JSONEncoder().encode(deepLink),
           let deepLinkDict = try? JSONSerialization.jsonObject(with: deepLinkData) as? [String: Any] {
            content.userInfo = [
                "deepLink": deepLinkDict,
                "chatType": chatType,
                "senderID": senderID ?? "",
                "senderName": senderName
            ]
        }

        // Add thread identifier for grouping notifications
        switch type {
        case .privateMessage:
            content.threadIdentifier = "private_\(senderID ?? "unknown")"
        case .groupMessage, .mention:
            content.threadIdentifier = "group_chat"
        }

        // Create a unique identifier for this notification
        let identifier = "chat_\(UUID().uuidString)"

        // Immediate trigger
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            log("[NOTIFICATION] Successfully sent \(type) notification from \(senderName) - id: \(identifier)", category: .runtime)
        } catch {
            log("[NOTIFICATION] Failed to send notification: \(error)", level: .error, category: .runtime)
        }
    }

    /// Truncate message preview if too long
    private func truncateMessagePreview(_ message: String, maxLength: Int = 100) -> String {
        if message.count <= maxLength {
            return message
        }
        let truncated = String(message.prefix(maxLength - 3))
        return truncated + "..."
    }

    // MARK: - Clear Notifications

    /// Clear all pending chat notifications
    public func clearAllNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    /// Clear notifications for a specific chat
    public nonisolated func clearNotifications(forChatID chatID: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let identifiersToRemove = notifications
                .filter { $0.request.identifier.contains(chatID) }
                .map { $0.request.identifier }

            center.removeDeliveredNotifications(withIdentifiers: identifiersToRemove)
        }
    }

    /// Clear notifications for a specific thread (private chat or group)
    public func clearNotifications(forThreadID threadID: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let identifiersToRemove = notifications
                .filter { $0.request.content.threadIdentifier == threadID }
                .map { $0.request.identifier }

            center.removeDeliveredNotifications(withIdentifiers: identifiersToRemove)
        }
    }
}
