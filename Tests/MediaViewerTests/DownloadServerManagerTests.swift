import XCTest
@testable import MediaViewer

final class DownloadServerManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadServerManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testLaunchAgentSnapshotReadsArchiveDirectory() throws {
        let snapshot = try makeSnapshot([
            "Label": "com.nodraw.download-server",
            "ProgramArguments": ["/usr/bin/env", "python3", "-m", "uvicorn", "main:app"],
            "WorkingDirectory": "/tmp/server",
            "EnvironmentVariables": [
                "MEDIA_ARCHIVER_DIR": "/tmp/archive/../Archive/Subdir"
            ]
        ])

        XCTAssertEqual(snapshot.label, "com.nodraw.download-server")
        XCTAssertEqual(snapshot.standardizedArchiveDirectory, "/tmp/Archive/Subdir")
    }

    func testLaunchAgentSnapshotResolvesRelativeScriptAgainstWorkingDirectory() throws {
        let serverDir = tempDir.appendingPathComponent("server", isDirectory: true)
        let mainPy = serverDir.appendingPathComponent("main.py")
        let python = tempDir.appendingPathComponent("venv/bin/python3")

        try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mainPy.path, contents: Data())
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let snapshot = try makeSnapshot([
            "Label": "com.mediaviewer.download-server",
            "ProgramArguments": [python.path, "main.py"],
            "WorkingDirectory": serverDir.path
        ])

        XCTAssertFalse(snapshot.referencesMissingPaths())

        try FileManager.default.removeItem(at: mainPy)
        XCTAssertTrue(snapshot.referencesMissingPaths())
    }

    func testLaunchAgentSnapshotDetectsLegacyMediaViewerWorkspace() throws {
        let snapshot = try makeSnapshot([
            "Label": "com.mediaviewer.download-server",
            "ProgramArguments": ["/opt/example/media-viewer/server/venv/bin/python3", "main.py"],
            "WorkingDirectory": "/opt/example/media-viewer/server"
        ])

        XCTAssertTrue(snapshot.pointsToLegacyMediaViewerWorkspace)
    }

    func testLaunchAgentSnapshotTracksWrappedExecutablePath() throws {
        let binary = tempDir.appendingPathComponent("download-server/media-archiver")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data())

        let snapshot = try makeSnapshot([
            "Label": "com.nodraw.download-server",
            "ProgramArguments": [
                "/bin/sh",
                "-c",
                "sleep 5; exec \"$0\" \"$@\"",
                binary.path
            ],
            "WorkingDirectory": binary.deletingLastPathComponent().path
        ])

        XCTAssertFalse(snapshot.referencesMissingPaths())

        try FileManager.default.removeItem(at: binary)
        XCTAssertTrue(snapshot.referencesMissingPaths())
    }

    func testArchivePathStoreReconcilesLegacyDownloadServerArchiveKey() throws {
        try XCTSkipIf(archivePathEnvironmentOverrideIsActive, "Archive path environment override is intentionally authoritative")
        let defaults = try makeIsolatedDefaults()
        let legacyPath = tempDir
            .appendingPathComponent("legacy", isDirectory: true)
            .appendingPathComponent("../Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyPath, withIntermediateDirectories: true)

        defaults.set(legacyPath.path, forKey: ArchivePathStore.downloadServerArchiveDirKey)

        let resolvedPath = ArchivePathStore.reconciledPath(defaults: defaults).standardizedFileURL.path

        XCTAssertEqual(resolvedPath, legacyPath.standardizedFileURL.path)
        XCTAssertEqual(defaults.string(forKey: ArchivePathStore.archivePathKey), resolvedPath)
        XCTAssertEqual(defaults.string(forKey: ArchivePathStore.downloadServerArchiveDirKey), resolvedPath)
    }

    func testArchivePathStoreSetCurrentPathKeepsDownloadServerArchiveInSync() throws {
        try XCTSkipIf(archivePathEnvironmentOverrideIsActive, "Archive path environment override is intentionally authoritative")
        let defaults = try makeIsolatedDefaults()
        let stalePath = tempDir.appendingPathComponent("Stale", isDirectory: true)
        let archivePath = tempDir.appendingPathComponent("Archive", isDirectory: true)

        defaults.set(stalePath.path, forKey: ArchivePathStore.archivePathKey)
        defaults.set(stalePath.path, forKey: ArchivePathStore.downloadServerArchiveDirKey)

        ArchivePathStore.setCurrentPath(archivePath, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: ArchivePathStore.archivePathKey), archivePath.standardizedFileURL.path)
        XCTAssertEqual(defaults.string(forKey: ArchivePathStore.downloadServerArchiveDirKey), archivePath.standardizedFileURL.path)
        XCTAssertEqual(ArchivePathStore.currentPath(defaults: defaults).standardizedFileURL.path, archivePath.standardizedFileURL.path)
    }

    @MainActor
    func testGeneratedLaunchAgentPlistUsesManagedPortArchiveAndDelayedLaunch() throws {
        let archive = tempDir.appendingPathComponent("Archive", isDirectory: true)
        let binary = tempDir.appendingPathComponent("download-server/media-archiver")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data())

        let manager = DownloadServerManager()
        let plistData = try manager.generateStandaloneLaunchAgentPlistForTesting(
            binary: binary,
            archiveDirectory: archive.path
        )
        let snapshot = try XCTUnwrap(DownloadServerManager.LaunchAgentPlistSnapshot(data: plistData))

        XCTAssertEqual(snapshot.label, DownloadServerManager.plistLabel)
        XCTAssertEqual(snapshot.standardizedArchiveDirectory, archive.standardizedFileURL.path)
        XCTAssertEqual(snapshot.environmentVariables["MEDIA_ARCHIVER_PORT"], "\(DownloadServerManager.port)")
        XCTAssertEqual(snapshot.environmentVariables["MEDIA_ARCHIVER_DIR"], archive.path)
        XCTAssertEqual(snapshot.environmentVariables["PATH"], DownloadToolSearchPaths.launchdPath)
        XCTAssertTrue(snapshot.environmentVariables["PATH"]?.contains(AppPaths.binDirectory.path) == true)
        XCTAssertEqual(snapshot.programArguments.prefix(4), [
            "/bin/sh",
            "-c",
            "sleep 5; exec \"$0\" \"$@\"",
            binary.path
        ])
        XCTAssertEqual(snapshot.workingDirectory, AppPaths.downloadServerDirectory.path)
    }

    @MainActor
    func testManagerArchiveDirectoryUsesArchivePathStoreEffectivePathForGeneratedPlist() throws {
        try XCTSkipIf(archivePathEnvironmentOverrideIsActive, "Archive path environment override is intentionally authoritative")
        let snapshot = DefaultsSnapshot()
        defer { snapshot.restore() }

        let archive = tempDir.appendingPathComponent("Archive From App State", isDirectory: true)
        let binary = tempDir.appendingPathComponent("download-server/media-archiver")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data())
        ArchivePathStore.setCurrentPath(archive)

        let manager = DownloadServerManager()
        let plistData = try manager.generateStandaloneLaunchAgentPlistForTesting(
            binary: binary,
            archiveDirectory: manager.archiveDirectory
        )
        let plistSnapshot = try XCTUnwrap(DownloadServerManager.LaunchAgentPlistSnapshot(data: plistData))

        XCTAssertEqual(manager.archiveDirectory, archive.standardizedFileURL.path)
        XCTAssertEqual(plistSnapshot.standardizedArchiveDirectory, archive.standardizedFileURL.path)
    }

    private func makeSnapshot(_ plist: [String: Any]) throws -> DownloadServerManager.LaunchAgentPlistSnapshot {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        return try XCTUnwrap(DownloadServerManager.LaunchAgentPlistSnapshot(data: data))
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "DownloadServerManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private var archivePathEnvironmentOverrideIsActive: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["NODRAW_ARCHIVE_PATH"]?.isEmpty == false
            || env["MEDIAVIEWER_ARCHIVE_PATH"]?.isEmpty == false
    }

    private struct DefaultsSnapshot {
        let archivePath: String?
        let downloadServerArchiveDir: String?

        init() {
            archivePath = UserDefaults.standard.string(forKey: ArchivePathStore.archivePathKey)
            downloadServerArchiveDir = UserDefaults.standard.string(forKey: ArchivePathStore.downloadServerArchiveDirKey)
        }

        func restore() {
            restore(archivePath, forKey: ArchivePathStore.archivePathKey)
            restore(downloadServerArchiveDir, forKey: ArchivePathStore.downloadServerArchiveDirKey)
        }

        private func restore(_ value: String?, forKey key: String) {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
