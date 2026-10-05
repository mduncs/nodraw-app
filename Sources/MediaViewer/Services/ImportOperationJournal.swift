import Foundation
import CryptoKit
import Darwin

/// Destination-local evidence; never removes a source or guesses ownership from a name.
enum DurableArchiveFile {
    static func sync(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try sync(url)
        try sync(url.deletingLastPathComponent())
    }

    static func publish(_ source: URL, to destination: URL) throws {
        try sync(source)
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw posixError()
        }
        try sync(destination.deletingLastPathComponent())
        try sync(source.deletingLastPathComponent())
    }

    static func copyCancellable(_ source: URL, to destination: URL) throws {
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close(); try? output.close() }
        // Drain each chunk: in a long-lived task the autoreleased reads otherwise pile up
        // until the whole copy ends (a large video costs its full size in memory).
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty else { return false }
            try Task.checkCancellation()
            try output.write(contentsOf: bytes)
            return true
        }) {}
        // Retain the source's Finder metadata, ACLs and dates without recopying
        // data or exposing the destination before the journaled publication.
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw posixError()
        }
        try output.synchronize()
        try sync(destination.deletingLastPathComponent())
    }
}

struct ImportFileEvidence: Codable, Sendable {
    let device: UInt64
    let inode: UInt64
    let sha256: String

    init(url: URL, cancellation: Bool = true) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
            throw ImportError(filename: url.lastPathComponent, reason: "File is missing, empty, or a symbolic link")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        // Drained per chunk for the same reason as `copyCancellable`.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty else { return false }
            if cancellation { try Task.checkCancellation() }
            hash.update(data: bytes)
            return true
        }) {}
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (after[.systemNumber] as? NSNumber)?.uint64Value == device,
              (after[.systemFileNumber] as? NSNumber)?.uint64Value == inode,
              (after[.size] as? NSNumber) == (attributes[.size] as? NSNumber),
              (after[.modificationDate] as? Date) == (attributes[.modificationDate] as? Date) else {
            throw ImportError(filename: url.lastPathComponent, reason: "File changed while being read; retry when it is stable")
        }
        sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ url: URL) -> Bool {
        guard let current = try? Self(url: url, cancellation: false) else { return false }
        return device == current.device && inode == current.inode && sha256 == current.sha256
    }
}

struct ImportOperation: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case preparing, staged, mediaPublished, filesPublished, databaseCommitted, completed, failed, cancelled }
    let id: UUID
    let itemID: UUID
    let sourceURL: URL
    let destinationURL: URL
    let metadataURL: URL
    let metadata: MediaMetadata
    var phase: Phase = .preparing
    var mediaEvidence: ImportFileEvidence?
    var sidecarEvidence: ImportFileEvidence?
    /// Optional for compatibility with receipts written before replay prevention.
    var sourceEvidence: ImportFileEvidence?
    var sourceSidecarEvidence: ImportFileEvidence?
    var hadSourceSidecar: Bool?
    var error: String?
}

/// ImportService instances are short-lived (one per drop). Serialize publication
/// and recovery for an archive across those instances, not just within one actor.
actor ImportArchiveGate {
    static let shared = ImportArchiveGate()
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: String) async {
        if held.insert(key).inserted { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    func release(_ key: String) {
        if var pending = waiters[key], !pending.isEmpty {
            let next = pending.removeFirst()
            waiters[key] = pending.isEmpty ? nil : pending
            next.resume()
        } else { held.remove(key) }
    }
}

struct ImportOperationJournal: Sendable {
    let archivePath: URL
    var root: URL { archivePath.appendingPathComponent(".nodraw-imports", isDirectory: true) }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func recordURL(_ id: UUID) -> URL { folder(id).appendingPathComponent(".state.json") }
    func stagedMedia(_ operation: ImportOperation) -> URL { folder(operation.id).appendingPathComponent(".media.\(operation.sourceURL.pathExtension)") }
    func stagedSidecar(_ operation: ImportOperation) -> URL { folder(operation.id).appendingPathComponent(".sidecar.md") }

    func validateContained(_ url: URL) throws {
        let rootPath = archivePath.resolvingSymlinksInPath().path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(rootPath),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw ImportError(filename: url.lastPathComponent, reason: "Import path changed outside its archive; files were preserved")
        }
    }

    func save(_ operation: ImportOperation) throws {
        try validateContained(folder(operation.id))
        try FileManager.default.createDirectory(at: folder(operation.id), withIntermediateDirectories: true)
        try DurableArchiveFile.write(JSONEncoder().encode(operation), to: recordURL(operation.id))
        try DurableArchiveFile.sync(root)
        try DurableArchiveFile.sync(archivePath)
    }

    func operations() throws -> [ImportOperation] {
        let scan = try scan()
        if let error = scan.errors.first { throw error }
        return scan.operations
    }

    func scan() throws -> (operations: [ImportOperation], errors: [ImportError]) {
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], []) }
        try validateContained(root)
        var operations: [ImportOperation] = []
        var errors: [ImportError] = []
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where UUID(uuidString: directory.lastPathComponent) != nil {
            do {
                let path = directory.appendingPathComponent(".state.json")
                try validateContained(path)
                let operation = try JSONDecoder().decode(ImportOperation.self, from: Data(contentsOf: path))
                guard operation.id.uuidString == directory.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
                operations.append(operation)
            } catch {
                errors.append(ImportError(filename: "Import recovery", reason: "An import record needs review: \(error.localizedDescription)", operationID: UUID(uuidString: directory.lastPathComponent)))
            }
        }
        return (operations, errors)
    }

    func publish(_ staged: URL, to destination: URL, evidence: ImportFileEvidence) throws {
        try validateContained(staged)
        try validateContained(destination)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard evidence.matches(destination) else {
                throw ImportError(filename: destination.lastPathComponent, reason: "A different file occupies the import destination. Reveal it and resolve the collision before retrying.")
            }
            return
        }
        guard evidence.matches(staged) else {
            throw ImportError(filename: staged.lastPathComponent, reason: "Staged import changed or is incomplete; original and recovery files were preserved")
        }
        try DurableArchiveFile.publish(staged, to: destination)
    }
}

/// Retains the provider-delivered URL (including its sandbox extension) across UI waits.
final class ImportSecurityScope: @unchecked Sendable {
    let url: URL
    private let accessing: Bool
    init(_ url: URL) {
        self.url = url
        accessing = url.startAccessingSecurityScopedResource()
    }
    deinit { if accessing { url.stopAccessingSecurityScopedResource() } }
}
