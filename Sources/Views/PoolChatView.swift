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

/// Cross-platform gray background color
private extension Color {
    static var systemGray6Color: Color {
        #if canImport(UIKit)
        return Color(.systemGray6)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var systemGray5Color: Color {
        #if canImport(UIKit)
        return Color(.systemGray5)
        #else
        return Color(nsColor: .separatorColor)
        #endif
    }

    static var systemBackgroundColor: Color {
        #if canImport(UIKit)
        return Color(.systemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var secondarySystemGroupedBackgroundColor: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var tertiarySystemGroupedBackgroundColor: Color {
        #if canImport(UIKit)
        return Color(uiColor: .tertiarySystemGroupedBackground)
        #else
        return Color(nsColor: .textBackgroundColor)
        #endif
    }
}

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

    public init(viewModel: PoolChatViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Connection status bar (compact, below window title bar)
            ConnectionStatusBar(
                connectedPeers: viewModel.connectedPeers,
                isConnected: viewModel.isConnected,
                isHost: viewModel.isPoolHost,
                onClearHistory: { viewModel.showClearHistoryDialog() },
                onGroupVoiceCall: {
                    viewModel.callManager.initiateCall(to: viewModel.connectedPeers.map(\.id), video: false)
                    viewModel.showActiveCallView = true
                },
                onGroupVideoCall: {
                    viewModel.callManager.initiateCall(to: viewModel.connectedPeers.map(\.id), video: true)
                    viewModel.showActiveCallView = true
                }
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
        .background(poolGroupedBackgroundColor)
        .onChange(of: viewModel.selectedPhotoItem) { _, newValue in
            if newValue != nil {
                viewModel.handleImageSelection()
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
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
            Button("Cancel", role: .cancel) {}
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
            return viewModel.isPoolHost ? "Clear Chat History" : "Clear Your View"
        } else {
            return "Clear Private Chat"
        }
    }

    /// Button title for the clear history alert
    private var clearHistoryButtonTitle: String {
        if viewModel.chatMode.isGroup {
            return viewModel.isPoolHost ? "Clear for Everyone" : "Clear"
        } else {
            return "Clear"
        }
    }

    /// Message for the clear history alert based on current chat mode
    private var clearHistoryAlertMessage: String {
        if viewModel.chatMode.isGroup {
            if viewModel.isPoolHost {
                return "This will clear the chat history for all pool members. This action cannot be undone."
            } else {
                return "This will clear your local chat view. Other members will still see the messages."
            }
        } else {
            return "This will clear your private conversation. The other participant's view will not be affected."
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
                        Text("Loading history...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.secondarySystemGroupedBackgroundColor.opacity(0.8))
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

    var body: some View {
        HStack(spacing: 0) {
            // Group tab
            TabButton(
                title: "Group",
                icon: "person.3.fill",
                isSelected: selectedTab == 0,
                badgeCount: groupUnreadCount
            ) {
                selectedTab = 0
            }

            // Divider
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1, height: 24)

            // Private tab
            TabButton(
                title: "Private",
                icon: "person.fill",
                isSelected: selectedTab == 1,
                badgeCount: privateUnreadCount
            ) {
                selectedTab = 1
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondarySystemGroupedBackgroundColor)
    }
}

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let badgeCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))

                Text(title)
                    .font(.system(size: 14, weight: .medium))

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                }
            }
            .foregroundStyle(isSelected ? .blue : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                isSelected ?
                    Color.blue.opacity(0.1) :
                    Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .yellow, .red]
        return colors[peer.avatarColorIndex % colors.count]
    }

    var body: some View {
        HStack(spacing: 12) {
            // Back button
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            // Avatar
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(String(peer.effectiveDisplayName.prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    )

                // Online indicator
                if isOnline {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.secondarySystemGroupedBackgroundColor, lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }
            }

            // Name and status
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.effectiveDisplayName)
                    .font(.system(size: 15, weight: .semibold))

                Text(isOnline ? "Online" : "Offline")
                    .font(.system(size: 12))
                    .foregroundStyle(isOnline ? .green : .secondary)
            }

            Spacer()

            // Call buttons (only shown when peer is online)
            if isOnline {
                HStack(spacing: 12) {
                    if let onVoiceCall {
                        Button(action: onVoiceCall) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    if let onVideoCall {
                        Button(action: onVideoCall) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Encryption indicator
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                Text("Encrypted")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.15))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondarySystemGroupedBackgroundColor)
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
                    SectionHeader(title: "Start New Chat")

                    ForEach(newPeers, id: \.id) { peer in
                        NewChatPeerRow(peer: peer, onTap: { onSelectPeer(peer) })
                        Divider().padding(.leading, 66)
                    }
                }

                // Existing chats section
                if !chatInfos.isEmpty {
                    SectionHeader(title: "Recent Chats")

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
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

struct NewChatPeerRow: View {
    let peer: Peer
    let onTap: () -> Void

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .yellow, .red]
        return colors[peer.avatarColorIndex % colors.count]
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Avatar with online indicator
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(avatarColor)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Text(String(peer.effectiveDisplayName.prefix(1)).uppercased())
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        )

                    Circle()
                        .fill(Color.green)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .strokeBorder(poolGroupedBackgroundColor, lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(peer.effectiveDisplayName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)

                    Text("Online")
                        .font(.system(size: 13))
                        .foregroundStyle(.green)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PrivateChatRow: View {
    let info: PrivateChatInfo
    let onTap: () -> Void

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .yellow, .red]
        return colors[info.avatarColorIndex % colors.count]
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Avatar
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(avatarColor)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Text(String(info.peerName.prefix(1)).uppercased())
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        )

                    if info.isOnline {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .strokeBorder(poolGroupedBackgroundColor, lineWidth: 2)
                            )
                            .offset(x: 2, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(info.peerName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)

                        Spacer()

                        if let time = info.lastMessageTime {
                            Text(formatTime(time))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        if let lastMessage = info.lastMessage {
                            Text(lastMessage)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if info.unreadCount > 0 {
                            Text("\(info.unreadCount)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.blue))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

struct PrivateChatEmptyView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "person.2.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Private Chats")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Start a private conversation\nwith a connected pool member")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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
                        SectionHeader(title: "Current Group")

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
                        SectionHeader(title: "Past Groups")

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
                                    Label("Delete", systemImage: "trash")
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

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .yellow, .red]
        return colors[info.avatarColorIndex % colors.count]
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
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
                                    Image(systemName: "person.3.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.white)
                                }
                            }
                        )

                    // Online indicator for current group
                    if info.isHostConnected {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .strokeBorder(poolGroupedBackgroundColor, lineWidth: 2)
                            )
                            .offset(x: 2, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(info.hostDisplayName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)

                        if isCurrentGroup {
                            Text("CONNECTED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green))
                        }

                        Spacer()

                        if let time = info.lastMessageTime {
                            Text(formatTime(time))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        if let lastMessage = info.lastMessage {
                            Text(lastMessage)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if !info.isHostConnected {
                            Text("Host not connected")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                                .italic()
                        } else {
                            Text("No messages yet")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        if info.unreadCount > 0 {
                            Text("\(info.unreadCount)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.blue))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

struct GroupChatEmptyView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "person.3.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Group Chats")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Join or host a Connection Pool\nto start a group chat")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Group Chat Header

struct GroupChatHeader: View {
    let group: GroupChatInfo
    let onBack: () -> Void

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .yellow, .red]
        return colors[group.avatarColorIndex % colors.count]
    }

    var body: some View {
        HStack(spacing: 12) {
            // Back button
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
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
                                Image(systemName: "person.3.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                            }
                        }
                    )

                // Online indicator
                if group.isHostConnected {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.secondarySystemGroupedBackgroundColor, lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }
            }

            // Name and status
            VStack(alignment: .leading, spacing: 2) {
                Text(group.hostDisplayName)
                    .font(.system(size: 15, weight: .semibold))

                Text(group.isHostConnected ? "Connected" : "Host not connected")
                    .font(.system(size: 12))
                    .foregroundStyle(group.isHostConnected ? .green : .secondary)
            }

            Spacer()

            // Encryption indicator
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                Text("Encrypted")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.15))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondarySystemGroupedBackgroundColor)
    }
}

// MARK: - Not Connected View

struct NotConnectedView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 8) {
                Text("Not Connected")
                    .font(.title2.bold())

                Text("Join or host a Connection Pool\nto start chatting")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Instructions card
            VStack(spacing: 0) {
                InstructionRow(
                    icon: "antenna.radiowaves.left.and.right",
                    iconColor: .blue,
                    title: "Open Connection Pool",
                    description: "Launch the Connection Pool app",
                    showDivider: true
                )

                InstructionRow(
                    icon: "person.2.fill",
                    iconColor: .green,
                    title: "Host or Join",
                    description: "Create a pool or join an existing one",
                    showDivider: true
                )

                InstructionRow(
                    icon: "message.fill",
                    iconColor: .cyan,
                    title: "Start Chatting",
                    description: "Send messages, photos, and voice notes",
                    showDivider: false
                )
            }
            .background(Color.secondarySystemGroupedBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)

            Spacer()

            // Security hint
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)

                Text("End-to-end encrypted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
        }
    }
}

struct InstructionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let showDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(iconColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if showDivider {
                Divider()
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

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Text(connectionStatus)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isConnected ? Color.secondary : Color.orange)

            Spacer()

            // Participants indicator
            if isConnected && connectedPeers.count > 0 {
                HStack(spacing: -6) {
                    ForEach(Array(connectedPeers.prefix(3).enumerated()), id: \.element.id) { index, peer in
                        Circle()
                            .fill(avatarColor(for: peer.avatarColorIndex))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Text(String(peer.effectiveDisplayName.prefix(1)).uppercased())
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.secondarySystemGroupedBackgroundColor, lineWidth: 1.5)
                            )
                            .zIndex(Double(3 - index))
                    }
                    if connectedPeers.count > 3 {
                        Circle()
                            .fill(Color.gray)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Text("+\(connectedPeers.count - 3)")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.white)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.secondarySystemGroupedBackgroundColor, lineWidth: 1.5)
                            )
                    }
                }

                Text("\(connectedPeers.count) online")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                // Group call buttons
                if let onGroupVoiceCall {
                    Button(action: onGroupVoiceCall) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
                if let onGroupVideoCall {
                    Button(action: onGroupVideoCall) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Options menu (only when connected)
            if isConnected {
                Menu {
                    Button(role: .destructive) {
                        onClearHistory()
                    } label: {
                        Label(
                            isHost ? "Clear History for All" : "Clear My View",
                            systemImage: "trash"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondarySystemGroupedBackgroundColor)
    }

    private var connectionStatus: String {
        if !isConnected {
            return "Not connected to pool"
        }
        // When isConnected is true, the user can send and receive messages
        // Show "Connected" status since chat functionality is working
        return "Connected"
    }

    private func avatarColor(for index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .yellow, .red]
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
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "text.bubble")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)

            Text("No messages yet")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Be the first to say hello!")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

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
                        .foregroundStyle(.secondary)

                    Text("*")
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)

                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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
                            .foregroundStyle(.white)
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
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }

            Button {
                onShowReactionPicker()
            } label: {
                Label("Add Reaction", systemImage: "face.smiling")
            }

            if let text = message.text {
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = text
                    #elseif canImport(AppKit)
                    NSPasteboard.general.setString(text, forType: .string)
                    #endif
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
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
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .yellow, .red]
        return colors[message.avatarColorIndex % colors.count]
    }
}

// MARK: - Reply Preview Bubble

struct ReplyPreviewBubble: View {
    let senderName: String
    let previewText: String
    let isFromLocalUser: Bool

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(isFromLocalUser ? Color.white.opacity(0.5) : Color.blue)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isFromLocalUser ? .white.opacity(0.9) : .blue)

                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(isFromLocalUser ? .white.opacity(0.7) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isFromLocalUser ? Color.blue.opacity(0.3) : Color.tertiarySystemGroupedBackgroundColor)
        )
    }
}

// MARK: - Quick Reaction Picker

struct QuickReactionPicker: View {
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.secondarySystemGroupedBackgroundColor)
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        )
    }
}

// MARK: - Reactions Display View

struct ReactionsDisplayView: View {
    let reactions: [(emoji: String, peerIDs: [String])]
    let localPeerID: String
    let onToggleReaction: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(reactions, id: \.emoji) { reaction in
                Button {
                    onToggleReaction(reaction.emoji)
                } label: {
                    HStack(spacing: 4) {
                        Text(reaction.emoji)
                            .font(.system(size: 14))

                        if reaction.peerIDs.count > 1 {
                            Text("\(reaction.peerIDs.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(reaction.peerIDs.contains(localPeerID)
                                  ? Color.blue.opacity(0.2)
                                  : Color.tertiarySystemGroupedBackgroundColor)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                reaction.peerIDs.contains(localPeerID)
                                    ? Color.blue.opacity(0.5)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Poll header
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)

                Text("Poll")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)

                Spacer()

                Text("\(pollData.totalVotes) vote\(pollData.totalVotes == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Question
            Text(pollData.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            // Options
            VStack(spacing: 8) {
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
                    .foregroundStyle(.tertiary)

                Spacer()

                if votedOption != nil && !pollData.allowVoteChange {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                        Text("Vote locked")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.tertiarySystemGroupedBackgroundColor)
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

    var body: some View {
        Button(action: onVote) {
            ZStack(alignment: .leading) {
                // Progress bar background
                GeometryReader { geometry in
                    if hasVoted {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.blue.opacity(0.3) : Color.gray.opacity(0.15))
                            .frame(width: geometry.size.width * percentage)
                    }
                }

                HStack {
                    // Option text
                    Text(option)
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    Spacer()

                    // Vote indicator / percentage
                    if hasVoted {
                        HStack(spacing: 4) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.blue)
                            }

                            Text("\(Int(percentage * 100))%")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.blue : Color.gray.opacity(0.3),
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

    var body: some View {
        VStack(alignment: isFromLocalUser ? .trailing : .leading, spacing: 2) {
            TextWithMentions(
                text: text,
                mentions: mentions,
                isFromLocalUser: isFromLocalUser,
                localPeerID: localPeerID
            )
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                BubbleShape(isFromLocalUser: isFromLocalUser)
                    .fill(isFromLocalUser ? Color.blue : Color.tertiarySystemGroupedBackgroundColor)
            )

            if showTimestamp {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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

    var body: some View {
        VStack(alignment: isFromLocalUser ? .trailing : .leading, spacing: 2) {
            if let data = imageData, let image = platformImage(from: data) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
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
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.tertiarySystemGroupedBackgroundColor)
                    .frame(width: 150, height: 150)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                    )
            }

            if showTimestamp && imageData == nil {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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

    var body: some View {
        VStack(alignment: isFromLocalUser ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 10) {
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(isFromLocalUser ? .white : .blue)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(isFromLocalUser ? Color.white.opacity(0.2) : Color.blue.opacity(0.15))
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    // Waveform
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            WaveformView()
                                .foregroundStyle(isFromLocalUser ? Color.white.opacity(0.4) : Color.secondary.opacity(0.4))

                            WaveformView()
                                .foregroundStyle(isFromLocalUser ? .white : .blue)
                                .mask(
                                    Rectangle()
                                        .frame(width: geometry.size.width * progress)
                                )
                        }
                    }
                    .frame(height: 20)

                    Text(duration.formattedDuration)
                        .font(.system(size: 11))
                        .foregroundStyle(isFromLocalUser ? .white.opacity(0.8) : .secondary)
                }
                .frame(width: 100)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                BubbleShape(isFromLocalUser: isFromLocalUser)
                    .fill(isFromLocalUser ? Color.blue : Color.tertiarySystemGroupedBackgroundColor)
            )

            if showTimestamp {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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

    var body: some View {
        VStack(alignment: isFromLocalUser ? .trailing : .leading, spacing: 2) {
            Text(emoji)
                .font(.system(size: 48))

            if showTimestamp {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - System Message View

struct SystemMessageView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.tertiarySystemGroupedBackgroundColor)
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

    var body: some View {
        VStack(spacing: 0) {
            // Reply preview bar
            if let replyMessage = replyingToMessage {
                ReplyInputPreview(
                    senderName: replyMessage.senderName,
                    previewText: replyMessage.previewText,
                    onCancel: onCancelReply
                )
            }

            HStack(spacing: 10) {
                // Attachment button (photo picker)
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(isConnected ? .secondary : .quaternary)
                        .frame(width: 36, height: 36)
                }
                .disabled(!isConnected)

                // Poll button (group chat only)
                if isGroupChat {
                    Button(action: onCreatePoll) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(isConnected ? .secondary : .quaternary)
                            .frame(width: 36, height: 36)
                    }
                    .disabled(!isConnected)
                }

                // Emoji button
                Button(action: {
                    withAnimation { showEmojiPicker.toggle() }
                }) {
                    Image(systemName: showEmojiPicker ? "keyboard" : "face.smiling")
                        .font(.system(size: 20))
                        .foregroundStyle(isConnected ? .secondary : .quaternary)
                        .frame(width: 36, height: 36)
                }
                .disabled(!isConnected)

                // Text field
                TextField("Message", text: $text)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.tertiarySystemGroupedBackgroundColor)
                    )
                    .disabled(!isConnected)

                // Send or Voice button
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Voice record button
                    Button(action: onStartVoiceRecording) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle()
                                    .fill(isConnected ? Color.blue : Color.gray)
                            )
                    }
                    .disabled(!isConnected)
                } else {
                    // Send button
                    Button(action: onSendText) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle()
                                    .fill(Color.blue)
                            )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color.secondarySystemGroupedBackgroundColor)
    }
}

// MARK: - Reply Input Preview

struct ReplyInputPreview: View {
    let senderName: String
    let previewText: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.blue)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(senderName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)

                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tertiarySystemGroupedBackgroundColor)
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
                    TextField("Ask a question...", text: $question)
                } header: {
                    Text("Question")
                }

                Section {
                    // ISSUE 4 FIX: Use identifiable items with ForEach to prevent crash
                    ForEach($pollOptions) { $option in
                        HStack {
                            TextField("Option", text: $option.text)

                            if pollOptions.count > 2 {
                                Button {
                                    removeOption(option.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }

                    if pollOptions.count < 6 {
                        Button {
                            addOption()
                        } label: {
                            Label("Add Option", systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("Options")
                } footer: {
                    Text("Add 2-6 options for voters to choose from")
                }

                // ISSUE 5: Allow vote change toggle
                Section {
                    Toggle("Allow changing vote", isOn: $allowVoteChange)
                } footer: {
                    Text(allowVoteChange ? "Voters can change their vote after voting" : "Voters can only vote once and cannot change their vote")
                }
            }
            .navigationTitle("Create Poll")
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
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

    @State private var pulseAnimation = false

    var body: some View {
        HStack(spacing: 16) {
            // Cancel button
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color.red)
                    )
            }

            Spacer()

            // Recording indicator
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                    .opacity(pulseAnimation ? 0.7 : 1.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulseAnimation)

                Text(duration.formattedDuration)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
            }
            .onAppear { pulseAnimation = true }

            Spacer()

            // Send button
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(Color.blue)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondarySystemGroupedBackgroundColor)
    }
}

// MARK: - Emoji Picker View

struct EmojiPickerView: View {
    @Binding var selectedCategory: EmojiCategory
    let onEmojiSelected: (String) -> Void
    let onEmojiSent: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Category tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(EmojiCategory.allCases) { category in
                        Button(action: {
                            selectedCategory = category
                        }) {
                            Image(systemName: category.icon)
                                .font(.system(size: 18))
                                .foregroundStyle(selectedCategory == category ? .white : .secondary)
                                .frame(width: 40, height: 40)
                                .background(
                                    selectedCategory == category ?
                                    Color.blue :
                                    Color.clear
                                )
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 10)

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
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(height: 200)
        }
        .background(Color.secondarySystemGroupedBackgroundColor)
    }
}

// MARK: - Mention Picker View

struct MentionPickerView: View {
    let peers: [MentionInfo]
    let onSelect: (MentionInfo) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "at")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("Mention someone")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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
        .background(Color.secondarySystemGroupedBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 8, y: -2)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

struct MentionPeerRow: View {
    let peer: MentionInfo
    let onTap: () -> Void

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .yellow, .red]
        return colors[peer.avatarColorIndex % colors.count]
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(String(peer.displayName.prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    )

                Text(peer.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Text("@\(peer.displayName.replacingOccurrences(of: " ", with: "_"))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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

    var body: some View {
        highlightedText
    }

    private var highlightedText: Text {
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
                    .foregroundColor(isFromLocalUser ? .white : .primary)
            }

            // Add the mention with highlight
            let mentionText = nsText.substring(with: match.range)
            let isSelfMention = mentions.contains(localPeerID)

            result = result + Text(mentionText)
                .foregroundColor(isFromLocalUser ? .white : .blue)
                .fontWeight(isSelfMention ? .bold : .medium)
                .underline(isSelfMention)

            lastEnd = match.range.location + match.range.length
        }

        // Add any remaining text
        if lastEnd < nsText.length {
            let remainingRange = NSRange(location: lastEnd, length: nsText.length - lastEnd)
            let remainingText = nsText.substring(with: remainingRange)
            result = result + Text(remainingText)
                .foregroundColor(isFromLocalUser ? .white : .primary)
        }

        // If no matches, return original text
        if matches.isEmpty {
            return Text(text)
                .foregroundColor(isFromLocalUser ? .white : .primary)
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

private var poolGroupedBackgroundColor: Color {
    #if canImport(UIKit)
    Color(.systemGroupedBackground)
    #else
    Color(nsColor: .windowBackgroundColor)
    #endif
}

#if DEBUG
struct PoolChatView_Previews: PreviewProvider {
    static var previews: some View {
        PoolChatView(viewModel: PoolChatViewModel())
    }
}
#endif
