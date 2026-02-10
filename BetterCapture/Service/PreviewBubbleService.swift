//
//  PreviewBubbleService.swift
//  BetterCapture
//
//  Created on 09.02.26.
//

import ScreenCaptureKit
import AppKit
import OSLog

/// Service for managing the preview bubble's live video stream
@MainActor
@Observable
final class PreviewBubbleService: NSObject {

    // MARK: - Properties

    private(set) var previewImage: NSImage?

    private var stream: SCStream?
    private var currentFilter: SCContentFilter?
    private let previewQueue = DispatchQueue(label: "com.bettercapture.bubblePreviewQueue", qos: .userInteractive)

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture",
        category: "PreviewBubbleService"
    )

    // Preview configuration constants - optimized for bubble preview
    private let previewWidth = 240
    private let previewHeight = 240

    // MARK: - Public Methods

    /// Sets the content filter for the preview stream
    /// - Parameter filter: The content filter to use
    func setContentFilter(_ filter: SCContentFilter) {
        currentFilter = filter
    }

    /// Starts the preview stream for the bubble window
    func startPreview() async {
        guard let filter = currentFilter else {
            logger.info("No content filter set, skipping bubble preview start")
            return
        }

        guard stream == nil else {
            logger.info("Bubble preview stream already running")
            return
        }

        await startStream(with: filter)
    }

    /// Stops the preview stream
    func stopPreview() async {
        await stopStream()
    }

    // MARK: - Private Methods

    private func startStream(with filter: SCContentFilter) async {
        do {
            let config = createPreviewConfiguration()
            stream = SCStream(filter: filter, configuration: config, delegate: self)

            guard let stream else {
                logger.error("Failed to create bubble preview stream")
                return
            }

            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: previewQueue)
            try await stream.startCapture()

            logger.info("Bubble preview stream started")

        } catch let error as NSError {
            if error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && error.code == -3801 {
                logger.warning("Screen capture permission not granted for bubble preview")
            } else {
                logger.error("Failed to start bubble preview: \(error.localizedDescription)")
            }
            await stopStream()
        }
    }

    private func stopStream() async {
        if let stream {
            do {
                try await stream.stopCapture()
                logger.info("Bubble preview stream stopped")
            } catch {
                logger.error("Failed to stop bubble preview stream: \(error.localizedDescription)")
            }
            self.stream = nil
        }
        previewImage = nil
    }

    private func createPreviewConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()

        // Lower resolution for bubble preview
        config.width = previewWidth
        config.height = previewHeight

        // Lower frame rate for preview (15 FPS is sufficient)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)

        // BGRA pixel format for display
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // No audio for preview
        config.capturesAudio = false

        // Show cursor in preview
        config.showsCursor = true

        return config
    }

    /// Converts a CMSampleBuffer to an NSImage
    private nonisolated func createImage(from sampleBuffer: CMSampleBuffer) -> NSImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }
}

// MARK: - SCStreamDelegate

extension PreviewBubbleService: SCStreamDelegate {

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            self.stream = nil
            self.logger.error("Bubble preview stream stopped with error: \(error.localizedDescription)")
        }
    }
}

// MARK: - SCStreamOutput

extension PreviewBubbleService: SCStreamOutput {

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Check frame status - only process complete frames
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete else {
            return
        }

        // Convert to NSImage
        guard let image = createImage(from: sampleBuffer) else { return }

        Task { @MainActor in
            // Continuously update the preview image with each new frame
            self.previewImage = image
        }
    }
}
