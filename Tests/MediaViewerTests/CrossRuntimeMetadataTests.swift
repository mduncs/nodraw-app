import XCTest
import Yams
@testable import MediaViewer

/// Integration boundary: the real Python server publisher contends with the
/// real Swift publisher. This never starts either application or opens live DBs.
final class CrossRuntimeMetadataTests: XCTestCase {
    private var directory: URL!
    private var sidecar: URL!
    private var children: [Process] = []
    private let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nodraw-cross-writer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sidecar = directory.appendingPathComponent("fixture.md")
        try "---\r\ntags: []\r\nnotes: base\r\nunknown:\r\n  unicode: 雪\r\n---\r\nBody **unchanged**.\r\n".write(to: sidecar, atomically: false, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        for child in children where child.isRunning { child.terminate() }
        children = []
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func startPython(_ script: String) throws -> (Process, Pipe) {
        let executable = repository.appendingPathComponent("server/.venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Cross-runtime gate requires server/.venv/bin/python")
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = repository.appendingPathComponent("server")
        process.arguments = ["-c", script, sidecar.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        children.append(process)
        try process.run()
        return (process, output)
    }

    private func finish(_ process: Process, output: Pipe) async throws -> String {
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if process.isRunning {
            process.terminate()
            throw NSError(domain: "CrossRuntimeMetadataTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Python publisher did not finish after lock release"])
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        return text
    }

    func testAppAndServerSerializeDifferentFieldsThroughSameStableLock() async throws {
        var child: (Process, Pipe)?
        try FrontmatterWriter.processFrontmatter(at: sidecar) { yaml in
            child = try startPython("""
            import sys, fcntl
            from pathlib import Path
            import sidecar_projection as projection
            original_flock = fcntl.flock
            def observed_flock(fd, operation):
                if operation == fcntl.LOCK_EX:
                    print('LOCKING', flush=True)
                return original_flock(fd, operation)
            fcntl.flock = observed_flock
            projection.project(Path(sys.argv[1]), {'tags': ['server', '雪']}, {'tags': [[]]})
            print('APPLIED', flush=True)
            """)
            let output = try XCTUnwrap(child?.1)
            let signal = output.fileHandleForReading.readData(ofLength: 8)
            XCTAssertEqual(String(decoding: signal, as: UTF8.self), "LOCKING\n")
            XCTAssertTrue(child?.0.isRunning == true)
            yaml["notes"] = "app\nmultiline"
        }
        let running = try XCTUnwrap(child)
        let output = try await finish(running.0, output: running.1)
        XCTAssertTrue(output.contains("APPLIED"))
        let final = try String(contentsOf: sidecar, encoding: .utf8)
        let values = try XCTUnwrap(Yams.load(yaml: FrontmatterWriter.parseBoundaries(final).yamlText) as? [String: Any])
        XCTAssertEqual(values["tags"] as? [String], ["server", "雪"])
        XCTAssertEqual(values["notes"] as? String, "app\nmultiline")
        XCTAssertEqual((values["unknown"] as? [String: String])?["unicode"], "雪")
        XCTAssertTrue(final.hasSuffix("---\r\nBody **unchanged**.\r\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".fixture.md.nodraw-lock").path))
    }

    func testServerDetectsAppSameFieldEditWithoutReplacingIt() async throws {
        try FrontmatterWriter.processFrontmatter(at: sidecar) { $0["notes"] = "app wins until explicitly resolved" }
        let before = try Data(contentsOf: sidecar)
        let child = try startPython("""
        import sys
        from pathlib import Path
        import sidecar_projection as projection
        try:
            projection.project(Path(sys.argv[1]), {'notes': 'server edit'}, {'notes': ['base']})
            raise SystemExit('UNEXPECTED OVERWRITE')
        except projection.ProjectionConflict:
            print('CONFLICT', flush=True)
        """)
        let output = try await finish(child.0, output: child.1)
        XCTAssertTrue(output.contains("CONFLICT"))
        XCTAssertEqual(try Data(contentsOf: sidecar), before)
    }
}
