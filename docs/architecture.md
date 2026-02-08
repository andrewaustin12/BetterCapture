# BetterCapture Architecture

This document provides a high-level overview of the BetterCapture architecture, focusing on the component structure, data flow, and media handling.

## High-Level Components

BetterCapture follows the **MVVM (Model-View-ViewModel)** pattern. The application is structured around a central ViewModel that coordinates interactions between the UI views and various backend services.

### Component Relationship Diagram

```mermaid
classDiagram
    %% View Layer
    class MenuBarView {
        +UI Main Interface
    }
    class SettingsView {
        +UI Configuration
    }

    %% ViewModel Layer
    class RecorderViewModel {
        +RecordingState state
        +startRecording()
        +stopRecording()
    }

    %% Model/Data Layer
    class SettingsStore {
        +VideoCodec videoCodec
        +ContainerFormat containerFormat
        +Persists User Preferences
    }

    %% Service Layer
    class CaptureEngine {
        +SCStream stream
        +SCContentSharingPicker picker
        +Handles ScreenCaptureKit
    }
    class AssetWriter {
        +AVAssetWriter writer
        +Writes Media to Disk
    }
    class PreviewService {
        +Generates Thumbnails
        +Live Preview Stream
    }
    class ContentFilterService {
        +Applies Window Exclusions
        +Wallpapers/Dock/Self Hiding
    }
    class AudioDeviceService {
        +Enumerates Microphones
    }

    %% Relationships
    MenuBarView --> RecorderViewModel : Binds to
    SettingsView --> SettingsStore : Binds to
    RecorderViewModel --> SettingsStore : Reads/Writes
    RecorderViewModel --> CaptureEngine : Controls
    RecorderViewModel --> AssetWriter : Controls
    RecorderViewModel --> PreviewService : Controls
    RecorderViewModel --> AudioDeviceService : Uses
    
    CaptureEngine --> ContentFilterService : Uses
    CaptureEngine ..> AssetWriter : Sends Samples (Delegate)
```

### Key Components Description

- **RecorderViewModel**: The heart of the application. It manages the application state (Idle, Recording), handles user intents from the UI, and orchestrates the recording lifecycle.
- **SettingsStore**: Manages persistent user preferences (codecs, frame rates, paths) and handles logic for ensuring compatibility between selected codecs and containers.
- **CaptureEngine**: A wrapper around Apple's `ScreenCaptureKit`. It manages the `SCStream`, handles the content picker, and receives raw audio/video sample buffers.
- **AssetWriter**: Wraps `AVAssetWriter`. It receives `CMSampleBuffer`s from the `CaptureEngine` and writes them to the output file on disk. It handles format conversions and pixel buffer adaptation.
- **ContentFilterService**: Helper service that modifies `SCContentFilter` objects to implement features like hiding the wallpaper, dock, or the application window itself from recordings.

## Recording Data Flow

The screen recording process involves a pipeline where data flows from the system's `ScreenCaptureKit` through the application services to the disk.

### Internal Flow Diagram

```mermaid
sequenceDiagram
    participant User
    participant ViewModel as RecorderViewModel
    participant Engine as CaptureEngine
    participant SCK as ScreenCaptureKit
    participant Writer as AssetWriter
    participant Disk as File System

    User->>ViewModel: Click "Start Recording"
    ViewModel->>Writer: Setup (File URL, Settings)
    ViewModel->>Engine: startCapture(Settings)
    
    rect rgb(30, 30, 30)
        note right of ViewModel: Recording Loop
        Engine->>SCK: Create & Start SCStream
        SCK-->>Engine: Output Video SampleBuffer
        Engine-->>Writer: Append Video Sample
        SCK-->>Engine: Output Audio SampleBuffer
        Engine-->>Writer: Append Audio Sample
        Writer-->>Disk: Write Media Data
    end

    User->>ViewModel: Click "Stop Recording"
    ViewModel->>Engine: stopCapture()
    Engine->>SCK: Stop Stream
    ViewModel->>Writer: finishWriting()
    Writer-->>Disk: Finalize Movie File
    ViewModel->>User: Send Notification
```

### Flow Details

1.  **Initialization**: When the user initiates a recording, the `RecorderViewModel` prepares the `AssetWriter` with the target file path and encoding settings.
2.  **Capture Start**: The `CaptureEngine` validates permissions, applies content filters (e.g., hiding the cursor or wallpaper), and initializes the `ScreenCaptureKit` stream.
3.  **Sample Processing**:
    *   `ScreenCaptureKit` delivers `CMSampleBuffer` objects (video frames, system audio, microphone audio) to the `CaptureEngine`.
    *   The `CaptureEngine` forwards these buffers synchronously to the `AssetWriter` via a delegate pattern.
    *   The `AssetWriter` appends these samples to the `AVAssetWriterInput`s. It handles pixel format conversion (e.g., for HDR 10-bit support) if necessary.
4.  **Finalization**: Upon stopping, the stream is halted, and the `AssetWriter` closes the file, ensuring all metadata is written correctly.

## Codecs and Containers

BetterCapture supports flexible combinations of codecs and containers, managed by the `SettingsStore`. The architecture ensures that invalid combinations (like Alpha channel in MP4) are prevented at the configuration level.

### Supported Containers
*   **MOV (QuickTime)**: The preferred format. Supports all features including Alpha Channel, HDR, and uncompressed audio (PCM).
*   **MP4 (MPEG-4)**: A widely compatible format. Restricted to H.264/HEVC and AAC audio. Does not support Alpha Channel or HDR.

### Supported Codecs
*   **Video**: H.264, HEVC (H.265), ProRes 422, ProRes 4444.
*   **Audio**: AAC (Compressed), PCM (Uncompressed).

> **Note**: For detailed compatibility matrices, restrictions, and feature support (such as Alpha Channel availability per codec), please refer to the [Compatibility Documentation](../docs/compatibility.md).
