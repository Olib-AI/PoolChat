// CallManager.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import Combine
import CoreVideo
import ConnectionPool

// MARK: - Call Manager Delegate

/// Delegate protocol for CallManager to send signals and media through the chat pipeline.
@MainActor
public protocol CallManagerDelegate: AnyObject {
    /// Send a call signaling message to specified peers.
    func callManager(_ manager: CallManager, sendSignal signal: CallSignal, to peerIDs: [String])
    /// Send a media frame to specified peers (unreliable for low latency).
    func callManager(_ manager: CallManager, sendMediaFrame data: Data, to peerIDs: [String])
    /// Notify that a call ended (for system message insertion in chat).
    func callManager(_ manager: CallManager, callDidEnd callID: UUID, duration: TimeInterval?, reason: CallEndReason)
    /// Get display name for a peer ID.
    func callManager(_ manager: CallManager, displayNameFor peerID: String) -> String
}

// MARK: - Call Manager

/// Orchestrates call lifecycle: signaling, state machine, and media service coordination.
///
/// Owns at most one active ``CallSession`` at a time. Signaling messages are sent through
/// the ``CallManagerDelegate`` (implemented by ``PoolChatViewModel``) which routes them
/// through the existing encrypted message pipeline.
///
/// Media services (``AudioCallService``, ``VideoCallService``) are started/stopped
/// based on call state transitions.
@MainActor
public final class CallManager: ObservableObject, Sendable {

    // MARK: - Constants

    /// Timeout for outgoing ring (seconds).
    private static let ringTimeoutSeconds: TimeInterval = 45
    /// Timeout for connecting state before giving up.
    private static let connectingTimeoutSeconds: TimeInterval = 15

    // MARK: - Published State

    /// The current active or pending call session, if any.
    @Published public private(set) var currentCall: CallSession?
    /// Incoming call signal awaiting user action (accept/reject).
    @Published public private(set) var incomingCallSignal: CallSignal?
    /// Local camera preview for the active call.
    @Published public private(set) var localVideoBuffer: CVPixelBuffer?
    /// Latest decoded remote video frames keyed by peer ID.
    @Published public private(set) var remoteVideoBuffers: [String: CVPixelBuffer] = [:]

    // MARK: - Dependencies

    /// Delegate for sending signals and media through the chat pipeline.
    public weak var delegate: CallManagerDelegate?

    /// Local peer ID (from ConnectionPoolManager).
    public var localPeerID: String = ""
    /// Local display name.
    public var localDisplayName: String = ""

    // MARK: - Private State

    /// Timer for ring timeout.
    private var ringTimeoutTask: Task<Void, Never>?
    /// Timer for connecting timeout.
    private var connectingTimeoutTask: Task<Void, Never>?
    /// Audio call service (created when audio starts).
    private var audioService: AudioCallService?
    /// Video call service (created when video starts).
    private var videoService: VideoCallService?
    /// Cancellables for Combine subscriptions.
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    public init() {}

    deinit {
        ringTimeoutTask?.cancel()
        connectingTimeoutTask?.cancel()
    }

    // MARK: - Public API: Initiate Call

    /// Start a call to one or more peers.
    ///
    /// - Parameters:
    ///   - peerIDs: The peer IDs to call.
    ///   - video: Whether to include video.
    public func initiateCall(to peerIDs: [String], video: Bool) {
        guard currentCall == nil else {
            log("[CALL] Cannot initiate call: already in a call", level: .warning, category: .network)
            return
        }
        guard !peerIDs.isEmpty else { return }

        let callID = UUID()
        let participantNames = buildParticipantNames(for: peerIDs)

        let session = CallSession(
            id: callID,
            isVideoCall: video,
            participants: peerIDs,
            participantNames: participantNames,
            initiatorPeerID: localPeerID,
            initialState: .outgoingRinging
        )
        currentCall = session

        // Send offer to all recipients
        let signal = CallSignal(
            callID: callID,
            signalType: .offer,
            callerPeerID: localPeerID,
            callerDisplayName: localDisplayName,
            calleePeerIDs: peerIDs,
            isVideoCall: video
        )
        delegate?.callManager(self, sendSignal: signal, to: peerIDs)

        // Start ring timeout
        startRingTimeout(callID: callID)

        log("[CALL] Initiated \(video ? "video" : "audio") call \(callID.uuidString.prefix(8))... to \(peerIDs.count) peer(s)", category: .network)
    }

    // MARK: - Public API: Answer Call

    /// Accept an incoming call.
    public func answerCall() {
        guard let signal = incomingCallSignal,
              let session = currentCall,
              session.state == .incomingRinging else {
            log("[CALL] Cannot answer: no incoming call", level: .warning, category: .network)
            return
        }

        incomingCallSignal = nil
        session.transitionTo(.connecting)

        // Send answer to the caller
        let answer = CallSignal(
            callID: signal.callID,
            signalType: .answer,
            callerPeerID: localPeerID,
            callerDisplayName: localDisplayName,
            calleePeerIDs: [signal.callerPeerID],
            isVideoCall: signal.isVideoCall
        )
        delegate?.callManager(self, sendSignal: answer, to: [signal.callerPeerID])

        // Start media immediately after answering
        startMedia(for: session)

        log("[CALL] Answered call \(signal.callID.uuidString.prefix(8))...", category: .network)
    }

    // MARK: - Public API: Reject Call

    /// Reject an incoming call.
    public func rejectCall() {
        guard let signal = incomingCallSignal else {
            log("[CALL] Cannot reject: no incoming call", level: .warning, category: .network)
            return
        }

        // Send reject to the caller
        let reject = CallSignal(
            callID: signal.callID,
            signalType: .reject,
            callerPeerID: localPeerID,
            callerDisplayName: localDisplayName,
            calleePeerIDs: [signal.callerPeerID],
            isVideoCall: signal.isVideoCall
        )
        delegate?.callManager(self, sendSignal: reject, to: [signal.callerPeerID])

        cleanupCall(reason: .rejected)
        log("[CALL] Rejected call \(signal.callID.uuidString.prefix(8))...", category: .network)
    }

    // MARK: - Public API: End Call

    /// End the current active or ringing call.
    public func endCall() {
        guard let session = currentCall else { return }

        // Send end signal to all participants
        let end = CallSignal(
            callID: session.id,
            signalType: .end,
            callerPeerID: localPeerID,
            callerDisplayName: localDisplayName,
            calleePeerIDs: session.participants,
            isVideoCall: session.isVideoCall
        )
        delegate?.callManager(self, sendSignal: end, to: session.participants)

        cleanupCall(reason: .hungUp)
        log("[CALL] Ended call \(session.id.uuidString.prefix(8))...", category: .network)
    }

    // MARK: - Public API: Media Controls

    /// Toggle local audio mute.
    public func toggleMute() {
        guard let session = currentCall, session.state == .active else { return }
        session.localAudioMuted.toggle()
        audioService?.setMuted(session.localAudioMuted)
        sendMediaControl(for: session)
    }

    /// Toggle local video.
    public func toggleVideo() {
        guard let session = currentCall, session.state == .active, session.isVideoCall else { return }
        session.localVideoEnabled.toggle()
        videoService?.setVideoEnabled(session.localVideoEnabled)
        sendMediaControl(for: session)
    }

    /// Toggle speaker output.
    public func toggleSpeaker() {
        guard let session = currentCall, session.state == .active else { return }
        session.speakerEnabled.toggle()
        audioService?.setSpeakerEnabled(session.speakerEnabled)
    }

    // MARK: - Signal Handling (called by PoolChatViewModel)

    /// Handle an incoming call signal from a remote peer.
    public func handleCallSignal(_ signal: CallSignal, from senderPeerID: String) {
        log("[CALL] Received \(signal.signalType.rawValue) from \(senderPeerID.prefix(8))... for call \(signal.callID.uuidString.prefix(8))...", category: .network)

        switch signal.signalType {
        case .offer:
            handleOffer(signal, from: senderPeerID)
        case .answer:
            handleAnswer(signal, from: senderPeerID)
        case .reject:
            handleReject(signal, from: senderPeerID)
        case .end:
            handleEnd(signal, from: senderPeerID)
        case .busy:
            handleBusy(signal, from: senderPeerID)
        case .mediaControl:
            handleMediaControl(signal, from: senderPeerID)
        case .requestKeyframe:
            handleKeyframeRequest(from: senderPeerID)
        }
    }

    // MARK: - Media Frame Handling (called by PoolChatViewModel)

    /// Handle an incoming media frame from a remote peer.
    public func handleMediaFrame(_ data: Data, from senderPeerID: String) {
        guard let (header, payload) = MediaFrameCodec.unpack(data) else {
            log("[CALL] Failed to unpack media frame from \(senderPeerID.prefix(8))...", level: .warning, category: .network)
            return
        }

        // Verify frame belongs to current call
        guard let session = currentCall, session.id == header.callID,
              (session.state == .active || session.state == .connecting) else {
            return
        }

        switch header.mediaType {
        case .audio:
            audioService?.receiveFrame(header, payload: payload)
        case .video:
            videoService?.receiveFrame(header, payload: payload)
        }
    }

    // MARK: - Peer Disconnect Handling

    /// Called when a peer disconnects from the pool.
    public func handlePeerDisconnected(_ peerID: String) {
        guard let session = currentCall else { return }

        if session.participants.contains(peerID) {
            if session.isGroupCall {
                // In group call, just update participant state
                session.remoteParticipantStates.removeValue(forKey: peerID)
                // If all participants left, end the call
                let remainingConnected = session.participants.filter { pid in
                    session.remoteParticipantStates[pid] != nil
                }
                if remainingConnected.isEmpty {
                    cleanupCall(reason: .disconnected)
                }
            } else {
                // 1-on-1 call: end immediately
                cleanupCall(reason: .disconnected)
            }
        }
    }

    // MARK: - Private: Signal Handlers

    private func handleOffer(_ signal: CallSignal, from senderPeerID: String) {
        if currentCall != nil {
            // Already in a call, send busy
            let busy = CallSignal(
                callID: signal.callID,
                signalType: .busy,
                callerPeerID: localPeerID,
                callerDisplayName: localDisplayName,
                calleePeerIDs: [senderPeerID],
                isVideoCall: signal.isVideoCall
            )
            delegate?.callManager(self, sendSignal: busy, to: [senderPeerID])
            return
        }

        let participantNames = buildParticipantNames(for: [senderPeerID])

        let session = CallSession(
            id: signal.callID,
            isVideoCall: signal.isVideoCall,
            participants: [senderPeerID],
            participantNames: participantNames,
            initiatorPeerID: senderPeerID,
            initialState: .incomingRinging
        )
        currentCall = session
        incomingCallSignal = signal

        // Start ring timeout for the incoming call too
        startRingTimeout(callID: signal.callID)
    }

    private func handleAnswer(_ signal: CallSignal, from senderPeerID: String) {
        guard let session = currentCall,
              session.id == signal.callID,
              session.state == .outgoingRinging else {
            return
        }

        cancelTimeouts()
        session.transitionTo(.connecting)

        // Start media
        startMedia(for: session)
    }

    private func handleReject(_ signal: CallSignal, from senderPeerID: String) {
        guard let session = currentCall,
              session.id == signal.callID else {
            return
        }

        if session.isGroupCall {
            // In group call, just note the rejection
            session.remoteParticipantStates.removeValue(forKey: senderPeerID)
        } else {
            cleanupCall(reason: .rejected)
        }
    }

    private func handleEnd(_ signal: CallSignal, from senderPeerID: String) {
        guard let session = currentCall,
              session.id == signal.callID else {
            return
        }
        cleanupCall(reason: .hungUp)
    }

    private func handleBusy(_ signal: CallSignal, from senderPeerID: String) {
        guard let session = currentCall,
              session.id == signal.callID else {
            return
        }

        if !session.isGroupCall {
            cleanupCall(reason: .busy)
        }
    }

    private func handleMediaControl(_ signal: CallSignal, from senderPeerID: String) {
        guard let session = currentCall,
              session.id == signal.callID,
              let control = signal.mediaControl else {
            return
        }
        session.updateRemoteParticipant(senderPeerID, audioMuted: control.audioMuted, videoEnabled: control.videoEnabled)
    }

    private func handleKeyframeRequest(from senderPeerID: String) {
        videoService?.forceKeyframe()
    }

    // MARK: - Private: Media Lifecycle

    private func startMedia(for session: CallSession) {
        cancelTimeouts()

        // Create audio service
        let audio = AudioCallService()
        audioService = audio

        // Set up audio frame callback
        audio.onFrameEncoded = { [weak self] frameData in
            guard let self else { return }
            Task { @MainActor in
                self.delegate?.callManager(self, sendMediaFrame: frameData, to: session.participants)
            }
        }

        // Start audio capture
        audio.startCapture(
            callID: session.id,
            senderPeerID: localPeerID
        )

        // Start video if needed
        if session.isVideoCall {
            let video = VideoCallService()
            videoService = video
            bindVideoService(video)

            video.onFrameEncoded = { [weak self] frameData in
                guard let self else { return }
                Task { @MainActor in
                    self.delegate?.callManager(self, sendMediaFrame: frameData, to: session.participants)
                }
            }

            video.startCapture(
                callID: session.id,
                senderPeerID: localPeerID
            )
        }

        // Transition to active after a short delay to allow media setup
        startConnectingTimeout(callID: session.id)

        // Transition to active immediately (media services handle their own startup)
        session.transitionTo(.active)
        cancelTimeouts()

        log("[CALL] Media started for call \(session.id.uuidString.prefix(8))...", category: .network)
    }

    private func stopMedia() {
        cancellables.removeAll()
        localVideoBuffer = nil
        remoteVideoBuffers.removeAll()
        audioService?.stopCapture()
        audioService = nil
        videoService?.stopCapture()
        videoService = nil
    }

    // MARK: - Private: Cleanup

    private func cleanupCall(reason: CallEndReason) {
        guard let session = currentCall else { return }

        cancelTimeouts()
        stopMedia()

        let duration = session.activeDuration
        session.endReason = reason
        session.transitionTo(.ending)

        // Notify delegate for system message
        delegate?.callManager(self, callDidEnd: session.id, duration: duration, reason: reason)

        // Clear state
        currentCall = nil
        incomingCallSignal = nil

        log("[CALL] Call \(session.id.uuidString.prefix(8))... ended: \(reason.rawValue), duration: \(duration.map { String(format: "%.0fs", $0) } ?? "n/a")", category: .network)
    }

    // MARK: - Private: Timeouts

    private func startRingTimeout(callID: UUID) {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.ringTimeoutSeconds))
            guard !Task.isCancelled else { return }
            guard let self, let session = self.currentCall,
                  session.id == callID,
                  (session.state == .outgoingRinging || session.state == .incomingRinging) else {
                return
            }
            self.cleanupCall(reason: .timeout)
            log("[CALL] Ring timeout for call \(callID.uuidString.prefix(8))...", category: .network)
        }
    }

    private func startConnectingTimeout(callID: UUID) {
        connectingTimeoutTask?.cancel()
        connectingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectingTimeoutSeconds))
            guard !Task.isCancelled else { return }
            guard let self, let session = self.currentCall,
                  session.id == callID,
                  session.state == .connecting else {
                return
            }
            self.cleanupCall(reason: .timeout)
            log("[CALL] Connecting timeout for call \(callID.uuidString.prefix(8))...", category: .network)
        }
    }

    private func cancelTimeouts() {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil
        connectingTimeoutTask?.cancel()
        connectingTimeoutTask = nil
    }

    private func bindVideoService(_ video: VideoCallService) {
        video.$localPreviewBuffer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffer in
                self?.localVideoBuffer = buffer
            }
            .store(in: &cancellables)

        video.$remoteVideoBuffers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffers in
                self?.remoteVideoBuffers = buffers
            }
            .store(in: &cancellables)
    }

    // MARK: - Private: Helpers

    private func sendMediaControl(for session: CallSession) {
        let control = CallSignal(
            callID: session.id,
            signalType: .mediaControl,
            callerPeerID: localPeerID,
            callerDisplayName: localDisplayName,
            calleePeerIDs: session.participants,
            isVideoCall: session.isVideoCall,
            mediaControl: MediaControlPayload(
                audioMuted: session.localAudioMuted,
                videoEnabled: session.localVideoEnabled
            )
        )
        delegate?.callManager(self, sendSignal: control, to: session.participants)
    }

    private func buildParticipantNames(for peerIDs: [String]) -> [String: String] {
        var names: [String: String] = [:]
        for peerID in peerIDs {
            names[peerID] = delegate?.callManager(self, displayNameFor: peerID) ?? peerID.prefix(8).description
        }
        return names
    }
}
