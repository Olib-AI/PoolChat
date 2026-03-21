// VoiceRecordingCleanupTests.swift
// PoolChatTests

import XCTest
@testable import PoolChat

/// Tests for the stale voice file cleanup logic in VoiceRecordingService.
/// These tests exercise the file system cleanup behavior without requiring audio hardware.
@available(macOS 14.0, iOS 17.0, *)
final class VoiceRecordingCleanupTests: XCTestCase {

    private let tempDir = FileManager.default.temporaryDirectory

    override func tearDown() {
        // Clean up any test files we created
        let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        for file in (contents ?? []) where file.lastPathComponent.hasPrefix("voice_test_") {
            try? FileManager.default.removeItem(at: file)
        }
        super.tearDown()
    }

    @MainActor
    func testCleanupStaleVoiceFilesOnInit() throws {
        // Create fake stale voice files in the temp directory
        let staleFile1 = tempDir.appendingPathComponent("voice_\(UUID().uuidString).m4a")
        let staleFile2 = tempDir.appendingPathComponent("voice_\(UUID().uuidString).m4a")
        let nonVoiceFile = tempDir.appendingPathComponent("other_file.txt")

        try Data("fake audio 1".utf8).write(to: staleFile1)
        try Data("fake audio 2".utf8).write(to: staleFile2)
        try Data("not audio".utf8).write(to: nonVoiceFile)

        // Creating VoiceRecordingService triggers cleanupStaleVoiceFiles in init
        _ = VoiceRecordingService()

        // Stale voice files should be removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile1.path), "Stale voice file 1 should be cleaned up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile2.path), "Stale voice file 2 should be cleaned up")

        // Non-voice files should remain
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonVoiceFile.path), "Non-voice files should not be removed")

        // Cleanup
        try? FileManager.default.removeItem(at: nonVoiceFile)
    }

    // MARK: - TimeInterval Formatting

    func testFormattedDurationMinutesAndSeconds() {
        let duration: TimeInterval = 125 // 2 minutes 5 seconds
        XCTAssertEqual(duration.formattedDuration, "2:05")
    }

    func testFormattedDurationZero() {
        let duration: TimeInterval = 0
        XCTAssertEqual(duration.formattedDuration, "0:00")
    }

    func testFormattedDurationUnderOneMinute() {
        let duration: TimeInterval = 45
        XCTAssertEqual(duration.formattedDuration, "0:45")
    }
}
