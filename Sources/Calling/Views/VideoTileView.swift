// VideoTileView.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import SwiftUI
import CoreVideo
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Video Tile View

/// SwiftUI view that renders a CVPixelBuffer using AVSampleBufferDisplayLayer.
///
/// Used for both local camera preview and remote peer video in calls.
/// Supports mirroring (for front-facing camera preview) and aspect-fit scaling.
#if os(iOS)
public struct VideoTileView: UIViewRepresentable {
    /// The pixel buffer to render.
    let pixelBuffer: CVPixelBuffer?
    /// Whether to mirror the video horizontally (true for local front camera).
    var isMirrored: Bool = false

    public init(pixelBuffer: CVPixelBuffer?, isMirrored: Bool = false) {
        self.pixelBuffer = pixelBuffer
        self.isMirrored = isMirrored
    }

    public func makeUIView(context: Context) -> VideoRenderView {
        let view = VideoRenderView()
        view.isMirrored = isMirrored
        return view
    }

    public func updateUIView(_ uiView: VideoRenderView, context: Context) {
        uiView.isMirrored = isMirrored
        uiView.displayPixelBuffer(pixelBuffer)
    }
}

/// UIView backed by AVSampleBufferDisplayLayer for efficient video rendering.
public class VideoRenderView: UIView {

    var isMirrored: Bool = false {
        didSet {
            updateMirror()
        }
    }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    public override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        clipsToBounds = true
        layer.cornerRadius = 8
    }

    private func updateMirror() {
        if isMirrored {
            transform = CGAffineTransform(scaleX: -1, y: 1)
        } else {
            transform = .identity
        }
    }

    /// Display a CVPixelBuffer on the render layer.
    func displayPixelBuffer(_ pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer else {
            displayLayer.flushAndRemoveImage()
            return
        }

        // Create CMSampleBuffer from pixel buffer
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { return }

        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard let sampleBuffer else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        displayLayer.enqueue(sampleBuffer)
    }
}
#else
// macOS fallback - render as CIImage in a simple NSView wrapper
public struct VideoTileView: View {
    let pixelBuffer: CVPixelBuffer?
    var isMirrored: Bool = false

    public init(pixelBuffer: CVPixelBuffer?, isMirrored: Bool = false) {
        self.pixelBuffer = pixelBuffer
        self.isMirrored = isMirrored
    }

    public var body: some View {
        Rectangle()
            .fill(Color.black)
            .overlay {
                if let pixelBuffer {
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    let context = CIContext()
                    if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                        Image(decorative: cgImage, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
#endif
