// CallButtonsView.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import SwiftUI
import ConnectionPool

// MARK: - Call Control Button

/// A circular control button used in call views.
struct CallControlButton: View {
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    /// Font Awesome icon name (rendered via the injected renderer in-app).
    let icon: String
    /// Legacy SF Symbol used only when no icon renderer is wired.
    let systemFallback: String
    let label: String
    var isActive: Bool = false
    var isDestructive: Bool = false
    var size: CGFloat = 56
    let action: () -> Void

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: theme.spacingS) {
            Button(action: action) {
                PoolIcon(icon, size: size * 0.38, weight: .solid, systemFallback: systemFallback)
                    .foregroundColor(buttonForeground(theme))
                    .frame(width: size, height: size)
                    .background(buttonBackground(theme))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Text(label)
                .font(theme.fontCaption)
                .foregroundColor(theme.textSecondary)
        }
    }

    private func buttonForeground(_ theme: PoolThemeSnapshot) -> Color {
        if isDestructive { return theme.textOnAccent }
        if isActive { return theme.accent }
        return theme.textPrimary
    }

    private func buttonBackground(_ theme: PoolThemeSnapshot) -> Color {
        if isDestructive { return theme.danger }
        if isActive { return theme.accent.opacity(0.22) }
        return theme.surfaceSecondary
    }
}

// MARK: - Call Buttons View

/// Bottom control bar for an active call.
struct CallButtonsView: View {
    @ObservedObject var callSession: CallSession
    @ObservedObject private var design = PoolDesign.shared
    let onToggleMute: () -> Void
    let onToggleSpeaker: () -> Void
    let onToggleVideo: () -> Void
    let onEndCall: () -> Void

    var body: some View {
        HStack(spacing: 28) {
            // Mute
            CallControlButton(
                icon: callSession.localAudioMuted ? "microphone-slash" : "microphone",
                systemFallback: callSession.localAudioMuted ? "mic.slash.fill" : "mic.fill",
                label: callSession.localAudioMuted
                    ? poolString("poolchat.call.unmute", fallback: "Unmute")
                    : poolString("poolchat.call.mute", fallback: "Mute"),
                isActive: callSession.localAudioMuted,
                action: onToggleMute
            )

            // Speaker
            CallControlButton(
                icon: callSession.speakerEnabled ? "volume-high" : "volume",
                systemFallback: callSession.speakerEnabled ? "speaker.wave.3.fill" : "speaker.fill",
                label: poolString("poolchat.call.speaker", fallback: "Speaker"),
                isActive: callSession.speakerEnabled,
                action: onToggleSpeaker
            )

            // Video toggle (only for video calls)
            if callSession.isVideoCall {
                CallControlButton(
                    icon: callSession.localVideoEnabled ? "video" : "video-slash",
                    systemFallback: callSession.localVideoEnabled ? "video.fill" : "video.slash.fill",
                    label: callSession.localVideoEnabled
                        ? poolString("poolchat.call.camera", fallback: "Camera")
                        : poolString("poolchat.call.cameraOff", fallback: "Camera Off"),
                    isActive: !callSession.localVideoEnabled,
                    action: onToggleVideo
                )
            }

            // End call
            CallControlButton(
                icon: "phone-slash",
                systemFallback: "phone.down.fill",
                label: poolString("poolchat.call.end", fallback: "End"),
                isDestructive: true,
                size: 64,
                action: onEndCall
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
