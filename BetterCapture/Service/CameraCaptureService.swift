//
//  CameraCaptureService.swift
//  BetterCapture
//
//  Created on 09.02.26.
//

import AVFoundation
import AppKit
import CoreImage
import OSLog
import Vision

/// Service for capturing the user's camera/webcam feed for the Loom-style bubble overlay
@MainActor
@Observable
final class CameraCaptureService: NSObject {

    // MARK: - Properties

    private(set) var previewImage: NSImage?
    private(set) var isCapturing = false

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let captureQueue = DispatchQueue(label: "com.bettercapture.cameraCapture", qos: .userInteractive)

    // Thread-safe storage for latest frame (accessed from compositor on capture queue)
    private nonisolated(unsafe) let bufferLock = NSLock()
    private nonisolated(unsafe) var _latestPixelBuffer: CVPixelBuffer?
    /// When set, getLatestFrame returns this static snapshot instead of live feed
    private nonisolated(unsafe) var _staticSnapshotBuffer: CVPixelBuffer?

    /// FaceTime-style background effect (blur)
    nonisolated(unsafe) var backgroundEffect: CameraBackgroundEffect = .none

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture",
        category: "CameraCaptureService"
    )

    // Bubble dimensions for overlay (matches PreviewSize.medium)
    private let captureWidth = 240
    private let captureHeight = 180

    // MARK: - Public Methods

    /// Requests camera permission and returns whether it was granted
    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Checks if camera permission has been granted
    var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Starts capturing from the selected camera (or system default when nil)
    /// - Parameter selectedDeviceID: Optional unique ID of the camera device to use
    func startCapture(selectedDeviceID: String? = nil) async {
        guard !isCapturing else { return }
        guard hasPermission else {
            logger.warning("Camera permission not granted")
            return
        }

        // Prefer the explicitly selected device when available, otherwise fall back gracefully
        let videoDevices = AVCaptureDevice.devices(for: .video)

        let camera: AVCaptureDevice?
        if let selectedDeviceID,
           let selected = videoDevices.first(where: { $0.uniqueID == selectedDeviceID }) {
            camera = selected
        } else {
            // On macOS, use default(for:) — builtInWideAngleCamera with position fails on Mac
            camera = AVCaptureDevice.default(for: .video) ?? videoDevices.first
        }

        guard let camera else {
            logger.error("No camera device available")
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .hd1280x720

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
            }

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: captureQueue)

            if session.canAddOutput(output) {
                session.addOutput(output)
                videoOutput = output
            }

            session.startRunning()
            captureSession = session
            isCapturing = true
            logger.info("Camera capture started")
        } catch {
            logger.error("Failed to start camera capture: \(error.localizedDescription)")
        }
    }

    /// Stops camera capture
    func stopCapture() {
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil
        isCapturing = false
        previewImage = nil
        bufferLock.lock()
        _latestPixelBuffer = nil
        _staticSnapshotBuffer = nil
        bufferLock.unlock()
        logger.info("Camera capture stopped")
    }

    /// Locks the current frame as a static snapshot (used for non-live bubble and overlay)
    func lockCurrentFrameAsSnapshot() {
        bufferLock.lock()
        _staticSnapshotBuffer = _latestPixelBuffer
        bufferLock.unlock()
    }

    /// Gets the latest camera frame as a pixel buffer (for compositing)
    /// Returns static snapshot if locked, otherwise live frame. Scaled to the specified size.
    /// Can be called from any thread (e.g. capture queue)
    nonisolated func getLatestFrame(forOverlaySize size: CGSize) -> CVPixelBuffer? {
        bufferLock.lock()
        let sourceBuffer = _staticSnapshotBuffer ?? _latestPixelBuffer
        bufferLock.unlock()
        guard let sourceBuffer else { return nil }

        let targetWidth = Int(size.width)
        let targetHeight = Int(size.height)

        var scaledBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth,
            targetHeight,
            kCVPixelFormatType_32BGRA,
            nil,
            &scaledBuffer
        )

        guard let outputBuffer = scaledBuffer else { return nil }

        let ciImage = CIImage(cvPixelBuffer: sourceBuffer)
        let scaleX = CGFloat(targetWidth) / CGFloat(CVPixelBufferGetWidth(sourceBuffer))
        let scaleY = CGFloat(targetHeight) / CGFloat(CVPixelBufferGetHeight(sourceBuffer))
        var scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        if backgroundEffect == .blur, let blurredImage = applyBackgroundBlur(to: scaledImage) {
            scaledImage = blurredImage
        }

        let context = CIContext()
        context.render(scaledImage, to: outputBuffer)

        return outputBuffer
    }

    /// Applies person segmentation + background blur (FaceTime-style)
    private nonisolated func applyBackgroundBlur(to image: CIImage) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let maskObservation = request.results?.first as? VNPixelBufferObservation else {
            return nil
        }

        var maskImage = CIImage(cvPixelBuffer: maskObservation.pixelBuffer)
        // Ensure mask matches image extent (Vision may return different dimensions)
        if maskImage.extent != image.extent {
            let scaleX = image.extent.width / maskImage.extent.width
            let scaleY = image.extent.height / maskImage.extent.height
            maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            maskImage = maskImage.cropped(to: image.extent)
        }
        let blurredImage = image.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 25])
        return image.applyingFilter("CIBlendWithMask", parameters: [
            "inputMaskImage": maskImage,
            "inputBackgroundImage": blurredImage
        ])
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Copy the pixel buffer since the original gets reused by the capture session
        var copyBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            nil,
            &copyBuffer
        )
        guard let copy = copyBuffer else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(copy, [])
        }
        memcpy(
            CVPixelBufferGetBaseAddress(copy),
            CVPixelBufferGetBaseAddress(pixelBuffer),
            CVPixelBufferGetDataSize(pixelBuffer)
        )

        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if self.backgroundEffect == .blur, let blurred = self.applyBackgroundBlur(to: ciImage) {
            ciImage = blurred
        }
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        Task { @MainActor in
            self.previewImage = image
        }
        bufferLock.lock()
        _latestPixelBuffer = copy
        bufferLock.unlock()
    }
}
