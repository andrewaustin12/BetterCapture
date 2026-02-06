//
//  PreviewThumbnailView.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 02.02.26.
//

import SwiftUI

/// Displays a preview thumbnail of the selected capture content
struct PreviewThumbnailView: View {
    let previewImage: NSImage?

    var body: some View {
        Group {
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                placeholderView
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "display")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Loading Preview...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
    }
}

// MARK: - Preview

#Preview("With Image") {
    PreviewThumbnailView(previewImage: NSImage(systemSymbolName: "display", accessibilityDescription: nil))
        .frame(width: 320)
}

#Preview("Placeholder") {
    PreviewThumbnailView(previewImage: nil)
        .frame(width: 320)
}
