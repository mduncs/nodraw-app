/// SwiftUI search + analysis table demo.
///
/// Two views:
///   - **Table**: Bases-style interactive table showing per-image analysis
///     (scene labels, OCR text, aesthetics score). Sortable columns.
///   - **Search**: Natural language search across indexed images.

import SwiftUI
import PhotoPipeline
import ImageIO
import UniformTypeIdentifiers

@main
struct SearchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    static var autoLoadFolder: URL? {
        let args = CommandLine.arguments
        // Support --folder <path> or bare positional arg
        if let idx = args.firstIndex(of: "--folder"), idx + 1 < args.count {
            return URL(fileURLWithPath: args[idx + 1])
        }
        // Bare positional: first arg that looks like a path (not a flag)
        if args.count > 1 {
            let candidate = args[1]
            if !candidate.hasPrefix("-") {
                let url = URL(fileURLWithPath: candidate)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    return url
                }
            }
        }
        return nil
    }

    static var autoSearchQuery: String? {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--auto-search"), idx + 1 < args.count {
            return args[idx + 1]
        }
        return nil
    }
}


func debugLog(_ msg: String) {
    let url = URL(fileURLWithPath: "/tmp/searchui-debug.log")
    let line = "\(Date()): \(msg)\n"
    if let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        try? line.data(using: .utf8)!.write(to: url)
    }
}

// MARK: - View Model

enum ViewMode: String, CaseIterable {
    case table = "Table"
    case search = "Search"
}

enum SortField: String, CaseIterable {
    case name = "Name"
    case topScene = "Scene"
    case objects = "Objects"
    case aesthetics = "Aesthetics"
    case faces = "Faces"
    case ocrText = "OCR Text"
    case curation = "Curation"
    case junk = "Junk"
}

@MainActor
class SearchViewModel: ObservableObject {
    @Published var viewMode: ViewMode = .table
    @Published var query = ""
    @Published var results: [SearchResult] = []
    @Published var analyses: [AssetAnalysis] = []
    @Published var indexedCount = 0
    @Published var isIndexing = false
    @Published var statusMessage = "Drop images to index, then browse the table."
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var sortField: SortField = .name
    @Published var sortAscending = true
    @Published var selectedAssetID: String?
    @Published var filterText = ""

    private var index: SearchIndex?
    private let storePath: URL

    var filteredAnalyses: [AssetAnalysis] {
        var items = analyses
        if !filterText.isEmpty {
            let q = filterText.lowercased()
            items = items.filter { a in
                a.assetID.lowercased().contains(q)
                || a.sceneLabels.contains { $0.label.lowercased().contains(q) }
                || a.ocrText.lowercased().contains(q)
                || a.objectRecognitions.contains { $0.name.lowercased().contains(q) }
            }
        }
        return sorted(items)
    }

    init() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photopipeline-search-ui")
        self.storePath = tempDir
        try? FileManager.default.removeItem(at: tempDir)

        do {
            let config = IndexConfiguration(
                enableEmbeddingSearch: true,
                enableSceneClassification: true,
                enableObjectRecognition: true,
                enableFaceGallery: false,
                enableTextRecognition: true,
                ocrLanguages: ["en-US"]
            )
            self.index = try SearchIndex(configuration: config, storePath: tempDir)
            statusMessage = "Ready — drop images or click Load Folder."
        } catch {
            statusMessage = "Init failed: \(error.localizedDescription)"
        }
    }

    func loadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of images to index"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadDirectory(url)
    }

    func loadDirectory(_ dir: URL) {
        guard let index else { return }
        isIndexing = true
        statusMessage = "Scanning \(dir.lastPathComponent)..."

        Task {
            let fm = FileManager.default
            let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "webp"]
            var urls: [URL] = []

            if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if imageExts.contains(fileURL.pathExtension.lowercased()) {
                        urls.append(fileURL)
                    }
                }
            }

            guard !urls.isEmpty else {
                statusMessage = "No images found in \(dir.lastPathComponent)."
                isIndexing = false
                return
            }

            debugLog("Found \(urls.count) images in \(dir.path)")
            statusMessage = "Indexing \(urls.count) images..."
            var succeeded = 0

            for (i, url) in urls.enumerated() {
                let assetID = url.deletingPathExtension().lastPathComponent
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continue
                }
                do {
                    let result = try await index.index(image: cgImage, assetID: assetID)
                    if result.modulesSucceeded > 0 { succeeded += 1 }
                } catch {
                    debugLog("[\(assetID)] ERROR: \(error)")
                }

                let thumb = NSImage(cgImage: cgImage, size: NSSize(width: 64, height: 64))
                thumbnails[assetID] = thumb

                if (i + 1) % 3 == 0 || i == urls.count - 1 {
                    statusMessage = "Indexing... \(i + 1)/\(urls.count)"
                }
            }

            indexedCount += succeeded
            isIndexing = false
            refreshAnalyses()
            statusMessage = "Indexed \(succeeded)/\(urls.count) images."
        }
    }

    func indexURLs(_ urls: [URL]) {
        guard let index else { return }
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "webp"]
        let imageURLs = urls.filter { imageExts.contains($0.pathExtension.lowercased()) }
        guard !imageURLs.isEmpty else {
            statusMessage = "No supported images in drop."
            return
        }

        isIndexing = true
        statusMessage = "Indexing \(imageURLs.count) images..."

        Task {
            var succeeded = 0
            for url in imageURLs {
                let assetID = url.deletingPathExtension().lastPathComponent
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continue
                }
                do {
                    let result = try await index.index(image: cgImage, assetID: assetID)
                    if result.modulesSucceeded > 0 { succeeded += 1 }
                } catch {
                    debugLog("[\(assetID)] ERROR: \(error)")
                }
                let thumb = NSImage(cgImage: cgImage, size: NSSize(width: 64, height: 64))
                thumbnails[assetID] = thumb
            }
            indexedCount += succeeded
            isIndexing = false
            refreshAnalyses()
            statusMessage = "Indexed \(succeeded)/\(imageURLs.count) images."
        }
    }

    func search() {
        guard let index, !query.isEmpty else { return }
        statusMessage = "Searching..."
        Task {
            do {
                results = try await index.search(query, limit: 20)
                statusMessage = results.isEmpty
                    ? "No results for \"\(query)\""
                    : "\(results.count) result\(results.count == 1 ? "" : "s") for \"\(query)\""
            } catch {
                statusMessage = "Search error: \(error.localizedDescription)"
            }
        }
    }

    func refreshAnalyses() {
        guard let index else { return }
        analyses = index.allAnalysis()
    }

    func toggleSort(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = true
        }
    }

    private func sorted(_ items: [AssetAnalysis]) -> [AssetAnalysis] {
        let asc = sortAscending
        switch sortField {
        case .name:
            return items.sorted { asc ? $0.assetID < $1.assetID : $0.assetID > $1.assetID }
        case .topScene:
            return items.sorted {
                let a = $0.sceneLabels.first?.label ?? ""
                let b = $1.sceneLabels.first?.label ?? ""
                return asc ? a < b : a > b
            }
        case .objects:
            return items.sorted {
                let a = $0.objectRecognitions.first?.name ?? ""
                let b = $1.objectRecognitions.first?.name ?? ""
                return asc ? a < b : a > b
            }
        case .aesthetics:
            return items.sorted { asc ? $0.aestheticsScore < $1.aestheticsScore : $0.aestheticsScore > $1.aestheticsScore }
        case .faces:
            return items.sorted { asc ? $0.faceCount < $1.faceCount : $0.faceCount > $1.faceCount }
        case .ocrText:
            return items.sorted { asc ? $0.ocrText < $1.ocrText : $0.ocrText > $1.ocrText }
        case .curation:
            return items.sorted {
                let a = $0.curationScore ?? -1
                let b = $1.curationScore ?? -1
                return asc ? a < b : a > b
            }
        case .junk:
            return items.sorted {
                let a = $0.junkConfidence ?? -1
                let b = $1.junkConfidence ?? -1
                return asc ? a < b : a > b
            }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var vm = SearchViewModel()
    @State private var isDropTargeted = false
    @State private var didAutoLoad = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if vm.indexedCount == 0 && !vm.isIndexing {
                dropZone
            } else {
                switch vm.viewMode {
                case .table:
                    AnalysisTableView(vm: vm)
                case .search:
                    searchView
                }
            }

            Divider()
            statusBar
        }
        .frame(minWidth: 960, minHeight: 500)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear {
            guard !didAutoLoad else { return }
            didAutoLoad = true
            if let folder = SearchApp.autoLoadFolder {
                vm.loadDirectory(folder)
            }
        }
        .onReceive(vm.$isIndexing) { indexing in
            if !indexing && vm.indexedCount > 0,
               let q = SearchApp.autoSearchQuery, !q.isEmpty, vm.results.isEmpty {
                vm.viewMode = .search
                vm.query = q
                vm.search()
            }
        }
    }

    var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $vm.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 130)

            if vm.viewMode == .search {
                TextField("Search photos...", text: $vm.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .onSubmit { vm.search() }
            } else {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Filter...", text: $vm.filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(maxWidth: 200)
            }

            Spacer()

            if vm.isIndexing {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                vm.loadFolder()
            } label: {
                Label("Load Folder", systemImage: "folder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.isIndexing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    var statusBar: some View {
        HStack {
            Text(vm.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            if vm.indexedCount > 0 {
                Text("\(vm.indexedCount) indexed")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Search View

    var searchView: some View {
        Group {
            if vm.results.isEmpty {
                VStack {
                    Spacer()
                    Text("Type a query and press Search")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(vm.results) { result in
                    HStack(spacing: 12) {
                        thumbnailView(result.assetID, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.assetID)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            Text(result.detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            matchBadge(result.matchType)
                            Text(String(format: "%.3f", result.score))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    var dropZone: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundColor(isDropTargeted ? .accentColor : .secondary.opacity(0.4))
            Text(isDropTargeted ? "Drop to index" : "Drop images here")
                .font(.title3)
                .foregroundColor(isDropTargeted ? .accentColor : .secondary)
            Text("or use Load Folder above")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .padding(8)
        )
    }

    // MARK: - Helpers

    @ViewBuilder
    func thumbnailView(_ assetID: String, size: CGFloat) -> some View {
        if let thumb = vm.thumbnails[assetID] {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .cornerRadius(6)
                .clipped()
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(.secondary.opacity(0.3))
                )
        }
    }

    func matchBadge(_ type: MatchType) -> some View {
        Text(type.rawValue)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(matchColor(type).opacity(0.15))
            .foregroundColor(matchColor(type))
            .cornerRadius(4)
    }

    func matchColor(_ type: MatchType) -> Color {
        switch type {
        case .embedding: return .blue
        case .scene: return .green
        case .object: return .orange
        case .face: return .purple
        case .text: return .red
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { vm.indexURLs(urls) }
        }
        return true
    }
}

// MARK: - Analysis Table View (Bases-style)

struct AnalysisTableView: View {
    @ObservedObject var vm: SearchViewModel

    // Column proportions: thumb(fixed) | name | scenes | objects | aesthetics(fixed) | faces(fixed) | curation(fixed) | ocr | status(fixed)
    private let thumbWidth: CGFloat = 44
    private let aesWidth: CGFloat = 80
    private let facesWidth: CGFloat = 44
    private let curationWidth: CGFloat = 72
    private let statusWidth: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            let fixedW = thumbWidth + aesWidth + facesWidth + curationWidth + statusWidth + 32
            let flexWidth = max(0, geo.size.width - fixedW)
            let nameW = flexWidth * 0.20
            let sceneW = flexWidth * 0.25
            let objW = flexWidth * 0.25
            let ocrW = flexWidth * 0.30

            VStack(spacing: 0) {
                headerRow(nameW: nameW, sceneW: sceneW, objW: objW, ocrW: ocrW)

                if vm.filteredAnalyses.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(vm.filteredAnalyses.enumerated()), id: \.element.id) { idx, analysis in
                                row(analysis, idx: idx, nameW: nameW, sceneW: sceneW, objW: objW, ocrW: ocrW)
                            }
                        }
                    }
                }
            }
        }
    }

    var emptyState: some View {
        VStack {
            Spacer()
            if vm.isIndexing {
                ProgressView("Indexing...")
                    .foregroundColor(.secondary)
            } else if !vm.filterText.isEmpty {
                Text("No matches for \"\(vm.filterText)\"")
                    .foregroundColor(.secondary)
            } else {
                Text("No analysis data yet")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    func headerRow(nameW: CGFloat, sceneW: CGFloat, objW: CGFloat, ocrW: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: thumbWidth)
            headerCell("Name", field: .name, width: nameW)
            headerCell("Scenes", field: .topScene, width: sceneW)
            headerCell("Objects", field: .objects, width: objW)
            headerCell("Aes", field: .aesthetics, width: aesWidth)
            headerCell("Faces", field: .faces, width: facesWidth)
            headerCell("Curation", field: .curation, width: curationWidth)
            headerCell("OCR", field: .ocrText, width: ocrW)
            headerCell("", field: .junk, width: statusWidth)
        }
        .frame(height: 28)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    func headerCell(_ title: String, field: SortField, width: CGFloat) -> some View {
        Button { vm.toggleSort(field) } label: {
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                if vm.sortField == field {
                    Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: width, alignment: .leading)
            .padding(.leading, 6)
        }
        .buttonStyle(.plain)
    }

    func row(_ analysis: AssetAnalysis, idx: Int, nameW: CGFloat, sceneW: CGFloat, objW: CGFloat, ocrW: CGFloat) -> some View {
        AnalysisRow(analysis: analysis, vm: vm, nameW: nameW, sceneW: sceneW, objW: objW, ocrW: ocrW, aesW: aesWidth, facesW: facesWidth, curationW: curationWidth, statusW: statusWidth, thumbW: thumbWidth, isEven: idx % 2 == 0)
    }
}

struct AnalysisRow: View {
    let analysis: AssetAnalysis
    @ObservedObject var vm: SearchViewModel
    let nameW: CGFloat
    let sceneW: CGFloat
    let objW: CGFloat
    let ocrW: CGFloat
    let aesW: CGFloat
    let facesW: CGFloat
    let curationW: CGFloat
    let statusW: CGFloat
    let thumbW: CGFloat
    let isEven: Bool

    @State private var isHovered = false
    @State private var ocrExpanded = false
    @State private var scenesExpanded = false
    @State private var objectsExpanded = false

    var body: some View {
        HStack(spacing: 0) {
            thumbCell
            nameCell
            sceneCell
            objectCell
            aesCell
            facesCell
            curationCell
            ocrCell
            statusCell
        }
        .frame(height: anyExpanded ? nil : 44)
        .frame(minHeight: 44)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { vm.selectedAssetID = analysis.assetID }
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) {
            Color(nsColor: .separatorColor).frame(height: 0.5)
        }
    }

    var anyExpanded: Bool { ocrExpanded || scenesExpanded || objectsExpanded }

    var rowBackground: Color {
        if vm.selectedAssetID == analysis.assetID {
            return Color.accentColor.opacity(0.08)
        }
        if isHovered {
            return Color(nsColor: .controlAccentColor).opacity(0.04)
        }
        return isEven ? Color.clear : Color(nsColor: .textBackgroundColor).opacity(0.4)
    }

    // MARK: - Cells

    var thumbCell: some View {
        Group {
            if let thumb = vm.thumbnails[analysis.assetID] {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .cornerRadius(4)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.3))
                    )
            }
        }
        .frame(width: thumbW)
    }

    var nameCell: some View {
        Text(shortName(analysis.assetID))
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: nameW, alignment: .leading)
            .padding(.leading, 6)
            .help(analysis.assetID)
    }

    var sceneCell: some View {
        let visibleLabels = scenesExpanded ? analysis.sceneLabels : Array(analysis.sceneLabels.prefix(3))
        let overflow = analysis.sceneLabels.count - 3

        return VStack(alignment: .leading, spacing: 2) {
            FlowLayout(spacing: 3) {
                ForEach(Array(visibleLabels.enumerated()), id: \.offset) { _, label in
                    ScenePill(text: label.label, confidence: label.confidence)
                }
                if overflow > 0 {
                    Text(scenesExpanded ? "less" : "+\(overflow)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.accentColor.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.08))
                        .cornerRadius(3)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { scenesExpanded.toggle() } }
                }
            }
        }
        .frame(width: sceneW, alignment: .leading)
        .padding(.leading, 6)
    }

    var aesCell: some View {
        HStack(spacing: 5) {
            // Colored bar
            RoundedRectangle(cornerRadius: 2)
                .fill(aesBarColor.opacity(0.7))
                .frame(width: max(2, CGFloat(analysis.aestheticsScore) * 40), height: 6)
                .animation(.easeOut(duration: 0.3), value: analysis.aestheticsScore)

            Text(String(format: "%.0f", analysis.aestheticsScore * 100))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(aesBarColor)
        }
        .frame(width: aesW, alignment: .leading)
        .padding(.leading, 6)
    }

    var aesBarColor: Color {
        let s = analysis.aestheticsScore
        if s >= 0.75 { return .green }
        if s >= 0.55 { return .orange }
        return .red
    }

    var objectCell: some View {
        let visibleObjects = objectsExpanded ? analysis.objectRecognitions : Array(analysis.objectRecognitions.prefix(2))
        let overflow = analysis.objectRecognitions.count - 2

        return VStack(alignment: .leading, spacing: 2) {
            if analysis.objectRecognitions.isEmpty {
                Text("—")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.3))
            } else {
                FlowLayout(spacing: 3) {
                    ForEach(Array(visibleObjects.enumerated()), id: \.offset) { _, rec in
                        ObjectPill(name: rec.name, domain: rec.domain, confidence: rec.confidence)
                    }
                    if overflow > 0 {
                        Text(objectsExpanded ? "less" : "+\(overflow)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.accentColor.opacity(0.7))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.08))
                            .cornerRadius(3)
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { objectsExpanded.toggle() } }
                    }
                }
            }
        }
        .frame(width: objW, alignment: .leading)
        .padding(.leading, 6)
    }

    var facesCell: some View {
        Group {
            if analysis.faceCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.purple.opacity(0.7))
                    Text("\(analysis.faceCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("—")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.3))
            }
        }
        .frame(width: facesW)
    }

    var ocrCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            if analysis.ocrText.isEmpty && (analysis.ocrRawLineCount ?? 0) == 0 {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.3))
            } else {
                // Diagnostic badge: "3/7 lines" or "3 lines"
                HStack(spacing: 3) {
                    if let raw = analysis.ocrRawLineCount, let kept = analysis.ocrKeptLineCount {
                        let dropped = raw - kept
                        Text("\(kept)/\(raw)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(dropped > 0 ? .orange : .green)
                        Text(dropped > 0 ? "kept" : "lines")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        if dropped > 0 {
                            Text("(\(dropped) filtered)")
                                .font(.system(size: 9))
                                .foregroundColor(.orange.opacity(0.7))
                        }
                    } else if !analysis.textObservations.isEmpty {
                        Text("\(analysis.textObservations.count) lines")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }

                if ocrExpanded {
                    // Show per-line with confidence
                    ForEach(Array(analysis.textObservations.enumerated()), id: \.offset) { _, obs in
                        HStack(spacing: 4) {
                            Text(String(format: "%.0f%%", obs.confidence * 100))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(confidenceColor(obs.confidence))
                                .frame(width: 28, alignment: .trailing)
                            Text(obs.text)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                } else if !analysis.ocrText.isEmpty {
                    Text(analysis.ocrText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(width: ocrW, alignment: .leading)
        .padding(.leading, 6)
        .contentShape(Rectangle())
        .onTapGesture { ocrExpanded.toggle() }
        .help(analysis.ocrText.isEmpty ? "No text detected" : analysis.ocrText)
    }

    func confidenceColor(_ conf: Float) -> Color {
        if conf >= 0.8 { return .green }
        if conf >= 0.5 { return .orange }
        return .red
    }

    var curationCell: some View {
        Group {
            if let score = analysis.curationScore {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(curationColor(score).opacity(0.7))
                        .frame(width: max(2, CGFloat(score) * 36), height: 6)
                    Text(String(format: "%.0f", score * 100))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(curationColor(score))
                }
                .help(analysis.curationGated
                    ? "Gated: quality \(String(format: "%.0f%%", (analysis.junkConfidence ?? 0) * 100)) < 50%"
                    : "Curation \(String(format: "%.0f%%", score * 100))")
            } else {
                Text("—")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.3))
            }
        }
        .frame(width: curationW, alignment: .leading)
        .padding(.leading, 6)
    }

    func curationColor(_ score: Float) -> Color {
        if score >= 0.6 { return .green }
        if score >= 0.3 { return .orange }
        if score > 0 { return .red }
        return .secondary
    }

    var statusCell: some View {
        Group {
            if let jc = analysis.junkConfidence {
                Circle()
                    .fill(jc < 0.5 ? Color.red.opacity(0.7) : Color.green.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .help(jc < 0.5
                        ? "Junk (quality \(String(format: "%.0f%%", jc * 100)))"
                        : "Quality \(String(format: "%.0f%%", jc * 100))")
            } else if analysis.isJunk {
                Circle()
                    .fill(Color.red.opacity(0.7))
                    .frame(width: 8, height: 8)
                    .help("Junk (scene heuristic)")
            } else if analysis.isUtility {
                Circle()
                    .fill(Color.orange.opacity(0.6))
                    .frame(width: 8, height: 8)
                    .help("Utility (screenshot/document)")
            } else {
                Circle()
                    .fill(Color.green.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .help("Good quality")
            }
        }
        .frame(width: statusW)
    }

    func shortName(_ name: String) -> String {
        // Strip common prefixes for readability
        var s = name
        // Remove date prefix like "2025-11-27-"
        if s.count > 11, s.prefix(4).allSatisfy(\.isNumber), s[s.index(s.startIndex, offsetBy: 4)] == "-" {
            let parts = s.split(separator: "-", maxSplits: 3)
            if parts.count >= 4 { s = String(parts[3...].joined(separator: "-")) }
        }
        return s
    }
}

// MARK: - Scene Pill

struct ScenePill: View {
    let text: String
    let confidence: Float

    var body: some View {
        Text(text.replacingOccurrences(of: "_", with: " "))
            .font(.system(size: 10))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(pillColor.opacity(0.12))
            .foregroundColor(pillColor)
            .cornerRadius(4)
    }

    var pillColor: Color {
        if confidence > 0.5 { return .blue }
        if confidence > 0.1 { return .indigo }
        return .secondary
    }
}

// MARK: - Flow Layout (wrapping pills)

struct FlowLayout: Layout {
    var spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxW && x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

// MARK: - Object Pill

struct ObjectPill: View {
    let name: String
    let domain: RecognitionDomain
    var confidence: Float = 0

    var body: some View {
        HStack(spacing: 2) {
            Text(name.replacingOccurrences(of: "_", with: " "))
                .font(.system(size: 10))
                .lineLimit(1)
            if confidence > 0 {
                Text(String(format: "%.0f%%", confidence * 100))
                    .font(.system(size: 8))
                    .foregroundColor(domainColor.opacity(0.6))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(domainColor.opacity(0.12))
        .foregroundColor(domainColor)
        .cornerRadius(4)
    }

    var domainColor: Color {
        switch domain {
        case .dogs: return .brown
        case .cats: return .orange
        case .birds: return .cyan
        case .food: return .red
        case .plants: return .green
        case .insects: return .yellow
        case .landmark, .naturalLandmark, .skyline: return .teal
        case .mammals, .reptiles: return .mint
        case .art, .sculpture: return .purple
        case .unknown: return .secondary
        }
    }
}
