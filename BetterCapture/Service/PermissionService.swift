//
//  PermissionService.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 07.02.26.
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import OSLog
import CoreGraphics
import AppKit

/// Service responsible for checking and requesting system permissions
@MainActor
@Observable
final class PermissionService {

    // MARK: - Permission States

    enum PermissionState {
        case unknown
        case granted
        case denied
    }

    private(set) var screenRecordingState: PermissionState = .unknown
    private(set) var microphoneState: PermissionState = .unknown
    private(set) var cameraState: PermissionState = .unknown

    var allPermissionsGranted: Bool {
        screenRecordingState == .granted && microphoneState == .granted
    }

    var hasAnyPermissionDenied: Bool {
        screenRecordingState == .denied || microphoneState == .denied || cameraState == .denied
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture",
        category: "PermissionService"
    )

    // MARK: - Initialization

    init() {
        updatePermissionStates()
    }

    // MARK: - Permission Checking

    /// Updates all permission states
    func updatePermissionStates() {
        // Log app bundle identifier for debugging
        if let bundleID = Bundle.main.bundleIdentifier {
            print("🔐 App Bundle ID: \(bundleID)")
        }
        
        let previousScreenState = screenRecordingState
        let previousMicState = microphoneState
        
        screenRecordingState = checkScreenRecordingPermission()
        microphoneState = checkMicrophonePermission()
        cameraState = checkCameraPermission()

        // Always log permission states (use info level so it's visible)
        let screenStatus = screenRecordingState == .granted ? "GRANTED" : (screenRecordingState == .denied ? "DENIED" : "UNKNOWN")
        let micStatus = microphoneState == .granted ? "GRANTED" : (microphoneState == .denied ? "DENIED" : "UNKNOWN")
        let camStatus = cameraState == .granted ? "GRANTED" : (cameraState == .denied ? "DENIED" : "UNKNOWN")
        
        if previousScreenState != screenRecordingState || previousMicState != microphoneState {
            logger.info("Permission states CHANGED - Screen: \(screenStatus), Microphone: \(micStatus), Camera: \(camStatus)")
            print("🔐 PermissionService: States CHANGED - Screen: \(screenStatus), Microphone: \(micStatus), Camera: \(camStatus)")
        } else {
            logger.info("Permission states checked - Screen: \(screenStatus), Microphone: \(micStatus), Camera: \(camStatus)")
            print("🔐 PermissionService: States checked - Screen: \(screenStatus), Microphone: \(micStatus), Camera: \(camStatus)")
        }
        
        // Also verify by trying to access ScreenCaptureKit (async, doesn't block)
        Task {
            await verifyScreenCapturePermission()
        }
    }
    
    /// Verifies screen capture permission by actually trying to access ScreenCaptureKit
    private func verifyScreenCapturePermission() async {
        // Add a small delay to ensure permission state has settled
        try? await Task.sleep(for: .milliseconds(100))
        
        do {
            // Try to get shareable content - this requires screen recording permission
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            print("🔐 ScreenCaptureKit verification: SUCCESS - Can access SCShareableContent (found \(content.displays.count) displays)")
            
            // If verification succeeds but our state says denied, update it
            if screenRecordingState != .granted {
                print("⚠️ Warning: CGPreflightScreenCaptureAccess() said denied, but ScreenCaptureKit access works!")
                print("✅ Updating permission state to GRANTED based on successful ScreenCaptureKit access")
                await MainActor.run {
                    screenRecordingState = .granted
                }
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
               nsError.code == -3801 {
                print("🔐 ScreenCaptureKit verification: FAILED - Permission denied (error -3801)")
                
                // Try one more time with CGRequestScreenCaptureAccess to refresh the cache
                print("🔐 Attempting to refresh permission cache...")
                let refreshResult = CGRequestScreenCaptureAccess()
                print("🔐 Permission refresh result: \(refreshResult)")
                
                if refreshResult {
                    print("✅ Permission refresh successful! Updating state...")
                    await MainActor.run {
                        screenRecordingState = .granted
                    }
                    
                    // Verify again after refresh
                    try? await Task.sleep(for: .milliseconds(200))
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        print("🔐 Post-refresh verification: SUCCESS - Found \(content.displays.count) displays")
                    } catch {
                        print("🔐 Post-refresh verification: Still failing - \(error.localizedDescription)")
                    }
                } else {
                    print("⚠️ TROUBLESHOOTING:")
                    print("   1. Check System Settings → Privacy & Security → Screen Recording")
                    print("   2. Make sure '\(Bundle.main.bundleIdentifier ?? "BetterCapture")' is checked")
                    print("   3. If it's checked, try:")
                    print("      - Unchecking and re-checking the app")
                    print("      - Completely quitting and restarting the app")
                    print("      - Running: tccutil reset ScreenCapture \(Bundle.main.bundleIdentifier ?? "")")
                    print("      - Restarting your Mac")
                }
                
                if screenRecordingState == .granted {
                    print("⚠️ Warning: CGPreflightScreenCaptureAccess() said granted, but ScreenCaptureKit access failed!")
                    await MainActor.run {
                        screenRecordingState = .denied
                    }
                }
            } else {
                print("🔐 ScreenCaptureKit verification: ERROR - \(error.localizedDescription)")
                print("   Error domain: \(nsError.domain), code: \(nsError.code)")
            }
        }
    }

    private func checkScreenRecordingPermission() -> PermissionState {
        // CGPreflightScreenCaptureAccess() is the standard way to check screen recording permission
        let preflightResult = CGPreflightScreenCaptureAccess()
        
        // Log the raw result for debugging
        print("🔐 CGPreflightScreenCaptureAccess() returned: \(preflightResult)")
        
        // If preflight says denied, try requesting permission anyway
        // This can refresh macOS's internal permission cache if permission was granted in System Settings
        if !preflightResult {
            print("🔐 Preflight returned false, attempting to refresh permission state...")
            let requestResult = CGRequestScreenCaptureAccess()
            print("🔐 CGRequestScreenCaptureAccess() returned: \(requestResult)")
            
            // If request returns true, permission is actually granted (macOS cache was stale)
            if requestResult {
                print("✅ Permission refresh successful - macOS cache was stale!")
                return .granted
            }
        }
        
        return preflightResult ? PermissionState.granted : .denied
    }

    private func checkMicrophonePermission() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .unknown
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .unknown
        }
    }

    private func checkCameraPermission() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .unknown
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .unknown
        }
    }

    // MARK: - Permission Requests

    /// Requests required permissions on app launch
    /// - Parameters:
    ///   - includeMicrophone: Whether to also request microphone permission
    ///   - includeCamera: Whether to also request camera permission (for Loom-style bubble)
    func requestPermissions(includeMicrophone: Bool, includeCamera: Bool = true) async {
        logger.info("Requesting permissions (includeMicrophone: \(includeMicrophone), includeCamera: \(includeCamera))...")

        // Request screen recording permission first (synchronous)
        requestScreenRecordingPermission()

        // Request microphone permission only if needed (asynchronous)
        if includeMicrophone {
            await requestMicrophonePermission()
        }

        // Request camera permission for Loom-style bubble
        if includeCamera {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
        }

        // Update states after requests
        updatePermissionStates()
    }

    /// Requests screen recording permission
    /// - Note: This will open System Settings if permission was previously denied
    func requestScreenRecordingPermission() {
        print("🔐 Requesting screen recording permission via CGRequestScreenCaptureAccess()...")
        let wasGranted = CGRequestScreenCaptureAccess()
        screenRecordingState = wasGranted ? .granted : .denied
        logger.info("Screen recording permission request result: \(wasGranted)")
        print("🔐 CGRequestScreenCaptureAccess() returned: \(wasGranted)")
        
        // If it returned false, check again after a short delay
        // Sometimes the system needs a moment to update
        if !wasGranted {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                print("🔐 Re-checking permission after request...")
                let recheckResult = CGPreflightScreenCaptureAccess()
                print("🔐 Re-check result: \(recheckResult)")
                if recheckResult {
                    screenRecordingState = .granted
                    print("🔐 Permission now granted after re-check!")
                }
            }
        }
    }

    /// Requests microphone permission
    func requestMicrophonePermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            microphoneState = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneState = granted ? .granted : .denied
            logger.info("Microphone permission request result: \(granted)")
        case .denied, .restricted:
            microphoneState = .denied
        @unknown default:
            microphoneState = .unknown
        }
    }

    /// Opens System Settings to the Screen Recording preferences pane
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings to the Microphone preferences pane
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings to the Camera preferences pane
    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}
