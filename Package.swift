// swift-tools-version: 6.2
import PackageDescription

// Test foundation only: `swift test` compiles the pure, Apple-Speech-free files
// that already live in the app's folder (no copy, no Xcode project change, no
// test code in the app target). The app itself is built by the Xcode project.
//
// MusicCore (music analysis: melody, notes, rhythm, harmony, loudness) lives
// outside the app's folder, so the Xcode project's synchronized group does not
// pick it up. The app does not use it yet.
let package = Package(
    name: "TranscriptCore",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "TranscriptCore",
            path: "LocalTranscriber",
            // YouTubeSource.swift is only here for SourceMetadata, which the
            // renderer takes for source packages.
            exclude: [
                "Assets.xcassets", "AudioReviewPlayer.swift", "BatchQueue.swift", "ContentView.swift", "Credits.rtf",
                "LibraryStore.swift", "MyApp.swift", "OutputDestination.swift", "Recorder.swift", "RecordingCloseGuard.swift",
                "SettingsView.swift", "SourcePackage.swift", "Theme.swift", "TranscriptReviewView.swift",
                "TranscriptionService.swift", "WorkspaceSidebar.swift",
            ],
            sources: ["Transcript", "YouTubeSource.swift"],
            // Same as the app target (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "TranscriptCoreTests",
            dependencies: ["TranscriptCore"],
            path: "Tests/TranscriptCoreTests",
            exclude: ["Fixtures"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "MusicCore",
            path: "MusicCore",
            exclude: ["README.md"],
            // Same default as the app target, so the files could move into it
            // unchanged; the analysis types are `nonisolated` to run off the
            // main actor.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "MusicCoreTests",
            dependencies: ["MusicCore"],
            path: "Tests/MusicCoreTests",
            exclude: ["Fixtures"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
