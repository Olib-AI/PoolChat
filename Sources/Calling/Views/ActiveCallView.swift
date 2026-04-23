// ActiveCallView.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import SwiftUI
import CoreVideo

// MARK: - Active Call View

/// Full-screen view for an active voice or video call.
///
/// For audio calls: displays participant info, call duration, and controls.
/// For video calls: displays remote video full-screen with local PiP and controls.
public struct ActiveCallView: View {
    @ObservedObject var callManager: CallManager
    @ObservedObject var callSession: CallSession

    @State private var showControls = true

    public init(
        callManager: CallManager,
        callSession: CallSession
    ) {
        self.callManager = callManager
        self.callSession = callSession
    }

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
            // Dark background
            LinearGradient(
                colors: [Color(white: 0.12), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Call state indicator
                if callSession.state == .connecting {
                    Text("Connecting...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text(formattedDuration)
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                // Participant avatars
                participantAvatars

                // Participant names
                Text(participantNames)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
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
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Video Call Content

    private var videoCallContent: some View {
        ZStack {
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
                        .font(.title2)
                        .foregroundColor(.white)
                    if callSession.state == .connecting {
                        Text("Connecting...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
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
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(radius: 4)
                            .padding(.top, 50)
                            .padding(.trailing, 16)
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
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.top, 50)
                .padding(.leading, 16)

                Spacer()

                // Bottom controls
                CallButtonsView(
                    callSession: callSession,
                    onToggleMute: { callManager.toggleMute() },
                    onToggleSpeaker: { callManager.toggleSpeaker() },
                    onToggleVideo: { callManager.toggleVideo() },
                    onEndCall: { callManager.endCall() }
                )
                .background(
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .padding(.bottom, 16)
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
                            .fill(Color(white: 0.15))
                            .overlay {
                                VStack(spacing: 8) {
                                    Circle()
                                        .fill(Color.blue.opacity(0.3))
                                        .frame(width: 60, height: 60)
                                        .overlay {
                                            Text(String((callSession.participantNames[peerID] ?? "?").prefix(1)).uppercased())
                                                .font(.title2.bold())
                                                .foregroundColor(.white)
                                        }
                                    Text(callSession.participantNames[peerID] ?? peerID.prefix(8).description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
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
                    .fill(Color.blue.opacity(0.3))
                    .frame(width: 80, height: 80)
                    .overlay {
                        Text(String((callSession.participantNames[peerID] ?? "?").prefix(1)).uppercased())
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .overlay {
                        // Mute indicator
                        if callSession.remoteParticipantStates[peerID]?.audioMuted == true {
                            Image(systemName: "mic.slash.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(4)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                                .offset(x: 28, y: 28)
                        }
                    }
            }
        }
    }

    // MARK: - Remote Status Indicators

    private var remoteStatusIndicators: some View {
        VStack(spacing: 4) {
            ForEach(callSession.participants, id: \.self) { peerID in
                if let state = callSession.remoteParticipantStates[peerID], state.audioMuted {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.slash.fill")
                            .font(.caption2)
                        Text("\(callSession.participantNames[peerID] ?? "Peer") is muted")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
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
    let onTap: () -> Void

    public init(callManager: CallManager, callSession: CallSession, onTap: @escaping () -> Void) {
        self.callManager = callManager
        self.callSession = callSession
        self.onTap = onTap
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Green call indicator
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                Image(systemName: "phone.fill")
                    .font(.caption)
                    .foregroundColor(.green)

                Text(participantNames)
                    .font(.caption)
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                Text(formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))

                // End call button
                Button {
                    callManager.endCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.2))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
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
