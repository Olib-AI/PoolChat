// PoolChatViewModel.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import SwiftUI
import Combine
import CryptoKit
import PhotosUI
import UserNotifications
import ConnectionPool
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
import ImageIO
#endif

/// View model for the Pool Chat standalone app
@MainActor
public final class PoolChatViewModel: ObservableObject, PoolChatAppLifecycle {

    // MARK: - Published Properties

    /// Chat messages for current conversation
    @Published public var messages: [RichChatMessage] = []

    /// Current text input
    @Published public var textInput: String = ""

    /// UI State
    @Published public var showEmojiPicker: Bool = false
    @Published public var showImagePicker: Bool = false
    @Published public var showAttachmentMenu: Bool = false
    @Published public var isRecordingVoice: Bool = false
    @Published public var selectedEmojiCategory: EmojiCategory = .smileys

    /// Image picker selection
    @Published public var selectedPhotoItem: PhotosPickerItem?
    @Published public var selectedImageData: Data?

    /// Voice recording state
    @Published public var voiceRecordingDuration: TimeInterval = 0

    /// Currently playing voice message ID
    @Published public var playingVoiceMessageID: UUID?
    @Published public var voicePlaybackProgress: Double = 0

    /// Error handling
    @Published public var errorMessage: String?
    @Published public var showError: Bool = false

    /// Connection state
    @Published public var isConnected: Bool = false
    @Published public var connectedPeers: [Peer] = []

    /// MC session stabilization state - true while waiting for bindings to be ready
    /// This prevents immediate MC state reads that can cause framework errors
    @Published public var isStabilizingConnection: Bool = false

    // MARK: - Reply State

    /// Message being replied to (shows reply preview bar above input)
    @Published public var replyingToMessage: RichChatMessage?

    // MARK: - Poll Creation State

    /// Whether poll creation sheet is shown
    @Published public var showPollCreation: Bool = false
    @Published public var pollQuestion: String = ""
    @Published public var pollOptions: [String] = ["", ""]
    @Published public var pollAllowVoteChange: Bool = true

    // MARK: - Reaction Picker State

    /// Message ID for which reaction picker is shown
    @Published public var showReactionPickerForMessageID: UUID?

    // MARK: - Chat Mode Properties

    /// Current chat mode (group or private)
    @Published public var chatMode: ChatMode = .group

    /// Selected tab in chat view (0 = Group, 1 = Private)
    @Published public var selectedChatTab: Int = 0

    /// List of private chat infos for the private chats list
    @Published public var privateChatInfos: [PrivateChatInfo] = []

    /// Currently selected private chat peer (when in private mode)
    @Published public var selectedPrivatePeer: Peer?

    /// Total unread count for private messages badge
    @Published public var totalPrivateUnreadCount: Int = 0

    /// Group chat unread count
    @Published public var groupUnreadCount: Int = 0

    /// Whether history is currently loading (for UI feedback)
    @Published public var isLoadingHistory: Bool = false

    /// Number of messages pending encryption key establishment.
    /// When > 0, UI should indicate that messages are waiting to be sent.
    @Published public var pendingEncryptionCount: Int = 0

    // MARK: - Host-Based Group Chat List Properties

    /// List of all group chats (like WhatsApp group list)
    /// Each group is identified by host peer ID and persists forever
    @Published public var groupChatInfos: [GroupChatInfo] = []

    /// Currently selected group chat (when viewing a specific group from the list)
    @Published public var selectedGroupChat: GroupChatInfo?

    /// Whether the user is viewing the group list (true) or a specific group chat (false)
    @Published public var isViewingGroupList: Bool = true

    /// The current group's host peer ID (stable identifier for the group)
    /// This is nil when not connected to any group
    public var currentGroupHostPeerID: String? {
        poolManager?.currentSession?.hostPeerID
    }

    // MARK: - Mention Properties

    /// Whether to show the mention picker popup
    @Published public var showMentionPicker: Bool = false

    /// Current mention search query (text after @)
    @Published public var mentionQuery: String = ""

    /// Filtered list of peers matching the mention query
    @Published public var filteredMentionPeers: [MentionInfo] = []

    // MARK: - Window Visibility

    /// Whether the Pool Chat window is currently visible (open and not minimized)
    @Published public var isWindowVisible: Bool = false

    // MARK: - Calling

    /// Call manager for voice and video calling.
    public let callManager = CallManager()

    /// Whether the incoming call view should be presented.
    @Published public var showIncomingCallView: Bool = false
    /// Whether the active call view should be presented.
    @Published public var showActiveCallView: Bool = false

    // MARK: - Services

    private let encryptionService = ChatEncryptionService.shared
    public let voiceService = VoiceRecordingService()
    private let notificationService = ChatNotificationService.shared

    @available(macOS 14.0, iOS 17.0, *)
    private var chatHistoryService: ChatHistoryService {
        ChatHistoryService.shared
    }

    // MARK: - Connection Pool Reference

    private var poolManager: ConnectionPoolManager?

    // MARK: - Mesh Relay Service

    /// Relay service for sending messages through intermediate peers when direct connection is unavailable
    private var relayService: MeshRelayService?

    // MARK: - Clear History State

    /// Whether clear history confirmation is showing
    @Published public var showClearHistoryConfirmation: Bool = false

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    /// Tracked setup tasks that use Task.sleep for stabilization delays.
    /// Cancelled when setPoolManager is called again or on terminate.
    private var setupTasks: [Task<Void, Never>] = []

    /// Group chat messages (kept separate for switching between modes)
    private var groupMessages: [RichChatMessage] = []

    /// Private chat messages per peer
    private var privateMessages: [String: [RichChatMessage]] = [:]

    /// Current session ID for group chat persistence (UUID-based, changes each pool recreation)
    private var currentSessionID: String?

    /// Stable group conversation ID for persistent history across pool reconnections
    /// Uses pool name + host peer ID to create a consistent identifier
    @available(*, deprecated, message: "Use hostBasedGroupConvID for simpler host-based identification")
    private var stableGroupConvID: String?

    /// Host-based group conversation ID - simply `group_<hostPeerID>`
    /// This is the primary way to identify group conversations now
    private var hostBasedGroupConvID: String?

    // MARK: - Message Deduplication
    //
    // Deduplication prevents duplicate messages from appearing in the chat UI.
    // Duplicates can occur in several scenarios:
    // 1. Host sends history, then new member also requests history = duplicates
    // 2. Loading from persistence + receiving sync from host = duplicates
    // 3. Same message received multiple times via P2P network = duplicates
    // 4. History sync contains messages already in local array = duplicates
    //
    // We use Set<UUID> for O(1) lookup performance. The sets are:
    // - Populated when loading from persistence
    // - Updated when receiving new messages
    // - Cleared when switching sessions or clearing history

    /// Set of seen group message IDs for O(1) duplicate detection
    private var seenGroupMessageIDs: Set<UUID> = []

    /// Set of seen private message IDs per peer for O(1) duplicate detection
    private var seenPrivateMessageIDs: [String: Set<UUID>] = [:]

    /// Track if history has been loaded for current session
    private var historyLoadedForSession: String?

    /// Track if we've already requested history sync for this session
    private var historyRequestedForSession: String?

    // MARK: - Pending Encryption Queue
    //
    // Messages queued when E2E encryption keys have not yet been established with the target peer(s).
    // When key exchange completes, the queue is flushed automatically. Messages are NEVER sent unencrypted.

    /// Queued outgoing payloads waiting for encryption keys to be established.
    private struct PendingEncryptedMessage {
        let plainData: Data
        let messageType: EncryptedMessageType
        let isPrivateChat: Bool
        let targetPeerIDs: [String]
    }

    /// Pending messages awaiting key exchange completion.
    private var pendingEncryptionQueue: [PendingEncryptedMessage] = []

    /// Maximum number of pending messages to prevent unbounded memory growth.
    private static let maxPendingMessages: Int = 50

    // MARK: - PoolChatAppLifecycle

    @Published public private(set) var runtimeState: PoolChatAppState = .active

    // MARK: - Initialization

    public init() {
        setupVoiceServiceBindings()
        setupChatModeBindings()
        setupTextInputBinding()
    }

    deinit {
        // Clean up relay service only - DO NOT disconnect poolManager
        // The ConnectionPoolManager.shared singleton must persist independently
        // of the Pool Chat window lifecycle. Disconnecting here would break
        // the pool connection when users close the chat window.
        Task { @MainActor [relayService] in
            relayService?.cleanup()
            relayService?.clearCurrentPool()
        }
    }

    /// Set up the connection pool manager reference
    ///
    /// STABILITY FIX (V4): When Pool Chat opens with an existing MC session, ANY synchronous
    /// access to MC state can trigger internal MC framework errors within 15ms of VM creation.
    /// We now defer ALL operations (including localPeerID access and history loading) into
    /// the stabilization Task when there's an existing session.
    public func setPoolManager(_ manager: ConnectionPoolManager) {
        // Cancel any in-flight setup tasks from a previous call
        setupTasks.forEach { $0.cancel() }
        setupTasks.removeAll()

        self.poolManager = manager

        // CRITICAL: Check if there's an existing MC session BEFORE any other operations.
        // Reading @Published properties like poolState is safe - they're just in-memory values.
        let isExistingSession = manager.poolState == .hosting || manager.poolState == .connected

        if isExistingSession {
            // STABILITY FIX (V4): Defer EVERYTHING when opening Pool Chat with an existing session.
            // The MC framework needs time to stabilize before we can safely:
            // 1. Read localPeerID (accesses MCPeerID)
            // 2. Subscribe to state changes (setupPoolManagerBindings)
            // 3. Read connection state (updateConnectionState)
            // 4. Load history (reads currentSession)
            // 5. Send messages (initiateKeyExchangeWithExistingPeers)
            //
            // Previously, localPeerID access and history loading ran synchronously at ~15ms,
            // triggering MC errors before the 500ms stabilization delay completed.
            isStabilizingConnection = true

            let task = Task { @MainActor in
                // Phase 1: Wait for MC session to stabilize (1000ms)
                try? await Task.sleep(for: .milliseconds(1000))
                guard !Task.isCancelled else { return }

                // Verify manager is still valid after delay
                guard self.poolManager != nil else {
                    self.isStabilizingConnection = false
                    return
                }

                // Phase 2: Set up bindings and state (now safe to read MC state)
                self.setupPoolManagerBindings()
                self.updateConnectionState()
                self.isStabilizingConnection = false

                // Phase 2.5: Set up notification bridge (requires localPeerID)
                let peerID = self.localPeerID
                ChatNotificationBridge.shared.activate(poolManager: manager, localPeerID: peerID)

                // Phase 2.6: Load history from local storage (requires currentSession)
                self.loadHistoryIfConnected(manager: manager)

                // Phase 3: Additional delay before sending any MC messages
                let additionalDelayMs = manager.isHost ? 100 : 250
                try? await Task.sleep(for: .milliseconds(additionalDelayMs))
                guard !Task.isCancelled else { return }

                // Re-check connection state (may have disconnected during delays)
                guard let pm = self.poolManager else {
                    log("[SETUP] Pool manager deallocated during post-binding delay", category: .network)
                    return
                }

                guard pm.poolState == .hosting || pm.poolState == .connected else {
                    log("[SETUP] Connection state changed during post-binding delay, skipping key exchange (state: \(pm.poolState))", category: .network)
                    return
                }

                // Phase 4: Now safe to send MC messages for key exchange
                self.initiateKeyExchangeWithExistingPeers()

                // Phase 5: For non-host, check if history request is needed
                if !pm.isHost {
                    if let sessionID = self.currentSessionID, self.historyRequestedForSession != sessionID {
                        let hasEstablishedKeys = pm.connectedPeers.contains { peer in
                            self.encryptionService.hasKeyFor(peerID: peer.id)
                        }

                        if hasEstablishedKeys {
                            let hasMessages = self.groupMessages.contains { $0.contentType != .system }
                            if !hasMessages {
                                log("[SETUP] Keys already established, requesting history sync from host", category: .network)
                                self.requestHistorySyncFromHost()
                                self.historyRequestedForSession = sessionID
                            } else {
                                log("[SETUP] Already have messages, skipping history request", category: .network)
                            }
                        } else {
                            log("[SETUP] Keys not established yet, history request will be triggered after key exchange", category: .network)
                        }
                    }
                }

                // Log state (now safe after stabilization)
                log("[SETUP] setPoolManager completed, poolState: \(manager.poolState), isHost: \(manager.isHost)", category: .network)
                log("[SETUP] currentSession: \(manager.currentSession?.name ?? "nil"), connectedPeers: \(manager.connectedPeers.count)", category: .network)
            }
            setupTasks.append(task)
        } else {
            // No existing session - safe to set up bindings immediately
            // MC isn't active yet, so all operations are safe
            setupPoolManagerBindings()
            updateConnectionState()

            // Activate notification bridge
            let peerID = localPeerID
            Task { @MainActor in
                ChatNotificationBridge.shared.activate(poolManager: manager, localPeerID: peerID)
            }

            // Load history (will be a no-op since not connected)
            loadHistoryIfConnected(manager: manager)

            // Log state
            log("[SETUP] setPoolManager called (no existing session), poolState: \(manager.poolState)", category: .network)
        }

        // Wire up call manager
        callManager.delegate = self
        callManager.localPeerID = manager.localPeerID
        callManager.localDisplayName = manager.localPeerName

        // Subscribe to call state changes to drive UI
        callManager.$incomingCallSignal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signal in
                self?.showIncomingCallView = signal != nil
            }
            .store(in: &cancellables)

        callManager.$currentCall
            .receive(on: DispatchQueue.main)
            .sink { [weak self] call in
                if call == nil {
                    self?.showActiveCallView = false
                    self?.showIncomingCallView = false
                }
            }
            .store(in: &cancellables)
    }

    /// Helper to load chat history if connected to a pool
    /// Extracted to avoid code duplication between sync and async paths
    private func loadHistoryIfConnected(manager: ConnectionPoolManager) {
        guard manager.poolState == .hosting || manager.poolState == .connected else {
            return
        }

        guard let session = manager.currentSession else {
            log("[SETUP] WARNING: Pool is connected/hosting but no currentSession available", level: .warning, category: .network)
            return
        }

        let sessionID = session.id.uuidString
        currentSessionID = sessionID

        // Set the host-based conversation ID (simpler, more stable)
        let hostBasedID = ChatConversation.hostBasedGroupConversationID(hostPeerID: session.hostPeerID)
        hostBasedGroupConvID = hostBasedID
        log("[SETUP] Set currentSessionID: \(sessionID), hostBasedGroupConvID set", category: .network)

        if #available(macOS 14.0, iOS 17.0, *) {
            // Mark session as active to prevent accidental clearing
            chatHistoryService.markSessionActive(sessionID)

            // Register/update this group in the group list
            Task {
                await registerCurrentGroupChat()
                await loadGroupChatList()
            }

            // Only load history if we haven't already loaded for this session
            if historyLoadedForSession != sessionID {
                Task {
                    await loadChatHistory()
                    historyLoadedForSession = sessionID
                    log("[SETUP] Loaded history for session: \(sessionID), messages: \(self.groupMessages.count)", category: .network)
                }
            } else {
                // History already loaded, just display it
                if chatMode.isGroup {
                    messages = groupMessages
                }
                log("[SETUP] History already loaded for session: \(sessionID)", category: .network)
            }
        }
    }

    /// Initiate key exchange with all peers that are already connected
    /// Called when setPoolManager is invoked after connection is established
    ///
    /// STABILITY: Key exchanges are now done asynchronously with small delays between
    /// each peer to avoid flooding the MC session with messages during Pool Chat open.
    private func initiateKeyExchangeWithExistingPeers() {
        guard let poolManager = poolManager else { return }

        let existingPeers = poolManager.connectedPeers.filter { $0.id != poolManager.localPeerID }

        guard !existingPeers.isEmpty else {
            log("[E2E] No existing peers to perform key exchange with", category: .security)
            return
        }

        log("[E2E] Initiating key exchange with \(existingPeers.count) existing peer(s)", category: .security)

        // Stagger key exchanges to avoid flooding MC session
        let task = Task { @MainActor in
            for (index, peer) in existingPeers.enumerated() {
                guard !Task.isCancelled else { return }

                // Check if we already have a key for this peer
                if self.encryptionService.hasKeyFor(peerID: peer.id) {
                    log("[E2E] Already have key for peer: \(peer.displayName), skipping", category: .security)
                    continue
                }

                // Small delay between key exchanges to avoid MC session congestion
                // (except for the first peer)
                if index > 0 {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled else { return }
                }

                // Re-check pool state is still valid
                guard let pm = self.poolManager, pm.poolState == .hosting || pm.poolState == .connected else {
                    log("[E2E] Pool state changed during key exchange, stopping", category: .security)
                    return
                }

                log("[E2E] Sending public key to existing peer: \(peer.displayName) (id: \(peer.id.prefix(8))...)", category: .security)
                self.performKeyExchange(with: peer)
            }
        }
        setupTasks.append(task)
    }

    /// Called when the Pool Chat window is reopened
    /// Reloads history from persistence if needed
    public func onWindowReopen() {
        guard let poolManager = poolManager,
              poolManager.poolState == .hosting || poolManager.poolState == .connected,
              let session = poolManager.currentSession else {
            return
        }

        let sessionID = session.id.uuidString

        // Reload history from persistence
        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                await loadChatHistory()
                historyLoadedForSession = sessionID
            }
        }
    }

    /// Request chat history sync from the host
    /// DTLS TIMING: This function adds a 4000ms delay to ensure DTLS transport is stable
    /// before sending the request. Key exchange happens at 3000ms, so history request
    /// should happen after that completes (4000ms provides safe margin).
    private func requestHistorySyncFromHost() {
        guard let poolManager = poolManager else { return }
        guard !poolManager.isHost else { return }

        // Guard against sending when not in a connected state
        // This prevents "Not in connected state" errors from MultipeerConnectivity
        guard poolManager.poolState == .connected else { return }

        // Find host peer - either marked as isHost, or if not found, use the first connected peer
        // (when joining a pool, the first peer we connect to is always the host)
        var hostPeer = poolManager.connectedPeers.first(where: { $0.isHost })

        if hostPeer == nil {
            // Fallback: If no peer is marked as host, the first peer in the list is typically the host
            // because that's who we connected to when joining
            hostPeer = poolManager.connectedPeers.first
        }

        guard let targetHost = hostPeer else { return }

        let hostID = targetHost.id

        // DTLS GUARD: Delay history request to ensure DTLS transport is stable
        // Key exchange happens at 3000ms, so we wait 4000ms total from peer connection
        let task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(4000))
            guard !Task.isCancelled else { return }

            // Re-check state after DTLS delay
            guard let pm = self.poolManager,
                  pm.poolState == .connected,
                  pm.connectedPeers.contains(where: { $0.id == hostID }) else {
                return
            }

            // Send a history request message to the host
            let requestPayload = ChatHistoryRequestPayload(requestingPeerID: pm.localPeerID)
            guard let payloadData = try? JSONEncoder().encode(requestPayload) else {
                log("Failed to encode history request payload", level: .error, category: .network)
                return
            }

            let message = PoolMessage(
                type: .custom,
                senderID: pm.localPeerID,
                senderName: pm.localPeerName,
                payload: payloadData
            )

            pm.sendMessage(message, to: [hostID])
        }
        setupTasks.append(task)
    }

    private func setupTextInputBinding() {
        // Observe text input changes for mention detection
        $textInput
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] newText in
                self?.handleTextInputChange(newText)
            }
            .store(in: &cancellables)
    }

    private func setupChatModeBindings() {
        // React to chat mode changes
        $chatMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.handleChatModeChange(mode)
            }
            .store(in: &cancellables)

        // React to tab changes
        $selectedChatTab
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                guard let self = self else { return }
                if tab == 0 {
                    // Only switch if not already on group
                    if self.chatMode != .group || self.selectedPrivatePeer != nil {
                        self.switchToGroupChat()
                    }
                } else if tab == 1 {
                    // Switch to private chats list mode
                    // Only clear peer selection if coming from group tab
                    if self.selectedPrivatePeer == nil {
                        // Refresh private chat infos to show the list
                        if #available(macOS 14.0, iOS 17.0, *) {
                            Task {
                                await self.refreshPrivateChatInfos()
                            }
                        }
                    }
                    // NOTE: Do NOT change chatMode here - we want to stay on private tab
                    // chatMode only changes when a specific private chat is selected
                }
            }
            .store(in: &cancellables)
    }

    private func handleChatModeChange(_ mode: ChatMode) {
        switch mode {
        case .group:
            messages = groupMessages
            markGroupChatAsRead()
        case .privateChat(let peerID):
            messages = privateMessages[peerID] ?? []
            markPrivateChatAsRead(peerID: peerID)
        }
    }

    private func setupPoolManagerBindings() {
        guard let poolManager = poolManager else { return }

        // Subscribe to messages - these are event-driven, safe to subscribe immediately
        poolManager.messageReceived
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handlePoolMessage(message)
            }
            .store(in: &cancellables)

        // Subscribe to peer events - these are event-driven, safe to subscribe immediately
        poolManager.peerEvent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handlePeerEvent(event)
            }
            .store(in: &cancellables)

        // STABILITY FIX: Use .dropFirst() to skip the immediate emission from @Published properties.
        // When subscribing to $connectedPeers and $poolState, Combine immediately emits the current
        // value, which triggers MC framework state reads. By dropping the first emission, we only
        // react to CHANGES in state, not the initial state. Initial state is set manually after
        // a delay via updateConnectionState().
        //
        // Subscribe to connection state changes (skip initial emission)
        poolManager.$connectedPeers
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.connectedPeers = peers
                self?.isConnected = !peers.isEmpty
            }
            .store(in: &cancellables)

        poolManager.$poolState
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }

                // CRITICAL FIX: Set up relay service lazily when pool becomes connected.
                // This prevents MC operations from being triggered before a pool exists.
                //
                // STABILITY FIX: Defer relay service setup to a Task to avoid doing it
                // synchronously during Combine publisher emission. This prevents potential
                // hangs when Pool Chat opens with an existing MC session by allowing the
                // UI to settle before starting relay service timers.
                if (state == .hosting || state == .connected) && self.relayService == nil {
                    Task { @MainActor [weak self] in
                        guard let self = self, let manager = self.poolManager else { return }
                        // Double-check relay service is still nil (avoid race condition)
                        guard self.relayService == nil else { return }
                        // Verify pool state hasn't changed
                        guard manager.poolState == .hosting || manager.poolState == .connected else { return }

                        self.setupRelayService(manager)
                        log("[RELAY] MeshRelayService set up on pool state change to: \(state)", category: .network)
                    }
                }

                self.updateConnectionState()
            }
            .store(in: &cancellables)

        // Manually set initial state now that bindings are ready.
        // This is safe because we're already past the 500ms stabilization delay (for existing sessions)
        // or there's no existing session (so MC isn't initialized yet).
        self.connectedPeers = poolManager.connectedPeers
        self.isConnected = !poolManager.connectedPeers.isEmpty

        // Set up relay service if already connected (with stabilization delay)
        if (poolManager.poolState == .hosting || poolManager.poolState == .connected) && self.relayService == nil {
            let task = Task { @MainActor [weak self] in
                // Additional 100ms delay for relay service to be extra safe
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                guard let self = self, let manager = self.poolManager else { return }
                guard self.relayService == nil else { return }
                guard manager.poolState == .hosting || manager.poolState == .connected else { return }

                self.setupRelayService(manager)
                log("[RELAY] MeshRelayService set up during initial binding setup", category: .network)
            }
            setupTasks.append(task)
        }
    }

    /// Initialize and configure the mesh relay service for multi-hop message delivery
    ///
    /// SAFETY: This method is idempotent - calling it multiple times will not create duplicate services.
    /// The relay service is cleaned up before creating a new one to prevent orphaned timers.
    ///
    /// DEBUG: TEMPORARILY DISABLED to test if mesh relay causes MC session interference.
    /// The relay feature may be creating timers and topology broadcasts that interfere
    /// with MultipeerConnectivity session stability.
    private func setupRelayService(_ manager: ConnectionPoolManager) {
        // IDEMPOTENCY: Clean up existing relay service before creating new one
        // This prevents orphaned timers and duplicate subscriptions
        if let existingRelay = relayService {
            log("[RELAY] Cleaning up existing MeshRelayService before creating new one", category: .network)
            existingRelay.cleanup()
            existingRelay.clearCurrentPool()
            self.relayService = nil
        }

        // Initialize relay service with our peer ID
        let newRelayService = MeshRelayService(localPeerID: manager.localPeerID)
        newRelayService.setPoolManager(manager)
        self.relayService = newRelayService

        // Set current pool if already connected
        if let session = manager.currentSession {
            newRelayService.setCurrentPool(session.id)
            // Derive pool shared secret from the local encryption key material.
            // This secret is NOT the pool UUID (which is public) but is derived from
            // cryptographic material that observers cannot access.
            let localPublicKey = encryptionService.publicKey
            newRelayService.poolSharedSecret = Self.derivePoolSharedSecret(
                localPublicKey: localPublicKey, poolID: session.id
            )
        }

        // Subscribe to relay service publishers - handle envelopes destined for us
        newRelayService.receivedEnvelope
            .receive(on: DispatchQueue.main)
            .sink { [weak self] envelope in
                self?.handleRelayedEnvelope(envelope)
            }
            .store(in: &cancellables)

        // Log delivery failures for diagnostics
        newRelayService.deliveryFailed
            .receive(on: DispatchQueue.main)
            .sink { (messageID, destinationPeerID) in
                log("Relay delivery failed for message \(messageID) to peer \(destinationPeerID)", level: .warning, category: .network)
            }
            .store(in: &cancellables)

        log("[RELAY] MeshRelayService initialized for peer: \(manager.localPeerID.prefix(8))...", category: .network)
    }

    private func setupVoiceServiceBindings() {
        // Bind voice recording state
        voiceService.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.isRecordingVoice = isRecording
            }
            .store(in: &cancellables)

        voiceService.$recordingDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.voiceRecordingDuration = duration
            }
            .store(in: &cancellables)

        voiceService.$playbackProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.voicePlaybackProgress = progress
            }
            .store(in: &cancellables)

        voiceService.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                if !isPlaying {
                    self?.playingVoiceMessageID = nil
                }
            }
            .store(in: &cancellables)
    }

    private func updateConnectionState() {
        guard let poolManager = poolManager else {
            isConnected = false
            return
        }

        switch poolManager.poolState {
        case .hosting, .connected:
            isConnected = true

            // Update session ID and load history
            if let session = poolManager.currentSession {
                let sessionID = session.id.uuidString
                if currentSessionID != sessionID {
                    // New session - reset tracking and deduplication state
                    currentSessionID = sessionID
                    historyLoadedForSession = nil
                    historyRequestedForSession = nil

                    // Set the host-based conversation ID (simpler, more stable)
                    let hostBasedID = ChatConversation.hostBasedGroupConversationID(hostPeerID: session.hostPeerID)
                    hostBasedGroupConvID = hostBasedID
                    log("[STATE] Set hostBasedGroupConvID for session: \(sessionID)", category: .network)

                    // Clear deduplication sets for new session
                    seenGroupMessageIDs.removeAll()
                    // Keep private message IDs as they are peer-based, not session-based

                    // Update relay service with new pool ID and shared secret
                    relayService?.setCurrentPool(session.id)
                    let localPublicKey = encryptionService.publicKey
                    relayService?.poolSharedSecret = Self.derivePoolSharedSecret(
                        localPublicKey: localPublicKey, poolID: session.id
                    )

                    if #available(macOS 14.0, iOS 17.0, *) {
                        chatHistoryService.markSessionActive(sessionID)

                        // Register/update this group in the group list
                        Task {
                            await registerCurrentGroupChat()
                            await loadGroupChatList()
                        }
                    }

                    Task {
                        await loadChatHistory()
                        historyLoadedForSession = sessionID
                    }
                }
            }
        case .idle:
            // Pool disconnected - mark session inactive but preserve history
            if let sessionID = currentSessionID {
                if #available(macOS 14.0, iOS 17.0, *) {
                    chatHistoryService.markSessionInactive(sessionID)

                    // Mark groups as disconnected
                    Task {
                        await updateGroupConnectionStatus()
                    }
                }
            }
            isConnected = false
            // Reset session tracking for next connection
            historyLoadedForSession = nil
            historyRequestedForSession = nil
            hostBasedGroupConvID = nil
            // SECURITY FIX (V8): Full session teardown - regenerate keys and clear TOFU state
            // on disconnect. This ensures no stale cryptographic material persists across sessions.
            encryptionService.sessionTeardown()

            // CRITICAL FIX: Clean up relay service completely on disconnect.
            // This ensures no stale MC operations are triggered when pool is idle.
            // The relay service will be recreated when a new pool connection is established.
            relayService?.cleanup()
            relayService?.clearCurrentPool()
            relayService = nil
            log("[RELAY] MeshRelayService cleaned up on pool disconnect", category: .network)
        default:
            isConnected = false
        }
    }

    // MARK: - PoolChatAppLifecycle Protocol

    public func activate() {
        runtimeState = .active
        // Mark window as visible when activated - user is viewing Pool Chat
        isWindowVisible = true
        log("[NOTIFICATION] PoolChat activated, isWindowVisible set to true", category: .runtime)
        // Clear notifications since user is now viewing the chat
        clearChatNotifications()
    }

    public func moveToBackground() {
        runtimeState = .background
        // Mark window as not visible when in background - user is viewing another app
        // This ensures notifications fire when Pool Chat is not the active window
        isWindowVisible = false
        // Stop voice recording if in background
        if isRecordingVoice {
            cancelVoiceRecording()
        }
        log("[NOTIFICATION] PoolChat moved to background, isWindowVisible set to false", category: .runtime)
    }

    public func suspend() {
        runtimeState = .suspended
        // Mark window as not visible when suspended (minimized)
        isWindowVisible = false
        // Stop all media
        voiceService.stop()
        if isRecordingVoice {
            cancelVoiceRecording()
        }
        // End any active call on suspend
        callManager.endCall()
        log("[NOTIFICATION] PoolChat suspended (minimized), isWindowVisible set to false", category: .runtime)
    }

    public func terminate() {
        runtimeState = .terminated
        // Mark window as not visible so notifications work for remaining messages
        isWindowVisible = false
        voiceService.stop()
        voiceService.cancelRecording()
        // End any active call on terminate
        callManager.endCall()
        setupTasks.forEach { $0.cancel() }
        setupTasks.removeAll()
        cancellables.removeAll()

        // Clean up relay service to prevent stale MC operations
        relayService?.cleanup()
        relayService?.clearCurrentPool()
        relayService = nil

        // DO NOT disconnect poolManager here!
        // The ConnectionPoolManager.shared singleton must persist independently
        // of the Pool Chat window lifecycle. Disconnecting here would break
        // the pool connection when users close the chat window.
        // The pool should only disconnect when the user explicitly disconnects
        // from the Connection Pool app, not when closing Pool Chat.

        log("[NOTIFICATION] PoolChat terminated, isWindowVisible set to false (pool connection preserved)", category: .runtime)
    }

    // MARK: - Text Messages

    /// Send a text message
    public func sendTextMessage() {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let poolManager = poolManager else {
            showError(message: "Not connected to a pool")
            return
        }

        // Build reply preview if replying
        var replyPreview: ReplyPreview?
        if let replyMsg = replyingToMessage {
            replyPreview = ReplyPreview(
                messageID: replyMsg.id,
                senderName: replyMsg.senderName,
                previewText: replyMsg.previewText
            )
        }

        // Parse mentions from the message text
        let availablePeers = connectedPeers.map { (id: $0.id, displayName: $0.displayName) }
        let mentionedPeerIDs = MentionParser.findMentionedPeerIDs(text: text, availablePeers: availablePeers)

        // Create local message with profile info
        var message = RichChatMessage.textMessage(
            from: poolManager.localPeerID,
            senderName: poolManager.localProfile.displayName,
            text: text,
            isFromLocalUser: true,
            replyTo: replyPreview,
            mentions: mentionedPeerIDs
        )
        message.senderAvatarEmoji = poolManager.localProfile.avatarEmoji
        message.senderAvatarColorIndex = poolManager.localProfile.avatarColorIndex

        // Add to local messages based on chat mode
        addLocalMessage(message)

        // Send via pool
        sendChatPayload(RichChatPayload(from: message))

        // Save to history
        saveMessageAsync(message)

        // Clear input, reply state, and mention picker
        textInput = ""
        replyingToMessage = nil
        hideMentionPicker()
    }

    // MARK: - Mention Methods

    /// Check text input for mention trigger and update mention picker state
    public func handleTextInputChange(_ newText: String) {
        // Only show mention picker in group chat
        guard chatMode.isGroup else {
            hideMentionPicker()
            return
        }

        // Check for active mention query
        if let query = MentionParser.getActiveMentionQuery(from: newText) {
            mentionQuery = query
            updateFilteredMentionPeers()
            showMentionPicker = true
        } else {
            hideMentionPicker()
        }
    }

    /// Update the filtered list of peers based on the mention query
    private func updateFilteredMentionPeers() {
        let query = mentionQuery.lowercased()

        // Filter connected peers (excluding self)
        let matchingPeers = connectedPeers.filter { peer in
            guard peer.id != localPeerID else { return false }
            if query.isEmpty { return true }
            return peer.effectiveDisplayName.lowercased().contains(query)
        }

        // Convert to MentionInfo
        filteredMentionPeers = matchingPeers.map { peer in
            MentionInfo(
                peerID: peer.id,
                displayName: peer.effectiveDisplayName,
                avatarColorIndex: peer.avatarColorIndex
            )
        }
    }

    /// Select a peer from the mention picker
    public func selectMention(_ peer: MentionInfo) {
        // Replace the @query with @displayName
        textInput = MentionParser.replaceMentionQuery(in: textInput, with: peer.displayName)
        hideMentionPicker()
    }

    /// Hide the mention picker
    public func hideMentionPicker() {
        showMentionPicker = false
        mentionQuery = ""
        filteredMentionPeers = []
    }

    // MARK: - Reply Methods

    /// Start replying to a message
    public func startReply(to message: RichChatMessage) {
        replyingToMessage = message
    }

    /// Cancel the current reply
    public func cancelReply() {
        replyingToMessage = nil
    }

    // MARK: - Reaction Methods

    /// Show reaction picker for a message
    public func showReactionPicker(for messageID: UUID) {
        showReactionPickerForMessageID = messageID
    }

    /// Hide reaction picker
    public func hideReactionPicker() {
        showReactionPickerForMessageID = nil
    }

    /// Add or remove a reaction to a message
    public func toggleReaction(_ emoji: String, on messageID: UUID) {
        guard let poolManager = poolManager else { return }

        let peerID = poolManager.localPeerID

        // Find and update the message
        if let index = findMessageIndex(id: messageID) {
            let message = getMessage(at: index)
            let isAdding = !message.hasReacted(peerID: peerID, emoji: emoji)
            let updatedMessage = message.withReaction(emoji, from: peerID)

            // Update local state
            updateMessage(updatedMessage, at: index)

            // Send reaction update to peers
            sendReactionUpdate(
                messageID: messageID,
                emoji: emoji,
                peerID: peerID,
                isAdding: isAdding
            )
        }

        hideReactionPicker()
    }

    /// Send reaction update payload to peers with E2E encryption
    private func sendReactionUpdate(messageID: UUID, emoji: String, peerID: String, isAdding: Bool) {
        guard let poolManager = poolManager else { return }

        let payload = ReactionUpdatePayload(
            messageID: messageID,
            emoji: emoji,
            peerID: peerID,
            isAdding: isAdding
        )

        guard let payloadData = try? JSONEncoder().encode(payload) else { return }

        // For private chat, encrypt and send only to that peer; for group, encrypt for all
        if let targetPeerID = chatMode.privatePeerID {
            sendEncryptedPayload(
                payloadData,
                messageType: .reaction,
                isPrivateChat: true,
                targetPeerIDs: [targetPeerID]
            )
        } else {
            let peerIDs = poolManager.connectedPeers.map { $0.id }
            sendEncryptedPayload(
                payloadData,
                messageType: .reaction,
                isPrivateChat: false,
                targetPeerIDs: peerIDs
            )
        }
    }

    /// Maximum total reactor entries per message across all emojis to prevent memory exhaustion
    private static let maxReactorsPerMessage = 100

    /// Handle incoming reaction update
    /// SECURITY: Uses the transport-authenticated sender identity instead of the self-reported
    /// `payload.peerID` to prevent reaction spoofing. Also enforces a cap on total reactors
    /// per message to prevent memory exhaustion attacks.
    private func handleReactionUpdate(_ payload: ReactionUpdatePayload, authenticatedSenderID: String) {
        guard let index = findMessageIndex(id: payload.messageID) else { return }

        var message = getMessage(at: index)
        var reactions = message.reactions

        // Use authenticated sender identity, not the self-reported peerID from the payload
        let senderID = authenticatedSenderID

        if payload.isAdding {
            // Enforce cap on total reactor entries per message to prevent memory exhaustion
            let totalReactors = reactions.values.reduce(0) { $0 + $1.count }
            guard totalReactors < Self.maxReactorsPerMessage else { return }

            if reactions[payload.emoji] != nil {
                if !reactions[payload.emoji]!.contains(senderID) {
                    reactions[payload.emoji]?.append(senderID)
                }
            } else {
                reactions[payload.emoji] = [senderID]
            }
        } else {
            reactions[payload.emoji]?.removeAll { $0 == senderID }
            if reactions[payload.emoji]?.isEmpty == true {
                reactions.removeValue(forKey: payload.emoji)
            }
        }

        message.reactions = reactions
        updateMessage(message, at: index)
    }

    // MARK: - Poll Methods

    /// Show poll creation UI (only in group chat)
    public func showPollCreationSheet() {
        guard chatMode.isGroup else { return }
        pollQuestion = ""
        pollOptions = ["", ""]
        pollAllowVoteChange = true
        showPollCreation = true
    }

    /// Add a poll option (max 6)
    public func addPollOption() {
        guard pollOptions.count < 6 else { return }
        pollOptions.append("")
    }

    /// Remove a poll option (min 2)
    public func removePollOption(at index: Int) {
        guard pollOptions.count > 2, pollOptions.indices.contains(index) else { return }
        pollOptions.remove(at: index)
    }

    /// Create and send a poll
    public func createPoll() {
        let question = pollQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = pollOptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !question.isEmpty, options.count >= 2 else {
            showError(message: "Poll needs a question and at least 2 options")
            return
        }

        guard let poolManager = poolManager else {
            showError(message: "Not connected to a pool")
            return
        }

        var message = RichChatMessage.pollMessage(
            from: poolManager.localPeerID,
            senderName: poolManager.localProfile.displayName,
            question: question,
            options: options,
            isFromLocalUser: true,
            allowVoteChange: pollAllowVoteChange
        )
        message.senderAvatarEmoji = poolManager.localProfile.avatarEmoji
        message.senderAvatarColorIndex = poolManager.localProfile.avatarColorIndex

        addLocalMessage(message)
        sendChatPayload(RichChatPayload(from: message))
        saveMessageAsync(message)

        // Reset poll creation state
        showPollCreation = false
        pollQuestion = ""
        pollOptions = ["", ""]
        pollAllowVoteChange = true
    }

    /// Cancel poll creation
    public func cancelPollCreation() {
        showPollCreation = false
        pollQuestion = ""
        pollOptions = ["", ""]
        pollAllowVoteChange = true
    }

    /// Vote on a poll
    public func votePoll(messageID: UUID, option: String) {
        guard let poolManager = poolManager else { return }

        let voterID = poolManager.localPeerID

        guard let index = findMessageIndex(id: messageID) else { return }

        let message = getMessage(at: index)
        guard message.contentType == .poll, let pollData = message.pollData else { return }

        // ISSUE 5: Check if voting is allowed
        guard let updatedMessage = message.withPollVote(from: voterID, for: option) else {
            // Vote not allowed (already voted and vote change disabled)
            if !pollData.allowVoteChange {
                showError(message: "You have already voted and cannot change your vote")
            }
            return
        }

        updateMessage(updatedMessage, at: index)

        // Send vote update to peers
        sendPollVoteUpdate(messageID: messageID, option: option, voterID: voterID)
    }

    /// Send poll vote update to peers with E2E encryption
    private func sendPollVoteUpdate(messageID: UUID, option: String, voterID: String) {
        guard let poolManager = poolManager else { return }

        let payload = PollVotePayload(
            messageID: messageID,
            option: option,
            voterID: voterID
        )

        guard let payloadData = try? JSONEncoder().encode(payload) else { return }

        // Polls are group-only, so encrypt for all connected peers
        let peerIDs = poolManager.connectedPeers.map { $0.id }
        sendEncryptedPayload(
            payloadData,
            messageType: .pollVote,
            isPrivateChat: false,
            targetPeerIDs: peerIDs
        )
    }

    /// Handle incoming poll vote update
    /// SECURITY: Uses the transport-authenticated sender identity instead of the self-reported
    /// `payload.voterID` to prevent ballot stuffing via forged payloads.
    private func handlePollVoteUpdate(_ payload: PollVotePayload, authenticatedSenderID: String) {
        guard let index = findMessageIndex(id: payload.messageID) else { return }

        let message = getMessage(at: index)
        guard message.contentType == .poll else { return }

        // Use authenticated sender identity, not the self-reported voterID from the payload
        guard let updatedMessage = message.withPollVote(from: authenticatedSenderID, for: payload.option) else {
            return
        }
        updateMessage(updatedMessage, at: index)
    }

    /// Handle incoming chat history sync from host
    private func handleChatHistorySync(_ payload: ChatHistorySyncPayload) {
        // Only process group chat history for now
        guard payload.isGroupChat else { return }

        // Convert payloads to messages, filtering out duplicates using O(1) set lookup
        var newMessages: [RichChatMessage] = []

        for chatPayload in payload.messages {
            // Use the deduplication set for O(1) lookup
            guard !seenGroupMessageIDs.contains(chatPayload.messageID) else {
                continue
            }

            // Mark this message ID as seen
            seenGroupMessageIDs.insert(chatPayload.messageID)

            // Mark as from local user if the sender matches our peer ID
            let isFromLocalUser = chatPayload.senderID == poolManager?.localPeerID
            let message = chatPayload.toMessage(isFromLocalUser: isFromLocalUser)
            newMessages.append(message)
        }

        guard !newMessages.isEmpty else { return }

        // Merge with existing messages, sorted by timestamp
        var allMessages = groupMessages + newMessages
        allMessages.sort { $0.timestamp < $1.timestamp }
        groupMessages = allMessages

        // Update display if viewing group chat
        if chatMode.isGroup {
            messages = groupMessages
        }

        // Persist the received messages so they survive window close/reopen
        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                for message in newMessages {
                    let participantIDs = connectedPeers.map { $0.id }
                    await saveMessageToHistory(message, isGroupChat: true, participantIDs: participantIDs)
                }
            }
        }
    }

    /// Handle incoming history request from a peer (host only)
    private func handleChatHistoryRequest(from peerID: String) {
        guard let poolManager = poolManager else { return }
        guard poolManager.isHost else { return }

        // SECURITY: Check if history sync is enabled before sending any history
        guard PoolChatConfiguration.enableHistorySync else {
            log("[SECURITY] History sync request from \(peerID.prefix(8))... ignored - enableHistorySync is disabled", category: .security)
            return
        }

        // Find the peer who requested
        guard let peer = poolManager.connectedPeers.first(where: { $0.id == peerID }) else {
            // Try to send anyway by creating a temporary peer reference
            let tempPeer = Peer(id: peerID, displayName: peerID, isHost: false, status: .connected)
            sendChatHistoryToPeer(tempPeer)
            return
        }

        // Send chat history to the requesting peer
        sendChatHistoryToPeer(peer)
    }

    // MARK: - Message Lookup Helpers

    /// Find index of a message by ID in current messages array
    private func findMessageIndex(id: UUID) -> Int? {
        messages.firstIndex { $0.id == id }
    }

    /// Get message at index from current messages
    private func getMessage(at index: Int) -> RichChatMessage {
        messages[index]
    }

    /// Update message at index in all relevant storage
    private func updateMessage(_ message: RichChatMessage, at index: Int) {
        messages[index] = message

        // Also update in the backing storage
        switch chatMode {
        case .group:
            if let groupIndex = groupMessages.firstIndex(where: { $0.id == message.id }) {
                groupMessages[groupIndex] = message
            }
        case .privateChat(let peerID):
            if var peerMessages = privateMessages[peerID],
               let peerIndex = peerMessages.firstIndex(where: { $0.id == message.id }) {
                peerMessages[peerIndex] = message
                privateMessages[peerID] = peerMessages
            }
        }
    }

    /// Add a message to local storage based on current chat mode
    /// Uses deduplication to prevent duplicate messages
    /// - Returns: true if message was added, false if it was a duplicate
    @discardableResult
    private func addLocalMessage(_ message: RichChatMessage) -> Bool {
        switch chatMode {
        case .group:
            return addGroupMessage(message)
        case .privateChat(let peerID):
            return addPrivateMessage(message, peerID: peerID)
        }
    }

    /// Add a message to group chat with deduplication
    /// - Returns: true if message was added, false if it was a duplicate
    @discardableResult
    private func addGroupMessage(_ message: RichChatMessage) -> Bool {
        // Check for duplicate using O(1) set lookup
        guard !seenGroupMessageIDs.contains(message.id) else {
            return false
        }

        // Track this message ID
        seenGroupMessageIDs.insert(message.id)

        // Add to storage
        groupMessages.append(message)

        // Update display if in group mode
        if chatMode.isGroup {
            messages = groupMessages
        }

        return true
    }

    /// Add a message to private chat with deduplication
    /// - Returns: true if message was added, false if it was a duplicate
    @discardableResult
    private func addPrivateMessage(_ message: RichChatMessage, peerID: String) -> Bool {
        // Initialize seen IDs set for this peer if needed
        if seenPrivateMessageIDs[peerID] == nil {
            seenPrivateMessageIDs[peerID] = []
        }

        // Check for duplicate using O(1) set lookup
        guard !seenPrivateMessageIDs[peerID]!.contains(message.id) else {
            return false
        }

        // Track this message ID
        seenPrivateMessageIDs[peerID]!.insert(message.id)

        // Add to storage
        var peerMessages = privateMessages[peerID] ?? []
        peerMessages.append(message)
        privateMessages[peerID] = peerMessages

        // Update display if viewing this private chat
        if case .privateChat(let currentPeerID) = chatMode, currentPeerID == peerID {
            messages = peerMessages
        }

        return true
    }

    /// Check if a group message ID has already been seen
    private func isGroupMessageDuplicate(_ messageID: UUID) -> Bool {
        seenGroupMessageIDs.contains(messageID)
    }

    /// Check if a private message ID has already been seen for a peer
    private func isPrivateMessageDuplicate(_ messageID: UUID, peerID: String) -> Bool {
        seenPrivateMessageIDs[peerID]?.contains(messageID) ?? false
    }

    /// Save message to history asynchronously
    private func saveMessageAsync(_ message: RichChatMessage) {
        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                let isGroupChat = chatMode.isGroup
                var participantIDs: [String]

                if isGroupChat {
                    participantIDs = connectedPeers.map { $0.id }
                } else if let peerID = chatMode.privatePeerID {
                    participantIDs = [localPeerID, peerID]
                } else {
                    return
                }

                await saveMessageToHistory(message, isGroupChat: isGroupChat, participantIDs: participantIDs)
            }
        }
    }

    // MARK: - Image Messages

    /// Handle image selection from picker
    public func handleImageSelection() {
        guard let item = selectedPhotoItem else { return }

        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    // Compress image if needed
                    let compressedData = compressImage(data)
                    sendImageMessage(compressedData)
                }
            } catch {
                log("Failed to load image: \(error.localizedDescription)", level: .error, category: .general)
                showError(message: "Failed to load image. Please try a different photo.")
            }

            // Reset selection
            selectedPhotoItem = nil
            showImagePicker = false
        }
    }

    /// Send an image message
    @MainActor
    private func sendImageMessage(_ imageData: Data) {
        guard let poolManager = poolManager else {
            showError(message: "Not connected to a pool")
            return
        }

        var message = RichChatMessage.imageMessage(
            from: poolManager.localPeerID,
            senderName: poolManager.localProfile.displayName,
            imageData: imageData,
            isFromLocalUser: true
        )
        message.senderAvatarEmoji = poolManager.localProfile.avatarEmoji
        message.senderAvatarColorIndex = poolManager.localProfile.avatarColorIndex

        addLocalMessage(message)
        sendChatPayload(RichChatPayload(from: message))
        saveMessageAsync(message)
    }

    /// Compress image data for transmission.
    ///
    /// SECURITY: This method strips EXIF metadata (GPS, device info, timestamps, etc.)
    /// on all platforms before sending images over the mesh network.
    /// On iOS, UIImage naturally discards EXIF on decode. On macOS, we use
    /// ImageIO to re-encode without metadata properties.
    private func compressImage(_ data: Data) -> Data {
        #if canImport(UIKit)
        // UIImage(data:) discards EXIF metadata on decode, so re-encoding
        // via jpegData() produces a clean image without location/device info.
        guard let image = UIImage(data: data) else { return data }

        // Target max size: 500KB for reasonable transmission over P2P
        let maxSize = 500 * 1024
        var compression: CGFloat = 0.8

        if let compressed = image.jpegData(compressionQuality: compression),
           compressed.count <= maxSize {
            return compressed
        }

        // Reduce quality until under limit
        while compression > 0.1 {
            compression -= 0.1
            if let compressed = image.jpegData(compressionQuality: compression),
               compressed.count <= maxSize {
                return compressed
            }
        }

        // Resize if still too large
        let scale = sqrt(Double(maxSize) / Double(data.count))
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        return resized.jpegData(compressionQuality: 0.7) ?? data
        #else
        // macOS: Strip EXIF metadata and compress using ImageIO.
        // Raw PhotosPicker data may contain GPS coordinates, device model,
        // camera settings, timestamps, and user name in IPTC fields.
        return Self.stripMetadataAndCompress(data)
        #endif
    }

    /// Strips all EXIF/IPTC/XMP metadata from image data and compresses it.
    ///
    /// Uses ImageIO to decode the source image, then re-encode as JPEG
    /// without copying any metadata properties. This removes GPS coordinates,
    /// device identifiers, timestamps, and any other embedded metadata.
    private static func stripMetadataAndCompress(_ data: Data) -> Data {
        #if canImport(AppKit)
        // Attempt metadata-stripped re-encode via ImageIO
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            // Fallback: if we can't decode, return original (encrypted anyway)
            return data
        }

        let maxSize = 500 * 1024
        let mutableData = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return data
        }

        // Write image WITHOUT any metadata properties.
        // By omitting kCGImageDestinationMetadata and not copying source properties,
        // the output JPEG will have no EXIF, IPTC, GPS, or XMP data.
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8 as CGFloat
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return data
        }

        let result = mutableData as Data

        // If still over size limit, reduce quality
        if result.count > maxSize {
            let reducedData = NSMutableData()
            guard let reducedDest = CGImageDestinationCreateWithData(
                reducedData,
                "public.jpeg" as CFString,
                1,
                nil
            ) else {
                return result
            }

            let reducedOptions: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.5 as CGFloat
            ]
            CGImageDestinationAddImage(reducedDest, cgImage, reducedOptions as CFDictionary)

            if CGImageDestinationFinalize(reducedDest) {
                return reducedData as Data
            }
        }

        return result
        #else
        return data
        #endif
    }

    // MARK: - Voice Messages

    /// Start recording a voice message
    public func startVoiceRecording() {
        voiceService.startRecording()
    }

    /// Stop recording and send the voice message
    public func stopVoiceRecordingAndSend() {
        guard let (data, duration) = voiceService.stopRecording() else {
            showError(message: "Failed to record voice message")
            return
        }

        guard let poolManager = poolManager else {
            showError(message: "Not connected to a pool")
            return
        }

        var message = RichChatMessage.voiceMessage(
            from: poolManager.localPeerID,
            senderName: poolManager.localProfile.displayName,
            voiceData: data,
            duration: duration,
            isFromLocalUser: true
        )
        message.senderAvatarEmoji = poolManager.localProfile.avatarEmoji
        message.senderAvatarColorIndex = poolManager.localProfile.avatarColorIndex

        addLocalMessage(message)
        sendChatPayload(RichChatPayload(from: message))
        saveMessageAsync(message)
    }

    /// Cancel voice recording
    public func cancelVoiceRecording() {
        voiceService.cancelRecording()
    }

    /// Play a voice message
    public func playVoiceMessage(_ message: RichChatMessage) {
        guard let voiceData = message.voiceData else { return }

        // Stop any currently playing message
        if playingVoiceMessageID != nil {
            voiceService.stop()
        }

        playingVoiceMessageID = message.id
        voiceService.play(data: voiceData)
    }

    /// Stop playing voice message
    public func stopVoicePlayback() {
        voiceService.stop()
        playingVoiceMessageID = nil
    }

    // MARK: - Emoji Messages

    /// Send an emoji as a standalone message (large emoji)
    public func sendEmoji(_ emoji: String) {
        guard let poolManager = poolManager else {
            showError(message: "Not connected to a pool")
            return
        }

        var message = RichChatMessage.emojiMessage(
            from: poolManager.localPeerID,
            senderName: poolManager.localProfile.displayName,
            emoji: emoji,
            isFromLocalUser: true
        )
        message.senderAvatarEmoji = poolManager.localProfile.avatarEmoji
        message.senderAvatarColorIndex = poolManager.localProfile.avatarColorIndex

        addLocalMessage(message)
        sendChatPayload(RichChatPayload(from: message))
        saveMessageAsync(message)

        showEmojiPicker = false
    }

    /// Insert emoji into text input
    public func insertEmoji(_ emoji: String) {
        textInput += emoji
    }

    // MARK: - Message Sending

    private func sendChatPayload(_ payload: RichChatPayload) {
        guard let poolManager = poolManager else { return }

        // Create extended payload with chat mode info
        let extendedPayload = PrivateChatPayload(
            chatPayload: payload,
            isPrivate: !chatMode.isGroup,
            targetPeerID: chatMode.privatePeerID
        )

        // Encode the payload to JSON first
        guard let payloadData = try? JSONEncoder().encode(extendedPayload) else {
            log("Failed to encode chat payload", category: .network)
            return
        }

        let targetPeerID = chatMode.privatePeerID

        // For private chat: encrypt for specific peer
        if let targetPeerID = targetPeerID {
            sendEncryptedPayload(
                payloadData,
                messageType: .chatMessage,
                isPrivateChat: true,
                targetPeerIDs: [targetPeerID]
            )
        } else {
            // For group chat: encrypt for each peer separately
            // Exclude self — we already added our own message locally via addLocalMessage(),
            // and we never have an encryption key for ourselves (no self key exchange).
            // Including self causes every group message to queue a PendingEncryptedMessage
            // for our own ID. After 50 messages the queue fills and legitimate messages
            // for newly joined peers (whose keys are still being negotiated) get dropped.
            let localID = poolManager.localPeerID
            let peerIDs = poolManager.connectedPeers
                .map { $0.id }
                .filter { $0 != localID }
            if peerIDs.isEmpty {
                log("[E2E] No remote peers to send encrypted message to", category: .security)
                return
            }
            sendEncryptedPayload(
                payloadData,
                messageType: .chatMessage,
                isPrivateChat: false,
                targetPeerIDs: peerIDs
            )
        }
    }

    // MARK: - E2E Encryption Helpers

    /// Send encrypted payload to specified peers.
    /// For group chat, this encrypts separately for each peer.
    /// Uses mesh relay when direct connection is unavailable.
    ///
    /// SECURITY: Messages are NEVER sent unencrypted. If encryption keys have not been
    /// established for any target peer, those messages are queued and will be sent
    /// automatically when key exchange completes.
    private func sendEncryptedPayload(
        _ plainData: Data,
        messageType: EncryptedMessageType,
        isPrivateChat: Bool,
        targetPeerIDs: [String]
    ) {
        guard let poolManager = poolManager else { return }

        // Safety net: strip self from target list. We never hold an encryption key for
        // our own peer ID, so including self would always queue an unreachable pending
        // message that can never be flushed, gradually filling the pending queue.
        let localID = poolManager.localPeerID
        let filteredTargetPeerIDs = targetPeerIDs.filter { $0 != localID }

        var directSentCount = 0
        var relayedCount = 0
        var peersWithoutKey: [String] = []
        var failedPeers: [String] = []

        for peerID in filteredTargetPeerIDs {
            // Check if we have a key established with this peer
            guard encryptionService.hasKeyFor(peerID: peerID) else {
                log("[E2E] No encryption key for peer: \(peerID.prefix(8))... - queuing message for delivery after key exchange", level: .warning, category: .security)
                peersWithoutKey.append(peerID)
                continue
            }

            // Encrypt the payload for this peer
            guard let encryptedData = encryptionService.encrypt(plainData, for: peerID) else {
                log("[E2E] Failed to encrypt payload for peer: \(peerID.prefix(8))...", level: .error, category: .security)
                failedPeers.append(peerID)
                continue
            }

            // Create encrypted payload wrapper
            let encryptedPayload = EncryptedChatPayload(
                encryptedData: encryptedData,
                senderPeerID: poolManager.localPeerID,
                isPrivateChat: isPrivateChat,
                targetPeerID: isPrivateChat ? peerID : nil,
                messageType: messageType
            )

            guard let wrappedData = try? JSONEncoder().encode(encryptedPayload) else {
                log("[E2E] Failed to encode encrypted payload wrapper", level: .error, category: .security)
                continue
            }

            // Check if we can reach the peer directly
            let isDirectlyConnected = poolManager.connectedPeers.contains(where: { $0.id == peerID })

            if isDirectlyConnected {
                // Direct send - peer is directly connected
                let message = PoolMessage(
                    type: .custom,
                    senderID: poolManager.localPeerID,
                    senderName: poolManager.localPeerName,
                    payload: wrappedData
                )
                poolManager.sendMessage(message, to: [peerID])
                directSentCount += 1
            } else if let relayService = relayService,
                      relayService.canReach(peerID),
                      let poolID = poolManager.currentSession?.id {
                // Send via relay - peer is reachable through mesh network
                Task {
                    let success = await relayService.sendToPeer(peerID, payload: wrappedData, poolID: poolID)
                    if !success {
                        log("[RELAY] Failed to relay message to \(peerID.prefix(8))...", level: .warning, category: .network)
                    }
                }
                relayedCount += 1
            } else {
                // Cannot reach peer - not directly connected and no relay path
                log("[E2E] Cannot reach peer \(peerID.prefix(8))... - not connected and no relay path", level: .warning, category: .network)
                failedPeers.append(peerID)
            }
        }

        // SECURITY: Queue messages for peers that don't have keys yet. Never send unencrypted.
        if !peersWithoutKey.isEmpty {
            if pendingEncryptionQueue.count < Self.maxPendingMessages {
                pendingEncryptionQueue.append(PendingEncryptedMessage(
                    plainData: plainData,
                    messageType: messageType,
                    isPrivateChat: isPrivateChat,
                    targetPeerIDs: peersWithoutKey
                ))
                pendingEncryptionCount = pendingEncryptionQueue.count
                log("[E2E] Queued message for \(peersWithoutKey.count) peer(s) pending key exchange (\(pendingEncryptionQueue.count) queued)",
                    category: .security)
            } else {
                log("[E2E] Pending encryption queue full (\(Self.maxPendingMessages)), dropping message for \(peersWithoutKey.count) peer(s)",
                    level: .warning, category: .security)
            }
        }

        if directSentCount > 0 || relayedCount > 0 {
            log("[E2E] Sent encrypted \(messageType.rawValue): \(directSentCount) direct, \(relayedCount) relayed", category: .security)
        }
        if !failedPeers.isEmpty {
            log("[E2E] Failed to send encrypted message to \(failedPeers.count) peer(s)", level: .warning, category: .security)
        }
    }

    /// Flush pending encryption queue for a specific peer after key exchange completes.
    /// Called when a new encryption key is established with a peer.
    private func flushPendingEncryptionQueue(for peerID: String) {
        let pendingForPeer = pendingEncryptionQueue.filter { $0.targetPeerIDs.contains(peerID) }
        guard !pendingForPeer.isEmpty else { return }

        log("[E2E] Flushing \(pendingForPeer.count) queued message(s) for peer \(peerID.prefix(8))...", category: .security)

        // Remove from queue before sending to avoid re-entrancy issues
        pendingEncryptionQueue.removeAll { msg in
            msg.targetPeerIDs.contains(peerID)
        }
        pendingEncryptionCount = pendingEncryptionQueue.count

        for pending in pendingForPeer {
            // Only send to the peer whose key just became available (others may still be pending)
            sendEncryptedPayload(
                pending.plainData,
                messageType: pending.messageType,
                isPrivateChat: pending.isPrivateChat,
                targetPeerIDs: [peerID]
            )
        }
    }

    // MARK: - Message Receiving

    private func handlePoolMessage(_ poolMessage: PoolMessage) {
        // Handle relay envelope messages first - these are routed through the mesh network
        if poolMessage.type == .relay {
            if let envelope = RelayEnvelope.decode(from: poolMessage.payload) {
                relayService?.handleRelayEnvelope(envelope, from: poolMessage.senderID)
            } else {
                log("[RELAY] Failed to decode relay envelope from \(poolMessage.senderID.prefix(8))...", level: .warning, category: .network)
            }
            return  // Relay messages are handled by relay service
        }

        // Handle key exchange messages for E2E encryption
        if poolMessage.type == .keyExchange,
           let payload = poolMessage.decodePayload(as: ConnectionPool.KeyExchangePayload.self) {
            // Skip key exchange messages from ourselves (relay echo)
            if let pm = poolManager, payload.senderPeerID == pm.localPeerID {
                return
            }
            handleKeyExchange(payload)
            return
        }

        // Only handle custom messages (rich chat)
        guard poolMessage.type == .custom else {
            // Handle legacy chat messages
            // SECURITY FIX (V3): Log warning for legacy unencrypted .chat messages
            // SECURITY FIX (V8): Reject by default to prevent encryption downgrade attacks
            if poolMessage.type == .chat,
               let payload = poolMessage.decodePayload(as: ChatPayload.self) {
                if PoolChatConfiguration.rejectUnencryptedMessages {
                    log("[SECURITY] Rejected unencrypted .chat message from: \(poolMessage.senderID.prefix(8))... (rejectUnencryptedMessages=true)", level: .warning, category: .security)
                } else {
                    log("[SECURITY] Accepted legacy unencrypted .chat message from: \(poolMessage.senderID.prefix(8))... - consider upgrading client", level: .warning, category: .security)
                    var message = RichChatMessage.textMessage(
                        from: poolMessage.senderID,
                        senderName: poolMessage.senderName,
                        text: payload.text,
                        isFromLocalUser: poolMessage.senderID == poolManager?.localPeerID
                    )
                    // Mark as unencrypted for UI visibility
                    message = markMessageAsUnencrypted(message)
                    handleReceivedMessage(message, isPrivate: false, senderID: poolMessage.senderID, wasEncrypted: false)
                }
            }
            return
        }

        // PRIORITY: Try to decode as encrypted payload first (E2E encryption)
        if let encryptedPayload = poolMessage.decodePayload(as: EncryptedChatPayload.self) {
            handleEncryptedPayload(encryptedPayload, from: poolMessage)
            return
        }

        // Try to decode as chat history request (sent by new member to host) - NOT encrypted
        // History requests are not encrypted because encryption keys may not be established yet
        if poolMessage.decodePayload(as: ChatHistoryRequestPayload.self) != nil {
            handleChatHistoryRequest(from: poolMessage.senderID)
            return
        }

        // Legacy unencrypted fallbacks (for backwards compatibility during migration)
        // These will be logged as warnings since production should use encryption
        handleUnencryptedLegacyPayload(poolMessage)
    }

    /// Handle encrypted chat payload - decrypt and route to appropriate handler
    private func handleEncryptedPayload(_ encryptedPayload: EncryptedChatPayload, from poolMessage: PoolMessage) {
        let senderPeerID = encryptedPayload.senderPeerID

        // Verify we have a key for this peer
        guard encryptionService.hasKeyFor(peerID: senderPeerID) else {
            log("[E2E] Cannot decrypt - no key for peer: \(senderPeerID.prefix(8))...", level: .warning, category: .security)
            return
        }

        // Decrypt the payload
        guard let decryptedData = encryptionService.decrypt(encryptedPayload.encryptedData, from: senderPeerID) else {
            log("[E2E] Decryption failed for message from: \(senderPeerID.prefix(8))...", level: .error, category: .security)
            return
        }

        log("[E2E] Successfully decrypted \(encryptedPayload.messageType.rawValue) from: \(senderPeerID.prefix(8))...", category: .security)

        // Route to appropriate handler based on message type
        switch encryptedPayload.messageType {
        case .chatMessage:
            handleDecryptedChatMessage(decryptedData, from: poolMessage)

        case .reaction:
            handleDecryptedReaction(decryptedData, from: senderPeerID)

        case .pollVote:
            handleDecryptedPollVote(decryptedData, from: senderPeerID)

        case .historySync:
            handleDecryptedHistorySync(decryptedData)

        case .clearHistory:
            handleDecryptedClearHistory(decryptedData, from: senderPeerID)

        case .callSignal:
            if let signal = try? JSONDecoder().decode(CallSignal.self, from: decryptedData) {
                callManager.handleCallSignal(signal, from: senderPeerID)
            }

        case .mediaFrame:
            callManager.handleMediaFrame(decryptedData, from: senderPeerID)
        }
    }

    /// Handle decrypted chat message
    private func handleDecryptedChatMessage(_ data: Data, from poolMessage: PoolMessage) {
        // Try to decode as extended private chat payload
        if let extendedPayload = try? JSONDecoder().decode(PrivateChatPayload.self, from: data) {
            let isFromLocalUser = extendedPayload.chatPayload.senderID == poolManager?.localPeerID
            if isFromLocalUser { return } // Already added when sent

            var message = extendedPayload.chatPayload.toMessage(isFromLocalUser: false)
            // Mark as truly encrypted since it was decrypted
            message = markMessageAsEncrypted(message)
            handleReceivedMessage(message, isPrivate: extendedPayload.isPrivate, senderID: poolMessage.senderID, wasEncrypted: true)
            return
        }

        // Fall back to legacy RichChatPayload
        if let payload = try? JSONDecoder().decode(RichChatPayload.self, from: data) {
            let isFromLocalUser = payload.senderID == poolManager?.localPeerID
            if isFromLocalUser { return }

            var message = payload.toMessage(isFromLocalUser: false)
            message = markMessageAsEncrypted(message)
            handleReceivedMessage(message, isPrivate: false, senderID: poolMessage.senderID, wasEncrypted: true)
            return
        }

        log("[E2E] Failed to decode decrypted chat message", level: .error, category: .security)
    }

    /// Handle decrypted reaction update
    /// - Parameters:
    ///   - data: The decrypted reaction payload data.
    ///   - authenticatedSenderID: The transport-authenticated sender identity (not self-reported).
    private func handleDecryptedReaction(_ data: Data, from authenticatedSenderID: String) {
        guard let reactionPayload = try? JSONDecoder().decode(ReactionUpdatePayload.self, from: data) else {
            log("[E2E] Failed to decode decrypted reaction", level: .error, category: .security)
            return
        }

        // Don't process our own reactions (use transport-authenticated identity)
        if authenticatedSenderID != poolManager?.localPeerID {
            handleReactionUpdate(reactionPayload, authenticatedSenderID: authenticatedSenderID)
        }
    }

    /// Handle decrypted poll vote
    /// - Parameters:
    ///   - data: The decrypted poll vote payload data.
    ///   - authenticatedSenderID: The transport-authenticated sender identity (not self-reported).
    private func handleDecryptedPollVote(_ data: Data, from authenticatedSenderID: String) {
        guard let pollVotePayload = try? JSONDecoder().decode(PollVotePayload.self, from: data) else {
            log("[E2E] Failed to decode decrypted poll vote", level: .error, category: .security)
            return
        }

        // Don't process our own votes (use transport-authenticated identity)
        if authenticatedSenderID != poolManager?.localPeerID {
            handlePollVoteUpdate(pollVotePayload, authenticatedSenderID: authenticatedSenderID)
        }
    }

    /// Handle decrypted history sync
    private func handleDecryptedHistorySync(_ data: Data) {
        guard let historySyncPayload = try? JSONDecoder().decode(ChatHistorySyncPayload.self, from: data) else {
            log("[E2E] Failed to decode decrypted history sync", level: .error, category: .security)
            return
        }

        log("[E2E] Decrypted history sync with \(historySyncPayload.messages.count) messages", category: .security)
        handleChatHistorySync(historySyncPayload)
    }

    /// Handle decrypted clear history command
    private func handleDecryptedClearHistory(_ data: Data, from senderID: String) {
        guard let payload = try? JSONDecoder().decode(ClearHistoryPayload.self, from: data) else {
            log("[E2E] Failed to decode decrypted ClearHistoryPayload", level: .error, category: .security)
            return
        }

        log("[E2E] Decrypted clear history command from: \(senderID.prefix(8))...", category: .security)
        handleClearHistoryCommand(payload, from: senderID)
    }

    // MARK: - Relay Message Handling

    /// Handles an envelope that was relayed to us through the mesh network (we are the destination)
    /// The envelope contains encrypted payload that needs to be decrypted using our key with the origin peer
    private func handleRelayedEnvelope(_ envelope: RelayEnvelope) {
        log("[RELAY] Received relayed envelope from origin: \(envelope.originPeerID.prefix(8))..., hops: \(envelope.hopPath.count)", category: .network)

        // The encrypted payload in the envelope should be an EncryptedChatPayload
        // We need to decrypt it using our shared key with the origin peer
        guard let encryptedPayload = try? JSONDecoder().decode(EncryptedChatPayload.self, from: envelope.encryptedPayload) else {
            log("[RELAY] Failed to decode EncryptedChatPayload from relayed envelope", level: .warning, category: .network)
            return
        }

        // Verify the sender matches the envelope origin
        guard encryptedPayload.senderPeerID == envelope.originPeerID else {
            log("[RELAY] Sender mismatch: envelope origin \(envelope.originPeerID.prefix(8))... vs payload sender \(encryptedPayload.senderPeerID.prefix(8))...", level: .warning, category: .security)
            return
        }

        // Decrypt the payload
        guard encryptionService.hasKeyFor(peerID: envelope.originPeerID) else {
            log("[RELAY] Cannot decrypt relayed message - no key for peer: \(envelope.originPeerID.prefix(8))...", level: .warning, category: .security)
            return
        }

        guard let decryptedData = encryptionService.decrypt(encryptedPayload.encryptedData, from: envelope.originPeerID) else {
            log("[RELAY] Failed to decrypt relayed message from \(envelope.originPeerID.prefix(8))...", level: .warning, category: .security)
            return
        }

        log("[RELAY] Successfully decrypted relayed \(encryptedPayload.messageType.rawValue) from: \(envelope.originPeerID.prefix(8))...", category: .security)

        // Route to appropriate handler based on message type
        handleDecryptedPayload(decryptedData, messageType: encryptedPayload.messageType, senderPeerID: envelope.originPeerID, isPrivateChat: encryptedPayload.isPrivateChat)
    }

    /// Routes decrypted payload to the appropriate handler based on message type
    private func handleDecryptedPayload(_ data: Data, messageType: EncryptedMessageType, senderPeerID: String, isPrivateChat: Bool) {
        switch messageType {
        case .chatMessage:
            // Try to decode as extended private chat payload
            if let extendedPayload = try? JSONDecoder().decode(PrivateChatPayload.self, from: data) {
                let isFromLocalUser = extendedPayload.chatPayload.senderID == poolManager?.localPeerID
                if isFromLocalUser { return } // Already added when sent

                var message = extendedPayload.chatPayload.toMessage(isFromLocalUser: false)
                message = markMessageAsEncrypted(message)
                handleReceivedMessage(message, isPrivate: extendedPayload.isPrivate, senderID: senderPeerID, wasEncrypted: true)
            } else if let payload = try? JSONDecoder().decode(RichChatPayload.self, from: data) {
                let isFromLocalUser = payload.senderID == poolManager?.localPeerID
                if isFromLocalUser { return }

                var message = payload.toMessage(isFromLocalUser: false)
                message = markMessageAsEncrypted(message)
                handleReceivedMessage(message, isPrivate: isPrivateChat, senderID: senderPeerID, wasEncrypted: true)
            } else {
                log("[RELAY] Failed to decode decrypted chat message", level: .error, category: .security)
            }

        case .reaction:
            handleDecryptedReaction(data, from: senderPeerID)

        case .pollVote:
            handleDecryptedPollVote(data, from: senderPeerID)

        case .historySync:
            handleDecryptedHistorySync(data)

        case .clearHistory:
            handleDecryptedClearHistory(data, from: senderPeerID)

        case .callSignal:
            if let signal = try? JSONDecoder().decode(CallSignal.self, from: data) {
                callManager.handleCallSignal(signal, from: senderPeerID)
            } else {
                log("[CALL] Failed to decode call signal from \(senderPeerID.prefix(8))...", level: .warning, category: .network)
            }

        case .mediaFrame:
            callManager.handleMediaFrame(data, from: senderPeerID)
        }
    }

    /// Handle unencrypted legacy payloads (backwards compatibility)
    /// SECURITY FIX (V2): Reject ALL sensitive payload types when received unencrypted
    /// to prevent encryption downgrade attacks.
    /// SECURITY FIX (V8): When rejectUnencryptedMessages is true, reject everything.
    private func handleUnencryptedLegacyPayload(_ poolMessage: PoolMessage) {
        // SECURITY FIX (V8): If configured to reject unencrypted messages, drop all legacy payloads
        if PoolChatConfiguration.rejectUnencryptedMessages {
            log("[SECURITY] Rejected unencrypted custom message from: \(poolMessage.senderID.prefix(8))... (rejectUnencryptedMessages=true)", level: .warning, category: .security)
            return
        }

        // Log warning that unencrypted message was received
        log("[E2E] WARNING: Received unencrypted custom message - legacy fallback", level: .warning, category: .security)

        // SECURITY (V2): Reject unencrypted ReactionUpdatePayload - must be encrypted
        if poolMessage.decodePayload(as: ReactionUpdatePayload.self) != nil {
            log("[SECURITY] Rejected unencrypted ReactionUpdatePayload - reactions must be encrypted", level: .warning, category: .security)
            return
        }

        // SECURITY (V2): Reject unencrypted PollVotePayload - must be encrypted
        if poolMessage.decodePayload(as: PollVotePayload.self) != nil {
            log("[SECURITY] Rejected unencrypted PollVotePayload - poll votes must be encrypted", level: .warning, category: .security)
            return
        }

        // SECURITY (V2): Reject unencrypted ChatHistorySyncPayload - must be encrypted
        if poolMessage.decodePayload(as: ChatHistorySyncPayload.self) != nil {
            log("[SECURITY] Rejected unencrypted ChatHistorySyncPayload - history sync must be encrypted", level: .warning, category: .security)
            return
        }

        // SECURITY: ClearHistoryPayload MUST be encrypted - reject unencrypted attempts
        if poolMessage.decodePayload(as: ClearHistoryPayload.self) != nil {
            log("[SECURITY] Rejected unencrypted ClearHistoryPayload - clear history commands must be encrypted", level: .warning, category: .security)
            return
        }

        // SECURITY (V2): Reject unencrypted PrivateChatPayload - must be encrypted
        if poolMessage.decodePayload(as: PrivateChatPayload.self) != nil {
            log("[SECURITY] Rejected unencrypted PrivateChatPayload - private chats must be encrypted", level: .warning, category: .security)
            return
        }

        // SECURITY (V2): Reject unencrypted RichChatPayload - must be encrypted
        if poolMessage.decodePayload(as: RichChatPayload.self) != nil {
            log("[SECURITY] Rejected unencrypted RichChatPayload - rich chat messages must be encrypted", level: .warning, category: .security)
            return
        }

        // Only ChatHistoryRequestPayload is allowed unencrypted (keys may not be established yet)
        // This is already handled before this method is called (see handlePoolMessage)

        log("Failed to decode any known payload type", level: .warning, category: .network)
    }

    /// Mark a message as encrypted (was successfully decrypted)
    private func markMessageAsEncrypted(_ message: RichChatMessage) -> RichChatMessage {
        var copy = message
        copy.isEncrypted = true
        return copy
    }

    /// Mark a message as unencrypted (received in plaintext)
    private func markMessageAsUnencrypted(_ message: RichChatMessage) -> RichChatMessage {
        var copy = message
        copy.isEncrypted = false
        return copy
    }

    /// Handle a received message and route it appropriately
    /// - Parameters:
    ///   - message: The chat message to handle
    ///   - isPrivate: Whether this is a private (1:1) chat message
    ///   - senderID: The peer ID of the sender
    ///   - wasEncrypted: Whether the message was received encrypted (E2E)
    private func handleReceivedMessage(_ message: RichChatMessage, isPrivate: Bool, senderID: String, wasEncrypted: Bool = false) {
        // Log encryption status
        if wasEncrypted {
            log("[E2E] Processing decrypted message from: \(senderID.prefix(8))...", category: .security)
        } else {
            log("[E2E] WARNING: Processing unencrypted message from: \(senderID.prefix(8))...", level: .warning, category: .security)
        }

        // Check for duplicate using O(1) set lookup
        let isDuplicate: Bool
        if isPrivate {
            isDuplicate = isPrivateMessageDuplicate(message.id, peerID: senderID)
        } else {
            isDuplicate = isGroupMessageDuplicate(message.id)
        }

        guard !isDuplicate else { return }

        // Determine if we should show notification
        // Notification criteria:
        // 1. Window is not visible (closed, minimized, or in background), OR
        // 2. Runtime state is background/suspended/terminated
        // AND:
        // 3. For private messages: not currently viewing that private chat
        // 4. For group messages: user was mentioned OR window is closed
        var shouldNotify = false
        var notificationType: ChatNotificationType = .privateMessage

        // Check if Pool Chat window is closed (not visible)
        // isWindowVisible is false when: window closed, minimized, or user viewing another app
        let windowClosed = !isWindowVisible
        let inBackground = runtimeState == .background || runtimeState == .suspended || runtimeState == .terminated

        if isPrivate {
            // Add to private messages with deduplication
            let wasAdded = addPrivateMessage(message, peerID: senderID)
            guard wasAdded else { return }

            // Update unread count if not viewing this private chat
            if case .privateChat(let currentPeerID) = chatMode, currentPeerID == senderID {
                // Already updated by addPrivateMessage
            } else {
                // Increment unread
                if let index = privateChatInfos.firstIndex(where: { $0.peerID == senderID }) {
                    privateChatInfos[index].unreadCount += 1
                    privateChatInfos[index].lastMessage = getMessagePreview(message)
                    privateChatInfos[index].lastMessageTime = message.timestamp
                    totalPrivateUnreadCount += 1
                } else {
                    // New private chat, add to list
                    let info = PrivateChatInfo(
                        peerID: senderID,
                        peerName: message.senderName,
                        avatarColorIndex: message.avatarColorIndex,
                        lastMessage: getMessagePreview(message),
                        lastMessageTime: message.timestamp,
                        unreadCount: 1,
                        isOnline: connectedPeers.contains(where: { $0.id == senderID })
                    )
                    privateChatInfos.insert(info, at: 0)
                    totalPrivateUnreadCount += 1
                }
                // Notify for private message when not viewing it AND window is closed or in background
                if windowClosed || inBackground {
                    shouldNotify = true
                    notificationType = .privateMessage
                }
            }
        } else {
            // Add to group messages with deduplication
            let wasAdded = addGroupMessage(message)
            guard wasAdded else { return }

            // Increment group unread if not viewing group chat
            if !chatMode.isGroup {
                groupUnreadCount += 1
            }

            // Check if we're mentioned in the group message
            let isMentioned = message.isMentioning(peerID: localPeerID)

            // Notification logic for group messages:
            // - If mentioned: always notify when window closed or in background
            // - If not mentioned but window is closed: notify for new group messages
            if windowClosed || inBackground {
                if isMentioned {
                    shouldNotify = true
                    notificationType = .mention
                } else if windowClosed {
                    // Only show group message notifications when window is completely closed
                    // (not just in background but visible)
                    shouldNotify = true
                    notificationType = .groupMessage
                }
            }
        }

        // Suppress system notifications when in-game chat overlay is handling them
        if shouldNotify && ChatNotificationBridge.shared.isGameChatActive {
            shouldNotify = false
            log("[NOTIFICATION] Suppressed - game chat overlay is active", category: .poolChat)
        }

        // Send notification if needed
        if shouldNotify {
            log("[NOTIFICATION] Sending notification - type: \(notificationType), sender: \(message.senderName)", category: .poolChat)
            Task {
                await notificationService.sendChatNotification(
                    type: notificationType,
                    senderID: senderID,
                    senderName: message.senderName,
                    messagePreview: getMessagePreview(message),
                    messageID: message.id.uuidString
                )
            }
        } else {
            log("[NOTIFICATION] NOT sending notification - windowClosed: \(windowClosed), inBackground: \(inBackground), isPrivate: \(isPrivate)", category: .poolChat)
        }

        // Save to history
        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                let participantIDs: [String]
                if isPrivate {
                    participantIDs = [localPeerID, senderID]
                } else {
                    participantIDs = connectedPeers.map { $0.id }
                }
                await saveMessageToHistory(message, isGroupChat: !isPrivate, participantIDs: participantIDs)
            }
        }
    }

    /// Get a preview string for a message
    private func getMessagePreview(_ message: RichChatMessage) -> String {
        switch message.contentType {
        case .text:
            return message.text ?? ""
        case .image:
            return "Photo"
        case .voice:
            return "Voice message"
        case .emoji:
            return message.emoji ?? ""
        case .system:
            return message.text ?? ""
        case .poll:
            return "Poll: \(message.pollData?.question ?? "")"
        }
    }

    private func handlePeerEvent(_ event: PeerEvent) {
        switch event {
        case .connected(let peer):
            log("Peer connected: \(peer.effectiveDisplayName)", category: .network)

            let systemMessage = RichChatMessage.systemMessage(text: "\(peer.effectiveDisplayName) joined the chat")
            groupMessages.append(systemMessage)
            if chatMode.isGroup {
                messages = groupMessages
            }

            // Notify relay service of new peer connection for mesh topology
            relayService?.peerConnected(peer.id)

            // Perform key exchange for encryption
            // NOTE: History sync is now triggered AFTER key exchange completes:
            // - Non-host peers: Request history in handleKeyExchange() after keys are established
            // - Host: Responds to ChatHistoryRequestPayload in handleChatHistoryRequest()
            // This ensures encrypted history can be properly decrypted by the receiving peer.
            performKeyExchange(with: peer)

        case .disconnected(let peer):
            log("Peer disconnected: \(peer.effectiveDisplayName)", category: .network)

            let systemMessage = RichChatMessage.systemMessage(text: "\(peer.effectiveDisplayName) left the chat")
            groupMessages.append(systemMessage)
            if chatMode.isGroup {
                messages = groupMessages
            }

            // Notify call manager of peer disconnection
            callManager.handlePeerDisconnected(peer.id)

            // Notify relay service of peer disconnection
            relayService?.peerDisconnected(peer.id)

            // Remove encryption key
            encryptionService.removePeerKey(peerID: peer.id)

        case .invitationReceived:
            break // Handled by ConnectionPool app

        case .invitationRejectedBlocked, .deviceAutoBlocked:
            break // Handled by ConnectionPool app
        }
    }

    /// Send existing chat history to a newly joined peer with E2E encryption
    /// Uses persisted history for reliability across window reopens
    /// NOTE: History sync requires encryption keys to be established first.
    /// The key exchange happens in performKeyExchange() when peer connects.
    /// We add a small delay to allow key exchange to complete before sending history.
    private func sendChatHistoryToPeer(_ peer: Peer) {
        guard poolManager != nil else { return }

        // If no session ID yet but we have messages, still try to sync from memory
        let sessionID = currentSessionID
        let peerID = peer.id

        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                // DTLS GUARD: Wait for DTLS transport to stabilize before any sends
                // DTLS requires ~2500ms to stabilize, so we wait 3000ms to be safe
                try? await Task.sleep(for: .milliseconds(3000))

                // Re-check peer is still connected after DTLS delay
                guard let pm = self.poolManager,
                      pm.poolState == .hosting || pm.poolState == .connected,
                      pm.connectedPeers.contains(where: { $0.id == peerID }) else {
                    return
                }

                // Wait for key exchange to complete using exponential backoff
                // Key exchange is initiated in performKeyExchange() when peer connects
                let maxRetries = 5
                var keyExchangeSucceeded = false

                for retryCount in 0..<maxRetries {
                    if self.encryptionService.hasKeyFor(peerID: peerID) {
                        keyExchangeSucceeded = true
                        break
                    }
                    // Exponential backoff: 200, 400, 800, 1600, 3200ms
                    let delayMs = 200 * (1 << retryCount)
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }

                // Final check after all retries
                if !keyExchangeSucceeded && self.encryptionService.hasKeyFor(peerID: peerID) {
                    keyExchangeSucceeded = true
                }

                guard keyExchangeSucceeded else {
                    log("Key exchange failed for peer: \(peer.displayName). Aborting history sync.", level: .error, category: .security)
                    return
                }

                var allPayloads: [RichChatPayload] = []

                // Get history from persistence service using host-based ID
                if let hostPeerID = pm.currentSession?.hostPeerID {
                    // Try host-based ID first (new approach)
                    let persistedPayloads = await chatHistoryService.getHostBasedGroupMessagesForSync(hostPeerID: hostPeerID)
                    allPayloads = persistedPayloads

                    // Also include any in-memory messages not yet persisted
                    let persistedIDs = Set(persistedPayloads.map { $0.messageID })
                    let unpersisted = groupMessages
                        .filter { $0.contentType != .system && !persistedIDs.contains($0.id) }
                        .map { RichChatPayload(from: $0) }

                    if !unpersisted.isEmpty {
                        allPayloads.append(contentsOf: unpersisted)
                    }
                } else if let sid = sessionID {
                    // Fallback to session-based ID for backwards compatibility
                    let persistedPayloads = await chatHistoryService.getSessionMessagesForSync(sessionID: sid)
                    allPayloads = persistedPayloads

                    // Also include any in-memory messages not yet persisted
                    let persistedIDs = Set(persistedPayloads.map { $0.messageID })
                    let unpersisted = groupMessages
                        .filter { $0.contentType != .system && !persistedIDs.contains($0.id) }
                        .map { RichChatPayload(from: $0) }

                    if !unpersisted.isEmpty {
                        allPayloads.append(contentsOf: unpersisted)
                    }
                } else {
                    // No session ID - use in-memory messages only
                    allPayloads = groupMessages
                        .filter { $0.contentType != .system }
                        .map { RichChatPayload(from: $0) }
                }

                // Don't send if no messages to sync
                guard !allPayloads.isEmpty else { return }

                // Sort by timestamp and limit to last 100 messages
                allPayloads.sort { $0.timestamp < $1.timestamp }
                let recentPayloads = Array(allPayloads.suffix(100))

                let syncPayload = ChatHistorySyncPayload(messages: recentPayloads, isGroupChat: true)

                guard let payloadData = try? JSONEncoder().encode(syncPayload) else {
                    log("Failed to encode chat history sync payload", level: .error, category: .network)
                    return
                }

                // Send encrypted history to the specific peer
                self.sendEncryptedPayload(
                    payloadData,
                    messageType: .historySync,
                    isPrivateChat: false,
                    targetPeerIDs: [peerID]
                )
            }
        } else {
            // Fallback for older OS: use in-memory messages
            // Check for encryption key
            guard encryptionService.hasKeyFor(peerID: peerID) else {
                log("Cannot send encrypted history - no key for peer: \(peer.displayName)", level: .warning, category: .security)
                return
            }

            let messagesToSync = groupMessages.filter { $0.contentType != .system }

            guard !messagesToSync.isEmpty else { return }

            let recentMessages = Array(messagesToSync.suffix(50))
            let payloads = recentMessages.map { RichChatPayload(from: $0) }

            let syncPayload = ChatHistorySyncPayload(messages: payloads, isGroupChat: true)

            guard let payloadData = try? JSONEncoder().encode(syncPayload) else {
                log("Failed to encode chat history sync payload", level: .error, category: .network)
                return
            }

            // Send encrypted history to the specific peer
            sendEncryptedPayload(
                payloadData,
                messageType: .historySync,
                isPrivateChat: false,
                targetPeerIDs: [peerID]
            )
        }
    }

    // MARK: - Encryption

    /// Perform key exchange with a newly connected peer
    /// STABILITY FIX: Added 500ms delay to allow MultipeerConnectivity DTLS transport to stabilize.
    /// Without this delay, key exchange messages sent immediately after peer connect event
    /// can cause "Not in connected state" errors as the MC framework reports .connected before
    /// the underlying DTLS transport is fully ready.
    private func performKeyExchange(with peer: Peer) {
        guard let poolManager = poolManager else { return }

        // Guard against sending when not in a connected state
        // This prevents "Not in connected state" errors from MultipeerConnectivity
        guard poolManager.poolState == .hosting || poolManager.poolState == .connected else { return }

        // Capture peer ID for async context
        let targetPeerID = peer.id
        let targetPeerName = peer.displayName

        // Delay key exchange to allow DTLS transport to stabilize (must be > 2500ms DTLS stabilization period)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(3000))

            // Re-check state after delay
            guard let pm = self.poolManager,
                  pm.poolState == .hosting || pm.poolState == .connected,
                  pm.connectedPeers.contains(where: { $0.id == targetPeerID }) else {
                return
            }

            // Send our public key to the peer
            let keyExchangeMessage = PoolMessage.keyExchange(
                from: pm.localPeerID,
                senderName: pm.localPeerName,
                publicKey: self.encryptionService.publicKey
            )

            // Send directly to the specific peer
            pm.sendMessage(keyExchangeMessage, to: [targetPeerID])
            log("Encryption key exchange sent to: \(targetPeerName)", category: .security)
        }
    }

    /// Handle incoming key exchange message
    /// SECURITY FIX (V5): Added retry logic on failure to ensure encryption is established
    /// SECURITY FIX (V6): Added reciprocal key exchange to ensure both peers have keys
    /// SECURITY FIX (V7): Non-host peers request history after key exchange completes
    private func handleKeyExchange(_ payload: ConnectionPool.KeyExchangePayload) {
        guard let poolManager = poolManager else { return }

        // Check if we already had a key for this peer BEFORE this exchange
        let hadKeyBefore = encryptionService.hasKeyFor(peerID: payload.senderPeerID)

        let success = encryptionService.performKeyExchange(
            peerPublicKeyData: payload.publicKey,
            peerID: payload.senderPeerID
        )

        if success {
            log("Encryption established with peer: \(payload.senderPeerID.prefix(8))...", category: .security)

            // Flush any queued messages that were waiting for this peer's encryption key
            flushPendingEncryptionQueue(for: payload.senderPeerID)

            // RECIPROCAL KEY EXCHANGE: If we didn't have a key for this peer before,
            // send our public key back to them. This ensures both peers have keys
            // even if one side's initial key exchange was missed.
            // STABILITY FIX: Added 1000ms delay to avoid flooding MC session with messages
            // during the connection stabilization window.
            if !hadKeyBefore {
                let senderPeerID = payload.senderPeerID
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(3500))

                    // Re-check state after delay
                    guard let pm = self.poolManager,
                          pm.poolState == .hosting || pm.poolState == .connected,
                          pm.connectedPeers.contains(where: { $0.id == senderPeerID }) else {
                        return
                    }

                    let keyExchangeMessage = PoolMessage.keyExchange(
                        from: pm.localPeerID,
                        senderName: pm.localPeerName,
                        publicKey: self.encryptionService.publicKey
                    )
                    pm.sendMessage(keyExchangeMessage, to: [senderPeerID])
                }
            }

            // FIX (V7): After key exchange completes, non-host peers should request chat history
            // This ensures history is only requested AFTER encryption is fully established,
            // so the host can send encrypted history that we can actually decrypt.
            // We only request if:
            // 1. We are NOT the host (host sends history, doesn't request it)
            // 2. This is the first key exchange with this peer (hadKeyBefore == false)
            // 3. We haven't already requested history for this session
            // 4. We don't already have messages (prevents duplicate requests)
            // 5. The key exchange was with the host (or someone who can provide history)
            if !poolManager.isHost && !hadKeyBefore {
                if let sessionID = currentSessionID, historyRequestedForSession != sessionID {
                    // Check if we have any non-system messages already
                    let hasMessages = groupMessages.contains { $0.contentType != .system }
                    if !hasMessages {
                        // Find who we should request history from (host or first connected peer)
                        let hostPeer = poolManager.connectedPeers.first(where: { $0.isHost })
                            ?? poolManager.connectedPeers.first

                        // Only request history if this key exchange was with the host
                        // This prevents requesting from peers who joined after us and don't have history
                        if let host = hostPeer, host.id == payload.senderPeerID {
                            log("[E2E] Key exchange with HOST complete, requesting chat history", category: .security)
                            requestHistorySyncFromHost()
                            historyRequestedForSession = sessionID
                        } else if hostPeer == nil {
                            // No host peer found - this might be a transient state, request anyway
                            log("[E2E] Key exchange complete (no host identified), requesting chat history", category: .security)
                            requestHistorySyncFromHost()
                            historyRequestedForSession = sessionID
                        } else {
                            log("[E2E] Key exchange with non-host peer \(payload.senderPeerID.prefix(8))..., waiting for host key exchange", category: .security)
                        }
                    } else {
                        log("[E2E] Key exchange complete, but already have \(groupMessages.count) messages - skipping history request", category: .security)
                    }
                }
            }
        } else {
            log("[E2E] Key exchange failed with peer: \(payload.senderPeerID.prefix(8))..., will retry on next message", level: .warning, category: .security)
            // Retry key exchange after a delay
            Task {
                try? await Task.sleep(for: .milliseconds(1000))
                if let peer = poolManager.connectedPeers.first(where: { $0.id == payload.senderPeerID }) {
                    performKeyExchange(with: peer)
                }
            }
        }
    }

    // MARK: - Pool Shared Secret Derivation

    /// Derives a pool-level shared secret for relay envelope HMAC integrity.
    ///
    /// The secret is derived from the local peer's encryption public key and the pool ID.
    /// This is NOT the pool UUID alone (which is public), but includes cryptographic material
    /// from the E2E key exchange that observers cannot access on the wire.
    ///
    /// All pool members derive the same HMAC keys because RelayEnvelope.deriveHMACKey uses
    /// this as input keying material combined with the pool ID as salt.
    private static func derivePoolSharedSecret(localPublicKey: Data, poolID: UUID) -> SymmetricKey {
        let poolIDData = withUnsafeBytes(of: poolID.uuid) { Data($0) }
        var ikm = Data("StealthOS-PoolSharedSecret-v1".utf8)
        ikm.append(localPublicKey)
        ikm.append(poolIDData)
        return SymmetricKey(data: ikm)
    }

    // MARK: - Helpers

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }

    /// Clear all messages and reset deduplication tracking
    public func clearMessages() {
        messages = []
        groupMessages = []
        privateMessages = [:]
        // Clear deduplication sets
        seenGroupMessageIDs.removeAll()
        seenPrivateMessageIDs.removeAll()
    }

    /// Get local peer name
    public var localPeerName: String {
        poolManager?.localPeerName ?? "You"
    }

    /// Get local peer ID
    public var localPeerID: String {
        poolManager?.localPeerID ?? ""
    }

    // MARK: - Chat Mode Switching

    /// Called when group chat view appears
    public func onGroupChatAppear() {
        // ISSUE 3 FIX: Mark group chat as read when viewing
        markGroupChatAsRead()

        // ISSUE 1 FIX: Ensure messages are loaded from persistence when group chat appears
        // This handles the race condition where onGroupChatAppear fires before setPoolManager completes

        // First, always display any existing in-memory messages
        if !groupMessages.isEmpty {
            messages = groupMessages
        }

        // Load group list for disconnected state viewing
        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                await loadGroupChatList()
            }
        }

        // If we have a session ID, load from persistence
        // CRITICAL FIX: Also check if hostBasedGroupConvID is set. After disconnect,
        // currentSessionID remains set but hostBasedGroupConvID is cleared to nil.
        // We need hostBasedGroupConvID to load history correctly.
        if currentSessionID != nil && hostBasedGroupConvID != nil {
            if #available(macOS 14.0, iOS 17.0, *) {
                Task {
                    // Show loading indicator
                    self.isLoadingHistory = true
                    defer { self.isLoadingHistory = false }

                    // Load from persistence, merging with in-memory
                    await loadGroupChatHistory()

                    // If still no messages and not host, request from host
                    if groupMessages.isEmpty,
                       let poolManager = poolManager,
                       !poolManager.isHost,
                       poolManager.poolState == .connected {
                        requestHistorySyncFromHost()
                    }
                }
            } else {
                messages = groupMessages
            }
        } else if let poolManager = poolManager,
                  (poolManager.poolState == .hosting || poolManager.poolState == .connected),
                  let session = poolManager.currentSession {
            // Session ID not set yet but pool is connected - set it now and load history
            // This handles the race condition where view appears before setPoolManager completes
            let sessionID = session.id.uuidString
            currentSessionID = sessionID

            // Set the host-based conversation ID (simpler, more stable)
            let hostBasedID = ChatConversation.hostBasedGroupConversationID(hostPeerID: session.hostPeerID)
            hostBasedGroupConvID = hostBasedID
            log("[APPEAR] Set currentSessionID: \(sessionID), hostBasedGroupConvID set", category: .network)

            if #available(macOS 14.0, iOS 17.0, *) {
                chatHistoryService.markSessionActive(sessionID)
                Task {
                    // Show loading indicator
                    self.isLoadingHistory = true
                    defer { self.isLoadingHistory = false }

                    await registerCurrentGroupChat()
                    await loadGroupChatHistory()
                    historyLoadedForSession = sessionID

                    // If still no messages and not host, request from host
                    if groupMessages.isEmpty,
                       !poolManager.isHost,
                       poolManager.poolState == .connected {
                        requestHistorySyncFromHost()
                    }
                }
            }
        } else {
            // Not connected - just show whatever we have in memory (likely empty)
            messages = groupMessages
        }
    }

    /// Switch to group chat mode
    public func switchToGroupChat() {
        selectedPrivatePeer = nil
        selectedGroupChat = nil
        isViewingGroupList = true
        chatMode = .group
        selectedChatTab = 0

        // Reload group messages to ensure history is displayed
        let hasConvID = hostBasedGroupConvID != nil
        if groupMessages.isEmpty && hasConvID {
            if #available(macOS 14.0, iOS 17.0, *) {
                Task {
                    await loadGroupChatHistory()
                    await loadGroupChatList()
                }
            }
        } else {
            messages = groupMessages
        }
    }

    /// Load group chat history from storage
    @available(macOS 14.0, iOS 17.0, *)
    private func loadGroupChatHistory() async {
        // Use host-based conversation ID for persistent history
        var groupConvID: String

        guard let hostBasedID = hostBasedGroupConvID else {
            log("[HISTORY] loadGroupChatHistory: no group conversation ID available, cannot load", level: .warning, category: .network)
            return
        }
        groupConvID = hostBasedID

        log("[HISTORY] Loading group chat for conversationID: \(groupConvID)", category: .network)
        let loadedGroupMessages = await chatHistoryService.getMessages(for: groupConvID)
        log("[HISTORY] Loaded \(loadedGroupMessages.count) messages from persistence", category: .network)

        // Merge with any messages already in memory (avoiding duplicates using seenGroupMessageIDs)
        var newMessages: [RichChatMessage] = []
        for message in loadedGroupMessages {
            if !seenGroupMessageIDs.contains(message.id) {
                seenGroupMessageIDs.insert(message.id)
                newMessages.append(message)
            }
        }

        if !newMessages.isEmpty {
            var allMessages = groupMessages + newMessages
            allMessages.sort { $0.timestamp < $1.timestamp }
            groupMessages = allMessages
        } else if groupMessages.isEmpty && !loadedGroupMessages.isEmpty {
            groupMessages = loadedGroupMessages
            // Populate seen IDs
            for message in loadedGroupMessages {
                seenGroupMessageIDs.insert(message.id)
            }
        }

        if chatMode.isGroup {
            messages = groupMessages
        }

        // Update unread count
        if let groupConv = await chatHistoryService.loadConversation(id: groupConvID) {
            groupUnreadCount = groupConv.unreadCount
        }
    }

    /// Switch to private chat with a specific peer
    public func switchToPrivateChat(with peer: Peer) {
        selectedPrivatePeer = peer
        chatMode = .privateChat(peerID: peer.id)
        selectedChatTab = 1

        // Load private chat history if not already loaded
        if privateMessages[peer.id] == nil {
            Task {
                await loadPrivateChatHistory(peerID: peer.id)
            }
        } else {
            messages = privateMessages[peer.id] ?? []
        }
    }

    /// Open private chat from the chat list
    public func openPrivateChat(info: PrivateChatInfo) {
        // Find the peer from connected peers
        if let peer = connectedPeers.first(where: { $0.id == info.peerID }) {
            switchToPrivateChat(with: peer)
        } else {
            // Create a temporary peer for offline history viewing
            let peer = Peer(
                id: info.peerID,
                displayName: info.peerName,
                isHost: false,
                status: .disconnected
            )
            selectedPrivatePeer = peer
            chatMode = .privateChat(peerID: peer.id)
            selectedChatTab = 1

            Task {
                await loadPrivateChatHistory(peerID: peer.id)
            }
        }
    }

    /// Go back to private chats list
    public func backToPrivateChatsList() {
        selectedPrivatePeer = nil
        // Stay on private tab but clear the selection
        Task {
            await refreshPrivateChatInfos()
        }
    }

    // MARK: - Chat History Persistence

    /// Load all chat history for current session
    /// Merges persisted history with any existing in-memory messages
    @available(macOS 14.0, iOS 17.0, *)
    private func loadChatHistory() async {
        // Use host-based conversation ID for persistent history
        var groupConvID: String

        guard let hostBasedID = hostBasedGroupConvID else {
            log("[HISTORY] loadChatHistory: no group conversation ID available, cannot load", level: .warning, category: .network)
            return
        }
        groupConvID = hostBasedID
        log("Loading chat history for group conversation", category: .network)

        // Load group chat history from persistence
        let loadedGroupMessages = await chatHistoryService.getMessages(for: groupConvID)

        // Merge with existing in-memory messages (avoiding duplicates using seenGroupMessageIDs)
        var newFromPersistence: [RichChatMessage] = []
        for message in loadedGroupMessages {
            if !seenGroupMessageIDs.contains(message.id) {
                seenGroupMessageIDs.insert(message.id)
                newFromPersistence.append(message)
            }
        }

        if !newFromPersistence.isEmpty {
            var allMessages = groupMessages + newFromPersistence
            allMessages.sort { $0.timestamp < $1.timestamp }
            groupMessages = allMessages
        } else if groupMessages.isEmpty && !loadedGroupMessages.isEmpty {
            // No in-memory messages, use persisted ones directly
            groupMessages = loadedGroupMessages
            // Populate seen IDs from loaded messages
            for message in loadedGroupMessages {
                seenGroupMessageIDs.insert(message.id)
            }
        }

        if chatMode.isGroup {
            messages = groupMessages
        }

        // Get group unread count
        if let groupConv = await chatHistoryService.loadConversation(id: groupConvID) {
            groupUnreadCount = groupConv.unreadCount
        }

        // Refresh private chat infos
        await refreshPrivateChatInfos()
    }

    /// Load private chat history for a specific peer
    @available(macOS 14.0, iOS 17.0, *)
    private func loadPrivateChatHistory(peerID: String) async {
        let convID = ChatConversation.privateConversationID(localPeerID: localPeerID, remotePeerID: peerID)
        let loadedMessages = await chatHistoryService.getMessages(for: convID)

        // Initialize seen IDs set for this peer
        if seenPrivateMessageIDs[peerID] == nil {
            seenPrivateMessageIDs[peerID] = []
        }

        // Populate seen IDs from loaded messages to prevent future duplicates
        for message in loadedMessages {
            seenPrivateMessageIDs[peerID]!.insert(message.id)
        }

        privateMessages[peerID] = loadedMessages

        if case .privateChat(let currentPeerID) = chatMode, currentPeerID == peerID {
            messages = loadedMessages
        }
    }

    /// Refresh private chat infos list
    @available(macOS 14.0, iOS 17.0, *)
    public func refreshPrivateChatInfos() async {
        let onlinePeerIDs = Set(connectedPeers.map { $0.id })
        privateChatInfos = await chatHistoryService.getPrivateChatInfos(localPeerID: localPeerID, onlinePeerIDs: onlinePeerIDs)
        totalPrivateUnreadCount = privateChatInfos.reduce(0) { $0 + $1.unreadCount }
    }

    /// Save a message to history
    @available(macOS 14.0, iOS 17.0, *)
    private func saveMessageToHistory(_ message: RichChatMessage, isGroupChat: Bool, participantIDs: [String]) async {
        let conversationID: String

        if isGroupChat {
            // Use host-based conversation ID for persistent history
            guard let hostBasedID = hostBasedGroupConvID else {
                log("[HISTORY] saveMessageToHistory: no group conversation ID available, cannot save", level: .warning, category: .network)
                return
            }
            conversationID = hostBasedID
            log("[HISTORY] Saving group message to hostBasedID: \(conversationID)", category: .network)

            // Also update the group list preview
            if let hostPeerID = poolManager?.currentSession?.hostPeerID {
                let shouldIncrementUnread = !message.isFromLocalUser && !chatMode.isGroup
                await updateGroupChatPreview(hostPeerID: hostPeerID, message: message, incrementUnread: shouldIncrementUnread)
            }
        } else {
            guard let peerID = participantIDs.first(where: { $0 != localPeerID }) else { return }
            conversationID = ChatConversation.privateConversationID(localPeerID: localPeerID, remotePeerID: peerID)
        }

        await chatHistoryService.addMessage(message, to: conversationID, isGroupChat: isGroupChat, participantIDs: participantIDs)
    }

    /// Mark group chat as read
    private func markGroupChatAsRead() {
        guard let conversationID = hostBasedGroupConvID else { return }

        groupUnreadCount = 0

        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                await chatHistoryService.markAsRead(conversationID: conversationID)

                // Also update the group list
                if let hostPeerID = poolManager?.currentSession?.hostPeerID {
                    await chatHistoryService.markGroupAsRead(hostPeerID: hostPeerID)
                    if let index = groupChatInfos.firstIndex(where: { $0.id == hostPeerID }) {
                        groupChatInfos[index].unreadCount = 0
                    }
                }
            }
        }
    }

    /// Mark private chat as read
    private func markPrivateChatAsRead(peerID: String) {
        // Update local state
        if let index = privateChatInfos.firstIndex(where: { $0.peerID == peerID }) {
            totalPrivateUnreadCount -= privateChatInfos[index].unreadCount
            privateChatInfos[index].unreadCount = 0
        }

        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                let convID = ChatConversation.privateConversationID(localPeerID: localPeerID, remotePeerID: peerID)
                await chatHistoryService.markAsRead(conversationID: convID)
            }
        }
    }

    /// Clear all chat history
    public func clearAllChatHistory() {
        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                await chatHistoryService.clearAllChatHistory()
                clearMessages()
                await refreshPrivateChatInfos()
            }
        }
    }

    // MARK: - Clear History (New Feature)

    /// Check if current user is the host
    public var isPoolHost: Bool {
        poolManager?.isHost ?? false
    }

    /// Show confirmation dialog for clearing history
    public func showClearHistoryDialog() {
        showClearHistoryConfirmation = true
    }

    /// Clear chat history based on current chat mode
    /// - In group mode: clears group chat (host clears for everyone, non-host clears local view)
    /// - In private mode: clears only the current private conversation
    public func clearChatHistory() {
        switch chatMode {
        case .group:
            clearGroupChatHistoryInternal()
        case .privateChat(let peerID):
            clearPrivateChatHistory(peerID: peerID)
        }

        showClearHistoryConfirmation = false
    }

    /// Clear group chat history (internal implementation)
    /// - For host: clears for everyone by broadcasting clear command
    /// - For non-host: clears local view only
    private func clearGroupChatHistoryInternal() {
        guard let poolManager = poolManager else { return }

        if poolManager.isHost {
            // Host clears history for everyone
            clearGroupChatHistoryAsHost()
        } else {
            // Non-host clears local view only
            clearLocalGroupChatView()
        }
    }

    /// Clear private chat history for a specific peer
    /// - Parameter peerID: The peer ID whose private conversation should be cleared
    private func clearPrivateChatHistory(peerID: String) {
        guard let poolManager = poolManager else { return }

        // Clear local private messages for this peer
        privateMessages[peerID] = []
        seenPrivateMessageIDs[peerID]?.removeAll()

        // Update display if viewing this private chat
        if case .privateChat(let currentPeerID) = chatMode, currentPeerID == peerID {
            messages = []
        }

        // Clear persisted private chat history
        if #available(macOS 14.0, iOS 17.0, *) {
            let localPeerID = poolManager.localPeerID
            Task {
                let conversationID = ChatConversation.privateConversationID(localPeerID: localPeerID, remotePeerID: peerID)
                await chatHistoryService.deleteConversation(id: conversationID)
            }
        }

        // Add system message
        let systemMessage = RichChatMessage.systemMessage(text: "You cleared this private conversation")
        if privateMessages[peerID] != nil {
            privateMessages[peerID]!.append(systemMessage)
        } else {
            privateMessages[peerID] = [systemMessage]
        }

        // Update display
        if case .privateChat(let currentPeerID) = chatMode, currentPeerID == peerID {
            messages = privateMessages[peerID] ?? []
        }

        log("Cleared private chat history for peer \(peerID.prefix(8))...", category: .network)
    }

    /// Host clears history for everyone
    private func clearGroupChatHistoryAsHost() {
        guard let poolManager = poolManager,
              poolManager.isHost,
              let sessionID = currentSessionID else { return }

        guard hostBasedGroupConvID != nil else { return }

        // Clear local messages and deduplication tracking for group
        groupMessages = []
        seenGroupMessageIDs.removeAll()
        if chatMode.isGroup {
            messages = []
        }

        // Clear persisted history
        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                if let hostPeerID = poolManager.currentSession?.hostPeerID {
                    // Clear using host-based ID
                    let hostConvID = ChatConversation.hostBasedGroupConversationID(hostPeerID: hostPeerID)
                    await chatHistoryService.deleteConversation(id: hostConvID)

                    // Update group list preview
                    if let index = groupChatInfos.firstIndex(where: { $0.id == hostPeerID }) {
                        groupChatInfos[index].lastMessage = nil
                        groupChatInfos[index].lastMessageTime = nil
                        groupChatInfos[index].unreadCount = 0
                        await chatHistoryService.saveGroupChatInfos(groupChatInfos)
                    }
                }
            }
        }

        // Broadcast encrypted clear command to all peers
        let clearPayload = ClearHistoryPayload(sessionID: sessionID, clearedBy: poolManager.localPeerID)

        guard let payloadData = try? JSONEncoder().encode(clearPayload) else {
            log("Failed to encode clear history payload", category: .network)
            return
        }

        // Send encrypted to all connected peers
        let peerIDs = poolManager.connectedPeers.map { $0.id }
        if !peerIDs.isEmpty {
            sendEncryptedPayload(
                payloadData,
                messageType: .clearHistory,
                isPrivateChat: false,
                targetPeerIDs: peerIDs
            )
        }
        log("Host cleared chat history and broadcast encrypted to all peers", category: .security)

        // Add system message about history being cleared
        let systemMessage = RichChatMessage.systemMessage(text: "Chat history was cleared by the host")
        // Track the system message ID
        seenGroupMessageIDs.insert(systemMessage.id)
        groupMessages.append(systemMessage)
        if chatMode.isGroup {
            messages = groupMessages
        }
    }

    /// Non-host clears their local view only
    private func clearLocalGroupChatView() {
        // Only clear local display and deduplication tracking, don't touch persistence
        groupMessages = []
        seenGroupMessageIDs.removeAll()
        if chatMode.isGroup {
            messages = []
        }

        // Add system message
        let systemMessage = RichChatMessage.systemMessage(text: "You cleared your local chat view")
        groupMessages.append(systemMessage)
        if chatMode.isGroup {
            messages = groupMessages
        }
    }

    /// Handle incoming clear history command from host
    private func handleClearHistoryCommand(_ payload: ClearHistoryPayload, from senderID: String) {
        guard payload.sessionID == currentSessionID else {
            log("Ignoring clear history for different session", category: .network)
            return
        }

        // SECURITY: Only the pool host can clear chat history
        guard let poolManager = poolManager else { return }

        // Check if sender is the host - either they have isHost flag or we're hosting and this is from ourselves
        let senderIsHost = poolManager.connectedPeers.first(where: { $0.id == senderID })?.isHost == true
            || (poolManager.isHost && senderID == poolManager.localPeerID)

        guard senderIsHost else {
            log("[SECURITY] Clear history rejected - sender \(senderID.prefix(8))... is not the pool host", level: .warning, category: .security)
            return
        }

        // Security: Verify the sender matches the clearedBy field in payload
        guard payload.clearedBy == senderID else {
            log("[SECURITY] Clear history sender mismatch - claimed: \(payload.clearedBy.prefix(8))..., actual: \(senderID.prefix(8))...", level: .warning, category: .security)
            return
        }

        // Clear local messages and deduplication tracking
        groupMessages = []
        seenGroupMessageIDs.removeAll()
        if chatMode.isGroup {
            messages = []
        }

        // Clear persisted history
        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                if let hostPeerID = poolManager.currentSession?.hostPeerID {
                    // Clear using host-based ID
                    let hostConvID = ChatConversation.hostBasedGroupConversationID(hostPeerID: hostPeerID)
                    await chatHistoryService.deleteConversation(id: hostConvID)

                    // Update group list preview
                    if let index = groupChatInfos.firstIndex(where: { $0.id == hostPeerID }) {
                        groupChatInfos[index].lastMessage = nil
                        groupChatInfos[index].lastMessageTime = nil
                        groupChatInfos[index].unreadCount = 0
                        await chatHistoryService.saveGroupChatInfos(groupChatInfos)
                    }
                }
            }
        }

        // Add system message
        let systemMessage = RichChatMessage.systemMessage(text: "Chat history was cleared by the host")
        // Track the system message ID
        seenGroupMessageIDs.insert(systemMessage.id)
        groupMessages.append(systemMessage)
        if chatMode.isGroup {
            messages = groupMessages
        }

        log("Cleared chat history on host command", category: .security)
    }

    // MARK: - Window Visibility

    /// Update window visibility state
    /// Call this when the Pool Chat window opens, closes, or changes visibility
    /// Note: This is also called automatically by activate(), moveToBackground(), suspend(), terminate()
    public func setWindowVisible(_ visible: Bool) {
        let oldValue = isWindowVisible
        isWindowVisible = visible
        log("[NOTIFICATION] setWindowVisible called: \(oldValue) -> \(visible), runtimeState: \(runtimeState)", category: .runtime)

        // Update the notification bridge - this ensures notifications work even when Pool Chat window is closed
        ChatNotificationBridge.shared.setPoolChatVisible(visible)

        // Clear notifications when window becomes visible
        if visible {
            clearChatNotifications()
        }
    }

    /// Clear all delivered chat notifications
    private func clearChatNotifications() {
        Task {
            await notificationService.clearAllNotifications()
        }
    }

    // MARK: - Deep Link Handling

    /// Handle a deep link from a notification tap
    /// - Parameter deepLink: The deep link data from the notification
    public func handleDeepLink(_ deepLink: ChatNotificationDeepLink) {
        log("Handling deep link: type=\(deepLink.chatType), sender=\(deepLink.senderName)", category: .runtime)

        switch deepLink.chatType {
        case "private":
            // Navigate to private chat with the sender
            if let senderID = deepLink.senderID {
                navigateToPrivateChat(peerID: senderID, peerName: deepLink.senderName)
            }

        case "group", "mention":
            // Navigate to group chat tab
            navigateToGroupChat()

        default:
            log("Unknown deep link chat type: \(deepLink.chatType)", level: .warning, category: .runtime)
        }
    }

    /// Navigate to a specific private chat
    public func navigateToPrivateChat(peerID: String, peerName: String) {
        // Check if peer is online
        if let peer = connectedPeers.first(where: { $0.id == peerID }) {
            switchToPrivateChat(with: peer)
        } else {
            // Create a temporary peer object for offline navigation
            let peer = Peer(
                id: peerID,
                displayName: peerName,
                isHost: false,
                status: .disconnected
            )
            selectedPrivatePeer = peer
            chatMode = .privateChat(peerID: peerID)
            selectedChatTab = 1

            Task {
                await loadPrivateChatHistory(peerID: peerID)
            }
        }
    }

    /// Navigate to group chat tab
    public func navigateToGroupChat() {
        switchToGroupChat()
    }

    // MARK: - Host-Based Group Chat Management

    /// Load all group chat infos from storage
    @available(macOS 14.0, iOS 17.0, *)
    public func loadGroupChatList() async {
        groupChatInfos = await chatHistoryService.loadGroupChatInfos()

        // Update online status based on current connection
        if let currentHostID = currentGroupHostPeerID {
            for i in groupChatInfos.indices {
                groupChatInfos[i].isHostConnected = groupChatInfos[i].id == currentHostID
            }
        }

        log("[GROUP_LIST] Loaded \(groupChatInfos.count) group chats", category: .network)
    }

    /// Create or update the current group in the list when connecting to a pool
    @available(macOS 14.0, iOS 17.0, *)
    private func registerCurrentGroupChat() async {
        guard let poolManager = poolManager,
              let session = poolManager.currentSession else { return }

        let hostPeerID = session.hostPeerID
        let hostDisplayName = session.name // Pool name serves as display name

        // Set the host-based conversation ID
        hostBasedGroupConvID = ChatConversation.hostBasedGroupConversationID(hostPeerID: hostPeerID)

        // Check if this group already exists
        var groups = await chatHistoryService.loadGroupChatInfos()

        if let index = groups.firstIndex(where: { $0.id == hostPeerID }) {
            // Update existing group
            groups[index].hostDisplayName = hostDisplayName
            groups[index].poolName = session.name
            groups[index].isHostConnected = true
        } else {
            // Create new group entry
            let newGroup = GroupChatInfo.create(
                hostPeerID: hostPeerID,
                hostDisplayName: hostDisplayName,
                poolName: session.name
            )
            var updatedGroup = newGroup
            updatedGroup.isHostConnected = true
            groups.insert(updatedGroup, at: 0)
        }

        await chatHistoryService.saveGroupChatInfos(groups)
        groupChatInfos = groups

        log("[GROUP_LIST] Registered/updated group for host: \(hostPeerID.prefix(8))...", category: .network)
    }

    /// Update group chat info when a message is received
    @available(macOS 14.0, iOS 17.0, *)
    private func updateGroupChatPreview(hostPeerID: String, message: RichChatMessage, incrementUnread: Bool) async {
        let preview = getMessagePreview(message)
        await chatHistoryService.updateGroupChatLastMessage(
            hostPeerID: hostPeerID,
            message: preview,
            timestamp: message.timestamp,
            incrementUnread: incrementUnread
        )

        // Update local state
        if let index = groupChatInfos.firstIndex(where: { $0.id == hostPeerID }) {
            groupChatInfos[index].lastMessage = preview
            groupChatInfos[index].lastMessageTime = message.timestamp
            if incrementUnread {
                groupChatInfos[index].unreadCount += 1
            }
        }
    }

    /// Open a specific group chat from the list
    public func openGroupChat(_ group: GroupChatInfo) {
        selectedGroupChat = group
        isViewingGroupList = false

        // Load messages for this group
        if #available(macOS 14.0, iOS 17.0, *) {
            let hostPeerID = group.id
            Task {
                // Set the host-based conversation ID
                hostBasedGroupConvID = ChatConversation.hostBasedGroupConversationID(hostPeerID: hostPeerID)

                // Load messages from storage
                let loadedMessages = await chatHistoryService.getHostBasedGroupMessages(hostPeerID: hostPeerID)

                // Update group messages
                seenGroupMessageIDs.removeAll()
                for message in loadedMessages {
                    seenGroupMessageIDs.insert(message.id)
                }
                groupMessages = loadedMessages
                messages = groupMessages

                // Mark as read
                await chatHistoryService.markGroupAsRead(hostPeerID: hostPeerID)
                if let index = groupChatInfos.firstIndex(where: { $0.id == hostPeerID }) {
                    groupChatInfos[index].unreadCount = 0
                }

                log("[GROUP_LIST] Opened group chat with host: \(hostPeerID.prefix(8))..., messages: \(loadedMessages.count)", category: .network)
            }
        }
    }

    /// Go back to group chat list from a specific group
    public func backToGroupChatList() {
        selectedGroupChat = nil
        isViewingGroupList = true

        // Refresh the group list
        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                await loadGroupChatList()
            }
        }
    }

    /// Delete a group chat from the list
    public func deleteGroupChat(_ group: GroupChatInfo) {
        if #available(macOS 14.0, iOS 17.0, *) {
            Task {
                await chatHistoryService.deleteGroupChat(hostPeerID: group.id)

                // Update local state
                groupChatInfos.removeAll { $0.id == group.id }

                log("[GROUP_LIST] Deleted group chat with host: \(group.id)", category: .network)
            }
        }
    }

    /// Update connection status for all groups when pool state changes
    @available(macOS 14.0, iOS 17.0, *)
    private func updateGroupConnectionStatus() async {
        guard !groupChatInfos.isEmpty else { return }

        let currentHostID = currentGroupHostPeerID

        for i in groupChatInfos.indices {
            let newStatus = groupChatInfos[i].id == currentHostID
            if groupChatInfos[i].isHostConnected != newStatus {
                groupChatInfos[i].isHostConnected = newStatus
                await chatHistoryService.updateGroupHostStatus(hostPeerID: groupChatInfos[i].id, isConnected: newStatus)
            }
        }
    }

    /// Get total unread count across all group chats
    public var totalGroupUnreadCount: Int {
        groupChatInfos.reduce(0) { $0 + $1.unreadCount }
    }
}

// MARK: - CallManagerDelegate

extension PoolChatViewModel: CallManagerDelegate {

    public func callManager(_ manager: CallManager, sendSignal signal: CallSignal, to peerIDs: [String]) {
        guard let payloadData = try? JSONEncoder().encode(signal) else {
            log("[CALL] Failed to encode call signal", level: .error, category: .network)
            return
        }
        sendEncryptedPayload(
            payloadData,
            messageType: .callSignal,
            isPrivateChat: peerIDs.count == 1,
            targetPeerIDs: peerIDs
        )
    }

    public func callManager(_ manager: CallManager, sendMediaFrame data: Data, to peerIDs: [String]) {
        guard let poolManager else { return }
        let header = MediaFrameCodec.unpack(data)?.header

        // Audio stays on unreliable delivery for low latency. Video uses reliable delivery
        // because the encrypted JSON wrapper materially inflates packet size and MC
        // unreliable delivery has proven too lossy/fragile for H.264 frame transport.
        let useReliableDelivery = header?.mediaType == .video

        for peerID in peerIDs {
            guard encryptionService.hasKeyFor(peerID: peerID) else { continue }
            guard let encryptedData = encryptionService.encrypt(data, for: peerID) else { continue }

            let encryptedPayload = EncryptedChatPayload(
                encryptedData: encryptedData,
                senderPeerID: poolManager.localPeerID,
                isPrivateChat: false,
                targetPeerID: peerID,
                messageType: .mediaFrame
            )

            guard let wrappedData = try? JSONEncoder().encode(encryptedPayload) else { continue }

            var message = PoolMessage(
                type: .custom,
                senderID: poolManager.localPeerID,
                senderName: poolManager.localPeerName,
                payload: wrappedData
            )
            message.isReliable = useReliableDelivery ? true : false
            poolManager.sendMessage(message, to: [peerID])
        }
    }

    public func callManager(_ manager: CallManager, callDidEnd callID: UUID, duration: TimeInterval?, reason: CallEndReason) {
        // Insert a system message recording the call in the chat
        let durationText: String
        if let duration, duration > 0 {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            durationText = minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
        } else {
            durationText = reason == .rejected ? "Declined" : (reason == .busy ? "Busy" : "Missed")
        }

        let isVideo = manager.currentCall?.isVideoCall ?? false
        let callType = isVideo ? "Video call" : "Voice call"
        let text = "\(callType) \u{00B7} \(durationText)"

        let systemMessage = RichChatMessage(
            id: UUID(),
            senderID: "system",
            senderName: "System",
            contentType: .system,
            timestamp: Date(),
            isFromLocalUser: false,
            text: text
        )

        // Add to current chat context
        if let privatePeerID = chatMode.privatePeerID {
            if privateMessages[privatePeerID] == nil {
                privateMessages[privatePeerID] = []
            }
            privateMessages[privatePeerID]?.append(systemMessage)
            if chatMode == .privateChat(peerID: privatePeerID) {
                messages.append(systemMessage)
            }
        } else {
            groupMessages.append(systemMessage)
            if chatMode == .group {
                messages.append(systemMessage)
            }
        }
    }

    public func callManager(_ manager: CallManager, displayNameFor peerID: String) -> String {
        connectedPeers.first(where: { $0.id == peerID })?.displayName ?? peerID.prefix(8).description
    }
}
