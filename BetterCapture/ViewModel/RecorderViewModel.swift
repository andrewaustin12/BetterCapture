//
//  RecorderViewModel.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 29.01.26.
//

import Foundation
import ScreenCaptureKit
import UserNotifications
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
    let previewService: PreviewService
    private let captureEngine: CaptureEngine
    private let assetWriter: AssetWriter

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "RecorderViewModel")

    // MARK: - Private Properties

    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var videoSize: CGSize = .zero

    // MARK: - Initialization

    init() {
        self.settings = SettingsStore()
        self.audioDeviceService = AudioDeviceService()
        self.previewService = PreviewService()
        self.captureEngine = CaptureEngine()
        self.assetWriter = AssetWriter()

        captureEngine.delegate = self
        captureEngine.sampleBufferDelegate = assetWriter
        previewService.delegate = self

        // Request notification permissions
        requestNotificationPermission()
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

        do {
            state = .recording
            lastError = nil

            logger.info("Starting recording sequence...")

            // Cancel any in-progress preview capture before starting recording
            logger.info("Cancelling any active preview...")
            await previewService.cancelCapture()
            previewService.clearPreview()
            logger.info("Preview cleared")

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

            // Start capture with the calculated video size
            logger.info("Starting capture engine...")
            try await captureEngine.startCapture(with: settings, videoSize: videoSize)

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

        do {
            // Stop capture first
            try await captureEngine.stopCapture()

            // Finalize file
            let outputURL = try await assetWriter.finishWriting()

            state = .idle
            recordingDuration = 0

            // Send notification
            sendRecordingCompleteNotification(fileURL: outputURL)

            logger.info("Recording stopped and saved to: \(outputURL.lastPathComponent)")

            // Re-capture preview for the selected content
            if let filter = selectedContentFilter {
                await previewService.captureSnapshot(for: filter)
            }

        } catch {
            state = .idle
            lastError = error
            assetWriter.cancel()
            logger.error("Failed to stop recording: \(error.localizedDescription)")
        }
    }

    /// Clears the current content selection
    func clearSelection() {
        captureEngine.clearSelection()
    }

    // MARK: - Timer Management

    private func startTimer() {
        recordingStartTime = Date()
        recordingDuration = 0

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                self.logger.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    private func sendRecordingCompleteNotification(fileURL: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Recording Saved"
        content.body = "Your recording has been saved to \(fileURL.lastPathComponent)"
        content.sound = .default

        // Store the file URL for opening when notification is clicked
        content.userInfo = ["fileURL": fileURL.path()]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                self.logger.error("Failed to send notification: \(error.localizedDescription)")
            }
        }
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
}

// MARK: - CaptureEngineDelegate

extension RecorderViewModel: CaptureEngineDelegate {

    func captureEngine(_ engine: CaptureEngine, didUpdateFilter filter: SCContentFilter) {
        selectedContentFilter = filter
        logger.info("Content filter updated")

        // Capture a preview snapshot for the new filter if not recording
        if !isRecording {
            Task {
                // Cancel any in-progress capture first to ensure the new one starts
                await previewService.cancelCapture()
                await previewService.captureSnapshot(for: filter)
            }
        }
    }

    func captureEngine(_ engine: CaptureEngine, didStopWithError error: Error?) {
        if let error {
            lastError = error
            logger.error("Capture stopped with error: \(error.localizedDescription)")
        }

        // Clean up if we were recording
        if isRecording {
            stopTimer()
            assetWriter.cancel()
            state = .idle
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
