// PoolChatView.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import SwiftUI
import PhotosUI
import ConnectionPool
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Cross-Platform Helpers

private extension View {
    @ViewBuilder
    func crossPlatformInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func crossPlatformCallPresentation<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}

// MARK: - Debug Traced Animation Modifier


/// Main view for the Pool Chat standalone app
public struct PoolChatView: View {
    @ObservedObject var viewModel: PoolChatViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    public init(viewModel: PoolChatViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        return VStack(spacing: 0) {
            // Connection status bar (compact, below window title bar)
            ConnectionStatusBar(
                connectedPeers: viewModel.connectedPeers,
                isConnected: viewModel.isConnected,
                isHost: viewModel.isPoolHost,
                onClearHistory: { viewModel.showClearHistoryDialog() },
                // Hide group-call buttons here while a private chat is active —
                // the private peer header carries its own per-peer call buttons,
                // and showing both reads as duplicate.
                onGroupVoiceCall: viewModel.chatMode.isGroup ? {
                    viewModel.callManager.initiateCall(to: viewModel.connectedPeers.map(\.id), video: false)
                    viewModel.showActiveCallView = true
                } : nil,
                onGroupVideoCall: viewModel.chatMode.isGroup ? {
                    viewModel.callManager.initiateCall(to: viewModel.connectedPeers.map(\.id), video: true)
                    viewModel.showActiveCallView = true
                } : nil
            )

            // Main content area
            if viewModel.isConnected {
                // Chat mode tabs
                ChatModeTabBar(
                    selectedTab: $viewModel.selectedChatTab,
                    groupUnreadCount: viewModel.groupUnreadCount,
                    privateUnreadCount: viewModel.totalPrivateUnreadCount
                )

                // Content based on selected tab
                if viewModel.selectedChatTab == 0 {
                    // Group chat
                    groupChatContent
                } else {
                    // Private chats
                    privateChatContent
                }
            } else {
                // Not connected: Show empty state
                NotConnectedView()
            }

            // Emoji Picker (shown above input)
            if viewModel.showEmojiPicker && viewModel.isConnected && shouldShowInput {
                EmojiPickerView(
                    selectedCategory: $viewModel.selectedEmojiCategory,
                    onEmojiSelected: { emoji in
                        viewModel.insertEmoji(emoji)
                    },
                    onEmojiSent: { emoji in
                        viewModel.sendEmoji(emoji)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Input bar (shown for group chat or when in a private conversation)
            if viewModel.isConnected && shouldShowInput {
                if viewModel.isRecordingVoice {
                    VoiceRecordingIndicator(
                        duration: viewModel.voiceRecordingDuration,
                        onCancel: { viewModel.cancelVoiceRecording() },
                        onSend: { viewModel.stopVoiceRecordingAndSend() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    VStack(spacing: 0) {
                        // Mention picker popup (shown above input)
                        if viewModel.showMentionPicker && !viewModel.filteredMentionPeers.isEmpty {
                            MentionPickerView(
                                peers: viewModel.filteredMentionPeers,
                                onSelect: { peer in
                                    viewModel.selectMention(peer)
                                }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        ChatInputBar(
                            text: $viewModel.textInput,
                            showEmojiPicker: $viewModel.showEmojiPicker,
                            showImagePicker: $viewModel.showImagePicker,
                            selectedPhotoItem: $viewModel.selectedPhotoItem,
                            replyingToMessage: viewModel.replyingToMessage,
                            isGroupChat: viewModel.chatMode.isGroup,
                            onSendText: { viewModel.sendTextMessage() },
                            onStartVoiceRecording: { viewModel.startVoiceRecording() },
                            onCancelReply: { viewModel.cancelReply() },
                            onCreatePoll: { viewModel.showPollCreationSheet() },
                            isConnected: viewModel.isConnected
                        )
                    }
                }
            }
        }
        .background(theme.background)
        .onChange(of: viewModel.selectedPhotoItem) { _, newValue in
            if newValue != nil {
                viewModel.handleImageSelection()
            }
        }
        .alert(poolString("poolchat.error.title", fallback: "Error"), isPresented: $viewModel.showError) {
            Button(poolString("common.ok", fallback: "OK"), role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? poolString("poolchat.error.unknown", fallback: "Unknown error"))
        }
        .sheet(isPresented: $viewModel.showPollCreation) {
            PollCreationSheet(
                question: $viewModel.pollQuestion,
                options: $viewModel.pollOptions,
                allowVoteChange: $viewModel.pollAllowVoteChange,
                onAddOption: { viewModel.addPollOption() },
                onRemoveOption: { viewModel.removePollOption(at: $0) },
                onCreate: { viewModel.createPoll() },
                onCancel: { viewModel.cancelPollCreation() }
            )
        }
        .alert(
            clearHistoryAlertTitle,
            isPresented: $viewModel.showClearHistoryConfirmation
        ) {
            Button(poolString("common.cancel", fallback: "Cancel"), role: .cancel) {}
            Button(clearHistoryButtonTitle, role: .destructive) {
                viewModel.clearChatHistory()
            }
        } message: {
            Text(clearHistoryAlertMessage)
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.showEmojiPicker)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isRecordingVoice)
        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedChatTab)
        .animation(.easeInOut(duration: 0.2), value: viewModel.replyingToMessage != nil)
        .animation(.easeInOut(duration: 0.15), value: viewModel.showMentionPicker)
        // MARK: - Call UI Integration
        // Audio call banner (shown at top when audio call is active)
        .overlay(alignment: .top) {
            if let session = viewModel.callManager.currentCall,
               session.state == .active,
               !session.isVideoCall,
               !viewModel.showActiveCallView {
                AudioCallBannerView(
                    callManager: viewModel.callManager,
                    callSession: session,
                    onTap: { viewModel.showActiveCallView = true }
                )
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Incoming call full-screen cover
        .crossPlatformCallPresentation(isPresented: $viewModel.showIncomingCallView) {
            if let signal = viewModel.callManager.incomingCallSignal {
                IncomingCallView(
                    signal: signal,
                    onAnswer: {
                        viewModel.callManager.answerCall()
                        viewModel.showIncomingCallView = false
                        viewModel.showActiveCallView = true
                    },
                    onDecline: {
                        viewModel.callManager.rejectCall()
                        viewModel.showIncomingCallView = false
                    }
                )
            }
        }
        // Active call full-screen cover
        .crossPlatformCallPresentation(isPresented: $viewModel.showActiveCallView) {
            if let session = viewModel.callManager.currentCall {
                ActiveCallView(
                    callManager: viewModel.callManager,
                    callSession: session
                )
            } else {
                // Safety: dismiss if call ended while cover was presented
                Color.clear.onAppear {
                    viewModel.showActiveCallView = false
                }
            }
        }
        .onAppear {
            // Mark window as visible for notification handling
            // Note: This is a fallback - visibility is primarily managed by AppWindow lifecycle methods
            viewModel.setWindowVisible(true)
        }
        .onDisappear {
            // Mark window as not visible - notifications will be shown for new messages
            // Note: This is a fallback - visibility is primarily managed by AppWindow lifecycle methods
            viewModel.setWindowVisible(false)
        }
    }

    /// Whether to show the input bar
    private var shouldShowInput: Bool {
        // Show input when:
        // 1. On group tab AND connected (viewing current group conversation)
        // 2. On private tab AND has a selected peer to chat with
        if viewModel.selectedChatTab == 0 {
            // Group tab: show input only when connected (not viewing disconnected group list)
            return viewModel.isConnected
        } else {
            // Private tab: show input only when a peer is selected
            return viewModel.selectedPrivatePeer != nil
        }
    }

    // MARK: - Clear History Alert Helpers

    /// Title for the clear history alert based on current chat mode
    private var clearHistoryAlertTitle: String {
        if viewModel.chatMode.isGroup {
            return viewModel.isPoolHost
                ? poolString("poolchat.clear.groupHostTitle", fallback: "Clear Chat History")
                : poolString("poolchat.clear.groupMemberTitle", fallback: "Clear Your View")
        } else {
            return poolString("poolchat.clear.privateTitle", fallback: "Clear Private Chat")
        }
    }

    /// Button title for the clear history alert
    private var clearHistoryButtonTitle: String {
        if viewModel.chatMode.isGroup {
            return viewModel.isPoolHost
                ? poolString("poolchat.clear.forEveryone", fallback: "Clear for Everyone")
                : poolString("poolchat.clear.confirm", fallback: "Clear")
        } else {
            return poolString("poolchat.clear.confirm", fallback: "Clear")
        }
    }

    /// Message for the clear history alert based on current chat mode
    private var clearHistoryAlertMessage: String {
        if viewModel.chatMode.isGroup {
            if viewModel.isPoolHost {
                return poolString("poolchat.clear.groupHostMessage", fallback: "This will clear the chat history for all pool members. This action cannot be undone.")
            } else {
                return poolString("poolchat.clear.groupMemberMessage", fallback: "This will clear your local chat view. Other members will still see the messages.")
            }
        } else {
            return poolString("poolchat.clear.privateMessage", fallback: "This will clear your private conversation. The other participant's view will not be affected.")
        }
    }

    /// Group chat content view - shows either group list or current group conversation
    @ViewBuilder
    private var groupChatContent: some View {
        if viewModel.isConnected {
            // Connected: show current group conversation
            VStack(spacing: 0) {
                // Show group header when viewing a group from the list
                if !viewModel.isViewingGroupList, let selectedGroup = viewModel.selectedGroupChat {
                    GroupChatHeader(
                        group: selectedGroup,
                        onBack: { viewModel.backToGroupChatList() }
                    )
                }

                // ISSUE 1 FIX: Show subtle loading indicator while history loads
                if viewModel.isLoadingHistory {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        PoolText("poolchat.messages.loadingHistory", fallback: "Loading history…")
                            .font(.caption)
                            .foregroundColor(design.snapshot(dark: scheme == .dark).textSecondary)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(design.snapshot(dark: scheme == .dark).surface.opacity(0.8))
                }

                MessagesListView(
                    messages: viewModel.messages,
                    playingVoiceMessageID: viewModel.playingVoiceMessageID,
                    voicePlaybackProgress: viewModel.voicePlaybackProgress,
                    localPeerID: viewModel.localPeerID,
                    showReactionPickerForMessageID: viewModel.showReactionPickerForMessageID,
                    onPlayVoice: { viewModel.playVoiceMessage($0) },
                    onStopVoice: { viewModel.stopVoicePlayback() },
                    onReply: { viewModel.startReply(to: $0) },
                    onShowReactionPicker: { viewModel.showReactionPicker(for: $0) },
                    onHideReactionPicker: { viewModel.hideReactionPicker() },
                    onToggleReaction: { emoji, messageID in viewModel.toggleReaction(emoji, on: messageID) },
                    onPollVote: { messageID, option in viewModel.votePoll(messageID: messageID, option: option) }
                )
            }
            .onAppear {
                viewModel.onGroupChatAppear()
            }
        } else {
            // Not connected: show group list (history of past groups)
            GroupChatListView(
                groupInfos: viewModel.groupChatInfos,
                currentHostPeerID: viewModel.currentGroupHostPeerID,
                onSelectGroup: { group in
                    viewModel.openGroupChat(group)
                },
                onDeleteGroup: { group in
                    viewModel.deleteGroupChat(group)
                }
            )
        }
    }

    /// Private chat content view
    @ViewBuilder
    private var privateChatContent: some View {
        if let selectedPeer = viewModel.selectedPrivatePeer {
            // Viewing a private conversation
            VStack(spacing: 0) {
                // Private chat header with back button
                PrivateChatHeader(
                    peer: selectedPeer,
                    isOnline: viewModel.connectedPeers.contains(where: { $0.id == selectedPeer.id }),
                    onBack: { viewModel.backToPrivateChatsList() },
                    onVoiceCall: {
                        viewModel.callManager.initiateCall(to: [selectedPeer.id], video: false)
                        viewModel.showActiveCallView = true
                    },
                    onVideoCall: {
                        viewModel.callManager.initiateCall(to: [selectedPeer.id], video: true)
                        viewModel.showActiveCallView = true
                    }
                )

                MessagesListView(
                    messages: viewModel.messages,
                    playingVoiceMessageID: viewModel.playingVoiceMessageID,
                    voicePlaybackProgress: viewModel.voicePlaybackProgress,
                    localPeerID: viewModel.localPeerID,
                    showReactionPickerForMessageID: viewModel.showReactionPickerForMessageID,
                    onPlayVoice: { viewModel.playVoiceMessage($0) },
                    onStopVoice: { viewModel.stopVoicePlayback() },
                    onReply: { viewModel.startReply(to: $0) },
                    onShowReactionPicker: { viewModel.showReactionPicker(for: $0) },
                    onHideReactionPicker: { viewModel.hideReactionPicker() },
                    onToggleReaction: { emoji, messageID in viewModel.toggleReaction(emoji, on: messageID) },
                    onPollVote: { _, _ in } // Polls are group-only
                )
            }
        } else {
            // Private chats list
            PrivateChatListView(
                chatInfos: viewModel.privateChatInfos,
                connectedPeers: viewModel.connectedPeers,
                localPeerID: viewModel.localPeerID,
                onSelectChat: { info in
                    viewModel.openPrivateChat(info: info)
                },
                onSelectPeer: { peer in
                    viewModel.switchToPrivateChat(with: peer)
                }
            )
        }
    }
}

// MARK: - Chat Mode Tab Bar

struct ChatModeTabBar: View {
    @Binding var selectedTab: Int
    let groupUnreadCount: Int
    let privateUnreadCount: Int

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: 0) {
            // Group tab
            TabButton(
                titleKey: "poolchat.tab.group",
                titleFallback: "Group",
                icon: "users",
                systemFallback: "person.3.fill",
                isSelected: selectedTab == 0,
                badgeCount: groupUnreadCount
            ) {
                selectedTab = 0
            }

            // Divider
            Rectangle()
                .fill(theme.separator)
                .frame(width: 1, height: 24)

            // Private tab
            TabButton(
                titleKey: "poolchat.tab.private",
                titleFallback: "Private",
                icon: "user",
                systemFallback: "person.fill",
                isSelected: selectedTab == 1,
                badgeCount: privateUnreadCount
            ) {
                selectedTab = 1
            }
        }
        .padding(.horizontal, theme.spacingM)
        .padding(.vertical, theme.spacingS)
        .background(theme.surface)
    }
}

struct TabButton: View {
    let titleKey: String
    let titleFallback: String
    let icon: String
    let systemFallback: String
    let isSelected: Bool
    let badgeCount: Int
    let action: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        Button(action: action) {
            HStack(spacing: theme.spacingXS + 2) {
                PoolIcon(icon, size: 14, systemFallback: systemFallback)

                PoolText(titleKey, fallback: titleFallback)
                    .font(theme.fontBody.weight(.medium))

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.textOnAccent)
                        .padding(.horizontal, theme.spacingXS + 2)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.danger))
                }
            }
            .foregroundColor(isSelected ? theme.accent : theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.spacingS)
            .background(
                isSelected ? theme.accent.opacity(0.12) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Private Chat Header

struct PrivateChatHeader: View {
    let peer: Peer
    let isOnline: Bool
    let onBack: () -> Void
    var onVoiceCall: (() -> Void)?
    var onVideoCall: (() -> Void)?

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    private var avatarColor: Color {
        PoolUserProfile.availableColors[peer.avatarColorIndex % PoolUserProfile.availableColors.count]
    }

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingM) {
            // Back button
            Button(action: onBack) {
                PoolIcon("chevron-left", size: 16, systemFallback: "chevron.left")
                    .foregroundColor(theme.accent)
            }

            // Avatar
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(String(peer.effectiveDisplayName.prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.textOnAccent)
                    )

                // Online indicator
                if isOnline {
                    Circle()
                        .fill(theme.success)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .strokeBorder(theme.surface, lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }
            }

            // Name and status
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.effectiveDisplayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.textPrimary)

                Text(isOnline
                     ? poolString("poolchat.status.onlineSingle", fallback: "Online")
                     : poolString("poolchat.status.offline", fallback: "Offline"))
                    .font(.system(size: 12))
                    .foregroundColor(isOnline ? theme.success : theme.textSecondary)
            }

            Spacer()

            // Call buttons (only shown when peer is online)
            if isOnline {
                HStack(spacing: theme.spacingM) {
                    if let onVoiceCall {
                        Button(action: onVoiceCall) {
                            PoolIcon("phone", size: 15, systemFallback: "phone.fill")
                                .foregroundColor(theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    if let onVideoCall {
                        Button(action: onVideoCall) {
                            PoolIcon("video", size: 15, systemFallback: "video.fill")
                                .foregroundColor(theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Encryption indicator
            HStack(spacing: theme.spacingXS) {
                PoolIcon("lock", size: 10, systemFallback: "lock.fill")
                PoolText("poolchat.encrypted", fallback: "Encrypted")
                    .font(.system(size: 10))
            }
            .foregroundColor(theme.success)
            .padding(.horizontal, theme.spacingS)
            .padding(.vertical, theme.spacingXS)
            .background(theme.success.opacity(0.15))
            .clipShape(Capsule())
        }
        .padding(.horizontal, theme.spacingM)
        .padding(.vertical, theme.spacingS + 2)
        .background(theme.surface)
    }
}

// MARK: - Private Chat List View

struct PrivateChatListView: View {
    let chatInfos: [PrivateChatInfo]
    let connectedPeers: [Peer]
    let localPeerID: String
    let onSelectChat: (PrivateChatInfo) -> Void
    let onSelectPeer: (Peer) -> Void

    /// Peers that don't have existing chat history
    /// Filters out: self (localPeerID) and peers with existing chat history
    /// NOTE: Hosts ARE included so joined members can start private chats with the host
    private var newPeers: [Peer] {
        let existingPeerIDs = Set(chatInfos.map { $0.peerID })
        return connectedPeers.filter { peer in
            // Exclude self - user should not see their own name in private chat list
            guard peer.id != localPeerID else { return false }
            // Exclude peers with existing chat history (they appear in Recent Chats)
            guard !existingPeerIDs.contains(peer.id) else { return false }
            // NOTE: Hosts are now INCLUDED - joined members should be able to private chat with the host
            return true
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Online members section (peers without existing chats)
                if !newPeers.isEmpty {
                    SectionHeader(titleKey: "poolchat.private.startNew", titleFallback: "Start New Chat")

                    ForEach(newPeers, id: \.id) { peer in
                        NewChatPeerRow(peer: peer, onTap: { onSelectPeer(peer) })
                        Divider().padding(.leading, 66)
                    }
                }

                // Existing chats section
                if !chatInfos.isEmpty {
                    SectionHeader(titleKey: "poolchat.private.recent", titleFallback: "Recent Chats")

                    ForEach(chatInfos) { info in
                        PrivateChatRow(info: info, onTap: { onSelectChat(info) })
                        if info.id != chatInfos.last?.id {
                            Divider().padding(.leading, 66)
                        }
                    }
                }

                // Empty state
                if chatInfos.isEmpty && newPeers.isEmpty {
                    PrivateChatEmptyView()
                }
            }
            .padding(.vertical, 8)
        }
    }
}

struct SectionHeader: View {
    let titleKey: String
    let titleFallback: String

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack {
            PoolText(titleKey, fallback: titleFallback)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.textSecondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, theme.spacingL)
        .padding(.top, theme.spacingL)
        .padding(.bottom, theme.spacingS)
    }
}

struct NewChatPeerRow: View {
    let peer: Peer
    let onTap: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    private var avatarColor: Color {
        PoolUserProfile.availableColors[peer.avatarColorIndex % PoolUserProfile.availableColors.count]
    }

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        Button(action: onTap) {
            HStack(spacing: theme.spacingL) {
                // Avatar with online indicator
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(avatarColor)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Text(String(peer.effectiveDisplayName.prefix(1)).uppercased())
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(theme.textOnAccent)
                        )

                    Circle()
                        .fill(theme.success)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .strokeBorder(theme.background, lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: theme.spacingXS) {
                    Text(peer.effectiveDisplayName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(theme.textPrimary)

                    PoolText("poolchat.status.onlineSingle", fallback: "Online")
                        .font(.system(size: 13))
                        .foregroundColor(theme.success)
                }

                Spacer()

                PoolIcon("chevron-right", size: 14, systemFallback: "chevron.right")
                    .foregroundColor(theme.textTertiary)
            }
            .padding(.horizontal, theme.spacingL)
            .padding(.vertical, theme.spacingS + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PrivateChatRow: View {
    let info: PrivateChatInfo
    let onTap: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    private var avatarColor: Color {
        PoolUserProfile.availableColors[info.avatarColorIndex % PoolUserProfile.availableColors.count]
    }

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        Button(action: onTap) {
            HStack(spacing: theme.spacingL) {
                // Avatar
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(avatarColor)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Text(String(info.peerName.prefix(1)).uppercased())
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(theme.textOnAccent)
                        )

                    if info.isOnline {
                        Circle()
                            .fill(theme.success)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .strokeBorder(theme.background, lineWidth: 2)
                            )
                            .offset(x: 2, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: theme.spacingXS) {
                    HStack {
                        Text(info.peerName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(theme.textPrimary)

                        Spacer()

                        if let time = info.lastMessageTime {
                            Text(formatTime(time))
                                .font(.system(size: 12))
                                .foregroundColor(theme.textSecondary)
                        }
                    }

                    HStack {
                        if let lastMessage = info.lastMessage {
                            Text(lastMessage)
                                .font(.system(size: 14))
                                .foregroundColor(theme.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if info.unreadCount > 0 {
                            Text("\(info.unreadCount)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(theme.textOnAccent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.accent))
                        }
                    }
                }
            }
            .padding(.horizontal, theme.spacingL)
            .padding(.vertical, theme.spacingS + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return poolString("poolchat.time.yesterday", fallback: "Yesterday")
        } else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

struct PrivateChatEmptyView: View {
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: theme.spacingL) {
            Spacer()

            PoolIcon("user-group", size: 46, systemFallback: "person.2.fill")
                .foregroundColor(theme.textTertiary)

            PoolText("poolchat.private.emptyTitle", fallback: "No Private Chats")
                .font(theme.fontHeading)
                .foregroundColor(theme.textSecondary)

            PoolText("poolchat.private.emptyMessage", fallback: "Start a private conversation with a connected pool member")
                .font(theme.fontBody)
                .foregroundColor(theme.textTertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(theme.background)
    }
}

// MARK: - Group Chat List View (WhatsApp-style)

struct GroupChatListView: View {
    let groupInfos: [GroupChatInfo]
    let currentHostPeerID: String?
    let onSelectGroup: (GroupChatInfo) -> Void
    let onDeleteGroup: (GroupChatInfo) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if groupInfos.isEmpty {
                    GroupChatEmptyView()
                } else {
                    // Current/connected group section
                    if let currentGroup = groupInfos.first(where: { $0.id == currentHostPeerID }) {
                        SectionHeader(titleKey: "poolchat.group.current", titleFallback: "Current Group")

                        GroupChatRow(
                            info: currentGroup,
                            isCurrentGroup: true,
                            onTap: { onSelectGroup(currentGroup) }
                        )
                        Divider().padding(.leading, 66)
                    }

                    // Past groups section
                    let pastGroups = groupInfos.filter { $0.id != currentHostPeerID }
                    if !pastGroups.isEmpty {
                        SectionHeader(titleKey: "poolchat.group.past", titleFallback: "Past Groups")

                        ForEach(pastGroups) { group in
                            GroupChatRow(
                                info: group,
                                isCurrentGroup: false,
                                onTap: { onSelectGroup(group) }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    onDeleteGroup(group)
                                } label: {
                                    poolMenuLabel("common.delete", fallback: "Delete", icon: "trash", systemFallback: "trash")
                                }
                            }

                            if group.id != pastGroups.last?.id {
                                Divider().padding(.leading, 66)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

struct GroupChatRow: View {
    let info: GroupChatInfo
    let isCurrentGroup: Bool
    let onTap: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    private var avatarColor: Color {
        PoolUserProfile.availableColors[info.avatarColorIndex % PoolUserProfile.availableColors.count]
    }

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        Button(action: onTap) {
            HStack(spacing: theme.spacingL) {
                // Group Avatar
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(avatarColor)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Group {
                                if let emoji = info.avatarEmoji {
                                    Text(emoji)
                                        .font(.system(size: 22))
                                } else {
                                    PoolIcon("users", size: 18, systemFallback: "person.3.fill")
                                        .foregroundColor(theme.textOnAccent)
                                }
                            }
                        )

                    // Online indicator for current group
                    if info.isHostConnected {
                        Circle()
                            .fill(theme.success)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .strokeBorder(theme.background, lineWidth: 2)
                            )
                            .offset(x: 2, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: theme.spacingXS) {
                    HStack {
                        Text(info.hostDisplayName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(theme.textPrimary)

                        if isCurrentGroup {
                            PoolText("poolchat.group.connected", fallback: "CONNECTED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(theme.textOnAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.success))
                        }

                        Spacer()

                        if let time = info.lastMessageTime {
                            Text(formatTime(time))
                                .font(.system(size: 12))
                                .foregroundColor(theme.textSecondary)
                        }
                    }

                    HStack {
                        if let lastMessage = info.lastMessage {
                            Text(lastMessage)
                                .font(.system(size: 14))
                                .foregroundColor(theme.textSecondary)
                                .lineLimit(1)
                        } else if !info.isHostConnected {
                            PoolText("poolchat.group.hostNotConnected", fallback: "Host not connected")
                                .font(.system(size: 14))
                                .foregroundColor(theme.textTertiary)
                                .italic()
                        } else {
                            PoolText("poolchat.group.noMessages", fallback: "No messages yet")
                                .font(.system(size: 14))
                                .foregroundColor(theme.textTertiary)
                        }

                        Spacer()

                        if info.unreadCount > 0 {
                            Text("\(info.unreadCount)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(theme.textOnAccent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.accent))
                        }
                    }
                }
            }
            .padding(.horizontal, theme.spacingL)
            .padding(.vertical, theme.spacingS + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return poolString("poolchat.time.yesterday", fallback: "Yesterday")
        } else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

struct GroupChatEmptyView: View {
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: theme.spacingL) {
            Spacer()

            PoolIcon("users", size: 46, systemFallback: "person.3.fill")
                .foregroundColor(theme.textTertiary)

            PoolText("poolchat.group.emptyTitle", fallback: "No Group Chats")
                .font(theme.fontHeading)
                .foregroundColor(theme.textSecondary)

            PoolText("poolchat.group.emptyMessage", fallback: "Join or host a Connection Pool to start a group chat")
                .font(theme.fontBody)
                .foregroundColor(theme.textTertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(theme.background)
    }
}

// MARK: - Group Chat Header

struct GroupChatHeader: View {
    let group: GroupChatInfo
    let onBack: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    private var avatarColor: Color {
        PoolUserProfile.availableColors[group.avatarColorIndex % PoolUserProfile.availableColors.count]
    }

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingM) {
            // Back button
            Button(action: onBack) {
                PoolIcon("chevron-left", size: 16, systemFallback: "chevron.left")
                    .foregroundColor(theme.accent)
            }

            // Avatar
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Group {
                            if let emoji = group.avatarEmoji {
                                Text(emoji)
                                    .font(.system(size: 16))
                            } else {
                                PoolIcon("users", size: 14, systemFallback: "person.3.fill")
                                    .foregroundColor(theme.textOnAccent)
                            }
                        }
                    )

                // Online indicator
                if group.isHostConnected {
                    Circle()
                        .fill(theme.success)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .strokeBorder(theme.surface, lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }
            }

            // Name and status
            VStack(alignment: .leading, spacing: 2) {
                Text(group.hostDisplayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.textPrimary)

                Text(group.isHostConnected
                     ? poolString("poolchat.status.connected", fallback: "Connected")
                     : poolString("poolchat.group.hostNotConnected", fallback: "Host not connected"))
                    .font(.system(size: 12))
                    .foregroundColor(group.isHostConnected ? theme.success : theme.textSecondary)
            }

            Spacer()

            // Encryption indicator
            HStack(spacing: theme.spacingXS) {
                PoolIcon("lock", size: 10, systemFallback: "lock.fill")
                PoolText("poolchat.encrypted", fallback: "Encrypted")
                    .font(.system(size: 10))
            }
            .foregroundColor(theme.success)
            .padding(.horizontal, theme.spacingS)
            .padding(.vertical, theme.spacingXS)
            .background(theme.success.opacity(0.15))
            .clipShape(Capsule())
        }
        .padding(.horizontal, theme.spacingM)
        .padding(.vertical, theme.spacingS + 2)
        .background(theme.surface)
    }
}

// MARK: - Not Connected View

struct NotConnectedView: View {
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: theme.spacingXL) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.15))
                    .frame(width: 80, height: 80)

                PoolIcon("comments", size: 36, systemFallback: "bubble.left.and.bubble.right.fill")
                    .foregroundColor(theme.accent)
            }

            VStack(spacing: theme.spacingS) {
                PoolText("poolchat.notConnected.title", fallback: "Not Connected")
                    .font(theme.fontHeading)
                    .foregroundColor(theme.textPrimary)

                PoolText("poolchat.notConnected.subtitle", fallback: "Join or host a Connection Pool to start chatting")
                    .font(theme.fontBody)
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // Instructions card
            VStack(spacing: 0) {
                InstructionRow(
                    icon: "tower-broadcast",
                    systemFallback: "antenna.radiowaves.left.and.right",
                    tint: theme.accent,
                    titleKey: "poolchat.notConnected.step1Title",
                    titleFallback: "Open Connection Pool",
                    descKey: "poolchat.notConnected.step1Desc",
                    descFallback: "Launch the Connection Pool app",
                    showDivider: true
                )

                InstructionRow(
                    icon: "user-group",
                    systemFallback: "person.2.fill",
                    tint: theme.success,
                    titleKey: "poolchat.notConnected.step2Title",
                    titleFallback: "Host or Join",
                    descKey: "poolchat.notConnected.step2Desc",
                    descFallback: "Create a pool or join an existing one",
                    showDivider: true
                )

                InstructionRow(
                    icon: "message",
                    systemFallback: "message.fill",
                    tint: theme.info,
                    titleKey: "poolchat.notConnected.step3Title",
                    titleFallback: "Start Chatting",
                    descKey: "poolchat.notConnected.step3Desc",
                    descFallback: "Send messages, photos, and voice notes",
                    showDivider: false
                )
            }
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
            .padding(.horizontal, theme.spacingL)

            Spacer()

            // Security hint
            HStack(spacing: theme.spacingXS + 2) {
                PoolIcon("shield-halved", size: 12, systemFallback: "lock.shield.fill")
                    .foregroundColor(theme.success)

                PoolText("poolchat.notConnected.encrypted", fallback: "End-to-end encrypted")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.textSecondary)
            }
            .padding(.bottom, theme.spacingS)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

struct InstructionRow: View {
    let icon: String
    let systemFallback: String
    let tint: Color
    let titleKey: String
    let titleFallback: String
    let descKey: String
    let descFallback: String
    let showDivider: Bool

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: 0) {
            HStack(spacing: theme.spacingM) {
                PoolIcon(icon, size: 18, systemFallback: systemFallback)
                    .foregroundColor(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    PoolText(titleKey, fallback: titleFallback)
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.textPrimary)

                    PoolText(descKey, fallback: descFallback)
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, theme.spacingL)
            .padding(.vertical, theme.spacingM)

            if showDivider {
                Rectangle()
                    .fill(theme.separator)
                    .frame(height: 1)
                    .padding(.leading, 66)
            }
        }
    }
}

// MARK: - Connection Status Bar (Compact)

struct ConnectionStatusBar: View {
    let connectedPeers: [Peer]
    let isConnected: Bool
    let isHost: Bool
    let onClearHistory: () -> Void
    var onGroupVoiceCall: (() -> Void)?
    var onGroupVideoCall: (() -> Void)?

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingS) {
            // Status indicator
            Circle()
                .fill(isConnected ? theme.success : theme.warning)
                .frame(width: 8, height: 8)

            Text(connectionStatus)
                .font(theme.fontCaption)
                .foregroundColor(isConnected ? theme.textSecondary : theme.warning)

            Spacer()

            // Participants indicator
            if isConnected && connectedPeers.count > 0 {
                HStack(spacing: -6) {
                    ForEach(Array(connectedPeers.prefix(3).enumerated()), id: \.element.id) { index, peer in
                        Circle()
                            .fill(avatarColor(for: peer.avatarColorIndex, theme: theme))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Text(String(peer.effectiveDisplayName.prefix(1)).uppercased())
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(theme.textOnAccent)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(theme.surface, lineWidth: 1.5)
                            )
                            .zIndex(Double(3 - index))
                    }
                    if connectedPeers.count > 3 {
                        Circle()
                            .fill(theme.textTertiary)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Text("+\(connectedPeers.count - 3)")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(theme.textOnAccent)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(theme.surface, lineWidth: 1.5)
                            )
                    }
                }

                Text(poolString("poolchat.status.online", fallback: "\(connectedPeers.count) online", args: ["count": "\(connectedPeers.count)"]))
                    .font(theme.fontCaption)
                    .foregroundColor(theme.textSecondary)

                // Group call buttons
                if let onGroupVoiceCall {
                    Button(action: onGroupVoiceCall) {
                        PoolIcon("phone", size: 14, systemFallback: "phone.fill")
                            .foregroundColor(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(poolString("poolchat.call.groupVoice", fallback: "Start group voice call"))
                }
                if let onGroupVideoCall {
                    Button(action: onGroupVideoCall) {
                        PoolIcon("video", size: 14, systemFallback: "video.fill")
                            .foregroundColor(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(poolString("poolchat.call.groupVideo", fallback: "Start group video call"))
                }
            }

            // Options menu (only when connected)
            if isConnected {
                Menu {
                    Button(role: .destructive) {
                        onClearHistory()
                    } label: {
                        poolMenuLabel(
                            isHost ? "poolchat.status.clearForAll" : "poolchat.status.clearMyView",
                            fallback: isHost ? "Clear History for All" : "Clear My View",
                            icon: "trash",
                            systemFallback: "trash"
                        )
                    }
                } label: {
                    PoolIcon("ellipsis", size: 18, systemFallback: "ellipsis.circle")
                        .foregroundColor(theme.textSecondary)
                }
                .accessibilityLabel(poolString("common.more", fallback: "More"))
            }
        }
        .padding(.horizontal, theme.spacingM)
        .padding(.vertical, theme.spacingXS + 2)
        .background(theme.surface)
    }

    private var connectionStatus: String {
        if !isConnected {
            return poolString("poolchat.status.notConnected", fallback: "Not connected to pool")
        }
        // When isConnected is true, the user can send and receive messages
        // Show "Connected" status since chat functionality is working
        return poolString("poolchat.status.connected", fallback: "Connected")
    }

    private func avatarColor(for index: Int, theme: PoolThemeSnapshot) -> Color {
        // Themed avatar palette (no purple); indexed by the peer's stable avatar index.
        let colors: [Color] = [
            theme.accent, theme.success, theme.warning,
            theme.info, theme.privacyAccent, theme.danger
        ]
        return colors[index % colors.count]
    }
}

// MARK: - Messages List View

struct MessagesListView: View {
    let messages: [RichChatMessage]
    let playingVoiceMessageID: UUID?
    let voicePlaybackProgress: Double
    let localPeerID: String
    let showReactionPickerForMessageID: UUID?
    let onPlayVoice: (RichChatMessage) -> Void
    let onStopVoice: () -> Void
    let onReply: (RichChatMessage) -> Void
    let onShowReactionPicker: (UUID) -> Void
    let onHideReactionPicker: () -> Void
    let onToggleReaction: (String, UUID) -> Void
    let onPollVote: (UUID, String) -> Void

    /// Whether auto-scroll is active. Disabled when user scrolls up manually.
    @State private var isAutoScrollEnabled = true

    /// Viewport height for scroll position calculation.
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        Group {
            if messages.isEmpty {
                EmptyMessagesView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    isPlayingVoice: playingVoiceMessageID == message.id,
                                    voicePlaybackProgress: playingVoiceMessageID == message.id ? voicePlaybackProgress : 0,
                                    localPeerID: localPeerID,
                                    showReactionPicker: showReactionPickerForMessageID == message.id,
                                    onPlayVoice: { onPlayVoice(message) },
                                    onStopVoice: onStopVoice,
                                    onReply: { onReply(message) },
                                    onShowReactionPicker: { onShowReactionPicker(message.id) },
                                    onHideReactionPicker: onHideReactionPicker,
                                    onToggleReaction: { emoji in onToggleReaction(emoji, message.id) },
                                    onPollVote: { option in onPollVote(message.id, option) }
                                )
                                .id(message.id)
                            }

                            // Invisible anchor at the very bottom for reliable scrolling
                            Color.clear
                                .frame(height: 1)
                                .id("bottom_anchor")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ScrollOffsetKey.self,
                                    value: geo.frame(in: .named("chatScroll")).maxY
                                )
                            }
                        )
                    }
                    .coordinateSpace(name: "chatScroll")
                    .background(
                        GeometryReader { viewport in
                            Color.clear.preference(
                                key: ViewportHeightKey.self,
                                value: viewport.size.height
                            )
                        }
                    )
                    .onPreferenceChange(ViewportHeightKey.self) { height in
                        viewportHeight = height
                    }
                    .onPreferenceChange(ScrollOffsetKey.self) { maxY in
                        // If the bottom of the content is near the viewport bottom,
                        // the user is at the bottom — re-enable auto-scroll.
                        // If they scrolled up significantly, disable it.
                        let threshold: CGFloat = 80
                        let isNearBottom = maxY < viewportHeight + threshold
                        if isNearBottom && !isAutoScrollEnabled {
                            isAutoScrollEnabled = true
                        } else if !isNearBottom && isAutoScrollEnabled {
                            isAutoScrollEnabled = false
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear {
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if isAutoScrollEnabled {
                            scrollToBottom(proxy: proxy, animated: true)
                        }
                    }
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom_anchor", anchor: .bottom)
        }
    }
}

/// Preference key to track the scroll content's bottom edge position.
private struct ScrollOffsetKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Preference key to track the viewport height.
private struct ViewportHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Empty Messages View

struct EmptyMessagesView: View {
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: theme.spacingL) {
            Spacer()

            PoolIcon("message", size: 46, systemFallback: "text.bubble")
                .foregroundColor(theme.textTertiary)

            PoolText("poolchat.messages.emptyTitle", fallback: "No messages yet")
                .font(theme.fontHeading)
                .foregroundColor(theme.textSecondary)

            PoolText("poolchat.messages.emptyMessage", fallback: "Be the first to say hello!")
                .font(theme.fontBody)
                .foregroundColor(theme.textTertiary)

            Spacer()
        }
    }
}

// MARK: - Message Bubble View

struct MessageBubbleView: View {
    let message: RichChatMessage
    let isPlayingVoice: Bool
    let voicePlaybackProgress: Double
    let localPeerID: String
    let showReactionPicker: Bool
    let onPlayVoice: () -> Void
    let onStopVoice: () -> Void
    let onReply: () -> Void
    let onShowReactionPicker: () -> Void
    let onHideReactionPicker: () -> Void
    let onToggleReaction: (String) -> Void
    let onPollVote: (String) -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    private let avatarSize: CGFloat = 32
    private let bubbleSpacing: CGFloat = 8

    var body: some View {
        // System messages are centered, handle separately
        if message.contentType == .system {
            SystemMessageView(text: message.text ?? "")
        } else if message.isFromLocalUser {
            // Outgoing message - right aligned, no avatar
            outgoingMessageLayout
        } else {
            // Incoming message - left aligned with avatar
            incomingMessageLayout
        }
    }

    // MARK: - Outgoing Message (Right Side)

    @ViewBuilder
    private var outgoingMessageLayout: some View {
        HStack(alignment: .bottom, spacing: bubbleSpacing) {
            Spacer(minLength: 60)

            VStack(alignment: .trailing, spacing: 2) {
                // Reply preview (if replying to someone)
                if let reply = message.replyTo {
                    ReplyPreviewBubble(
                        senderName: reply.senderName,
                        previewText: reply.previewText,
                        isFromLocalUser: true
                    )
                }

                // Message content with context menu
                messageContent
                    .contextMenu { messageContextMenu }

                // Reaction picker
                if showReactionPicker {
                    QuickReactionPicker(
                        onSelect: onToggleReaction,
                        onDismiss: onHideReactionPicker
                    )
                    .transition(.scale.combined(with: .opacity))
                }

                // Reactions display
                if !message.reactions.isEmpty {
                    ReactionsDisplayView(
                        reactions: message.sortedReactions,
                        localPeerID: localPeerID,
                        onToggleReaction: onToggleReaction
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showReactionPicker)
    }

    // MARK: - Incoming Message (Left Side with Avatar)

    @ViewBuilder
    private var incomingMessageLayout: some View {
        HStack(alignment: .top, spacing: bubbleSpacing) {
            // Avatar - aligned to top of message bubble
            avatarView

            VStack(alignment: .leading, spacing: 2) {
                // Reply preview (if replying to someone)
                if let reply = message.replyTo {
                    ReplyPreviewBubble(
                        senderName: reply.senderName,
                        previewText: reply.previewText,
                        isFromLocalUser: false
                    )
                }

                // Message content with context menu
                messageContent
                    .contextMenu { messageContextMenu }

                // Sender name and timestamp below bubble
                HStack(spacing: 4) {
                    Text(message.senderName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(design.snapshot(dark: scheme == .dark).textSecondary)

                    Text("*")
                        .font(.system(size: 8))
                        .foregroundColor(design.snapshot(dark: scheme == .dark).textTertiary)

                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundColor(design.snapshot(dark: scheme == .dark).textTertiary)
                }
                .padding(.leading, 4)

                // Reaction picker
                if showReactionPicker {
                    QuickReactionPicker(
                        onSelect: onToggleReaction,
                        onDismiss: onHideReactionPicker
                    )
                    .transition(.scale.combined(with: .opacity))
                }

                // Reactions display
                if !message.reactions.isEmpty {
                    ReactionsDisplayView(
                        reactions: message.sortedReactions,
                        localPeerID: localPeerID,
                        onToggleReaction: onToggleReaction
                    )
                }
            }

            Spacer(minLength: 60)
        }
        .animation(.easeInOut(duration: 0.2), value: showReactionPicker)
    }

    // MARK: - Avatar View

    @ViewBuilder
    private var avatarView: some View {
        Circle()
            .fill(avatarColor)
            .frame(width: avatarSize, height: avatarSize)
            .overlay(
                Group {
                    if let emoji = message.avatarEmoji {
                        Text(emoji)
                            .font(.system(size: 16))
                    } else {
                        Text(String(message.senderName.prefix(1)).uppercased())
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(design.snapshot(dark: scheme == .dark).textOnAccent)
                    }
                }
            )
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var messageContextMenu: some View {
        if message.contentType != .poll {
            Button {
                onReply()
            } label: {
                poolMenuLabel("poolchat.message.reply", fallback: "Reply", icon: "reply", systemFallback: "arrowshape.turn.up.left")
            }

            Button {
                onShowReactionPicker()
            } label: {
                poolMenuLabel("poolchat.message.addReaction", fallback: "Add Reaction", icon: "face-smile", systemFallback: "face.smiling")
            }

            if let text = message.text {
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = text
                    #elseif canImport(AppKit)
                    NSPasteboard.general.setString(text, forType: .string)
                    #endif
                } label: {
                    poolMenuLabel("common.copy", fallback: "Copy", icon: "copy", systemFallback: "doc.on.doc")
                }
            }
        }
    }

    // MARK: - Message Content

    @ViewBuilder
    private var messageContent: some View {
        switch message.contentType {
        case .text:
            TextMessageBubble(
                text: message.text ?? "",
                isFromLocalUser: message.isFromLocalUser,
                timestamp: message.timestamp,
                mentions: message.mentions,
                localPeerID: localPeerID,
                showTimestamp: message.isFromLocalUser // Only show inline timestamp for outgoing
            )

        case .image:
            ImageMessageBubble(
                imageData: message.imageData,
                isFromLocalUser: message.isFromLocalUser,
                timestamp: message.timestamp,
                showTimestamp: message.isFromLocalUser
            )

        case .voice:
            VoiceMessageBubble(
                duration: message.voiceDuration ?? 0,
                isFromLocalUser: message.isFromLocalUser,
                isPlaying: isPlayingVoice,
                progress: voicePlaybackProgress,
                timestamp: message.timestamp,
                showTimestamp: message.isFromLocalUser,
                onPlayPause: { isPlayingVoice ? onStopVoice() : onPlayVoice() }
            )

        case .emoji:
            EmojiMessageBubble(
                emoji: message.emoji ?? "",
                isFromLocalUser: message.isFromLocalUser,
                timestamp: message.timestamp,
                showTimestamp: message.isFromLocalUser
            )

        case .system:
            EmptyView() // Handled at top level

        case .poll:
            if let pollData = message.pollData {
                PollMessageBubble(
                    pollData: pollData,
                    isFromLocalUser: message.isFromLocalUser,
                    localPeerID: localPeerID,
                    timestamp: message.timestamp,
                    onVote: onPollVote
                )
            }
        }
    }

    private var avatarColor: Color {
        PoolUserProfile.availableColors[message.avatarColorIndex % PoolUserProfile.availableColors.count]
    }
}

// MARK: - Reply Preview Bubble

struct ReplyPreviewBubble: View {
    let senderName: String
    let previewText: String
    let isFromLocalUser: Bool

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingS) {
            Rectangle()
                .fill(isFromLocalUser ? theme.textOnAccent.opacity(0.5) : theme.accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(isFromLocalUser ? theme.textOnAccent.opacity(0.9) : theme.accent)

                Text(previewText)
                    .font(.caption)
                    .foregroundColor(isFromLocalUser ? theme.textOnAccent.opacity(0.7) : theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, theme.spacingS + 2)
        .padding(.vertical, theme.spacingXS + 2)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                .fill(isFromLocalUser ? theme.accent.opacity(0.3) : theme.surfaceSecondary)
        )
    }
}

// MARK: - Quick Reaction Picker

struct QuickReactionPicker: View {
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingS) {
            ForEach(RichChatMessage.quickReactions, id: \.self) { emoji in
                Button {
                    onSelect(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, theme.spacingM)
        .padding(.vertical, theme.spacingS)
        .background(
            Capsule()
                .fill(theme.surfaceElevated)
                .shadow(color: theme.shadow.opacity(0.1), radius: 8, y: 2)
        )
    }
}

// MARK: - Reactions Display View

struct ReactionsDisplayView: View {
    let reactions: [(emoji: String, peerIDs: [String])]
    let localPeerID: String
    let onToggleReaction: (String) -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingXS + 2) {
            ForEach(reactions, id: \.emoji) { reaction in
                Button {
                    onToggleReaction(reaction.emoji)
                } label: {
                    HStack(spacing: theme.spacingXS) {
                        Text(reaction.emoji)
                            .font(.system(size: 14))

                        if reaction.peerIDs.count > 1 {
                            Text("\(reaction.peerIDs.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, theme.spacingS)
                    .padding(.vertical, theme.spacingXS)
                    .background(
                        Capsule()
                            .fill(reaction.peerIDs.contains(localPeerID)
                                  ? theme.accent.opacity(0.2)
                                  : theme.surfaceSecondary)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                reaction.peerIDs.contains(localPeerID)
                                    ? theme.accent.opacity(0.5)
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Poll Message Bubble

struct PollMessageBubble: View {
    let pollData: PollData
    let isFromLocalUser: Bool
    let localPeerID: String
    let timestamp: Date
    let onVote: (String) -> Void

    private var votedOption: String? {
        pollData.votedOption(for: localPeerID)
    }

    /// Whether user can still vote (either hasn't voted, or vote change is allowed)
    private var canVote: Bool {
        pollData.canVote(peerID: localPeerID)
    }

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: theme.spacingM) {
            // Poll header
            HStack(spacing: theme.spacingS) {
                PoolIcon("chart-bar", size: 14, systemFallback: "chart.bar.fill")
                    .foregroundColor(theme.accent)

                PoolText("poolchat.poll.label", fallback: "Poll")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(theme.accent)

                Spacer()

                Text(pollData.totalVotes == 1
                     ? poolString("poolchat.poll.voteCountOne", fallback: "1 vote", args: ["count": "1"])
                     : poolString("poolchat.poll.voteCount", fallback: "\(pollData.totalVotes) votes", args: ["count": "\(pollData.totalVotes)"]))
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }

            // Question
            Text(pollData.question)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textPrimary)

            // Options
            VStack(spacing: theme.spacingS) {
                ForEach(pollData.options, id: \.self) { option in
                    PollOptionRow(
                        option: option,
                        voteCount: pollData.voteCount(for: option),
                        percentage: pollData.votePercentage(for: option),
                        isSelected: votedOption == option,
                        hasVoted: votedOption != nil,
                        canChangeVote: canVote,
                        onVote: { onVote(option) }
                    )
                }
            }

            // ISSUE 5: Show vote change status
            HStack {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(theme.textTertiary)

                Spacer()

                if votedOption != nil && !pollData.allowVoteChange {
                    HStack(spacing: theme.spacingXS) {
                        PoolIcon("lock", size: 9, systemFallback: "lock.fill")
                        PoolText("poolchat.poll.locked", fallback: "Vote locked")
                            .font(.caption2)
                    }
                    .foregroundColor(theme.textSecondary)
                }
            }
        }
        .padding(theme.spacingL)
        .frame(maxWidth: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous)
                .fill(theme.surfaceSecondary)
        )
    }
}

struct PollOptionRow: View {
    let option: String
    let voteCount: Int
    let percentage: Double
    let isSelected: Bool
    let hasVoted: Bool
    let canChangeVote: Bool  // ISSUE 5: Whether the user can change their vote
    let onVote: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        Button(action: onVote) {
            ZStack(alignment: .leading) {
                // Progress bar background
                GeometryReader { geometry in
                    if hasVoted {
                        RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                            .fill(isSelected ? theme.accent.opacity(0.3) : theme.textTertiary.opacity(0.15))
                            .frame(width: geometry.size.width * percentage)
                    }
                }

                HStack {
                    // Option text
                    Text(option)
                        .font(.subheadline)
                        .foregroundColor(theme.textPrimary)

                    Spacer()

                    // Vote indicator / percentage
                    if hasVoted {
                        HStack(spacing: theme.spacingXS) {
                            if isSelected {
                                PoolIcon("circle-check", size: 14, systemFallback: "checkmark.circle.fill")
                                    .foregroundColor(theme.accent)
                            }

                            Text("\(Int(percentage * 100))%")
                                .font(.caption.weight(.medium))
                                .foregroundColor(theme.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, theme.spacingM)
                .padding(.vertical, theme.spacingS + 2)
            }
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent : theme.border,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            // ISSUE 5: Reduce opacity when vote is locked
            .opacity(hasVoted && !canChangeVote && !isSelected ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(hasVoted && !canChangeVote) // ISSUE 5: Disable if already voted and can't change
    }
}

// MARK: - Text Message Bubble

struct TextMessageBubble: View {
    let text: String
    let isFromLocalUser: Bool
    let timestamp: Date
    var mentions: [String] = []
    var localPeerID: String = ""
    var showTimestamp: Bool = true

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(alignment: isFromLocalUser ? .trailing : .leading, spacing: 2) {
            TextWithMentions(
                text: text,
                mentions: mentions,
                isFromLocalUser: isFromLocalUser,
                localPeerID: localPeerID
            )
            .font(.body)
            .padding(.horizontal, theme.spacingM)
            .padding(.vertical, theme.spacingS)
            .background(
                BubbleShape(isFromLocalUser: isFromLocalUser)
                    .fill(isFromLocalUser ? theme.accent : theme.surfaceSecondary)
            )

            if showTimestamp {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Bubble Shape (Simple rounded rectangle - clean iMessage style)

struct BubbleShape: Shape {
    let isFromLocalUser: Bool

    func path(in rect: CGRect) -> Path {
        // Simple rounded rectangle without tail - cleaner appearance like modern iMessage
        let cornerRadius: CGFloat = 16
        return Path(roundedRect: rect, cornerRadius: cornerRadius)
    }
}

// MARK: - Image Message Bubble

struct ImageMessageBubble: View {
    let imageData: Data?
    let isFromLocalUser: Bool
    let timestamp: Date
    var showTimestamp: Bool = true

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(alignment: isFromLocalUser ? .trailing : .leading, spacing: 2) {
            if let data = imageData, let image = platformImage(from: data) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        // Timestamp overlay on image (always shown for context)
                        Text(timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(0.5))
                            )
                            .padding(6)
                    }
            } else {
                RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous)
                    .fill(theme.surfaceSecondary)
                    .frame(width: 150, height: 150)
                    .overlay(
                        PoolIcon("image", size: 32, systemFallback: "photo")
                            .foregroundColor(theme.textTertiary)
                    )
            }

            if showTimestamp && imageData == nil {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Voice Message Bubble

struct VoiceMessageBubble: View {
    let duration: TimeInterval
    let isFromLocalUser: Bool
    let isPlaying: Bool
    let progress: Double
    let timestamp: Date
    var showTimestamp: Bool = true
    let onPlayPause: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(alignment: isFromLocalUser ? .trailing : .leading, spacing: 2) {
            HStack(spacing: theme.spacingS + 2) {
                Button(action: onPlayPause) {
                    PoolIcon(isPlaying ? "pause" : "play", size: 14, systemFallback: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(isFromLocalUser ? theme.textOnAccent : theme.accent)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(isFromLocalUser ? theme.textOnAccent.opacity(0.2) : theme.accent.opacity(0.15))
                        )
                }

                VStack(alignment: .leading, spacing: theme.spacingXS) {
                    // Waveform
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            WaveformView()
                                .foregroundColor(isFromLocalUser ? theme.textOnAccent.opacity(0.4) : theme.textSecondary.opacity(0.4))

                            WaveformView()
                                .foregroundColor(isFromLocalUser ? theme.textOnAccent : theme.accent)
                                .mask(
                                    Rectangle()
                                        .frame(width: geometry.size.width * progress)
                                )
                        }
                    }
                    .frame(height: 20)

                    Text(duration.formattedDuration)
                        .font(.system(size: 11))
                        .foregroundColor(isFromLocalUser ? theme.textOnAccent.opacity(0.8) : theme.textSecondary)
                }
                .frame(width: 100)
            }
            .padding(.horizontal, theme.spacingS + 2)
            .padding(.vertical, theme.spacingS)
            .background(
                BubbleShape(isFromLocalUser: isFromLocalUser)
                    .fill(isFromLocalUser ? theme.accent : theme.surfaceSecondary)
            )

            if showTimestamp {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<18, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .frame(width: 3, height: randomHeight(for: index))
            }
        }
    }

    private func randomHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [8, 14, 10, 18, 12, 20, 9, 16, 11, 22, 10, 17, 8, 14, 12, 19, 9, 15]
        return heights[index % heights.count]
    }
}

// MARK: - Emoji Message Bubble

struct EmojiMessageBubble: View {
    let emoji: String
    let isFromLocalUser: Bool
    let timestamp: Date
    var showTimestamp: Bool = true

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(alignment: isFromLocalUser ? .trailing : .leading, spacing: 2) {
            Text(emoji)
                .font(.system(size: 48))

            if showTimestamp {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - System Message View

struct SystemMessageView: View {
    let text: String

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        Text(text)
            .font(.caption)
            .foregroundColor(theme.textSecondary)
            .padding(.horizontal, theme.spacingL)
            .padding(.vertical, theme.spacingXS + 3)
            .background(
                Capsule()
                    .fill(theme.surfaceSecondary)
            )
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Chat Input Bar

struct ChatInputBar: View {
    @Binding var text: String
    @Binding var showEmojiPicker: Bool
    @Binding var showImagePicker: Bool
    @Binding var selectedPhotoItem: PhotosPickerItem?
    let replyingToMessage: RichChatMessage?
    let isGroupChat: Bool
    let onSendText: () -> Void
    let onStartVoiceRecording: () -> Void
    let onCancelReply: () -> Void
    let onCreatePoll: () -> Void
    let isConnected: Bool

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: 0) {
            // Reply preview bar
            if let replyMessage = replyingToMessage {
                ReplyInputPreview(
                    senderName: replyMessage.senderName,
                    previewText: replyMessage.previewText,
                    onCancel: onCancelReply
                )
            }

            HStack(spacing: theme.spacingS + 2) {
                // Attachment button (photo picker)
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    // `PhotosPicker`'s label builder is `@Sendable`, hence nonisolated;
                    // `PoolDeferredLabel` moves construction into a main-actor `body`.
                    PoolDeferredLabel {
                        PoolIcon("image", size: 20, systemFallback: "photo.fill")
                            .foregroundColor(isConnected ? theme.textSecondary : theme.textTertiary)
                            .frame(width: 36, height: 36)
                    }
                }
                .disabled(!isConnected)

                // Poll button (group chat only)
                if isGroupChat {
                    Button(action: onCreatePoll) {
                        PoolIcon("chart-bar", size: 20, systemFallback: "chart.bar.fill")
                            .foregroundColor(isConnected ? theme.textSecondary : theme.textTertiary)
                            .frame(width: 36, height: 36)
                    }
                    .disabled(!isConnected)
                }

                // Emoji button
                Button(action: {
                    withAnimation { showEmojiPicker.toggle() }
                }) {
                    PoolIcon(showEmojiPicker ? "keyboard" : "face-smile", size: 20, systemFallback: showEmojiPicker ? "keyboard" : "face.smiling")
                        .foregroundColor(isConnected ? theme.textSecondary : theme.textTertiary)
                        .frame(width: 36, height: 36)
                }
                .disabled(!isConnected)

                // Text field
                TextField(poolString("poolchat.input.message", fallback: "Message"), text: $text)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, theme.spacingL)
                    .padding(.vertical, theme.spacingS + 2)
                    .background(
                        RoundedRectangle(cornerRadius: theme.radiusLarge + 6, style: .continuous)
                            .fill(theme.surfaceSecondary)
                    )
                    .disabled(!isConnected)

                // Send or Voice button
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Voice record button
                    Button(action: onStartVoiceRecording) {
                        PoolIcon("microphone", size: 18, systemFallback: "mic.fill")
                            .foregroundColor(theme.textOnAccent)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle()
                                    .fill(isConnected ? theme.accent : theme.textTertiary)
                            )
                    }
                    .disabled(!isConnected)
                } else {
                    // Send button
                    Button(action: onSendText) {
                        PoolIcon("arrow-up", size: 18, weight: .solid, systemFallback: "arrow.up")
                            .foregroundColor(theme.textOnAccent)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle()
                                    .fill(theme.accent)
                            )
                    }
                }
            }
            .padding(.horizontal, theme.spacingM)
            .padding(.vertical, theme.spacingS + 2)
        }
        .background(theme.surface)
    }
}

// MARK: - Reply Input Preview

struct ReplyInputPreview: View {
    let senderName: String
    let previewText: String
    let onCancel: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingM) {
            Rectangle()
                .fill(theme.accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(poolString("poolchat.input.replyingTo", fallback: "Replying to \(senderName)", args: ["name": senderName]))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(theme.accent)

                Text(previewText)
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onCancel) {
                PoolIcon("circle-xmark", size: 20, systemFallback: "xmark.circle.fill")
                    .foregroundColor(theme.textSecondary)
            }
        }
        .padding(.horizontal, theme.spacingM)
        .padding(.vertical, theme.spacingS)
        .background(theme.surfaceSecondary)
    }
}

// MARK: - Poll Creation Sheet

/// Identifiable wrapper for poll options to prevent "index out of range" crashes
/// when using ForEach with Binding on a mutable array
private struct PollOption: Identifiable {
    let id: UUID
    var text: String

    init(text: String = "") {
        self.id = UUID()
        self.text = text
    }
}

struct PollCreationSheet: View {
    @Binding var question: String
    @Binding var options: [String]
    @Binding var allowVoteChange: Bool
    let onAddOption: () -> Void
    let onRemoveOption: (Int) -> Void
    let onCreate: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    // ISSUE 4 FIX: Use identifiable local state to prevent "index out of range" crash
    // The crash occurred because ForEach(options.indices) with $options[index] binding
    // can access stale indices when the array is mutated during TextField editing.
    // Using @State with Identifiable items ensures stable identity during mutations.
    @State private var pollOptions: [PollOption] = []

    private var isValid: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        pollOptions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count >= 2
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(poolString("poolchat.poll.questionPlaceholder", fallback: "Ask a question…"), text: $question)
                } header: {
                    Text(poolString("poolchat.poll.question", fallback: "Question"))
                }

                Section {
                    // ISSUE 4 FIX: Use identifiable items with ForEach to prevent crash
                    ForEach($pollOptions) { $option in
                        HStack {
                            TextField(poolString("poolchat.poll.option", fallback: "Option"), text: $option.text)

                            if pollOptions.count > 2 {
                                Button {
                                    removeOption(option.id)
                                } label: {
                                    PoolIcon("circle-minus", size: 18, systemFallback: "minus.circle.fill")
                                        .foregroundColor(design.snapshot(dark: scheme == .dark).danger)
                                }
                            }
                        }
                    }

                    if pollOptions.count < 6 {
                        Button {
                            addOption()
                        } label: {
                            HStack(spacing: 8) {
                                PoolIcon("circle-plus", size: 16, systemFallback: "plus.circle")
                                PoolText("poolchat.poll.addOption", fallback: "Add Option")
                            }
                        }
                    }
                } header: {
                    Text(poolString("poolchat.poll.options", fallback: "Options"))
                } footer: {
                    Text(poolString("poolchat.poll.optionsFooter", fallback: "Add 2-6 options for voters to choose from"))
                }

                // ISSUE 5: Allow vote change toggle
                Section {
                    Toggle(poolString("poolchat.poll.allowChange", fallback: "Allow changing vote"), isOn: $allowVoteChange)
                } footer: {
                    Text(allowVoteChange
                         ? poolString("poolchat.poll.allowChangeOn", fallback: "Voters can change their vote after voting")
                         : poolString("poolchat.poll.allowChangeOff", fallback: "Voters can only vote once and cannot change their vote"))
                }
            }
            .navigationTitle(poolString("poolchat.poll.create", fallback: "Create Poll"))
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(poolString("common.cancel", fallback: "Cancel"), action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(poolString("poolchat.poll.createButton", fallback: "Create")) {
                        syncOptionsToBinding()
                        onCreate()
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear {
                // Initialize local state from binding
                pollOptions = options.map { PollOption(text: $0) }
                // Ensure we have at least 2 options
                while pollOptions.count < 2 {
                    pollOptions.append(PollOption())
                }
            }
        }
    }

    private func addOption() {
        guard pollOptions.count < 6 else { return }
        pollOptions.append(PollOption())
    }

    private func removeOption(_ id: UUID) {
        guard pollOptions.count > 2 else { return }
        pollOptions.removeAll { $0.id == id }
    }

    private func syncOptionsToBinding() {
        options = pollOptions.map { $0.text }
    }
}

// MARK: - Voice Recording Indicator

struct VoiceRecordingIndicator: View {
    let duration: TimeInterval
    let onCancel: () -> Void
    let onSend: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @State private var pulseAnimation = false

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingL) {
            // Cancel button
            Button(action: onCancel) {
                PoolIcon("xmark", size: 16, systemFallback: "xmark")
                    .foregroundColor(theme.textOnAccent)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(theme.danger)
                    )
            }

            Spacer()

            // Recording indicator
            HStack(spacing: theme.spacingS + 2) {
                Circle()
                    .fill(theme.danger)
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                    .opacity(pulseAnimation ? 0.7 : 1.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulseAnimation)

                Text(duration.formattedDuration)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
            }
            .onAppear { pulseAnimation = true }

            Spacer()

            // Send button
            Button(action: onSend) {
                PoolIcon("arrow-up", size: 18, weight: .solid, systemFallback: "arrow.up")
                    .foregroundColor(theme.textOnAccent)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(theme.accent)
                    )
            }
        }
        .padding(.horizontal, theme.spacingL)
        .padding(.vertical, theme.spacingM)
        .background(theme.surface)
    }
}

// MARK: - Emoji Picker View

struct EmojiPickerView: View {
    @Binding var selectedCategory: EmojiCategory
    let onEmojiSelected: (String) -> Void
    let onEmojiSent: (String) -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: 0) {
            // Category tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.spacingXS + 2) {
                    ForEach(EmojiCategory.allCases) { category in
                        Button(action: {
                            selectedCategory = category
                        }) {
                            // `category.icon` is an SF-Symbol name supplied by the
                            // EmojiCategory model (read-only); rendered directly so
                            // no FA-name mapping table has to be maintained here.
                            Image(systemName: category.icon)
                                .font(.system(size: 18))
                                .foregroundColor(selectedCategory == category ? theme.textOnAccent : theme.textSecondary)
                                .frame(width: 40, height: 40)
                                .background(
                                    selectedCategory == category ?
                                    theme.accent :
                                    Color.clear
                                )
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, theme.spacingM)
            }
            .padding(.vertical, theme.spacingS + 2)

            Divider()

            // Emoji grid
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 10) {
                    ForEach(selectedCategory.emojis, id: \.self) { emoji in
                        Button(action: {
                            onEmojiSelected(emoji)
                        }) {
                            Text(emoji)
                                .font(.system(size: 30))
                        }
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    onEmojiSent(emoji)
                                }
                        )
                    }
                }
                .padding(.horizontal, theme.spacingM)
                .padding(.vertical, theme.spacingS + 2)
            }
            .frame(height: 200)
        }
        .background(theme.surface)
    }
}

// MARK: - Mention Picker View

struct MentionPickerView: View {
    let peers: [MentionInfo]
    let onSelect: (MentionInfo) -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: 0) {
            // Header
            HStack {
                PoolIcon("at", size: 12, systemFallback: "at")
                    .foregroundColor(theme.accent)

                PoolText("poolchat.mention.title", fallback: "Mention someone")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.textSecondary)

                Spacer()
            }
            .padding(.horizontal, theme.spacingM)
            .padding(.vertical, theme.spacingS)

            Divider()

            // Peer list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(peers) { peer in
                        MentionPeerRow(peer: peer, onTap: { onSelect(peer) })

                        if peer.id != peers.last?.id {
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        .shadow(color: theme.shadow.opacity(0.1), radius: 8, y: -2)
        .padding(.horizontal, theme.spacingM)
        .padding(.bottom, theme.spacingXS)
    }
}

struct MentionPeerRow: View {
    let peer: MentionInfo
    let onTap: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    private var avatarColor: Color {
        PoolUserProfile.availableColors[peer.avatarColorIndex % PoolUserProfile.availableColors.count]
    }

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        Button(action: onTap) {
            HStack(spacing: theme.spacingM) {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(String(peer.displayName.prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.textOnAccent)
                    )

                Text(peer.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Text("@\(peer.displayName.replacingOccurrences(of: " ", with: "_"))")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
            }
            .padding(.horizontal, theme.spacingM)
            .padding(.vertical, theme.spacingS)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Text with Highlighted Mentions

struct TextWithMentions: View {
    let text: String
    let mentions: [String]
    let isFromLocalUser: Bool
    let localPeerID: String

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        highlightedText
    }

    private var highlightedText: Text {
        let theme = design.snapshot(dark: scheme == .dark)
        // Body text color: on-accent inside the sender's own bubble, primary otherwise.
        let bodyColor = isFromLocalUser ? theme.textOnAccent : theme.textPrimary
        // Mention accent: keep contrast inside the accent bubble by using on-accent there.
        let mentionColor = isFromLocalUser ? theme.textOnAccent : theme.accent

        // Parse text and highlight @mentions
        var result = Text("")
        let pattern = "@([\\w]+)"
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var lastEnd = 0

        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches {
            // Add text before this match
            if match.range.location > lastEnd {
                let beforeRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
                let beforeText = nsText.substring(with: beforeRange)
                result = result + Text(beforeText)
                    .foregroundColor(bodyColor)
            }

            // Add the mention with highlight
            let mentionText = nsText.substring(with: match.range)
            let isSelfMention = mentions.contains(localPeerID)

            result = result + Text(mentionText)
                .foregroundColor(mentionColor)
                .fontWeight(isSelfMention ? .bold : .medium)
                .underline(isSelfMention)

            lastEnd = match.range.location + match.range.length
        }

        // Add any remaining text
        if lastEnd < nsText.length {
            let remainingRange = NSRange(location: lastEnd, length: nsText.length - lastEnd)
            let remainingText = nsText.substring(with: remainingRange)
            result = result + Text(remainingText)
                .foregroundColor(bodyColor)
        }

        // If no matches, return original text
        if matches.isEmpty {
            return Text(text)
                .foregroundColor(bodyColor)
        }

        return result
    }
}

// MARK: - Preview

// MARK: - Cross-Platform Helpers

private func platformImage(from data: Data) -> Image? {
    #if canImport(UIKit)
    guard let uiImage = UIImage(data: data) else { return nil }
    return Image(uiImage: uiImage)
    #elseif canImport(AppKit)
    guard let nsImage = NSImage(data: data) else { return nil }
    return Image(nsImage: nsImage)
    #else
    return nil
    #endif
}

#if DEBUG
struct PoolChatView_Previews: PreviewProvider {
    static var previews: some View {
        PoolChatView(viewModel: PoolChatViewModel())
    }
}
#endif
