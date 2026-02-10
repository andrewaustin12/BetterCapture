//
//  PreviewBubbleWindow.swift
//  BetterCapture
//
//  Created on 09.02.26.
//

import AppKit
import SwiftUI
import OSLog

/// Screen corner positions for preview bubble
enum ScreenCorner: String, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

/// Preview bubble size options
enum PreviewSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var dimensions: CGSize {
        switch self {
        case .small: return CGSize(width: 288, height: 216)
        case .medium: return CGSize(width: 400, height: 300)
        case .large: return CGSize(width: 528, height: 396)
        }
    }
}

/// Service for managing the floating preview bubble window
@MainActor
@Observable
final class PreviewBubbleWindow {

    // MARK: - Properties

    private(set) var previewImage: NSImage?
    private(set) var duration: String = "00:00"
    private(set) var isVisible = false
    private var currentSize: PreviewSize = .medium

    private var window: NSWindow?
    private var hostingView: NSHostingView<PreviewBubbleView>?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture",
        category: "PreviewBubbleWindow"
    )

    // MARK: - Window Management

    private var isCameraBubble = false

    /// Shows the preview bubble window at the specified corner
    /// - Parameters:
    ///   - corner: The screen corner to position the window
    ///   - size: The size of the preview bubble
    ///   - isCameraBubble: When true, shows a circular static image (no LIVE badge)
    ///   - initialImage: Optional image to display immediately (e.g. first camera frame)
    func show(at corner: ScreenCorner, size: PreviewSize = .medium, isCameraBubble: Bool = false, initialImage: NSImage? = nil) {
        currentSize = size
        self.isCameraBubble = isCameraBubble
        if let initialImage { previewImage = initialImage }

        guard window == nil else {
            logger.info("Window already exists, bringing to front")
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let dimensions: CGSize = isCameraBubble
            ? CGSize(width: min(size.dimensions.width, size.dimensions.height),
                     height: min(size.dimensions.width, size.dimensions.height))
            : size.dimensions
        let frame = calculateWindowFrame(size: dimensions, corner: corner, isCameraBubble: isCameraBubble)

        // Create panel (floating window)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        // Create SwiftUI view
        let bubbleView = PreviewBubbleView(
            previewImage: previewImage,
            duration: duration,
            onClose: { [weak self] in
                self?.hide()
            },
            size: size,
            isCameraBubble: isCameraBubble
        )

        let hostingView = NSHostingView(rootView: bubbleView)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = hostingView

        self.window = panel
        self.hostingView = hostingView
        self.isVisible = true

        // Activate app so floating window is visible (menu bar apps often run in background)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        logger.info("Preview bubble window shown at \(corner.rawValue)")
    }

    /// Hides the preview bubble window
    func hide() {
        guard let window else { return }

        window.orderOut(nil)
        self.window = nil
        self.hostingView = nil
        self.isVisible = false

        logger.info("Preview bubble window hidden")
    }

    /// Updates the preview image displayed in the bubble
    /// - Parameter image: The new preview image
    func updatePreview(_ image: NSImage?) {
        previewImage = image
        updateView()
    }

    /// Updates the recording duration displayed in the bubble
    /// - Parameter duration: The formatted duration string
    func updateDuration(_ duration: String) {
        self.duration = duration
        updateView()
    }

    /// Gets the window number for exclusion from capture
    var windowNumber: Int? {
        window?.windowNumber
    }

    /// Gets the bubble window's frame in screen coordinates (for overlay positioning in recording)
    var frameInScreenCoordinates: NSRect? {
        window?.frame
    }

    // MARK: - Private Methods

    private func calculateWindowFrame(size: CGSize, corner: ScreenCorner, isCameraBubble: Bool = false) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100, width: size.width, height: size.height)
        }

        let screenFrame = screen.visibleFrame
        let padding: CGFloat = isCameraBubble ? 48 : 20

        let x: CGFloat
        let y: CGFloat

        switch corner {
        case .topLeft:
            x = screenFrame.minX + padding
            y = screenFrame.maxY - size.height - padding
        case .topRight:
            x = screenFrame.maxX - size.width - padding
            y = screenFrame.maxY - size.height - padding
        case .bottomLeft:
            x = screenFrame.minX + padding
            y = screenFrame.minY + padding
        case .bottomRight:
            x = screenFrame.maxX - size.width - padding
            y = screenFrame.minY + padding
        }

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func updateView() {
        guard let hostingView else { return }

        let bubbleView = PreviewBubbleView(
            previewImage: previewImage,
            duration: duration,
            onClose: { [weak self] in
                self?.hide()
            },
            size: currentSize,
            isCameraBubble: isCameraBubble
        )

        hostingView.rootView = bubbleView
    }
}
