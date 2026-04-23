// CallButtonsView.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import SwiftUI

// MARK: - Call Control Button

/// A circular control button used in call views.
struct CallControlButton: View {
    let systemImage: String
    let label: String
    var isActive: Bool = false
    var isDestructive: Bool = false
    var size: CGFloat = 56
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundColor(buttonForeground)
                    .frame(width: size, height: size)
                    .background(buttonBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var buttonForeground: Color {
        if isDestructive { return .white }
        if isActive { return .primary }
        return .white
    }

    private var buttonBackground: Color {
        if isDestructive { return .red }
        if isActive { return Color.white.opacity(0.25) }
        return Color.white.opacity(0.12)
    }
}

// MARK: - Call Buttons View

/// Bottom control bar for an active call.
struct CallButtonsView: View {
    @ObservedObject var callSession: CallSession
    let onToggleMute: () -> Void
    let onToggleSpeaker: () -> Void
    let onToggleVideo: () -> Void
    let onEndCall: () -> Void

    var body: some View {
        HStack(spacing: 28) {
            // Mute
            CallControlButton(
                systemImage: callSession.localAudioMuted ? "mic.slash.fill" : "mic.fill",
                label: callSession.localAudioMuted ? "Unmute" : "Mute",
                isActive: callSession.localAudioMuted,
                action: onToggleMute
            )

            // Speaker
            CallControlButton(
                systemImage: callSession.speakerEnabled ? "speaker.wave.3.fill" : "speaker.fill",
                label: "Speaker",
                isActive: callSession.speakerEnabled,
                action: onToggleSpeaker
            )

            // Video toggle (only for video calls)
            if callSession.isVideoCall {
                CallControlButton(
                    systemImage: callSession.localVideoEnabled ? "video.fill" : "video.slash.fill",
                    label: callSession.localVideoEnabled ? "Camera" : "Camera Off",
                    isActive: !callSession.localVideoEnabled,
                    action: onToggleVideo
                )
            }

            // End call
            CallControlButton(
                systemImage: "phone.down.fill",
                label: "End",
                isDestructive: true,
                size: 64,
                action: onEndCall
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
