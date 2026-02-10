//
//  BetterCaptureApp.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 29.01.26.
//

import SwiftUI
import AppKit

@main
struct BetterCaptureApp: App {
    @State private var viewModel = RecorderViewModel()
    @State private var updaterService = UpdaterService()

    var body: some Scene {
        // Menu bar extra - the primary interface
        // Using .window style to support custom toggle switches
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
                .task {
                    // Request permissions on first app launch
                    print("🚀 BetterCapture: App launching, requesting permissions...")
                    await viewModel.requestPermissionsOnLaunch()
                    
                    // Also check permissions after a short delay to catch any that were just granted
                    try? await Task.sleep(for: .milliseconds(500))
                    print("🚀 BetterCapture: Re-checking permissions after launch delay...")
                    viewModel.refreshPermissions()
                }
                .onAppear {
                    // Refresh permissions when menu bar window appears
                    // This ensures permissions are up-to-date after returning from System Settings
                    print("🚀 BetterCapture: Menu bar window appeared, refreshing permissions...")
                    viewModel.refreshPermissions()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Refresh permissions when app becomes active (e.g., after returning from System Settings)
                    print("🚀 BetterCapture: App became active, refreshing permissions...")
                    Task {
                        // Small delay to ensure System Settings has fully closed and permissions are updated
                        try? await Task.sleep(for: .milliseconds(500))
                        await MainActor.run {
                            viewModel.refreshPermissions()
                        }
                    }
                }
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView(settings: viewModel.settings, updaterService: updaterService)
                .onAppear {
                    // Refresh permissions when settings window appears
                    viewModel.refreshPermissions()
                }
        }
    }
}

/// The label shown in the menu bar (icon or duration timer)
struct MenuBarLabel: View {
    let viewModel: RecorderViewModel

    var body: some View {
        if viewModel.isRecording {
            // Show recording duration as text
            Text(viewModel.formattedDuration)
                .monospacedDigit()
        } else {
            // Show app icon
            Image(systemName: "record.circle")
        }
    }
}
