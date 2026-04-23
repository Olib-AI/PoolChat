// CallSignal.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Call Signal Type

/// Types of call signaling messages exchanged between peers.
public enum CallSignalType: String, Codable, Sendable {
    /// Initiator sends to recipient(s) to start a call.
    case offer = "offer"
    /// Recipient accepts the call.
    case answer = "answer"
    /// Recipient rejects the call.
    case reject = "reject"
    /// Either party ends the active call.
    case end = "end"
    /// Recipient is already in another call.
    case busy = "busy"
    /// Media state change notification (mute/unmute, camera on/off).
    case mediaControl = "media_control"
    /// Request for a keyframe (video only, after packet loss).
    case requestKeyframe = "request_keyframe"
}

// MARK: - Call Signal

/// A signaling message for call lifecycle management.
///
/// Sent through the existing `EncryptedChatPayload` pipeline using
/// `EncryptedMessageType.callSignal`. All signals are E2E encrypted.
public struct CallSignal: Codable, Sendable, Identifiable {
    /// Unique identifier for this call session.
    public let callID: UUID
    /// The type of signaling message.
    public let signalType: CallSignalType
    /// Peer ID of the call initiator.
    public let callerPeerID: String
    /// Display name of the caller (for UI).
    public let callerDisplayName: String
    /// Peer IDs of all call recipients.
    public let calleePeerIDs: [String]
    /// Whether this is a video call (false = audio only).
    public let isVideoCall: Bool
    /// Timestamp of signal creation.
    public let timestamp: Date
    /// Media control payload (only for `.mediaControl` type).
    public let mediaControl: MediaControlPayload?

    public var id: UUID { callID }

    public init(
        callID: UUID,
        signalType: CallSignalType,
        callerPeerID: String,
        callerDisplayName: String,
        calleePeerIDs: [String],
        isVideoCall: Bool,
        timestamp: Date = Date(),
        mediaControl: MediaControlPayload? = nil
    ) {
        self.callID = callID
        self.signalType = signalType
        self.callerPeerID = callerPeerID
        self.callerDisplayName = callerDisplayName
        self.calleePeerIDs = calleePeerIDs
        self.isVideoCall = isVideoCall
        self.timestamp = timestamp
        self.mediaControl = mediaControl
    }
}

// MARK: - Media Control Payload

/// Payload for media state change notifications during an active call.
public struct MediaControlPayload: Codable, Sendable {
    /// Whether the sender's microphone is muted.
    public let audioMuted: Bool
    /// Whether the sender's camera is enabled.
    public let videoEnabled: Bool
    /// Whether the sender is requesting a keyframe from the recipient (video only).
    public let requestKeyframe: Bool

    public init(
        audioMuted: Bool,
        videoEnabled: Bool,
        requestKeyframe: Bool = false
    ) {
        self.audioMuted = audioMuted
        self.videoEnabled = videoEnabled
        self.requestKeyframe = requestKeyframe
    }
}
