// IncomingCallView.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import SwiftUI
import ConnectionPool

// MARK: - Incoming Call View

/// Full-screen overlay for an incoming call.
///
/// Displays caller information with accept and decline buttons.
/// Auto-dismisses after the ring timeout (handled by ``CallManager``).
public struct IncomingCallView: View {
    let signal: CallSignal
    let onAnswer: () -> Void
    let onDecline: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseAnimation = false

    public init(signal: CallSignal, onAnswer: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.signal = signal
        self.onAnswer = onAnswer
        self.onDecline = onDecline
    }

    public var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        ZStack {
            theme.background
                .ignoresSafeArea()

            VStack(spacing: theme.spacingXL) {
                Spacer()

                // Call type indicator
                HStack(spacing: theme.spacingS) {
                    PoolIcon(
                        signal.isVideoCall ? "video" : "phone",
                        size: 14,
                        systemFallback: signal.isVideoCall ? "video.fill" : "phone.fill"
                    )
                    .foregroundColor(theme.textSecondary)
                    PoolText(
                        signal.isVideoCall ? "poolchat.call.incomingVideo" : "poolchat.call.incomingVoice",
                        fallback: signal.isVideoCall ? "Incoming Video Call" : "Incoming Voice Call"
                    )
                    .font(theme.fontBody)
                    .foregroundColor(theme.textSecondary)
                }

                // Caller avatar with pulse effect
                ZStack {
                    Circle()
                        .fill(theme.accent.opacity(0.15))
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                        .opacity(pulseAnimation ? 0 : 0.5)

                    Circle()
                        .fill(theme.accent.opacity(0.2))
                        .frame(width: 100, height: 100)

                    Text(callerInitial)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(theme.accent)
                }
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                        pulseAnimation = true
                    }
                }

                // Caller name
                Text(signal.callerDisplayName)
                    .font(theme.fontHeading)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.textPrimary)

                Spacer()

                // Action buttons
                HStack(spacing: 60) {
                    // Decline
                    VStack(spacing: theme.spacingS) {
                        Button(action: onDecline) {
                            PoolIcon("phone-slash", size: 28, systemFallback: "phone.down.fill")
                                .foregroundColor(theme.textOnAccent)
                                .frame(width: 72, height: 72)
                                .background(theme.danger)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(poolString("poolchat.call.decline", fallback: "Decline"))

                        PoolText("poolchat.call.decline", fallback: "Decline")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.textSecondary)
                    }

                    // Answer
                    VStack(spacing: theme.spacingS) {
                        Button(action: onAnswer) {
                            PoolIcon(
                                signal.isVideoCall ? "video" : "phone",
                                size: 28,
                                systemFallback: signal.isVideoCall ? "video.fill" : "phone.fill"
                            )
                            .foregroundColor(theme.textOnAccent)
                            .frame(width: 72, height: 72)
                            .background(theme.success)
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(poolString("poolchat.call.accept", fallback: "Accept"))

                        PoolText("poolchat.call.accept", fallback: "Accept")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.textSecondary)
                    }
                }
                .padding(.bottom, 60)
            }
        }
    }

    private var callerInitial: String {
        String(signal.callerDisplayName.prefix(1)).uppercased()
    }
}
