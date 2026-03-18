// VoiceRecordingService.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import AVFoundation
import Combine

/// Service for recording and playing back voice messages
@MainActor
public final class VoiceRecordingService: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var isRecording = false
    @Published public private(set) var isPlaying = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var playbackProgress: Double = 0

    // MARK: - Private Properties

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?

    // MARK: - Constants

    private static let maxRecordingDuration: TimeInterval = 60 // 1 minute max

    // MARK: - Audio Session State

    /// Track whether audio session has been configured to avoid redundant setup
    private var isAudioSessionConfigured = false

    // MARK: - Initialization

    public override init() {
        super.init()
        // NOTE: Audio session setup is DEFERRED until first recording.
        // Setting up AVAudioSession synchronously during init can HANG on macOS
        // if the audio system is in a bad state or another app holds the device.
        // This was causing Pool Chat to freeze immediately after opening.
    }

    /// Configure audio session for recording - called lazily before first recording.
    /// This is intentionally NOT called during init() to prevent blocking the main thread.
    private func ensureAudioSessionConfigured() {
        guard !isAudioSessionConfigured else { return }

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // macOS ("Designed for iPad") does not support .defaultToSpeaker or .allowBluetoothA2DP
            let categoryOptions: AVAudioSession.CategoryOptions = ProcessInfo.processInfo.isiOSAppOnMac ? [] : [.defaultToSpeaker, .allowBluetoothA2DP]
            try session.setCategory(.playAndRecord, mode: .default, options: categoryOptions)
            try session.setActive(true)
            isAudioSessionConfigured = true
            log("Audio session configured successfully", category: .general)
        } catch {
            log("Failed to setup audio session: \(error.localizedDescription)", level: .error, category: .general)
        }
        #else
        isAudioSessionConfigured = true
        #endif
    }

    // MARK: - Recording

    /// Start recording a voice message
    public func startRecording() {
        guard !isRecording else { return }

        // Request microphone permission
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                if granted {
                    self?.beginRecording()
                } else {
                    log("Microphone permission denied", category: .general)
                }
            }
        }
    }

    private func beginRecording() {
        // Ensure audio session is configured (lazy setup to avoid init hang)
        ensureAudioSessionConfigured()

        // Create a unique file URL for the recording
        let documentsPath = FileManager.default.temporaryDirectory
        let fileName = "voice_\(UUID().uuidString).m4a"
        recordingURL = documentsPath.appendingPathComponent(fileName)

        guard let url = recordingURL else { return }

        // Audio settings for good quality but reasonable file size
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()

            isRecording = true
            recordingDuration = 0

            // Start timer to track duration
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.recordingDuration = self.audioRecorder?.currentTime ?? 0

                    // Stop if max duration reached
                    if self.recordingDuration >= Self.maxRecordingDuration {
                        self.stopRecording()
                    }
                }
            }

            log("Started recording", category: .general)
        } catch {
            log("Failed to start recording: \(error.localizedDescription)", category: .general)
        }
    }

    /// Stop recording and return the recorded data
    /// - Returns: Tuple of (audio data, duration) or nil if recording failed
    public func stopRecording() -> (Data, TimeInterval)? {
        guard isRecording else { return nil }

        recordingTimer?.invalidate()
        recordingTimer = nil

        let duration = recordingDuration

        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false

        // Read the recorded file
        guard let url = recordingURL,
              let data = try? Data(contentsOf: url) else {
            log("Failed to read recorded audio", category: .general)
            return nil
        }

        // Clean up the temporary file
        try? FileManager.default.removeItem(at: url)
        recordingURL = nil

        log("Stopped recording, duration: \(duration)s, size: \(data.count) bytes", category: .general)
        return (data, duration)
    }

    /// Cancel recording without saving
    public func cancelRecording() {
        guard isRecording else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        recordingDuration = 0

        // Delete the temporary file
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil

        log("Cancelled recording", category: .general)
    }

    // MARK: - Playback

    /// Play a voice message from data
    /// - Parameter data: The audio data to play
    public func play(data: Data) {
        guard !isPlaying else {
            stop()
            return
        }

        // Ensure audio session is configured (lazy setup to avoid init hang)
        ensureAudioSessionConfigured()

        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.play()

            isPlaying = true
            playbackProgress = 0

            // Start timer to track progress
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self,
                          let player = self.audioPlayer else { return }

                    self.playbackProgress = player.currentTime / player.duration
                }
            }

            log("Started playback", category: .general)
        } catch {
            log("Failed to play audio: \(error.localizedDescription)", category: .general)
        }
    }

    /// Stop playback
    public func stop() {
        playbackTimer?.invalidate()
        playbackTimer = nil

        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playbackProgress = 0

        log("Stopped playback", category: .general)
    }

    /// Seek to a specific position (0-1)
    public func seek(to progress: Double) {
        guard let player = audioPlayer else { return }
        player.currentTime = player.duration * progress
        playbackProgress = progress
    }
}

// MARK: - AVAudioRecorderDelegate

extension VoiceRecordingService: AVAudioRecorderDelegate {
    nonisolated public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag {
                log("Recording finished unsuccessfully", category: .general)
            }
        }
    }

    nonisolated public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            if let error = error {
                log("Recording error: \(error.localizedDescription)", category: .general)
            }
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension VoiceRecordingService: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            playbackTimer?.invalidate()
            playbackTimer = nil
            isPlaying = false
            playbackProgress = 0
            log("Playback finished", category: .general)
        }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            if let error = error {
                log("Playback error: \(error.localizedDescription)", category: .general)
            }
        }
    }
}

// MARK: - Duration Formatting

extension TimeInterval {
    /// Format duration as mm:ss
    public var formattedDuration: String {
        let minutes = Int(self) / 60
        let seconds = Int(self) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
