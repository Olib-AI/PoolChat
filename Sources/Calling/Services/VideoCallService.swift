// VideoCallService.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Video Jitter Buffer

/// Simple jitter buffer for video frame fragment reassembly.
///
/// Reassembles fragmented video frames and yields complete frames
/// in sequence order once all fragments arrive.
final class VideoJitterBuffer: @unchecked Sendable {
    struct PendingFrame {
        let sequence: UInt32
        let totalFragments: UInt8
        var receivedFragments: [UInt8: Data]
        let isKeyFrame: Bool
        let receivedAt: Date

        var isComplete: Bool {
            receivedFragments.count == Int(totalFragments)
        }

        func reassemble() -> Data {
            var result = Data()
            for i in 0..<totalFragments {
                if let fragment = receivedFragments[i] {
                    result.append(fragment)
                }
            }
            return result
        }
    }

    private let lock = NSLock()
    private var pendingFrames: [UInt32: PendingFrame] = [:]
    private var nextExpectedSequence: UInt32 = 0
    private var isInitialized = false
    private let maxPendingFrames = 5
    /// Maximum age before dropping an incomplete frame.
    private let maxFrameAge: TimeInterval = 0.2

    /// Insert a fragment into the jitter buffer.
    /// Returns a complete reassembled frame if all fragments for a sequence have arrived.
    func insert(_ header: MediaFrameHeader, payload: Data) -> (sequence: UInt32, data: Data, isKeyFrame: Bool)? {
        lock.withLock {
            if !isInitialized {
                nextExpectedSequence = header.sequence
                isInitialized = true
            }

            // Create or update pending frame
            if pendingFrames[header.sequence] == nil {
                pendingFrames[header.sequence] = PendingFrame(
                    sequence: header.sequence,
                    totalFragments: header.totalFragments,
                    receivedFragments: [:],
                    isKeyFrame: header.isKeyFrame,
                    receivedAt: Date()
                )
            }

            pendingFrames[header.sequence]?.receivedFragments[header.fragmentIndex] = payload

            // Check if frame is complete
            if let frame = pendingFrames[header.sequence], frame.isComplete {
                pendingFrames.removeValue(forKey: header.sequence)
                nextExpectedSequence = header.sequence + 1

                // Clean up stale frames
                evictStaleFrames()

                return (header.sequence, frame.reassemble(), frame.isKeyFrame)
            }

            // Evict old incomplete frames
            evictStaleFrames()

            return nil
        }
    }

    private func evictStaleFrames() {
        let now = Date()
        let staleKeys = pendingFrames.filter { now.timeIntervalSince($0.value.receivedAt) > maxFrameAge }.map(\.key)
        for key in staleKeys {
            pendingFrames.removeValue(forKey: key)
        }

        // Keep buffer bounded
        while pendingFrames.count > maxPendingFrames {
            if let oldest = pendingFrames.min(by: { $0.key < $1.key })?.key {
                pendingFrames.removeValue(forKey: oldest)
            }
        }
    }

    func reset() {
        lock.withLock {
            pendingFrames.removeAll()
            isInitialized = false
            nextExpectedSequence = 0
        }
    }
}

// MARK: - Video Call Service

/// Manages real-time video capture, H.264 encoding, decoding, and rendering for calls.
///
/// **Capture pipeline**: `AVCaptureSession` -> `AVCaptureVideoDataOutput` -> `VTCompressionSession` (H.264) -> frame callback
/// **Playback pipeline**: received NAL units -> `VTDecompressionSession` -> `CVPixelBuffer` -> published for SwiftUI rendering
@MainActor
public final class VideoCallService: NSObject, @unchecked Sendable {

    // MARK: - Configuration

    /// Target frames per second.
    private static let targetFPS: Int = 15
    /// Target bitrate (bits per second).
    private static let targetBitrate: Int = 300_000
    /// Keyframe interval in frames.
    private static let keyframeInterval: Int = 30

    // MARK: - Published State

    /// Local camera preview pixel buffer.
    @Published public var localPreviewBuffer: CVPixelBuffer?
    /// Remote peer video buffers keyed by peer ID.
    @Published public var remoteVideoBuffers: [String: CVPixelBuffer] = [:]

    // MARK: - State

    /// Callback invoked with each encoded video frame (packed wire format).
    public var onFrameEncoded: (@Sendable (Data) -> Void)?

    private var captureSession: AVCaptureSession?
    private var compressionSession: VTCompressionSession?
    private var decompressionSessions: [String: VTDecompressionSession] = [:]
    private var jitterBuffers: [String: VideoJitterBuffer] = [:]
    private var captureSequence: UInt32 = 0
    private var callID: UUID?
    private var senderPeerID: String = ""
    private var isEnabled: Bool = true
    private var forceNextKeyframe: Bool = false

    // Video data output delegate queue
    private let videoQueue = DispatchQueue(label: "ai.olib.stealthos.video.capture", qos: .userInteractive)

    // MARK: - Lifecycle

    public override init() {
        super.init()
    }

    /// Start video capture for a call.
    public func startCapture(callID: UUID, senderPeerID: String) {
        self.callID = callID
        self.senderPeerID = senderPeerID
        self.captureSequence = 0
        self.forceNextKeyframe = true

        setupCaptureSession()

        captureSession?.startRunning()
        log("[VIDEO] Video capture started", category: .network)
    }

    /// Stop video capture.
    public func stopCapture() {
        captureSession?.stopRunning()
        captureSession = nil

        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }

        for (_, session) in decompressionSessions {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSessions.removeAll()
        jitterBuffers.removeAll()
        remoteVideoBuffers.removeAll()

        log("[VIDEO] Video capture stopped", category: .network)
    }

    /// Enable/disable video capture.
    public func setVideoEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            localPreviewBuffer = nil
        }
    }

    /// Force next encoded frame to be a keyframe.
    public func forceKeyframe() {
        forceNextKeyframe = true
    }

    // MARK: - Receive

    /// Receive a video frame fragment from a remote peer.
    public func receiveFrame(_ header: MediaFrameHeader, payload: Data) {
        let peerID = header.senderPeerID

        if jitterBuffers[peerID] == nil {
            jitterBuffers[peerID] = VideoJitterBuffer()
        }

        guard let result = jitterBuffers[peerID]?.insert(header, payload: payload) else { return }

        // Decode the complete frame
        decodeFrame(result.data, from: peerID, isKeyFrame: result.isKeyFrame)
    }

    // MARK: - Private: Capture Session

    private func setupCaptureSession() {
        #if os(iOS)
        let session = AVCaptureSession()

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            log("[VIDEO] Failed to access front camera", level: .error, category: .network)
            return
        }

        let preferredPreset: AVCaptureSession.Preset = ProcessInfo.processInfo.isiOSAppOnMac ? .hd1280x720 : .vga640x480
        if session.canSetSessionPreset(preferredPreset) {
            session.sessionPreset = preferredPreset
        } else {
            session.sessionPreset = .high
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        output.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        // Set frame rate
        if let connection = output.connection(with: .video) {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        do {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(Self.targetFPS))
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(Self.targetFPS))
            camera.unlockForConfiguration()
        } catch {
            log("[VIDEO] Failed to configure camera FPS: \(error.localizedDescription)", level: .warning, category: .network)
        }

        self.captureSession = session
        #endif
    }

    private func setupCompressionSession(width: Int32, height: Int32) {
        var session: VTCompressionSession?

        // C callback for VTCompressionSession output
        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let refcon else { return }
            let service = Unmanaged<VideoCallService>.fromOpaque(refcon).takeUnretainedValue()
            service.handleEncodedFrame(sampleBuffer)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: refcon,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            log("[VIDEO] Failed to create compression session: \(status)", level: .error, category: .network)
            return
        }

        // Configure encoder
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: Self.targetBitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Self.keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.compressionSession = session
    }

    // MARK: - Private: Encoding

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let callID else { return }

        // Check if keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true

        // Extract encoded data
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == noErr, let dataPointer else { return }

        var encodedData = Data(bytes: dataPointer, count: length)

        // Decompression setup on the receiver depends on SPS/PPS arriving in-band.
        // VTCompressionSession usually exposes them on the sample buffer format
        // description instead of including them in every block buffer payload.
        if isKeyFrame,
           let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
           let parameterSets = extractParameterSets(from: formatDescription) {
            var keyframePayload = Data()
            keyframePayload.append(parameterSets.sps)
            keyframePayload.append(parameterSets.pps)
            keyframePayload.append(encodedData)
            encodedData = keyframePayload
        }

        let sequence = captureSequence
        captureSequence += 1
        let timestamp = UInt32(sequence) * UInt32(90_000 / Self.targetFPS)

        // Fragment and send
        let fragments = MediaFrameCodec.fragment(
            callID: callID,
            senderPeerID: senderPeerID,
            mediaType: .video,
            sequence: sequence,
            timestamp: timestamp,
            isKeyFrame: isKeyFrame,
            payload: encodedData
        )

        for fragment in fragments {
            onFrameEncoded?(fragment)
        }
    }

    private func extractParameterSets(from formatDescription: CMFormatDescription) -> (sps: Data, pps: Data)? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        var parameterSetCount = 0
        var nalHeaderLength: Int32 = 0

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        guard spsStatus == noErr,
              ppsStatus == noErr,
              let spsPointer,
              let ppsPointer else {
            return nil
        }

        return (
            avccNALUnit(from: spsPointer, size: spsSize),
            avccNALUnit(from: ppsPointer, size: ppsSize)
        )
    }

    private func avccNALUnit(from pointer: UnsafePointer<UInt8>, size: Int) -> Data {
        var length = UInt32(size).bigEndian
        var data = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        data.append(pointer, count: size)
        return data
    }

    // MARK: - Private: Decoding

    private func decodeFrame(_ data: Data, from peerID: String, isKeyFrame: Bool) {
        // Create format description from the H.264 data
        // The encoded data from VTCompressionSession uses AVCC format (length-prefixed NAL units)
        guard data.count > 4 else { return }

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            let totalLength = data.count

            // Parse AVCC NAL units: [4-byte length][NAL unit data]
            var offset = 0
            var spsData: Data?
            var ppsData: Data?
            var accessUnit = Data()

            while offset + 4 < totalLength {
                let nalLength = Int(ptr[offset]) << 24 | Int(ptr[offset + 1]) << 16 |
                                Int(ptr[offset + 2]) << 8 | Int(ptr[offset + 3])
                offset += 4

                guard offset + nalLength <= totalLength, nalLength > 0 else { break }

                let nalType = ptr[offset] & 0x1F
                if nalType == 7 { // SPS
                    spsData = Data(bytes: ptr + offset, count: nalLength)
                } else if nalType == 8 { // PPS
                    ppsData = Data(bytes: ptr + offset, count: nalLength)
                } else {
                    accessUnit.append(ptr + offset - 4, count: nalLength + 4)
                }

                offset += nalLength
            }

            // Create or update decompression session if we have SPS/PPS
            if let sps = spsData, let pps = ppsData {
                createDecompressionSession(for: peerID, sps: sps, pps: pps)
            }

            // Decode each non-parameter-set NAL unit
            guard let session = decompressionSessions[peerID] else { return }
            guard !accessUnit.isEmpty else { return }
            decodeNALUnit(accessUnit, session: session, peerID: peerID)
        }
    }

    /// Per-peer format descriptions for H.264 decoding.
    private var formatDescriptions: [String: CMFormatDescription] = [:]

    private func createDecompressionSession(for peerID: String, sps: Data, pps: Data) {
        // Invalidate existing session
        if let existing = decompressionSessions[peerID] {
            VTDecompressionSessionInvalidate(existing)
            decompressionSessions.removeValue(forKey: peerID)
        }

        // Create format description from SPS/PPS
        var formatDescription: CMFormatDescription?

        let status: OSStatus = sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                guard let spsBase = spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return errSecParam
                }
                var ptrs: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil,
                    parameterSetCount: 2,
                    parameterSetPointers: &ptrs,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }

        guard status == noErr, let formatDesc = formatDescription else {
            log("[VIDEO] Failed to create format description for peer \(peerID.prefix(8))...: \(status)", level: .warning, category: .network)
            return
        }

        formatDescriptions[peerID] = formatDesc

        // Create decompression session with output handler
        let decoderConfig: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]

        // C callback record for decompression output.
        // The frameRefcon passed per-frame in decodeNALUnit carries the output pointer.
        let decompCallback: VTDecompressionOutputCallback = { _, sourceFrameRefCon, status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer, let sourceFrameRefCon else { return }
            let ctx = sourceFrameRefCon.assumingMemoryBound(to: CVPixelBuffer?.self)
            ctx.pointee = imageBuffer
        }
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompCallback,
            decompressionOutputRefCon: nil
        )

        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: decoderConfig as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        guard createStatus == noErr, let session else {
            log("[VIDEO] Failed to create decompression session: \(createStatus)", level: .warning, category: .network)
            return
        }

        decompressionSessions[peerID] = session
        log("[VIDEO] Created decompression session for peer \(peerID.prefix(8))...", category: .network)
    }

    private func decodeNALUnit(_ nalData: Data, session: VTDecompressionSession, peerID: String) {
        guard let formatDesc = formatDescriptions[peerID] else { return }

        // Create CMBlockBuffer with a copy of the data
        var blockBuffer: CMBlockBuffer?
        let dataLength = nalData.count

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return }

        status = nalData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return errSecParam }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }
        guard status == noErr else { return }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength
        status = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }

        // Decode synchronously using the callback set at session creation.
        // The frameRefcon pointer receives the decoded pixel buffer from the callback.
        var flagsOut = VTDecodeInfoFlags()

        let context = UnsafeMutablePointer<CVPixelBuffer?>.allocate(capacity: 1)
        context.initialize(to: nil)

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: context,
            infoFlagsOut: &flagsOut
        )

        // Wait for the callback to fire
        VTDecompressionSessionWaitForAsynchronousFrames(session)

        let decoded = context.pointee
        context.deinitialize(count: 1)
        context.deallocate()

        if decodeStatus == noErr, let decoded {
            remoteVideoBuffers[peerID] = decoded
        } else if decodeStatus != noErr {
            log("[VIDEO] Decode error for peer \(peerID.prefix(8))...: \(decodeStatus)", level: .warning, category: .network)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension VideoCallService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Extract values before crossing isolation boundary to avoid Sendable warnings.
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // ARC retains the pixel buffer via the let binding; safe to send across isolation.
        nonisolated(unsafe) let sendablePixelBuffer = pixelBuffer

        Task { @MainActor [weak self] in
            guard let self, self.isEnabled else { return }

            // Update local preview
            self.localPreviewBuffer = sendablePixelBuffer

            // Encode for transmission
            if self.compressionSession == nil {
                self.setupCompressionSession(
                    width: Int32(CVPixelBufferGetWidth(sendablePixelBuffer)),
                    height: Int32(CVPixelBufferGetHeight(sendablePixelBuffer))
                )
            }

            if let compressionSession = self.compressionSession {
                var properties: [CFString: Any]? = nil

                if self.forceNextKeyframe {
                    properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
                    self.forceNextKeyframe = false
                }

                VTCompressionSessionEncodeFrame(
                    compressionSession,
                    imageBuffer: sendablePixelBuffer,
                    presentationTimeStamp: presentationTime,
                    duration: .invalid,
                    frameProperties: properties as CFDictionary?,
                    sourceFrameRefcon: nil,
                    infoFlagsOut: nil
                )
            }
        }
    }
}
