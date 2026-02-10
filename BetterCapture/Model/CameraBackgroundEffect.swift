//
//  CameraBackgroundEffect.swift
//  BetterCapture
//
//  Created on 09.02.26.
//

import Foundation

/// FaceTime-style background effects for the camera bubble
enum CameraBackgroundEffect: String, CaseIterable, Identifiable {
    case none
    case blur

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .blur: return "Blur"
        }
    }
}
