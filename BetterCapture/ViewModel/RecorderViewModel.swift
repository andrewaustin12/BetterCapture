//
//  RecorderViewModel.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 29.01.26.
//

import Foundation
import ScreenCaptureKit
import AppKit
import OSLog

/// The main view model managing recording state and coordination between services
@MainActor
@Observable
final class RecorderViewModel {

    // MARK: - Recording State

    enum RecordingState {
        case idle
        case recording
        case stopping
    }

    // MARK: - Published Properties

    private(set) var state: RecordingState = .idle
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var lastError: Error?
    private(set) var selectedContentFilter: SCContentFilter?

    var isRecording: Bool {
        state == .recording
    }

    var canStartRecording: Bool {
        selectedContentFilter != nil && state == .idle
    }

    var hasContentSelected: Bool {
        selectedContentFilter != nil
    }

    var formattedDuration: String {
        let hours = Int(recordingDuration) / 3600
        let minutes = (Int(recordingDuration) % 3600) / 60
        let seconds = Int(recordingDuration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    // MARK: - Dependencies

    let settings: SettingsStore
    let audioDeviceService: AudioDeviceService
    let cameraDeviceService: CameraDeviceService
    let previewService: PreviewService
    let notificationService: NotificationService
    let permissionService: PermissionService
    private let captureEngine: CaptureEngine
    private let assetWriter: AssetWriter
    private let videoCompositor: VideoCompositor
    private let previewBubbleWindow: PreviewBubbleWindow
    private let previewBubbleService: PreviewBubbleService
    private let cameraCaptureService: CameraCaptureService

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "RecorderViewModel")

    // MARK: - Private Properties

    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var videoSize: CGSize = .zero
    private var idleCameraBubbleTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        self.settings = SettingsStore()
        self.audioDeviceService = AudioDeviceService()
        self.cameraDeviceService = CameraDeviceService()
        self.previewService = PreviewService()
        self.notificationService = NotificationService()
        self.permissionService = PermissionService()
        self.captureEngine = CaptureEngine()
        self.assetWriter = AssetWriter()
        self.videoCompositor = VideoCompositor()
        self.previewBubbleWindow = PreviewBubbleWindow()
        self.previewBubbleService = PreviewBubbleService()
        self.cameraCaptureService = CameraCaptureService()

        videoCompositor.assetWriter = assetWriter
        videoCompositor.cameraCaptureService = cameraCaptureService

        captureEngine.delegate = self
        captureEngine.sampleBufferDelegate = videoCompositor
        previewService.delegate = self
    }

    // MARK: - Permission Methods

    /// Requests required permissions on app launch
    /// Requests microphone if enabled, camera if camera bubble is enabled
    func requestPermissionsOnLaunch() async {
        await permissionService.requestPermissions(
            includeMicrophone: settings.captureMicrophone,
            includeCamera: settings.showCameraBubble
        )
    }

    /// Refreshes the current permission states
    func refreshPermissions() {
        permissionService.updatePermissionStates()
    }

    // MARK: - Public Methods

    /// Presents the system content sharing picker
    func presentPicker() {
        captureEngine.presentPicker()
    }

    /// Starts a new recording session
    func startRecording() async {
        guard canStartRecording else {
            logger.warning("Cannot start recording: no content selected or already recording")
            return
        }

        // Stop any idle camera bubble update loop when we transition into recording
        idleCameraBubbleTask?.cancel()
        idleCameraBubbleTask = nil

        do {
            state = .recording
            lastError = nil

            logger.info("Starting recording sequence...")

            // Stop any active live preview before starting recording
            logger.info("Stopping any active live preview...")
            await previewService.stopPreview()
            logger.info("Live preview stopped")

            // Determine video size from filter
            if let filter = captureEngine.contentFilter {
                videoSize = await getContentSize(from: filter)
            }
            logger.info("Video size: \(self.videoSize.width)x\(self.videoSize.height)")

            // Setup asset writer
            let outputURL = settings.generateOutputURL()
            try assetWriter.setup(url: outputURL, settings: settings, videoSize: videoSize)
            try assetWriter.startWriting()
            logger.info("AssetWriter ready")

            // Configure video compositor for camera overlay
            videoCompositor.videoSize = videoSize
            videoCompositor.isCameraOverlayEnabled = settings.showCameraBubble
            videoCompositor.overlayCorner = settings.previewBubbleCorner
            videoCompositor.overlaySize = settings.previewBubbleSize.dimensions
            let targetScreenForBubble: NSScreen?
            if let filter = captureEngine.contentFilter {
                videoCompositor.contentRect = filter.contentRect
                videoCompositor.pointPixelScale = CGFloat(filter.pointPixelScale)
                // Anchor the on-screen bubble to the same physical display as the
                // captured content so its corner position visually matches recording.
                let contentCenter = CGPoint(
                    x: filter.contentRect.midX,
                    y: filter.contentRect.midY
                )
                targetScreenForBubble = NSScreen.screens.first { $0.frame.contains(contentCenter) }
            }
            else {
                targetScreenForBubble = NSScreen.main
            }
            videoCompositor.bubbleFrameInScreen = nil

            // Start camera bubble if enabled (Loom-style)
            var excludedWindowNumbers: [Int] = []
            if settings.showCameraBubble {
                logger.info("Starting camera bubble...")
                var hasCameraPermission = cameraCaptureService.hasPermission
                if !hasCameraPermission {
                    hasCameraPermission = await cameraCaptureService.requestPermission()
                }
                // Always show bubble when camera bubble is enabled (even if camera fails)
                cameraCaptureService.backgroundEffect = settings.cameraBackgroundEffect
                await cameraCaptureService.startCapture(selectedDeviceID: settings.selectedCameraID)
                previewBubbleWindow.show(
                    at: settings.previewBubbleCorner,
                    size: settings.previewBubbleSize,
                    isCameraBubble: true,
                    initialImage: nil,
                    screen: targetScreenForBubble
                )
                try? await Task.sleep(for: .milliseconds(50))
                videoCompositor.bubbleFrameInScreen = previewBubbleWindow.frameInScreenCoordinates
                if let windowNumber = previewBubbleWindow.windowNumber {
                    excludedWindowNumbers.append(windowNumber)
                }
                if !hasCameraPermission {
                    logger.warning("Camera permission not granted, bubble will show placeholder")
                }
            }

            // Screen preview bubble (when camera bubble is disabled)
            if settings.showPreviewBubble && !settings.showCameraBubble {
                logger.info("Starting screen preview bubble...")
                if let filter = captureEngine.contentFilter {
                    previewBubbleService.setContentFilter(filter)
                    previewBubbleWindow.show(
                        at: settings.previewBubbleCorner,
                        size: settings.previewBubbleSize,
                        isCameraBubble: false,
                        initialImage: nil,
                        screen: targetScreenForBubble
                    )
                    try? await Task.sleep(for: .milliseconds(50))
                    if let windowNumber = previewBubbleWindow.windowNumber {
                        excludedWindowNumbers.append(windowNumber)
                    }
                    await previewBubbleService.startPreview()
                }
            }

            // Start capture with the calculated video size
            logger.info("Starting capture engine...")
            try await captureEngine.startCapture(with: settings, videoSize: videoSize, excludedWindowNumbers: excludedWindowNumbers)

            // Start timer
            startTimer()

            logger.info("Recording started")

        } catch {
            state = .idle
            lastError = error
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stops the current recording session
    func stopRecording() async {
        guard isRecording else { return }

        state = .stopping
        stopTimer()

        // Hide preview/camera bubble
        if settings.showCameraBubble || settings.showPreviewBubble {
            logger.info("Stopping preview bubble...")
            await previewBubbleService.stopPreview()
            cameraCaptureService.stopCapture()
            previewBubbleWindow.hide()
        }

        do {
            // Stop capture first
            try await captureEngine.stopCapture()

            // Finalize file
            let outputURL = try await assetWriter.finishWriting()

            state = .idle
            recordingDuration = 0

            logger.info("Recording stopped and saved to: \(outputURL.lastPathComponent)")

            // Brief delay to ensure screen sharing mode has fully stopped before sending notification
            try? await Task.sleep(for: .milliseconds(100))

            // Send notification
            notificationService.sendRecordingSavedNotification(fileURL: outputURL)

        } catch {
            state = .idle
            lastError = error
            assetWriter.cancel()
            notificationService.sendRecordingFailedNotification(error: error)
            logger.error("Failed to stop recording: \(error.localizedDescription)")
        }
    }

    /// Clears the current content selection
    func clearSelection() {
        captureEngine.clearSelection()
    }

    /// Starts the live preview stream (call when menu bar window opens)
    func startPreview() async {
        guard !isRecording else { return }
        await previewService.startPreview()
    }

    /// Stops the live preview stream (call when menu bar window closes)
    func stopPreview() async {
        await previewService.stopPreview()
    }

    // MARK: - Timer Management

    private func startTimer() {
        recordingStartTime = Date()
        recordingDuration = 0

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
                
                // Update bubble window duration and preview image
                if self.settings.showCameraBubble || self.settings.showPreviewBubble {
                    self.previewBubbleWindow.updateDuration(self.formattedDuration)
                    // Camera bubble: live feed for on-screen display and recording
                    if self.settings.showCameraBubble {
                        self.previewBubbleWindow.updatePreview(self.cameraCaptureService.previewImage)
                    } else if self.settings.showPreviewBubble, let image = self.previewBubbleService.previewImage {
                        self.previewBubbleWindow.updatePreview(image)
                    }
                }
            }
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
    }

    // MARK: - Helper Methods

    private func getContentSize(from filter: SCContentFilter) async -> CGSize {
        // Get the content rect from the filter
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)

        if rect.width > 0 && rect.height > 0 {
            return CGSize(
                width: rect.width * scale,
                height: rect.height * scale
            )
        }

        // Fallback to main screen size
        if let screen = NSScreen.main {
            return CGSize(
                width: screen.frame.width * screen.backingScaleFactor,
                height: screen.frame.height * screen.backingScaleFactor
            )
        }

        return CGSize(width: 1920, height: 1080)
    }

    // MARK: - Camera Bubble (Idle State)

    /// Shows the Loom-style camera bubble when enabled, even before recording starts.
    /// Called when the menu bar UI appears.
    func showIdleCameraBubbleIfNeeded() async {
        guard settings.showCameraBubble else { return }
        guard !isRecording else { return }

        // If the user has already selected capture content, anchor the bubble
        // to the same physical screen as that content; otherwise fall back to
        // the main screen.
        let targetScreenForBubble: NSScreen?
        if let filter = captureEngine.contentFilter {
            let contentCenter = CGPoint(
                x: filter.contentRect.midX,
                y: filter.contentRect.midY
            )
            targetScreenForBubble = NSScreen.screens.first { $0.frame.contains(contentCenter) }
        } else {
            targetScreenForBubble = NSScreen.main
        }

        if !previewBubbleWindow.isVisible {
            var hasCameraPermission = cameraCaptureService.hasPermission
            if !hasCameraPermission {
                hasCameraPermission = await cameraCaptureService.requestPermission()
            }

            cameraCaptureService.backgroundEffect = settings.cameraBackgroundEffect
            await cameraCaptureService.startCapture(selectedDeviceID: settings.selectedCameraID)

            previewBubbleWindow.show(
                at: settings.previewBubbleCorner,
                size: settings.previewBubbleSize,
                isCameraBubble: true,
                initialImage: cameraCaptureService.previewImage,
                screen: targetScreenForBubble
            )

            if !hasCameraPermission {
                logger.warning("Camera permission not granted, idle camera bubble will show placeholder")
            }
        } else {
            // Bubble already visible – just move/resize it to the correct screen/corner.
            previewBubbleWindow.resize(
                to: settings.previewBubbleSize,
                corner: settings.previewBubbleCorner,
                screen: targetScreenForBubble
            )
        }

        startIdleCameraBubbleUpdates()
    }

    /// Hides the idle camera bubble when not recording.
    func hideIdleCameraBubbleIfNeeded() {
        guard !isRecording else { return }
        idleCameraBubbleTask?.cancel()
        idleCameraBubbleTask = nil
        cameraCaptureService.stopCapture()
        previewBubbleWindow.hide()
    }

    /// Starts a lightweight update loop that keeps the idle camera bubble in sync with the latest camera frame.
    private func startIdleCameraBubbleUpdates() {
        idleCameraBubbleTask?.cancel()
        idleCameraBubbleTask = Task { [weak self] in
            await MainActor.run { }
            while let self, !self.isRecording, self.settings.showCameraBubble, self.previewBubbleWindow.isVisible {
                if let image = self.cameraCaptureService.previewImage {
                    self.previewBubbleWindow.updatePreview(image)
                }

                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    break
                }
            }
        }
    }

    /// Gets the preview bubble window for exclusion purposes
    var previewBubbleWindowNumber: Int? {
        previewBubbleWindow.windowNumber
    }
}

// MARK: - CaptureEngineDelegate

extension RecorderViewModel: CaptureEngineDelegate {

    func captureEngine(_ engine: CaptureEngine, didUpdateFilter filter: SCContentFilter) {
        selectedContentFilter = filter
        logger.info("Content filter updated")

        // Capture a static thumbnail for the preview
        Task {
            await previewService.setContentFilter(filter)

            // When the user selects new content and the camera bubble is enabled,
            // ensure the idle bubble (if visible) is anchored to the same screen
            // as the selected content before recording starts.
            if settings.showCameraBubble, !isRecording {
                await showIdleCameraBubbleIfNeeded()
            }
        }
    }

    func captureEngine(_ engine: CaptureEngine, didStopWithError error: Error?) {
        // Check if user clicked "Stop Sharing" in the menu bar
        let isUserStopped = (error as? SCStreamError)?.code == .userStopped

        if let error, !isUserStopped {
            lastError = error
            logger.error("Capture stopped with error: \(error.localizedDescription)")
        }

        // Clean up if we were recording
        if isRecording {
            if isUserStopped {
                // User clicked "Stop Sharing" - gracefully save the recording
                logger.info("User stopped sharing via system UI, saving recording...")
                Task {
                    await stopRecording()
                }
            } else {
                // Unexpected error - cancel the recording
                stopTimer()
                assetWriter.cancel()
                state = .idle
                notificationService.sendRecordingStoppedNotification(error: error)
            }
        }
    }

    func captureEngineDidCancelPicker(_ engine: CaptureEngine) {
        logger.info("Picker was cancelled, clearing selection and preview")

        // Clear the selected content filter
        selectedContentFilter = nil

        // Stop and clear the preview
        Task {
            await previewService.cancelCapture()
            previewService.clearPreview()
        }
    }
}

// MARK: - PreviewServiceDelegate

extension RecorderViewModel: PreviewServiceDelegate {

    func previewServiceDidStopByUser(_ service: PreviewService) {
        logger.info("User stopped sharing via system UI, clearing selection")

        // Clear the selection
        selectedContentFilter = nil

        // Clear the content filter in capture engine and deactivate picker
        captureEngine.clearSelection()
        captureEngine.deactivatePicker()
    }
}
