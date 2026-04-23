// CallSession.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Call State

/// The current state of a call session.
public enum CallState: Sendable, Equatable {
    /// No active call.
    case idle
    /// We initiated a call and are waiting for the remote to answer.
    case outgoingRinging
    /// We received a call offer and are ringing.
    case incomingRinging
    /// Call was answered, establishing media streams.
    case connecting
    /// Call is active with media flowing.
    case active
    /// Call is ending (cleanup in progress).
    case ending
}

// MARK: - Call End Reason

/// Why a call ended, used for UI display and system messages.
public enum CallEndReason: String, Sendable {
    case hungUp = "hung_up"
    case rejected = "rejected"
    case busy = "busy"
    case timeout = "timeout"
    case disconnected = "disconnected"
    case error = "error"
}

// MARK: - Remote Participant State

/// Media state of a remote participant in the call.
public struct RemoteParticipantState: Sendable {
    /// Whether the remote participant's audio is muted.
    public var audioMuted: Bool
    /// Whether the remote participant's camera is enabled.
    public var videoEnabled: Bool

    public init(audioMuted: Bool = false, videoEnabled: Bool = false) {
        self.audioMuted = audioMuted
        self.videoEnabled = videoEnabled
    }
}

// MARK: - Call Session

/// Represents an active or pending call session.
///
/// Created by ``CallManager`` when a call is initiated or received.
/// Published state changes drive the call UI.
@MainActor
public final class CallSession: ObservableObject, Identifiable, Sendable {
    /// Unique identifier for this call.
    public let id: UUID
    /// Whether this is a video call.
    public let isVideoCall: Bool
    /// Peer IDs of all participants (excluding local peer).
    public let participants: [String]
    /// Display names of participants keyed by peer ID.
    public let participantNames: [String: String]
    /// Peer ID of whoever initiated the call.
    public let initiatorPeerID: String
    /// When the call was created (offer sent or received).
    public let createdAt: Date

    /// Current call state.
    @Published public private(set) var state: CallState
    /// Whether the local microphone is muted.
    @Published public var localAudioMuted: Bool = false
    /// Whether the local camera is enabled (video calls only).
    @Published public var localVideoEnabled: Bool = true
    /// Whether speaker output is enabled.
    @Published public var speakerEnabled: Bool = false
    /// Media state of remote participants.
    @Published public var remoteParticipantStates: [String: RemoteParticipantState] = [:]
    /// When the call became active (media connected).
    @Published public var connectedAt: Date?
    /// Why the call ended.
    @Published public var endReason: CallEndReason?

    /// Elapsed duration since the call became active.
    public var activeDuration: TimeInterval? {
        guard let connectedAt else { return nil }
        return Date().timeIntervalSince(connectedAt)
    }

    /// Whether this is a group call (more than one remote participant).
    public var isGroupCall: Bool {
        participants.count > 1
    }

    public init(
        id: UUID,
        isVideoCall: Bool,
        participants: [String],
        participantNames: [String: String],
        initiatorPeerID: String,
        initialState: CallState
    ) {
        self.id = id
        self.isVideoCall = isVideoCall
        self.participants = participants
        self.participantNames = participantNames
        self.initiatorPeerID = initiatorPeerID
        self.createdAt = Date()
        self.state = initialState

        // Initialize remote participant states
        for peerID in participants {
            remoteParticipantStates[peerID] = RemoteParticipantState()
        }
    }

    // MARK: - State Transitions

    func transitionTo(_ newState: CallState) {
        let validTransitions: [CallState: Set<CallState>] = [
            .idle: [.outgoingRinging, .incomingRinging],
            .outgoingRinging: [.connecting, .ending],
            .incomingRinging: [.connecting, .ending],
            .connecting: [.active, .ending],
            .active: [.ending],
            .ending: [.idle],
        ]

        guard let allowed = validTransitions[state], allowed.contains(newState) else {
            log("[CALL] Invalid state transition: \(state) -> \(newState)", level: .warning, category: .network)
            return
        }

        log("[CALL] State transition: \(state) -> \(newState)", category: .network)
        state = newState

        if newState == .active {
            connectedAt = Date()
        }
    }

    func updateRemoteParticipant(_ peerID: String, audioMuted: Bool, videoEnabled: Bool) {
        remoteParticipantStates[peerID] = RemoteParticipantState(
            audioMuted: audioMuted,
            videoEnabled: videoEnabled
        )
    }
}
