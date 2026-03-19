// ChatNotificationBridge.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import Combine
import ConnectionPool

/// Bridge service that ensures chat notifications are sent even when Pool Chat window is closed.
///
/// The problem: When Pool Chat window is closed, its PoolChatViewModel is deallocated,
/// so there's no subscriber to receive messages and send notifications.
///
/// The solution: This bridge subscribes directly to ConnectionPoolManager.shared.messageReceived
/// and sends notifications for chat messages when Pool Chat is not visible.
///
/// Lifecycle:
/// - The bridge is a singleton that lives as long as the app
/// - It starts inactive and becomes active when Pool Chat first connects
/// - PoolChatViewModel updates the visibility state
/// - When Pool Chat window is closed, the bridge continues to receive messages and send notifications
@MainActor
public final class ChatNotificationBridge: ObservableObject {
    
    // MARK: - Singleton
    
    /// Shared instance for app-wide notification handling
    public static let shared = ChatNotificationBridge()
    
    // MARK: - Properties
    
    /// Whether Pool Chat window is currently visible (active and focused)
    /// Updated by PoolChatViewModel when window state changes
    @Published public private(set) var isPoolChatVisible: Bool = false

    /// Whether the in-game chat overlay is active (suppresses system notifications)
    /// Updated by GameChatOverlayViewModel when the overlay appears/disappears
    @Published public var isGameChatActive: Bool = false
    
    /// Whether the bridge is actively monitoring for messages
    @Published public private(set) var isActive: Bool = false
    
    /// Local peer ID for filtering out own messages
    private var localPeerID: String = ""
    
    // MARK: - Private Properties
    
    private let notificationService = ChatNotificationService.shared
    private var cancellables = Set<AnyCancellable>()
    private var poolManager: ConnectionPoolManager?
    
    // MARK: - Initialization
    
    private init() {
        log("[NOTIFICATION-BRIDGE] Initialized", category: .runtime)
    }
    
    // MARK: - Setup
    
    /// Activate the bridge with the connection pool manager
    /// Called when Pool Chat first connects to ensure notifications work
    public func activate(poolManager: ConnectionPoolManager, localPeerID: String) {
        guard !isActive || self.poolManager !== poolManager else {
            log("[NOTIFICATION-BRIDGE] Already active with this pool manager", category: .runtime)
            return
        }
        
        self.poolManager = poolManager
        self.localPeerID = localPeerID
        
        // Subscribe to messages
        cancellables.removeAll()
        poolManager.messageReceived
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleMessage(message)
            }
            .store(in: &cancellables)
        
        isActive = true
        log("[NOTIFICATION-BRIDGE] Activated - localPeerID: \(localPeerID)", category: .runtime)
    }
    
    /// Deactivate the bridge (called when disconnecting from pool)
    public func deactivate() {
        cancellables.removeAll()
        poolManager = nil
        isActive = false
        log("[NOTIFICATION-BRIDGE] Deactivated", category: .runtime)
    }
    
    // MARK: - Visibility Management
    
    /// Update Pool Chat window visibility state
    /// Called by PoolChatViewModel when window state changes
    public func setPoolChatVisible(_ visible: Bool) {
        let oldValue = isPoolChatVisible
        isPoolChatVisible = visible
        log("[NOTIFICATION-BRIDGE] Pool Chat visibility: \(oldValue) -> \(visible)", category: .runtime)
        
        // Clear notifications when becoming visible
        if visible {
            Task {
                await notificationService.clearAllNotifications()
            }
        }
    }
    
    // MARK: - Message Handling
    
    private func handleMessage(_ message: PoolMessage) {
        // Only handle chat messages
        guard message.type == .chat else { return }
        
        // Don't notify for own messages
        guard message.senderID != localPeerID else { return }
        
        // Don't notify if Pool Chat is visible
        guard !isPoolChatVisible else {
            log("[NOTIFICATION-BRIDGE] Skipping notification - Pool Chat is visible", level: .debug, category: .runtime)
            return
        }

        // Don't notify if in-game chat overlay is active (it has its own toast/badge)
        guard !isGameChatActive else {
            log("[NOTIFICATION-BRIDGE] Skipping notification - game chat overlay is active", level: .debug, category: .runtime)
            return
        }
        
        log("[NOTIFICATION-BRIDGE] Sending notification for message from \(message.senderName)", category: .runtime)
        
        // Extract message preview
        let messagePreview = extractMessagePreview(from: message)
        
        // Determine notification type
        let notificationType: ChatNotificationType = .groupMessage
        
        // Send notification
        Task {
            await notificationService.sendChatNotification(
                type: notificationType,
                senderID: message.senderID,
                senderName: message.senderName,
                messagePreview: messagePreview,
                messageID: message.id.uuidString
            )
        }
    }
    
    /// Extract a preview string from the message payload
    private func extractMessagePreview(from message: PoolMessage) -> String {
        let payloadData = message.payload

        // Try to decode as ChatPayload
        if let payload = try? JSONDecoder().decode(ChatPayload.self, from: payloadData) {
            return payload.text
        }

        // Fallback to simple text extraction
        if let text = String(data: payloadData, encoding: .utf8) {
            return text
        }

        return "New message"
    }
}

// MARK: - Simple ChatPayload for decoding

/// Minimal payload structure for extracting message text
private struct ChatPayload: Decodable {
    let text: String
}
