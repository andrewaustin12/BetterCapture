//
//  PreviewBubbleView.swift
//  BetterCapture
//
//  Created on 09.02.26.
//

import SwiftUI
import AppKit

/// SwiftUI view for the floating preview bubble
struct PreviewBubbleView: View {
    let previewImage: NSImage?
    let duration: String
    let onClose: () -> Void
    let size: PreviewSize
    /// When true, shows a circular static image of the user (no LIVE badge)
    let isCameraBubble: Bool

    @State private var isHovered = false

    init(
        previewImage: NSImage?,
        duration: String,
        onClose: @escaping () -> Void,
        size: PreviewSize = .medium,
        isCameraBubble: Bool = false
    ) {
        self.previewImage = previewImage
        self.duration = duration
        self.onClose = onClose
        self.size = size
        self.isCameraBubble = isCameraBubble
    }

    private var bubbleSize: CGSize {
        if isCameraBubble {
            let side = min(size.dimensions.width, size.dimensions.height)
            return CGSize(width: side, height: side)
        }
        return size.dimensions
    }

    var body: some View {
        Group {
            if isCameraBubble {
                cameraBubbleContent
            } else {
                screenPreviewContent
            }
        }
        .frame(width: bubbleSize.width, height: bubbleSize.height)
        .background {
            RoundedRectangle(cornerRadius: isCameraBubble ? bubbleSize.width / 2 : 10)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 2)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var cameraBubbleContent: some View {
        Group {
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .frame(width: bubbleSize.width - 16, height: bubbleSize.width - 16)
        .clipShape(.circle)
    }

    private var screenPreviewContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: .capsule)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.6)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)

            Group {
                if let image = previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 6))
            .padding(.horizontal, 8)

            Text(duration)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 6)
        }
    }
}

// MARK: - Preview

#Preview {
    PreviewBubbleView(
        previewImage: nil,
        duration: "00:05:23",
        onClose: {}
    )
}
