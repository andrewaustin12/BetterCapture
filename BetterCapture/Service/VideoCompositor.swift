//
//  VideoCompositor.swift
//  BetterCapture
//
//  Created on 09.02.26.
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

/// Composites camera overlay onto screen capture frames before passing to AssetWriter
final class VideoCompositor: CaptureEngineSampleBufferDelegate, @unchecked Sendable {

    // MARK: - Properties

    weak var cameraCaptureService: CameraCaptureService?
    weak var assetWriter: AssetWriter?
    var isCameraOverlayEnabled = false
    var overlayCorner: ScreenCorner = .bottomLeft
    var overlaySize: CGSize = CGSize(width: 240, height: 180)
    var videoSize: CGSize = .zero
    /// Capture region in screen coordinates (from SCContentFilter.contentRect)
    var contentRect: CGRect = .zero
    var pointPixelScale: CGFloat = 1
    /// Bubble window frame in screen coordinates — when set, overlay uses this for positioning
    var bubbleFrameInScreen: CGRect?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture",
        category: "VideoCompositor"
    )

    private let ciContext = CIContext()

    // MARK: - CaptureEngineSampleBufferDelegate

    func captureEngine(_ engine: CaptureEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard let assetWriter else { return }

        // Check frame status
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete else {
            return
        }

        guard let screenBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if isCameraOverlayEnabled, let cameraService = cameraCaptureService {
            // Composite camera overlay onto screen
            if let compositedBuffer = compositeCameraOntoScreen(
                screenBuffer: screenBuffer,
                cameraService: cameraService
            ) {
                assetWriter.appendCompositedVideoFrame(compositedBuffer, presentationTime: presentationTime)
                return
            }
        }

        // No overlay or compositing failed - pass through original
        assetWriter.appendVideoSample(sampleBuffer)
    }

    func captureEngine(_ engine: CaptureEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        assetWriter?.appendAudioSample(sampleBuffer)
    }

    func captureEngine(_ engine: CaptureEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer) {
        assetWriter?.appendMicrophoneSample(sampleBuffer)
    }

    // MARK: - Private Methods

    private func compositeCameraOntoScreen(screenBuffer: CVPixelBuffer, cameraService: CameraCaptureService) -> CVPixelBuffer? {
        guard let cameraBuffer = cameraService.getLatestFrame(forOverlaySize: overlaySize) else {
            return nil
        }

        let screenImage = CIImage(cvPixelBuffer: screenBuffer)
        let cameraImage = CIImage(cvPixelBuffer: cameraBuffer)

        let screenWidth = CGFloat(CVPixelBufferGetWidth(screenBuffer))
        let screenHeight = CGFloat(CVPixelBufferGetHeight(screenBuffer))

        let overlayW = overlaySize.width
        let overlayH = overlaySize.height

        // Decide overlay position based solely on the user's selected corner.
        // This ensures the recorded bubble always matches the setting, regardless
        // of where the draggable on-screen preview bubble is moved.
        let padding: CGFloat = 48
        let overlayX: CGFloat
        let overlayY: CGFloat

        switch overlayCorner {
        case .topLeft:
            overlayX = padding
            overlayY = screenHeight - overlayH - padding
        case .topRight:
            overlayX = screenWidth - overlayW - padding
            overlayY = screenHeight - overlayH - padding
        case .bottomLeft:
            overlayX = padding
            overlayY = padding
        case .bottomRight:
            overlayX = screenWidth - overlayW - padding
            overlayY = padding
        }

        // CIImage uses bottom-left origin; screen capture uses top-left
        // Transform camera to overlay position (Core Image: Y increases upward)
        let cameraPositioned = cameraImage.transformed(by: CGAffineTransform(translationX: overlayX, y: overlayY))

        // Circular mask for Loom-style bubble (use smaller dimension for circle)
        let circleRadius = min(overlayW, overlayH) / 2
        let circleCenterX = overlayX + overlayW / 2
        let circleCenterY = overlayY + overlayH / 2
        let radialGradient = CIFilter(name: "CIRadialGradient")!
        radialGradient.setValue(CIVector(x: circleCenterX, y: circleCenterY), forKey: "inputCenter")
        radialGradient.setValue(circleRadius, forKey: "inputRadius0")
        radialGradient.setValue(circleRadius, forKey: "inputRadius1")
        radialGradient.setValue(CIColor.white, forKey: "inputColor0")
        radialGradient.setValue(CIColor.black, forKey: "inputColor1")
        guard let maskImage = radialGradient.outputImage?.cropped(to: screenImage.extent) else {
            let composition = cameraPositioned.composited(over: screenImage)
            var outputBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(screenBuffer),
                                CVPixelBufferGetHeight(screenBuffer), kCVPixelFormatType_32BGRA, nil, &outputBuffer)
            guard let output = outputBuffer else { return nil }
            ciContext.render(composition, to: output)
            return output
        }
        let cameraMasked = cameraPositioned.applyingFilter("CIBlendWithMask", parameters: [
            "inputMaskImage": maskImage
        ])

        // Composite: circular camera on top of screen
        let composition = cameraMasked.composited(over: screenImage)

        // Create output buffer
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(screenBuffer),
            CVPixelBufferGetHeight(screenBuffer),
            kCVPixelFormatType_32BGRA,
            nil,
            &outputBuffer
        )

        guard let output = outputBuffer else { return nil }

        ciContext.render(composition, to: output)

        return output
    }

}
