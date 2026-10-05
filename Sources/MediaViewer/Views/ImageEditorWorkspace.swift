import SwiftUI
import AppKit

/// Native composition workspace. The caller owns media loading, rendering, and durable save/exit.
/// Document changes are always commands on the existing annotation session.
struct ImageEditorWorkspace<Content: View>: View {
    @ObservedObject var session: AnnotationEditorSession
    @Binding var selectedTool: AnnotationTool
    @Binding var currentStyle: ShapeStyle
    @Binding var currentTextStyle: TextStyle
    @Binding var eraserMode: EraserMode
    @Binding var eraserBrushSize: CGFloat
    @Binding var featherRadius: CGFloat
    var isProcessing: Bool = false
    var hasSelectedSubject: Bool = false
    /// Source-pixel control ranges and tool presets follow the document; see `EditorDocumentScale`.
    var documentScale: CGFloat = 1
    let onDone: () -> Void
    let onExport: () -> Void
    let onImportImage: () -> Void
    let onRemoveBackground: () -> Void
    let onIsolatePerson: () -> Void
    let onLiftSubjects: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var inspector: Inspector = .tool
    @State private var showClearConfirmation = false
    private enum Inspector { case tool, crop, adjustments }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                toolRail
                Divider()
                ZStack {
                    EditorWorkspaceGrid()
                    // The canvas owns its fit padding, zoom and pan.
                    content()
                        .environment(\.imageEditorIsCropping, inspector == .crop)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipped()
                Divider()
                sidebar
            }
            Divider()
            footer
        }
        .background(Color(hex: 0x171717))
        .preferredColorScheme(.dark)
        .confirmationDialog("Clear all edits?", isPresented: $showClearConfirmation) {
            Button("Clear Edits", role: .destructive) {
                session.execute(.clearAll, description: "Clear Edits")
                session.clearSelection()
            }
        } message: {
            Text("Your original image is preserved. This can be undone while the editor is open.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .annotationSelectTool)) { _ in
            inspector = .tool
        }
        .onChange(of: selectedTool) { previous, tool in
            if tool != .select { inspector = .tool }
            if tool == .highlighter && previous != .highlighter { currentStyle = preset(.highlighter) }
            else if previous == .highlighter { currentStyle = preset(tool.defaultStyle) }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(Color.accentOrange)
            Text("Image editor").font(.system(size: 12, weight: .semibold))
            Text("·").foregroundStyle(.tertiary)
            Text("Original preserved").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if isProcessing {
                ProgressView().controlSize(.small)
                Text("Processing…").font(.caption).foregroundStyle(.secondary)
            }
            saveStatus
            Button(action: onDone) {
                Text("Save & Close").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentOrange)
            .controlSize(.small)
            .disabled(session.isSaving)
            .help("Save this layered edit and return to the image")
        }
        .padding(.horizontal, 14)
        .frame(height: 43)
        .background(Color(hex: 0x202020))
    }

    @ViewBuilder private var saveStatus: some View {
        if let error = session.saveError {
            Label("Save failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).help(error)
                .font(.system(size: 10))
        } else if session.isSaving {
            Text("Saving…").foregroundStyle(.secondary).font(.system(size: 10))
        } else if session.isDirty {
            Text("Unsaved changes").foregroundStyle(.secondary).font(.system(size: 10))
        }
    }

    private var toolRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 5) {
                railTool(.select, title: "Select & move")
                railDivider
                railTool(.freeform, title: "Draw")
                railTool(.highlighter)
                railTool(.eraser, title: "Erase / restore")
                railDivider
                railTool(.rectangle)
                railTool(.ellipse, title: "Ellipse")
                railTool(.arrow)
                railTool(.text)
                railDivider
                railAction("crop", title: "Crop", active: inspector == .crop) {
                    selectedTool = .select
                    inspector = .crop
                }
                railAction("slider.horizontal.3", title: "Adjustments", active: inspector == .adjustments) {
                    selectedTool = .select
                    inspector = .adjustments
                }
                railDivider
                railTool(.subjectSelect, title: "Select subject")
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 7)
        }
        .frame(width: 56)
        .background(Color(hex: 0x202020))
    }

    private var railDivider: some View {
        Divider().padding(.horizontal, 7).padding(.vertical, 4)
    }

    private func railTool(_ tool: AnnotationTool, title: String? = nil) -> some View {
        let name = title ?? tool.displayName
        return railAction(tool.systemImage, title: tool.shortcutKey.map { "\(name) (\($0))" } ?? name,
                          active: inspector == .tool && selectedTool == tool) {
            inspector = .tool
            if tool == .highlighter && selectedTool != .highlighter { currentStyle = preset(.highlighter) }
            if selectedTool == .highlighter && tool != .highlighter { currentStyle = preset(tool.defaultStyle) }
            selectedTool = tool
        }
    }

    private func preset(_ style: ShapeStyle) -> ShapeStyle {
        EditorDocumentScale.scaled(style, by: documentScale)
    }

    private func scaledRange(_ range: ClosedRange<CGFloat>, limit: CGFloat = 1_000) -> ClosedRange<CGFloat> {
        EditorDocumentScale.range(range, by: documentScale, limit: limit)
    }

    private func railAction(_ icon: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(active ? Color.accentOrange : Color.primary.opacity(0.78))
                .frame(width: 40, height: 36)
                .background(active ? Color.accentOrange.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.accentOrange.opacity(0.4) : Color.clear))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    switch inspector {
                    case .crop:
                        EditorCropInspector(session: session)
                    case .adjustments:
                        EditorAdjustmentsInspector(session: session)
                    case .tool:
                        toolInspector
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: inspector == .adjustments ? 365 : 300)
            Divider()
            EditorWorkspaceLayers(session: session)
                .frame(minHeight: 180, maxHeight: .infinity)
        }
        .frame(width: 246)
        .background(Color(hex: 0x202020))
    }

    @ViewBuilder private var toolInspector: some View {
        EditorInspectorHeading(title: inspectorTitle, icon: selectedTool.systemImage)
        if let layer = session.annotationSet.activeLayer, layer.isLocked || !layer.isVisible {
            Label(layer.isLocked ? "Active layer is locked" : "Active layer is hidden", systemImage: layer.isLocked ? "lock.fill" : "eye.slash")
                .font(.system(size: 10)).foregroundStyle(.orange)
        }
        switch selectedTool {
        case .select:
            selectionInspector
        case .text:
            textInspector
        case .eraser:
            Picker("Mask brush", selection: $eraserMode) {
                ForEach(EraserMode.allCases) { mode in Text(mode.shortName).tag(mode) }
            }
            .pickerStyle(.segmented)
            EditorValueSlider(title: "Brush size", value: $eraserBrushSize, range: scaledRange(2...300, limit: 2_400), suffix: "px")
            instruction("Paint to erase image pixels or restore the original beneath earlier mask strokes.")
        case .subjectSelect, .backgroundRemove, .personSegment:
            subjectInspector
        default:
            strokeInspector
        }
        if session.selectedShapes.contains(where: \.isMask) {
            EditorValueSlider(title: "Edge feather", value: $featherRadius, range: 0...30, suffix: "px") {
                let commands = session.selectedShapes.filter(\.isMask).map {
                    AnnotationCommand.replaceShape(shapeId: $0.id, newShape: $0.withFeatherRadius(featherRadius))
                }
                session.executeGroup(commands, description: "Feather Mask")
            }
        }
    }

    private var inspectorTitle: String {
        selectedTool == .select ? "Selection" : selectedTool == .eraser ? "Mask brush" : selectedTool.displayName
    }

    @ViewBuilder private var selectionInspector: some View {
        if session.selectedShapes.isEmpty {
            instruction("Click an object to select it. Drag to move; drag empty space to select several. Shift-click adds to the selection.")
        } else {
            Text("\(session.selectedShapes.count) selected")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button("Duplicate") { session.duplicateSelected() }
                Button("Delete", role: .destructive) { session.deleteSelected() }
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                Button { session.sendBackward() } label: { Label("Back", systemImage: "square.3.layers.3d.bottom.filled") }
                    .help("Send Backward (⌘[) · ⇧⌘[ sends to back")
                Button { session.bringForward() } label: { Label("Forward", systemImage: "square.3.layers.3d.top.filled") }
                    .help("Bring Forward (⌘]) · ⇧⌘] brings to front")
            }
            .controlSize(.small)
            .disabled(session.selectedShapeIds.count != 1)
            if let shape = session.selectedShapes.first, session.selectedShapes.count == 1 {
                if case .text = shape {
                    EditorSelectedTextInspector(session: session, shape: shape, sizeRange: scaledRange(8...160))
                }
                if EditorSelectedStyleInspector.style(of: shape) != nil {
                    EditorSelectedStyleInspector(session: session, shape: shape, widthRange: scaledRange(1...80))
                }
                if case .extractedSubject(_, _, _, let opacity, let transform, _) = shape {
                    EditorSubjectTransformInspector(session: session, shape: shape, opacity: opacity, transform: transform)
                }
            }
            instruction("Drag the selection to move. Use its corner or edge handles to resize; hold Shift to preserve proportions. ⌘2 zooms to it.")
        }
    }

    private var strokeInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorColorControl(title: "Stroke", rgba: $currentStyle.strokeColor)
            EditorValueSlider(title: "Width", value: $currentStyle.strokeWidth, range: scaledRange(1...80), suffix: "px")
            if selectedTool == .rectangle || selectedTool == .ellipse {
                Toggle("Fill shape", isOn: Binding(
                    get: { currentStyle.fillColor != nil },
                    set: { currentStyle.fillColor = $0 ? currentStyle.strokeColor : nil }
                )).font(.system(size: 11))
                if currentStyle.fillColor != nil {
                    EditorColorControl(title: "Fill", rgba: Binding(
                        get: { currentStyle.fillColor ?? currentStyle.strokeColor },
                        set: { currentStyle.fillColor = $0 }
                    ))
                }
            }
            instruction("Drag on the image to \(selectedTool == .highlighter ? "highlight" : "draw"). New marks are placed on the active unlocked layer.")
        }
    }

    private var textInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorColorControl(title: "Text", rgba: $currentTextStyle.textColor)
            EditorValueSlider(title: "Size", value: $currentTextStyle.fontSize, range: scaledRange(8...160), suffix: "px")
            Picker("Weight", selection: $currentTextStyle.fontWeight) {
                ForEach(TextStyle.FontWeight.allCases, id: \.self) { weight in Text(weight.rawValue.capitalized).tag(weight) }
            }.controlSize(.small)
            Picker("Alignment", selection: $currentTextStyle.alignment) {
                ForEach(TextStyle.TextAlignment.allCases, id: \.self) { alignment in Text(alignment.rawValue.capitalized).tag(alignment) }
            }.controlSize(.small)
            Toggle("Text background", isOn: Binding(
                get: { currentTextStyle.backgroundColor != nil },
                set: { currentTextStyle.backgroundColor = $0 ? 0x00000099 : nil }
            )).font(.system(size: 11))
            instruction("Click the image, type, then press Return or click away. Select existing text to edit its content.")
        }
    }

    private var subjectInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            instruction("Click a subject to preview it, then Lift to Layer (Return) to add it as its own image layer. Esc cancels.")
            Button(action: onLiftSubjects) { Label("Lift selected subject", systemImage: "square.on.square") }
                .disabled(isProcessing || !hasSelectedSubject)
            Divider()
            Button(action: onRemoveBackground) { Label("Remove background", systemImage: "person.fill.viewfinder") }
                .disabled(isProcessing)
            Button(action: onIsolatePerson) { Label("Isolate people", systemImage: "figure.stand") }
                .disabled(isProcessing)
            EditorValueSlider(title: "Edge feather", value: $featherRadius, range: 0...30, suffix: "px")
        }
        .controlSize(.small)
    }

    private func instruction(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!session.canUndo)
                .help(session.undoDescription.map { "Undo \($0)" } ?? "Undo")
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!session.canRedo)
                .help(session.redoDescription.map { "Redo \($0)" } ?? "Redo")
            Divider().frame(height: 18)
            Menu {
                Button("Clear All Edits", role: .destructive) { showClearConfirmation = true }
                    .disabled(session.annotationSet.isEmpty)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                .help("More edit actions")
            Text("\(session.annotationSet.shapeCount) \(session.annotationSet.shapeCount == 1 ? "object" : "objects")")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            Spacer()
            Button(action: onImportImage) { Label("Add image", systemImage: "photo.badge.plus") }
            Button { inspector = .tool; selectedTool = .text } label: { Image(systemName: "textformat") }
                .help("Add text")
            Menu {
                Button("Rectangle") { inspector = .tool; selectedTool = .rectangle }
                Button("Ellipse") { inspector = .tool; selectedTool = .ellipse }
                Button("Arrow") { inspector = .tool; selectedTool = .arrow }
            } label: { Image(systemName: "square.on.circle") }
                .menuStyle(.borderlessButton).frame(width: 28).help("Add shape")
            Divider().frame(height: 18)
            Button(action: onExport) { Label("Export…", systemImage: "square.and.arrow.up") }
                .disabled(isProcessing)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 43)
        .background(Color(hex: 0x202020))
    }
}

private struct EditorWorkspaceGrid: View {
    var body: some View {
        Canvas { context, size in
            for x in stride(from: CGFloat(12), through: size.width, by: 24) {
                for y in stride(from: CGFloat(12), through: size.height, by: 24) {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.09)))
                }
            }
        }
        .background(Color(hex: 0x151515))
        .allowsHitTesting(false)
    }
}

private struct EditorInspectorHeading: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.9))
    }
}

private struct EditorValueSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var suffix: String = ""
    var decimals: Int = 0
    var onCommit: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.*f", decimals, Double(value)) + (suffix.isEmpty ? "" : " \(suffix)"))
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 10))
            Slider(value: $value, in: range, onEditingChanged: { editing in if !editing { onCommit?() } })
                .controlSize(.mini)
                .tint(Color.accentOrange)
        }
    }
}

private struct EditorColorControl: View {
    let title: String
    @Binding var rgba: UInt32
    private let colors: [UInt32] = [0xFFFFFFFF, 0x000000FF, 0xFF6B35FF, 0xEF4444FF, 0xEAB308FF, 0x22C55EFF, 0x3B82F6FF, 0xA855F7FF]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ColorPicker(title, selection: Binding(get: { color(rgba) }, set: { newValue in
                guard let color = NSColor(newValue).usingColorSpace(.deviceRGB) else { return }
                rgba = ShapeStyle.rgba(r: color.redComponent, g: color.greenComponent, b: color.blueComponent, a: color.alphaComponent)
            }), supportsOpacity: true).font(.system(size: 11))
            HStack(spacing: 7) {
                ForEach(colors, id: \.self) { value in
                    Button { rgba = (value & 0xFFFFFF00) | (rgba & 0xFF) } label: {
                        Circle().fill(color(value)).frame(width: 17, height: 17)
                            .overlay(Circle().stroke(.white.opacity((rgba & 0xFFFFFF00) == (value & 0xFFFFFF00) ? 0.95 : 0.18), lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel("Color \(String(value, radix: 16))")
                }
                Button(action: sampleScreenColor) {
                    Image(systemName: "eyedropper").font(.system(size: 11)).frame(width: 17, height: 17)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Pick a color from the image or anywhere on screen")
                .accessibilityLabel("Eyedropper")
            }
        }
    }
    /// The system sampler shows its loupe only after this explicit click; opacity is preserved.
    private func sampleScreenColor() {
        let binding = $rgba
        NSColorSampler().show { picked in
            guard let color = picked?.usingColorSpace(.sRGB) else { return }
            let alpha = CGFloat(binding.wrappedValue & 0xFF) / 255
            binding.wrappedValue = ShapeStyle.rgba(r: color.redComponent, g: color.greenComponent, b: color.blueComponent, a: alpha)
        }
    }
    private func color(_ value: UInt32) -> Color {
        Color(red: Double((value >> 24) & 0xFF) / 255, green: Double((value >> 16) & 0xFF) / 255, blue: Double((value >> 8) & 0xFF) / 255, opacity: Double(value & 0xFF) / 255)
    }
}

private struct EditorCropInspector: View {
    @ObservedObject var session: AnnotationEditorSession
    @State private var crop = NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorInspectorHeading(title: "Crop", icon: "crop")
            Text("Frame the composition. The original image and layers stay editable.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("Full") { crop = NormalizedRect(x: 0, y: 0, width: 1, height: 1) }
                Button("Inset") { crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) }
            }.controlSize(.small)
            cropSlider("Left", keyPath: \.x, range: 0...0.95)
            cropSlider("Top", keyPath: \.y, range: 0...0.95)
            cropSlider("Width", keyPath: \.width, range: 0.05...1)
            cropSlider("Height", keyPath: \.height, range: 0.05...1)
            HStack {
                Button("Apply Crop") { session.execute(.setCropRegion(crop), description: "Crop Image") }
                    .buttonStyle(.borderedProminent).tint(Color.accentOrange)
                Button("Reset") { session.execute(.setCropRegion(nil), description: "Reset Crop") }
                    .disabled(session.annotationSet.cropRegion == nil)
            }.controlSize(.small)
        }
        .onAppear { crop = session.annotationSet.cropRegion ?? crop }
        .onChange(of: session.annotationSet.cropRegion) { _, region in
            crop = region ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        }
    }
    private func cropSlider(_ title: String, keyPath: WritableKeyPath<NormalizedRect, CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        EditorValueSlider(title: title, value: Binding(get: { crop[keyPath: keyPath] * 100 }, set: { value in
            crop[keyPath: keyPath] = value / 100
            crop.width = min(crop.width, 1 - crop.x)
            crop.height = min(crop.height, 1 - crop.y)
        }), range: (range.lowerBound * 100)...(range.upperBound * 100), suffix: "%")
    }
}

private struct EditorAdjustmentsInspector: View {
    @ObservedObject var session: AnnotationEditorSession
    @State private var draft = PhotoAdjustments.identity
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                EditorInspectorHeading(title: "Adjustments", icon: "slider.horizontal.3")
                Spacer()
                Button("Reset") { draft = .identity; commit() }.controlSize(.mini)
                    .disabled(!draft.isModified)
            }
            adjustment("Brightness", \.brightness, -1...1)
            adjustment("Contrast", \.contrast, 0...4)
            adjustment("Saturation", \.saturation, 0...2)
            adjustment("Temperature", \.temperature, 2000...10000, decimals: 0)
            adjustment("Tint", \.tint, -100...100, decimals: 0)
            adjustment("Sharpness", \.sharpness, 0...2)
            adjustment("Vignette", \.vignette, 0...2)
        }
        .onAppear { draft = session.annotationSet.adjustments ?? .identity }
        .onChange(of: session.annotationSet.adjustments) { _, adjustments in draft = adjustments ?? .identity }
    }
    private func adjustment(_ title: String, _ keyPath: WritableKeyPath<PhotoAdjustments, CGFloat>, _ range: ClosedRange<CGFloat>, decimals: Int = 2) -> some View {
        EditorValueSlider(title: title, value: Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 }), range: range, decimals: decimals, onCommit: commit)
    }
    private func commit() { session.execute(.setAdjustments(draft.isModified ? draft : nil), description: "Adjust Image") }
}

private struct EditorSelectedTextInspector: View {
    @ObservedObject var session: AnnotationEditorSession
    let shape: AnnotationShape
    var sizeRange: ClosedRange<CGFloat> = 8...160
    @State private var content = ""
    @State private var style = TextStyle.default
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Text", text: $content, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
                .onSubmit(commit)
            EditorColorControl(title: "Text color", rgba: $style.textColor)
            EditorValueSlider(title: "Size", value: $style.fontSize, range: sizeRange, suffix: "px")
            Picker("Weight", selection: $style.fontWeight) {
                ForEach(TextStyle.FontWeight.allCases, id: \.self) { weight in Text(weight.rawValue.capitalized).tag(weight) }
            }.controlSize(.small)
            Button("Update Text", action: commit).controlSize(.small)
        }
        .onAppear(perform: load)
        .onChange(of: shape) { _, _ in load() }
    }
    private func load() { if case .text(_, _, let text, let textStyle) = shape { content = text; style = textStyle } }
    private func commit() {
        guard case .text(let id, let position, _, _) = shape, !content.isEmpty else { return }
        session.execute(.replaceShape(shapeId: id, newShape: .text(id: id, position: position, content: content, style: style)), description: "Edit Text")
    }
}

private struct EditorSelectedStyleInspector: View {
    @ObservedObject var session: AnnotationEditorSession
    let shape: AnnotationShape
    var widthRange: ClosedRange<CGFloat> = 1...80
    @State private var draft = ShapeStyle.defaultRectangle

    static func style(of shape: AnnotationShape) -> ShapeStyle? {
        switch shape {
        case .rectangle(_, _, let style), .ellipse(_, _, let style), .arrow(_, _, _, let style), .freeform(_, _, let style): return style
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorColorControl(title: "Stroke", rgba: $draft.strokeColor)
            EditorValueSlider(title: "Width", value: $draft.strokeWidth, range: widthRange, suffix: "px")
            if supportsFill {
                Toggle("Fill shape", isOn: Binding(get: { draft.fillColor != nil }, set: { draft.fillColor = $0 ? draft.strokeColor : nil }))
                    .font(.system(size: 11))
                if draft.fillColor != nil {
                    EditorColorControl(title: "Fill", rgba: Binding(get: { draft.fillColor ?? draft.strokeColor }, set: { draft.fillColor = $0 }))
                }
            }
            Button("Apply Style", action: commit).controlSize(.small)
                .disabled(Self.style(of: shape) == draft)
        }
        .onAppear { draft = Self.style(of: shape) ?? .defaultRectangle }
        .onChange(of: shape) { _, value in draft = Self.style(of: value) ?? .defaultRectangle }
    }

    private var supportsFill: Bool {
        switch shape { case .rectangle, .ellipse: return true; default: return false }
    }

    private func commit() {
        let updated: AnnotationShape
        switch shape {
        case .rectangle(let id, let rect, _): updated = .rectangle(id: id, rect: rect, style: draft)
        case .ellipse(let id, let rect, _): updated = .ellipse(id: id, rect: rect, style: draft)
        case .arrow(let id, let from, let to, _): updated = .arrow(id: id, from: from, to: to, style: draft)
        case .freeform(let id, let points, _): updated = .freeform(id: id, points: points, style: draft)
        default: return
        }
        session.execute(.replaceShape(shapeId: shape.id, newShape: updated), description: "Change Object Style")
    }
}

private struct EditorSubjectTransformInspector: View {
    @ObservedObject var session: AnnotationEditorSession
    let shape: AnnotationShape
    let opacity: CGFloat
    let transform: ShapeTransform
    @State private var draftOpacity: CGFloat = 1
    @State private var rotation: CGFloat = 0
    var body: some View {
        VStack(spacing: 12) {
            EditorValueSlider(title: "Object opacity", value: $draftOpacity, range: 0...1, decimals: 2, onCommit: commit)
            EditorValueSlider(title: "Rotation", value: $rotation, range: -180...180, suffix: "°", onCommit: commit)
        }
        .onAppear(perform: load)
        .onChange(of: shape) { _, _ in load() }
    }
    private func load() { draftOpacity = opacity; rotation = transform.rotation }
    private func commit() {
        guard case .extractedSubject(let id, let key, let bounds, _, var transform, let source) = shape else { return }
        transform.rotation = rotation
        let updated = AnnotationShape.extractedSubject(id: id, assetKey: key, bounds: bounds, opacity: draftOpacity, transform: transform, sourceSubjectId: source)
        session.execute(.replaceShape(shapeId: id, newShape: updated), description: "Transform Image Layer")
    }
}

private struct EditorWorkspaceLayers: View {
    @ObservedObject var session: AnnotationEditorSession
    @State private var renameID: UUID?
    @State private var name = ""
    @State private var opacity: CGFloat = 1
    private var active: AnnotationLayer? { session.annotationSet.activeLayer }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                EditorInspectorHeading(title: "Layers", icon: "square.3.layers.3d")
                Spacer()
                Button { session.execute(.addLayer(name: "Layer \(session.annotationSet.layers.count + 1)"), description: "Add Layer") } label: {
                    Image(systemName: "plus")
                }.buttonStyle(.plain).help("Add empty layer")
            }.padding(.horizontal, 14).padding(.vertical, 11)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(session.annotationSet.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                        layerRow(layer, index: index)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "photo").frame(width: 28, height: 28)
                            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                        Text("Original image").font(.system(size: 11))
                        Spacer()
                        Image(systemName: "lock.fill").font(.system(size: 9))
                    }.foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 5)
                }.padding(.horizontal, 7).padding(.bottom, 8)
            }
            if let layer = active {
                Divider()
                VStack(spacing: 9) {
                    EditorValueSlider(title: "Layer opacity", value: $opacity, range: 0...1, decimals: 2) {
                        session.execute(.setLayerOpacity(layerId: layer.id, opacity: opacity), description: "Layer Opacity")
                    }
                    HStack {
                        Text("Blend").foregroundStyle(.secondary)
                        Spacer()
                        Picker("Blend", selection: Binding(get: { layer.blendMode }, set: {
                            session.execute(.setLayerBlendMode(layerId: layer.id, blendMode: $0), description: "Layer Blend")
                        })) {
                            ForEach(LayerBlendMode.allCases, id: \.self) { mode in Text(mode.displayName).tag(mode) }
                        }.labelsHidden().controlSize(.mini).fixedSize()
                    }.font(.system(size: 10))
                }.padding(12)
            }
        }
        .onAppear { opacity = active?.opacity ?? 1 }
        .onChange(of: active?.id) { _, _ in opacity = active?.opacity ?? 1 }
        .onChange(of: active?.opacity) { _, value in opacity = value ?? 1 }
    }

    private func layerRow(_ layer: AnnotationLayer, index: Int) -> some View {
        HStack(spacing: 7) {
            Button {
                session.execute(.toggleLayerVisibility(layerId: layer.id), description: "Layer Visibility")
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 10)).foregroundStyle(layer.isVisible ? Color.secondary : Color.secondary.opacity(0.4))
                    .frame(width: 17, height: 24)
            }.buttonStyle(.plain).help(layer.isVisible ? "Hide layer" : "Show layer")
            Image(systemName: layer.shapes.last.map(EditorShapeGeometry.symbol) ?? "square.dashed")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 29, height: 29)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                if renameID == layer.id {
                    TextField("Layer name", text: $name)
                        .textFieldStyle(.plain).onSubmit { rename(layer.id) }
                } else {
                    Text(layer.name).lineLimit(1)
                        .onTapGesture(count: 2) { name = layer.name; renameID = layer.id }
                }
                Text("\(layer.shapes.count) \(layer.shapes.count == 1 ? "object" : "objects")")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                session.execute(.setLayerLocked(layerId: layer.id, locked: !layer.isLocked), description: "Layer Lock")
                if !layer.isLocked { session.selectedShapeIds.subtract(layer.shapes.map(\.id)) }
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 10)).foregroundStyle(layer.isLocked ? Color.accentOrange : Color.secondary.opacity(0.4))
                    .frame(width: 18, height: 24)
            }.buttonStyle(.plain).help(layer.isLocked ? "Unlock layer" : "Lock layer")
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(layer.id == session.annotationSet.activeLayerId ? Color.accentOrange.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture {
            session.execute(.setActiveLayer(layerId: layer.id), description: "Select Layer")
            if !layer.isLocked && layer.isVisible { session.selectedShapeIds = Set(layer.shapes.map(\.id)) }
            else { session.clearSelection() }
        }
        .contextMenu {
            Button("Rename") { name = layer.name; renameID = layer.id }
            Button("Move Forward") { session.execute(.moveLayer(fromIndex: index, toIndex: index + 2), description: "Move Layer Forward") }
                .disabled(index == session.annotationSet.layers.count - 1)
            Button("Move Backward") { session.execute(.moveLayer(fromIndex: index, toIndex: index - 1), description: "Move Layer Backward") }
                .disabled(index == 0)
            Button("Duplicate Layer") { session.execute(.duplicateLayer(layerId: layer.id, newLayerId: UUID()), description: "Duplicate Layer") }
            Divider()
            Button("Delete Layer", role: .destructive) { session.execute(.removeLayer(layerId: layer.id), description: "Delete Layer") }
                .disabled(layer.isLocked)
        }
    }
    private func rename(_ id: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { session.execute(.renameLayer(layerId: id, name: trimmed), description: "Rename Layer") }
        renameID = nil
    }
}

// The composition canvas can switch crop interactions without adding a second tool enum to the document.
private struct ImageEditorCropModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var imageEditorIsCropping: Bool {
        get { self[ImageEditorCropModeKey.self] }
        set { self[ImageEditorCropModeKey.self] = newValue }
    }
}
