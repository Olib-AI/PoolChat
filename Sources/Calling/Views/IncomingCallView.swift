// IncomingCallView.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import SwiftUI

// MARK: - Incoming Call View

/// Full-screen overlay for an incoming call.
///
/// Displays caller information with accept and decline buttons.
/// Auto-dismisses after the ring timeout (handled by ``CallManager``).
public struct IncomingCallView: View {
    let signal: CallSignal
    let onAnswer: () -> Void
    let onDecline: () -> Void

    @State private var pulseAnimation = false

    public init(signal: CallSignal, onAnswer: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.signal = signal
        self.onAnswer = onAnswer
        self.onDecline = onDecline
    }

    public var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color.black.opacity(0.9), Color(white: 0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Call type indicator
                HStack(spacing: 8) {
                    Image(systemName: signal.isVideoCall ? "video.fill" : "phone.fill")
                        .foregroundColor(.secondary)
                    Text(signal.isVideoCall ? "Incoming Video Call" : "Incoming Voice Call")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // Caller avatar with pulse effect
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                        .opacity(pulseAnimation ? 0 : 0.5)

                    Circle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: 100, height: 100)

                    Text(callerInitial)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(.white)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                        pulseAnimation = true
                    }
                }

                // Caller name
                Text(signal.callerDisplayName)
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Spacer()

                // Action buttons
                HStack(spacing: 60) {
                    // Decline
                    VStack(spacing: 8) {
                        Button(action: onDecline) {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                                .frame(width: 72, height: 72)
                                .background(Color.red)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Text("Decline")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Answer
                    VStack(spacing: 8) {
                        Button(action: onAnswer) {
                            Image(systemName: signal.isVideoCall ? "video.fill" : "phone.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                                .frame(width: 72, height: 72)
                                .background(Color.green)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Text("Accept")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
