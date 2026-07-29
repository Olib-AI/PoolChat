// ActiveCallView.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import SwiftUI
import CoreVideo
import ConnectionPool

// MARK: - Active Call View

/// Full-screen view for an active voice or video call.
///
/// For audio calls: displays participant info, call duration, and controls.
/// For video calls: displays remote video full-screen with local PiP and controls.
public struct ActiveCallView: View {
    @ObservedObject var callManager: CallManager
    @ObservedObject var callSession: CallSession
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    @State private var showControls = true

    public init(
        callManager: CallManager,
        callSession: CallSession
    ) {
        self.callManager = callManager
        self.callSession = callSession
    }

    private var theme: PoolThemeSnapshot { design.snapshot(dark: scheme == .dark) }

    public var body: some View {
        // TimelineView updates every second to drive the duration display
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
            ZStack {
                if callSession.isVideoCall {
                    videoCallContent
                } else {
                    audioCallContent
                }
            }
        }
    }

    // MARK: - Audio Call Content

    private var audioCallContent: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()

            VStack(spacing: theme.spacingXL) {
                Spacer()

                // Call state indicator
                if callSession.state == .connecting {
                    PoolText("poolchat.call.connecting", fallback: "Connecting…")
                        .font(theme.fontBody)
                        .foregroundColor(theme.textSecondary)
                } else {
                    Text(formattedDuration)
                        .font(theme.fontBody.monospacedDigit())
                        .foregroundColor(theme.textSecondary)
                }

                // Participant avatars
                participantAvatars

                // Participant names
                Text(participantNames)
                    .font(theme.fontHeading)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.textPrimary)
                    .multilineTextAlignment(.center)

                // Mute indicators for remote participants
                remoteStatusIndicators

                Spacer()

                // Controls
                CallButtonsView(
                    callSession: callSession,
                    onToggleMute: { callManager.toggleMute() },
                    onToggleSpeaker: { callManager.toggleSpeaker() },
                    onToggleVideo: { callManager.toggleVideo() },
                    onEndCall: { callManager.endCall() }
                )
                .padding(.bottom, theme.spacingXL)
            }
        }
    }

    // MARK: - Video Call Content

    private var videoCallContent: some View {
        ZStack {
            // Video letterbox is always black regardless of theme (functional
            // surface behind camera frames, not chrome).
            Color.black.ignoresSafeArea()

            // Remote video (full screen)
            if let firstParticipant = callSession.participants.first,
               let remoteBuffer = callManager.remoteVideoBuffers[firstParticipant] {
                VideoTileView(pixelBuffer: remoteBuffer, isMirrored: false)
                    .ignoresSafeArea()
            } else {
                // No video yet - show avatar
                VStack {
                    Text(participantNames)
                        .font(theme.fontHeading)
                        .foregroundColor(.white)
                    if callSession.state == .connecting {
                        PoolText("poolchat.call.connecting", fallback: "Connecting…")
                            .font(theme.fontBody)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }

            // Group video grid (for 2+ remote participants)
            if callSession.isGroupCall {
                videoGrid
            }

            // Local video PiP (top right)
            if let localBuffer = callManager.localVideoBuffer, callSession.localVideoEnabled {
                VStack {
                    HStack {
                        Spacer()
                        VideoTileView(pixelBuffer: localBuffer, isMirrored: true)
                            .frame(width: 120, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                            .shadow(color: theme.shadow.opacity(0.4), radius: 4)
                            .padding(.top, 50)
                            .padding(.trailing, theme.spacingL)
                    }
                    Spacer()
                }
            }

            // Controls overlay
            VStack {
                // Top bar with duration
                HStack {
                    if callSession.state == .active {
                        Text(formattedDuration)
                            .font(theme.fontBody.monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, theme.spacingM)
                            .padding(.vertical, theme.spacingXS + 2)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.top, 50)
                .padding(.leading, theme.spacingL)

                Spacer()

                // Bottom controls, on a legibility scrim over the video.
                CallButtonsView(
                    callSession: callSession,
                    onToggleMute: { callManager.toggleMute() },
                    onToggleSpeaker: { callManager.toggleSpeaker() },
                    onToggleVideo: { callManager.toggleVideo() },
                    onEndCall: { callManager.endCall() }
                )
                .background(Color.black.opacity(0.4))
                .padding(.bottom, theme.spacingL)
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
        }
    }

    // MARK: - Video Grid

    private var videoGrid: some View {
        GeometryReader { geometry in
            let columns = callSession.participants.count <= 2 ? 1 : 2
            let rows = (callSession.participants.count + columns - 1) / columns
            let tileHeight = geometry.size.height / CGFloat(rows)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns),
                spacing: 2
            ) {
                ForEach(callSession.participants, id: \.self) { peerID in
                    if let buffer = callManager.remoteVideoBuffers[peerID] {
                        VideoTileView(pixelBuffer: buffer, isMirrored: false)
                            .frame(height: tileHeight)
                    } else {
                        // Placeholder for peer with no video
                        Rectangle()
                            .fill(Color.black.opacity(0.85))
                            .overlay {
                                VStack(spacing: theme.spacingS) {
                                    Circle()
                                        .fill(theme.accent.opacity(0.3))
                                        .frame(width: 60, height: 60)
                                        .overlay {
                                            Text(String((callSession.participantNames[peerID] ?? "?").prefix(1)).uppercased())
                                                .font(.title2.bold())
                                                .foregroundColor(.white)
                                        }
                                    Text(callSession.participantNames[peerID] ?? peerID.prefix(8).description)
                                        .font(theme.fontCaption)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                            .frame(height: tileHeight)
                    }
                }
            }
        }
    }

    // MARK: - Participant Avatars

    private var participantAvatars: some View {
        HStack(spacing: -12) {
            ForEach(callSession.participants.prefix(4), id: \.self) { peerID in
                Circle()
                    .fill(theme.accent.opacity(0.3))
                    .frame(width: 80, height: 80)
                    .overlay {
                        Text(String((callSession.participantNames[peerID] ?? "?").prefix(1)).uppercased())
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(theme.accent)
                    }
                    .overlay {
                        // Mute indicator
                        if callSession.remoteParticipantStates[peerID]?.audioMuted == true {
                            PoolIcon("microphone-slash", size: 12, systemFallback: "mic.slash.fill")
                                .foregroundColor(theme.danger)
                                .padding(theme.spacingXS)
                                .background(theme.surface)
                                .clipShape(Circle())
                                .offset(x: 28, y: 28)
                        }
                    }
            }
        }
    }

    // MARK: - Remote Status Indicators

    private var remoteStatusIndicators: some View {
        VStack(spacing: theme.spacingXS) {
            ForEach(callSession.participants, id: \.self) { peerID in
                if let state = callSession.remoteParticipantStates[peerID], state.audioMuted {
                    HStack(spacing: theme.spacingXS) {
                        PoolIcon("microphone-slash", size: 11, systemFallback: "mic.slash.fill")
                        Text(poolString(
                            "poolchat.call.participantMuted",
                            fallback: "\(callSession.participantNames[peerID] ?? "Peer") is muted",
                            args: ["name": callSession.participantNames[peerID] ?? poolString("poolchat.call.peer", fallback: "Peer")]
                        ))
                        .font(theme.fontCaption)
                    }
                    .foregroundColor(theme.textSecondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private var participantNames: String {
        callSession.participants
            .compactMap { callSession.participantNames[$0] }
            .joined(separator: ", ")
    }

    private var formattedDuration: String {
        guard let connectedAt = callSession.connectedAt else { return "0:00" }
        let totalSeconds = Int(Date().timeIntervalSince(connectedAt))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Audio Call Banner View

/// Compact banner shown at the top of the chat when an audio call is active.
/// Tap to expand to full active call view.
public struct AudioCallBannerView: View {
    @ObservedObject var callManager: CallManager
    @ObservedObject var callSession: CallSession
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    let onTap: () -> Void

    public init(callManager: CallManager, callSession: CallSession, onTap: @escaping () -> Void) {
        self.callManager = callManager
        self.callSession = callSession
        self.onTap = onTap
    }

    public var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
        Button(action: onTap) {
            HStack(spacing: theme.spacingS) {
                // Active-call indicator
                Circle()
                    .fill(theme.success)
                    .frame(width: 8, height: 8)

                PoolIcon("phone", size: 12, systemFallback: "phone.fill")
                    .foregroundColor(theme.success)

                Text(participantNames)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(formattedDuration)
                    .font(theme.fontCaption.monospacedDigit())
                    .foregroundColor(theme.textSecondary)

                // End call button
                Button {
                    callManager.endCall()
                } label: {
                    PoolIcon("phone-slash", size: 12, systemFallback: "phone.down.fill")
                        .foregroundColor(theme.textOnAccent)
                        .padding(theme.spacingXS + 2)
                        .background(theme.danger)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(poolString("poolchat.call.end", fallback: "End"))
            }
            .padding(.horizontal, theme.spacingM)
            .padding(.vertical, theme.spacingS)
            .background(theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, theme.spacingS)
        } // TimelineView
    }

    private var participantNames: String {
        callSession.participants
            .compactMap { callSession.participantNames[$0] }
            .joined(separator: ", ")
    }

    private var formattedDuration: String {
        guard let connectedAt = callSession.connectedAt else { return "0:00" }
        let totalSeconds = Int(Date().timeIntervalSince(connectedAt))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
