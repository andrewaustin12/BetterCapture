//
//  CameraDeviceService.swift
//  BetterCapture
//
//  Created by Cursor on 10.02.26.
//

import AVFoundation
import OSLog

/// Represents a video input (camera) device
struct CameraInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool
}

/// Service for enumerating and monitoring available camera devices
@MainActor
@Observable
final class CameraDeviceService {

    // MARK: - Properties

    private(set) var availableDevices: [CameraInputDevice] = []

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture",
        category: "CameraDeviceService"
    )

    // MARK: - Initialization

    init() {
        refreshDevices()
        setupNotifications()
    }

    // MARK: - Public Methods

    /// Refreshes the list of available camera devices
    func refreshDevices() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external
            ],
            mediaType: .video,
            position: .unspecified
        )

        let defaultDevice = AVCaptureDevice.default(for: .video)

        availableDevices = discoverySession.devices.map { device in
            CameraInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device == defaultDevice
            )
        }

        logger.info("Found \(self.availableDevices.count) camera devices")
    }

    // MARK: - Private Methods

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
                self?.logger.info("Camera device connected")
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
                self?.logger.info("Camera device disconnected")
            }
        }
    }
}

