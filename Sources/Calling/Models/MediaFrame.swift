// MediaFrame.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Media Type

/// Type of media being transported in a frame.
public enum CallMediaType: String, Codable, Sendable {
    case audio = "audio"
    case video = "video"
}

// MARK: - Media Frame Header

/// Header for a media frame transported through the ConnectionPool.
///
/// The wire format after encryption is:
/// `[4 bytes: header JSON length (big-endian)] [N bytes: header JSON] [M bytes: codec payload]`
///
/// Audio frames are always unfragmented (single frame ~60-120 bytes).
/// Video frames may be fragmented into multiple packets of <= 60KB each.
public struct MediaFrameHeader: Codable, Sendable {
    /// Call session this frame belongs to.
    public let callID: UUID
    /// Peer ID of the frame sender.
    public let senderPeerID: String
    /// Whether this is audio or video.
    public let mediaType: CallMediaType
    /// Monotonically increasing sequence number per sender per media type.
    public let sequence: UInt32
    /// RTP-style timestamp (16kHz clock for audio, 90kHz for video).
    public let timestamp: UInt32
    /// Fragment index within a single encoded frame (0-based).
    public let fragmentIndex: UInt8
    /// Total number of fragments for this frame (1 = unfragmented).
    public let totalFragments: UInt8
    /// Whether this is a keyframe (video only, always false for audio).
    public let isKeyFrame: Bool

    public init(
        callID: UUID,
        senderPeerID: String,
        mediaType: CallMediaType,
        sequence: UInt32,
        timestamp: UInt32,
        fragmentIndex: UInt8 = 0,
        totalFragments: UInt8 = 1,
        isKeyFrame: Bool = false
    ) {
        self.callID = callID
        self.senderPeerID = senderPeerID
        self.mediaType = mediaType
        self.sequence = sequence
        self.timestamp = timestamp
        self.fragmentIndex = fragmentIndex
        self.totalFragments = totalFragments
        self.isKeyFrame = isKeyFrame
    }
}

// MARK: - Media Frame Packing

/// Utilities for packing/unpacking media frames into the wire format.
///
/// Wire format: `[4-byte big-endian header length] [JSON header] [codec payload]`
public enum MediaFrameCodec {

    /// Maximum raw codec payload size per fragment.
    ///
    /// Media frames are encrypted, JSON-encoded inside `EncryptedChatPayload`,
    /// then embedded as `Data` again inside `PoolMessage`, which means binary
    /// video payloads are base64-expanded twice before MC transport.
    /// Keeping the raw fragment size conservative avoids silently exceeding the
    /// practical MultipeerConnectivity packet budget.
    public static let maxFragmentPayloadSize = 16_000

    /// Pack a header and payload into the wire format.
    public static func pack(header: MediaFrameHeader, payload: Data) -> Data? {
        guard let headerJSON = try? JSONEncoder().encode(header) else { return nil }
        let headerLength = UInt32(headerJSON.count)

        var data = Data(capacity: 4 + headerJSON.count + payload.count)
        // 4-byte big-endian header length
        var lengthBE = headerLength.bigEndian
        data.append(Data(bytes: &lengthBE, count: 4))
        // JSON header
        data.append(headerJSON)
        // Codec payload
        data.append(payload)
        return data
    }

    /// Unpack a wire-format data blob into header and payload.
    public static func unpack(_ data: Data) -> (header: MediaFrameHeader, payload: Data)? {
        guard data.count >= 4 else { return nil }

        // Read 4-byte big-endian header length
        let headerLength = data.withUnsafeBytes { ptr -> UInt32 in
            UInt32(bigEndian: ptr.load(as: UInt32.self))
        }

        let headerEnd = 4 + Int(headerLength)
        guard data.count >= headerEnd else { return nil }

        let headerData = data[4..<headerEnd]
        guard let header = try? JSONDecoder().decode(MediaFrameHeader.self, from: headerData) else {
            return nil
        }

        let payload = data[headerEnd...]
        return (header, Data(payload))
    }

    /// Fragment a large payload into multiple wire-format packets.
    /// Returns one packed Data per fragment.
    public static func fragment(
        callID: UUID,
        senderPeerID: String,
        mediaType: CallMediaType,
        sequence: UInt32,
        timestamp: UInt32,
        isKeyFrame: Bool,
        payload: Data
    ) -> [Data] {
        if payload.count <= maxFragmentPayloadSize {
            let header = MediaFrameHeader(
                callID: callID,
                senderPeerID: senderPeerID,
                mediaType: mediaType,
                sequence: sequence,
                timestamp: timestamp,
                fragmentIndex: 0,
                totalFragments: 1,
                isKeyFrame: isKeyFrame
            )
            if let packed = pack(header: header, payload: payload) {
                return [packed]
            }
            return []
        }

        let totalFragments = UInt8(min(255, (payload.count + maxFragmentPayloadSize - 1) / maxFragmentPayloadSize))
        var fragments: [Data] = []

        for i in 0..<Int(totalFragments) {
            let start = i * maxFragmentPayloadSize
            let end = min(start + maxFragmentPayloadSize, payload.count)
            let chunk = payload[start..<end]

            let header = MediaFrameHeader(
                callID: callID,
                senderPeerID: senderPeerID,
                mediaType: mediaType,
                sequence: sequence,
                timestamp: timestamp,
                fragmentIndex: UInt8(i),
                totalFragments: totalFragments,
                isKeyFrame: isKeyFrame
            )

            if let packed = pack(header: header, payload: Data(chunk)) {
                fragments.append(packed)
            }
        }

        return fragments
    }
}
