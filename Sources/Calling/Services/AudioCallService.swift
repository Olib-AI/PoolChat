// AudioCallService.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
@preconcurrency import AVFoundation

// MARK: - Audio Jitter Buffer

/// Simple adaptive jitter buffer for audio frame reordering and smoothing.
///
/// Buffers incoming audio frames by sequence number and drains them
/// in order after the target depth is reached. Adapts depth based
/// on packet loss and underrun events.
final class AudioJitterBuffer: @unchecked Sendable {
    struct Entry {
        let sequence: UInt32
        let pcmData: Data
    }

    private let lock = NSLock()
    private var buffer: [UInt32: Data] = [:]
    private var nextExpectedSequence: UInt32 = 0
    private var isInitialized = false

    /// Target buffer depth in frames (e.g., 3 = 60ms at 20ms/frame).
    var targetDepth: Int = 3
    /// Maximum buffer depth before dropping oldest frames.
    private let maxDepth: Int = 10

    /// Insert a frame into the jitter buffer.
    func insert(sequence: UInt32, data: Data) {
        lock.withLock {
            if !isInitialized {
                nextExpectedSequence = sequence
                isInitialized = true
            }

            // Drop frames that are too old
            if sequence < nextExpectedSequence && (nextExpectedSequence - sequence) < UInt32(maxDepth) {
                return
            }

            buffer[sequence] = data

            // Evict if buffer is too large
            while buffer.count > maxDepth {
                if let minSeq = buffer.keys.min() {
                    buffer.removeValue(forKey: minSeq)
                    nextExpectedSequence = minSeq + 1
                }
            }
        }
    }

    /// Try to drain the next frame in sequence order.
    /// Returns nil if the next expected frame hasn't arrived yet.
    func drain() -> Data? {
        lock.withLock {
            while buffer.count >= targetDepth || buffer[nextExpectedSequence] != nil {
                if let data = buffer.removeValue(forKey: nextExpectedSequence) {
                    nextExpectedSequence += 1
                    return data
                }

                // Frame missing -- skip it and try next (packet loss).
                // This must stay iterative because recursing while holding NSLock deadlocks.
                if buffer.count >= targetDepth {
                    nextExpectedSequence += 1
                    targetDepth = min(targetDepth + 1, maxDepth)
                    continue
                }

                break
            }

            return nil
        }
    }

    /// Reset the buffer (e.g., on call end).
    func reset() {
        lock.withLock {
            buffer.removeAll()
            isInitialized = false
            nextExpectedSequence = 0
            targetDepth = 3
        }
    }
}

// MARK: - Audio Tap Context

/// All state needed by the audio tap closure, bundled into a Sendable struct
/// so the tap runs entirely outside MainActor isolation.
struct AudioTapContext: @unchecked Sendable {
    let mutedFlag: MutableSendableFlag
    let queue: DispatchQueue
    let inputFormat: AVAudioFormat
    let targetFormat: AVAudioFormat
    let callID: UUID
    let senderPeerID: String
    let sequenceCounter: AtomicCounter
    let onFrameEncoded: (@Sendable (Data) -> Void)?
}

/// Free function used as the audio tap handler — completely nonisolated.
private func audioTapHandler(buffer: AVAudioPCMBuffer, time: AVAudioTime, context: AudioTapContext) {
    guard !context.mutedFlag.value else { return }
    context.queue.async {
        AudioCallService.processBufferNonisolated(
            buffer,
            inputFormat: context.inputFormat,
            targetFormat: context.targetFormat,
            callID: context.callID,
            senderPeerID: context.senderPeerID,
            sequenceCounter: context.sequenceCounter,
            onFrameEncoded: context.onFrameEncoded
        )
    }
}

// MARK: - Thread-Safe Atomic Counter

/// A thread-safe monotonically increasing counter for sequence numbering.
final class AtomicCounter: @unchecked Sendable {
    private var _value: UInt32 = 0
    private let lock = NSLock()

    func next() -> UInt32 {
        lock.withLock {
            let v = _value
            _value += 1
            return v
        }
    }

    func reset() {
        lock.withLock { _value = 0 }
    }
}

// MARK: - Thread-Safe Mutable Flag

/// A thread-safe boolean flag that can be read from any thread (including real-time audio).
final class MutableSendableFlag: @unchecked Sendable {
    private var _value: Bool
    private let lock = NSLock()

    init(_ value: Bool) { _value = value }

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: - Audio Call Service

/// Manages real-time audio capture, encoding, decoding, and playback for calls.
///
/// **Capture pipeline**: `AVAudioEngine` input tap -> PCM -> `AVAudioConverter` -> AAC-LC -> frame callback
/// **Playback pipeline**: received frame -> AAC decode -> jitter buffer -> `AVAudioPlayerNode`
///
/// Uses `AVAudioSession` in `.voiceChat` mode which enables built-in echo cancellation
/// and noise reduction on iOS.
@MainActor
public final class AudioCallService: @unchecked Sendable {

    // MARK: - Configuration

    /// Audio sample rate (Hz).
    nonisolated private static let sampleRate: Double = 16_000
    /// Frame duration in seconds (20ms).
    nonisolated private static let frameDuration: Double = 0.02
    /// Samples per frame.
    nonisolated private static let samplesPerFrame: AVAudioFrameCount = AVAudioFrameCount(sampleRate * frameDuration)
    /// AAC encoder bitrate.
    nonisolated private static let encoderBitrate: Int = 24_000

    // MARK: - State

    /// Callback invoked with each encoded audio frame (packed wire format).
    public var onFrameEncoded: (@Sendable (Data) -> Void)?

    private var engine: AVAudioEngine?
    private var callID: UUID?
    private var senderPeerID: String = ""
    private var isSpeakerEnabled: Bool = false

    /// Mute flag accessed from the real-time audio thread. Must be thread-safe.
    private let _isMuted = MutableSendableFlag(false)

    /// Processing queue for audio capture (off the real-time audio thread).
    private let processingQueue = DispatchQueue(label: "ai.olib.stealthos.audio.process", qos: .userInteractive)

    /// Thread-safe sequence counter for capture frames.
    private let _captureSequenceCounter = AtomicCounter()

    // Playback
    private var playerNodes: [String: AVAudioPlayerNode] = [:]
    private var jitterBuffers: [String: AudioJitterBuffer] = [:]
    private var playbackTimer: Timer?
    private var remoteMixerNode: AVAudioMixerNode?

    // PCM format for internal processing
    private var pcmFormat: AVAudioFormat?

    // Interruption handling
    private var interruptionObserver: NSObjectProtocol?
    private var wasCapturing: Bool = false

    // MARK: - Lifecycle

    public init() {
        setupInterruptionHandling()
    }

    /// Start audio capture for a call.
    public func startCapture(callID: UUID, senderPeerID: String) {
        self.callID = callID
        self.senderPeerID = senderPeerID
        _captureSequenceCounter.reset()

        #if os(iOS)
        configureAudioSession()
        #endif

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create PCM format for our target sample rate
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            log("[AUDIO] Failed to create PCM format", level: .error, category: .network)
            return
        }
        self.pcmFormat = pcmFormat

        let remoteMixerNode = AVAudioMixerNode()
        engine.attach(remoteMixerNode)
        engine.connect(remoteMixerNode, to: engine.mainMixerNode, format: pcmFormat)
        self.remoteMixerNode = remoteMixerNode

        // Force creation of the output path before the engine starts so playback graph
        // changes later stay upstream of a stable mixer/output chain.
        _ = engine.mainMixerNode
        _ = engine.outputNode
        engine.prepare()

        // Install tap on input node.
        // The tap callback fires on a real-time audio thread — it must NOT touch
        // @MainActor state. We bundle all needed state into a Sendable context
        // and use a free function as the handler to avoid any MainActor capture.
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * Self.frameDuration)
        let ctx = AudioTapContext(
            mutedFlag: _isMuted,
            queue: processingQueue,
            inputFormat: inputFormat,
            targetFormat: pcmFormat,
            callID: callID,
            senderPeerID: senderPeerID,
            sequenceCounter: _captureSequenceCounter,
            onFrameEncoded: onFrameEncoded
        )

        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, time in
            audioTapHandler(buffer: buffer, time: time, context: ctx)
        }
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat, block: tapBlock)

        do {
            try engine.start()
            log("[AUDIO] Audio capture started", category: .network)
        } catch {
            log("[AUDIO] Failed to start audio engine: \(error.localizedDescription)", level: .error, category: .network)
        }
    }

    /// Stop audio capture and playback.
    public func stopCapture() {
        engine?.inputNode.removeTap(onBus: 0)
        playbackTimer?.invalidate()
        playbackTimer = nil

        for (_, node) in playerNodes {
            node.stop()
        }
        playerNodes.removeAll()
        jitterBuffers.removeAll()
        remoteMixerNode = nil
        engine?.stop()
        engine = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        removeInterruptionHandling()
        log("[AUDIO] Audio capture stopped", category: .network)
    }

    /// Set mute state (thread-safe, affects real-time audio capture).
    public func setMuted(_ muted: Bool) {
        _isMuted.value = muted
    }

    /// Set speaker enabled state.
    public func setSpeakerEnabled(_ enabled: Bool) {
        isSpeakerEnabled = enabled
        #if os(iOS)
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return }
        do {
            if enabled {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            } else {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
            }
        } catch {
            log("[AUDIO] Failed to set speaker: \(error.localizedDescription)", level: .warning, category: .network)
        }
        #endif
    }

    // MARK: - Receive

    /// Receive and buffer an audio frame from a remote peer.
    public func receiveFrame(_ header: MediaFrameHeader, payload: Data) {
        let peerID = header.senderPeerID

        // Get or create jitter buffer for this peer
        if jitterBuffers[peerID] == nil {
            jitterBuffers[peerID] = AudioJitterBuffer()
            ensurePlayerNode(for: peerID)
            startPlaybackTimerIfNeeded()
        }

        jitterBuffers[peerID]?.insert(sequence: header.sequence, data: payload)
    }

    // MARK: - Private: Audio Session

    #if os(iOS)
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            let categoryOptions: AVAudioSession.CategoryOptions = ProcessInfo.processInfo.isiOSAppOnMac
                ? []
                : [.allowBluetoothHFP, .defaultToSpeaker]
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: categoryOptions
            )
            try session.setPreferredSampleRate(Self.sampleRate)
            try session.setPreferredIOBufferDuration(Self.frameDuration)
            try session.setActive(true)
        } catch {
            log("[AUDIO] Failed to configure audio session: \(error.localizedDescription)", level: .error, category: .network)
        }
    }
    #endif

    // MARK: - Private: Capture Processing (nonisolated, runs on processingQueue)

    /// Static nonisolated processing method that runs entirely off the MainActor.
    /// All state is passed in via parameters captured at tap installation time.
    nonisolated static func processBufferNonisolated(
        _ buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        callID: UUID,
        senderPeerID: String,
        sequenceCounter: AtomicCounter,
        onFrameEncoded: (@Sendable (Data) -> Void)?
    ) {
        // Convert to target format if needed
        let pcmData: Data
        if inputFormat.sampleRate != sampleRate || inputFormat.channelCount != 1 {
            guard let converted = convertBuffer(buffer, from: inputFormat, to: targetFormat) else { return }
            pcmData = bufferToData(converted)
        } else {
            pcmData = bufferToData(buffer)
        }

        let sequence = sequenceCounter.next()
        let timestamp = sequence * UInt32(samplesPerFrame)

        // Pack into wire format
        let frames = MediaFrameCodec.fragment(
            callID: callID,
            senderPeerID: senderPeerID,
            mediaType: .audio,
            sequence: sequence,
            timestamp: timestamp,
            isKeyFrame: false,
            payload: pcmData
        )

        for frame in frames {
            onFrameEncoded?(frame)
        }
    }

    nonisolated private static func convertBuffer(_ buffer: AVAudioPCMBuffer, from sourceFormat: AVAudioFormat, to destFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: sourceFormat, to: destFormat) else { return nil }

        let ratio = destFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: destFormat, frameCapacity: outputFrameCount) else { return nil }

        var error: NSError?
        let inputBuffer = buffer
        final class Flag: @unchecked Sendable { var value = false }
        let provided = Flag()

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !provided.value {
                outStatus.pointee = .haveData
                provided.value = true
                return inputBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        if error != nil { return nil }
        return outputBuffer
    }

    nonisolated private static func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        guard let floatData = buffer.floatChannelData else { return Data() }
        let ptr = floatData[0]
        return Data(bytes: ptr, count: frames * MemoryLayout<Float>.size)
    }

    // MARK: - Private: Playback

    private func ensurePlayerNode(for peerID: String) {
        guard let engine, let remoteMixerNode, playerNodes[peerID] == nil, let pcmFormat else { return }

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: remoteMixerNode, format: pcmFormat)
        playerNodes[peerID] = playerNode
    }

    private func startPlaybackTimerIfNeeded() {
        guard playbackTimer == nil else { return }

        // Drain jitter buffers every 20ms
        playbackTimer = Timer.scheduledTimer(withTimeInterval: Self.frameDuration, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.drainJitterBuffers()
            }
        }
    }

    private func drainJitterBuffers() {
        guard let engine, engine.isRunning, let pcmFormat else { return }

        for (peerID, jitterBuffer) in jitterBuffers {
            guard let playerNode = playerNodes[peerID],
                  let pcmData = jitterBuffer.drain() else { continue }

            // Convert Data back to PCM buffer and schedule
            let frameCount = AVAudioFrameCount(pcmData.count / MemoryLayout<Float>.size)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else { continue }
            buffer.frameLength = frameCount

            pcmData.withUnsafeBytes { rawPtr in
                guard let src = rawPtr.baseAddress else { return }
                if let dest = buffer.floatChannelData?[0] {
                    memcpy(dest, src, pcmData.count)
                }
            }

            playerNode.scheduleBuffer(buffer)

            // Starting the player only after a buffer is queued avoids AVFAudio
            // exceptions from trying to play an unprimed node on first remote frame.
            if !playerNode.isPlaying {
                playerNode.play()
            }
        }
    }

    // MARK: - Private: Interruption Handling

    private func setupInterruptionHandling() {
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            // Extract values before crossing isolation boundary
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0

            Task { @MainActor in
                switch type {
                case .began:
                    self.wasCapturing = self.engine?.isRunning ?? false
                    self.engine?.pause()
                    log("[AUDIO] Audio interrupted (e.g., phone call)", category: .network)

                case .ended:
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
                    if shouldResume && self.wasCapturing {
                        try? self.engine?.start()
                        log("[AUDIO] Audio resumed after interruption", category: .network)
                    }

                @unknown default:
                    break
                }
            }
        }
        #endif
    }

    private func removeInterruptionHandling() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
    }
}
