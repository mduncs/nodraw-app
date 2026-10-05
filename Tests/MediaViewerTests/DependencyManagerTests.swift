import XCTest
@testable import MediaViewer

final class DependencyManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DependencyManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testFirstExecutableSearchesConfiguredDirectories() throws {
        let firstDir = tempDir.appendingPathComponent("first", isDirectory: true)
        let secondDir = tempDir.appendingPathComponent("second", isDirectory: true)
        let tool = secondDir.appendingPathComponent("ffmpeg")

        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        XCTAssertEqual(
            DependencyManager.firstExecutable(named: "ffmpeg", in: [firstDir, secondDir])?.path,
            tool.path
        )
    }

    func testPythonExecutableFromLauncherExpandsSimpleShellAssignments() throws {
        let serverDir = tempDir.appendingPathComponent("server", isDirectory: true)
        let python = serverDir.appendingPathComponent(".venv/bin/python")
        let launcher = tempDir.appendingPathComponent("media-archiver")

        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let script = """
        #!/bin/sh
        SERVER_DIR="\(serverDir.path)"
        PYTHON="$SERVER_DIR/.venv/bin/python"
        exec "$PYTHON" -m uvicorn main:app
        """
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        XCTAssertEqual(
            DependencyManager.pythonExecutableFromLauncher(launcher)?.standardizedFileURL.path,
            python.standardizedFileURL.path
        )
    }

    func testPythonBackedDownloadToolsAreRuntimeDependenciesNotStandaloneInstalls() {
        let pythonTools = DependencyManager.tools.filter { $0.pythonModuleName != nil }

        XCTAssertEqual(Set(pythonTools.map(\.name)), Set(["yt-dlp", "gallery-dl"]))
        XCTAssertTrue(pythonTools.allSatisfy { !$0.installable })
    }

    func testMediaNormalizationToolchainRegistersBothInstallableExecutables() throws {
        let requiredNames = Set(DependencyManager.requiredMediaExecutableNames)
        let toolsByName = Dictionary(
            uniqueKeysWithValues: DependencyManager.tools.map { ($0.name, $0) }
        )

        XCTAssertEqual(requiredNames, Set(["ffmpeg", "ffprobe"]))
        for name in requiredNames {
            let tool = try XCTUnwrap(toolsByName[name])
            XCTAssertTrue(tool.installable)
            XCTAssertEqual(tool.repo, "eugeneware/ffmpeg-static")
            XCTAssertEqual(tool.executableName, name)
            XCTAssertEqual(tool.versionArguments, ["-version"])
            XCTAssertFalse(tool.isArchive)
            XCTAssertTrue(tool.assetPattern.hasPrefix("\(name)-darwin-"))
        }
    }

    func testMediaToolReleaseMatchingRejectsSiblingMetadataAndCompressedAssets() throws {
        for name in DependencyManager.requiredMediaExecutableNames {
            let tool = try XCTUnwrap(DependencyManager.tools.first { $0.name == name })

            XCTAssertTrue(tool.matchesReleaseAsset(named: tool.assetPattern))
            XCTAssertFalse(tool.matchesReleaseAsset(named: "\(tool.assetPattern).gz"))
            XCTAssertFalse(tool.matchesReleaseAsset(named: "darwin-arm64.LICENSE"))
            XCTAssertFalse(tool.matchesReleaseAsset(named: "darwin-arm64.README"))
        }
    }

    func testManagedBinPathPrecedesHomebrewAndSystemPathsForServerWrapper() throws {
        let directories = DownloadToolSearchPaths.launchdDirectories
        let managedBin = AppPaths.binDirectory.standardizedFileURL

        XCTAssertEqual(try XCTUnwrap(directories.first), managedBin)
        XCTAssertTrue(directories.contains(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)))
        XCTAssertTrue(directories.contains(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)))
        XCTAssertTrue(directories.contains(URL(fileURLWithPath: "/usr/bin", isDirectory: true)))
        XCTAssertEqual(
            DownloadToolSearchPaths.launchdPath.split(separator: ":").first.map(String.init),
            managedBin.path
        )
    }

    func testFFprobeDetectionFallsBackToExternalInstallAndPrefersManagedCopy() throws {
        let managedDir = tempDir.appendingPathComponent("managed", isDirectory: true)
        let externalDir = tempDir.appendingPathComponent("homebrew", isDirectory: true)
        let externalProbe = externalDir.appendingPathComponent("ffprobe")
        let managedProbe = managedDir.appendingPathComponent("ffprobe")

        try FileManager.default.createDirectory(at: managedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        try makeExecutable(at: externalProbe)

        XCTAssertEqual(
            DependencyManager.firstExecutable(named: "ffprobe", in: [managedDir, externalDir]),
            externalProbe
        )

        try makeExecutable(at: managedProbe)
        XCTAssertEqual(
            DependencyManager.firstExecutable(named: "ffprobe", in: [managedDir, externalDir]),
            managedProbe
        )
    }

    private func makeExecutable(at url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
