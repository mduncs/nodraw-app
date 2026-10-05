import SwiftUI
import AppKit

// MARK: - HSB → RGB (pure math, no ObjC calls — fast for pixel-level rendering)

private func hsbToRGB(h: Double, s: Double, b: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
    let c = b * s
    let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
    let m = b - c
    let (r1, g1, b1): (Double, Double, Double)
    switch h * 6 {
    case 0..<1: (r1, g1, b1) = (c, x, 0)
    case 1..<2: (r1, g1, b1) = (x, c, 0)
    case 2..<3: (r1, g1, b1) = (0, c, x)
    case 3..<4: (r1, g1, b1) = (0, x, c)
    case 4..<5: (r1, g1, b1) = (x, 0, c)
    default:    (r1, g1, b1) = (c, 0, x)
    }
    return (UInt8(max(0, min(255, (r1 + m) * 255))),
            UInt8(max(0, min(255, (g1 + m) * 255))),
            UInt8(max(0, min(255, (b1 + m) * 255))))
}

// MARK: - Color Wheel

/// HSB color wheel — hue around circumference, saturation center→edge.
/// Rendered as a cached CGImage bitmap for performance (~40k pixels, <10ms).
/// Supports an optional tolerance halo showing the color match region.
struct ColorWheelView: View {
    @Binding var hue: Double       // 0...1
    @Binding var saturation: Double // 0...1
    var brightness: Double = 1.0
    let diameter: CGFloat

    /// Tolerance as fraction of wheel radius (0 = pinpoint, 1 = entire wheel)
    var toleranceFraction: Double = 0

    @State private var wheelImage: CGImage?
    @State private var cachedBrightness: Double = -1

    var body: some View {
        ZStack {
            if let img = wheelImage {
                Image(decorative: img, scale: 1.0)
                    .resizable()
                    .frame(width: diameter, height: diameter)
            }

            // Selection marker position
            let wheelRadius = diameter / 2
            let dist = saturation * wheelRadius
            let angle = hue * 2 * Double.pi - Double.pi
            let mx = wheelRadius + dist * cos(angle)
            let my = wheelRadius + dist * sin(angle)

            // Tolerance halo — translucent circle showing catchment area
            // Clamped so it never extends past the wheel edge
            if toleranceFraction > 0.01 {
                let rawHaloDiameter = toleranceFraction * diameter
                // Clamp: halo can't extend beyond wheel boundary from current position
                let distFromCenter = sqrt(pow(mx - wheelRadius, 2) + pow(my - wheelRadius, 2))
                let maxHaloRadius = wheelRadius - distFromCenter
                let haloDiameter = max(8, min(rawHaloDiameter, maxHaloRadius * 2))

                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: brightness).opacity(0.18))
                    .frame(width: haloDiameter, height: haloDiameter)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .position(x: mx, y: my)
                    .allowsHitTesting(false)
            }

            // Center dot — exact color, always prominent
            Circle()
                .fill(Color(hue: hue, saturation: saturation, brightness: brightness))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5).padding(-0.5))
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                .position(x: mx, y: my)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let center = diameter / 2
                    let dx = drag.location.x - center
                    let dy = drag.location.y - center
                    let distance = min(sqrt(dx * dx + dy * dy), center)
                    hue = Double((atan2(dy, dx) + CGFloat.pi) / (2 * CGFloat.pi))
                    saturation = distance / center
                }
        )
        .onAppear { renderWheel() }
        .onChange(of: brightness) { _, _ in renderWheel() }
        .accessibilityElement()
        .accessibilityLabel("Hue and saturation color wheel")
        .accessibilityValue("Hue \(Int(hue * 360)) degrees, saturation \(Int(saturation * 100)) percent, brightness \(Int(brightness * 100)) percent")
        .accessibilityHint("Drag to choose a color. Focus and use arrow keys to adjust hue and saturation.")
        .accessibilityAdjustableAction { direction in
            let change = direction == .increment ? 1.0 / 360.0 : -1.0 / 360.0
            adjustHue(change)
        }
        .accessibilityAction(named: Text("Increase saturation")) { adjustSaturation(0.05) }
        .accessibilityAction(named: Text("Decrease saturation")) { adjustSaturation(-0.05) }
        .focusable()
        .onKeyPress(.leftArrow) { adjustHue(-1.0 / 36.0); return .handled }
        .onKeyPress(.rightArrow) { adjustHue(1.0 / 36.0); return .handled }
        .onKeyPress(.upArrow) { adjustSaturation(0.05); return .handled }
        .onKeyPress(.downArrow) { adjustSaturation(-0.05); return .handled }
    }

    private func adjustHue(_ delta: Double) {
        hue = (hue + delta).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
    }

    private func adjustSaturation(_ delta: Double) {
        saturation = max(0, min(1, saturation + delta))
    }

    private func renderWheel() {
        guard brightness != cachedBrightness else { return }
        cachedBrightness = brightness

        let size = Int(diameter)
        let center = Double(size) / 2.0
        let radius = center

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) - center
                let dy = Double(y) - center
                let distance = sqrt(dx * dx + dy * dy)
                let offset = (y * size + x) * 4

                if distance <= radius {
                    // Soft anti-aliased edge (1px)
                    let alpha: Double = distance > radius - 1 ? max(0, radius - distance) : 1.0
                    let h = (atan2(dy, dx) + Double.pi) / (2 * Double.pi)
                    let s = distance / radius
                    let (r, g, b) = hsbToRGB(h: h, s: s, b: brightness)
                    pixels[offset]     = UInt8(Double(r) * alpha)
                    pixels[offset + 1] = UInt8(Double(g) * alpha)
                    pixels[offset + 2] = UInt8(Double(b) * alpha)
                    pixels[offset + 3] = UInt8(alpha * 255)
                }
            }
        }

        let provider = CGDataProvider(data: Data(bytes: pixels, count: pixels.count) as CFData)!
        wheelImage = CGImage(
            width: size, height: size,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

// MARK: - Brightness Strip

/// Vertical brightness slider — black at bottom, current hue/sat color at top
private struct BrightnessStrip: View {
    let hue: Double
    let saturation: Double
    @Binding var brightness: Double
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: saturation, brightness: 1.0),
                        Color.black
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .cornerRadius(4)

                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: brightness))
                    .frame(width: geo.size.width - 4, height: geo.size.width - 4)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                    .offset(y: CGFloat(1 - brightness) * (geo.size.height - geo.size.width + 4) + 2)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        brightness = max(0, min(1, 1.0 - Double(drag.location.y / geo.size.height)))
                    }
            )
        }
        .frame(width: 24, height: height)
        .accessibilityElement()
        .accessibilityLabel("Color brightness")
        .accessibilityValue("\(Int(brightness * 100)) percent")
        .accessibilityHint("Use up and down arrows to adjust brightness, or drag the strip")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.05 : -0.05
            brightness = max(0, min(1, brightness + delta))
        }
        .focusable()
        .onKeyPress(.upArrow) { brightness = min(1, brightness + 0.05); return .handled }
        .onKeyPress(.downArrow) { brightness = max(0, brightness - 0.05); return .handled }
    }
}

// MARK: - RGB Channel Slider

private struct ColorChannelSlider: View {
    let label: String
    @Binding var value: Int
    let gradientColors: [Color]
    var onChanged: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 10)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing)
                        .cornerRadius(3)

                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
                        .offset(x: CGFloat(value) / 255.0 * (geo.size.width - 14))
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let fraction = max(0, min(1, drag.location.x / geo.size.width))
                            value = Int(fraction * 255)
                            onChanged?()
                        }
                )
            }
            .frame(height: 14)

            Text("\(value)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel("\(channelName) channel")
        .accessibilityValue("\(value) out of 255")
        .accessibilityHint("Use left and right arrows to adjust the channel, or drag the slider")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 1 : -1
            value = max(0, min(255, value + delta))
            onChanged?()
        }
        .focusable()
        .onKeyPress(.leftArrow) { value = max(0, value - 1); onChanged?(); return .handled }
        .onKeyPress(.rightArrow) { value = min(255, value + 1); onChanged?(); return .handled }
    }

    private var channelName: String {
        switch label.uppercased() {
        case "R": return "Red"
        case "G": return "Green"
        case "B": return "Blue"
        default: return label
        }
    }
}

// MARK: - Quick Color Swatches

private let quickSwatchColors: [(name: String, hex: String)] = [
    ("Red", "E53935"), ("Orange", "FB8C00"), ("Yellow", "FDD835"), ("Green", "43A047"),
    ("Teal", "00897B"), ("Blue", "1E88E5"), ("Purple", "8E24AA"), ("Pink", "D81B60"),
    ("White", "FAFAFA"), ("Light Gray", "C0C0C0"), ("Medium Gray", "808080"), ("Dark Gray", "404040"),
    ("Black", "1A1A1A"), ("Beige", "D4C5A9"), ("Tan", "C4A882"), ("Brown", "6D4C41"),
]

// MARK: - Color Picker Popover

/// Popover for precision color search — color wheel with visual tolerance halo.
struct PrecisionColorSearchPopover: View {
    @Binding var colorSearch: ColorSearchRGB?
    var stagesSelection = false
    @Environment(\.dismiss) private var dismiss

    @AppStorage("recentColorSearches") private var recentColorsStorage: String = ""

    @State private var selectedColor: Color = .red
    @State private var hexInput: String = "E53935"
    @State private var tolerance: Double = 25
    @State private var isValidHex: Bool = true
    @State private var isUpdatingFromPicker: Bool = false
    @State private var usePerceptual: Bool = false
    @State private var deltaEThreshold: Double = 20

    @State private var hue: Double = 0
    @State private var saturation: Double = 1.0
    @State private var brightness: Double = 1.0
    @State private var previewR: Int = 229
    @State private var previewG: Int = 57
    @State private var previewB: Int = 53

    /// Tolerance mapped to fraction of wheel radius for halo display
    private var toleranceFraction: Double {
        // tolerance range 5-50 → halo fraction 0.04-0.30 of wheel diameter
        // Keeps it readable without overwhelming the wheel
        (tolerance - 5) / 45.0 * 0.26 + 0.04
    }

    private var recentColors: [String] {
        guard !recentColorsStorage.isEmpty else { return [] }
        return recentColorsStorage.split(separator: ",").map(String.init)
    }

    private func saveToRecentColors(_ hex: String) {
        let normalizedHex = hex.uppercased()
        var colors = recentColors.filter { $0.uppercased() != normalizedHex }
        colors.insert(normalizedHex, at: 0)
        recentColorsStorage = Array(colors.prefix(6)).joined(separator: ",")
    }

    var body: some View {
        VStack(spacing: 10) {
            // Header
            HStack {
                Text("Color Search")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close color search")
                .accessibilityHint("Dismisses without applying a new color search")
            }

            // Wheel + brightness strip
            HStack(spacing: 8) {
                ColorWheelView(
                    hue: $hue, saturation: $saturation,
                    brightness: brightness, diameter: 190,
                    toleranceFraction: toleranceFraction
                )
                .onChange(of: hue) { _, _ in syncColorFromHSB() }
                .onChange(of: saturation) { _, _ in syncColorFromHSB() }

                BrightnessStrip(hue: hue, saturation: saturation, brightness: $brightness, height: 190)
                    .onChange(of: brightness) { _, _ in syncColorFromHSB() }
            }

            // Swatches
            swatchGrid

            // Hex + eyedropper
            hexRow

            // RGB sliders
            VStack(spacing: 5) {
                ColorChannelSlider(
                    label: "R", value: $previewR,
                    gradientColors: [
                        Color(red: 0, green: Double(previewG)/255, blue: Double(previewB)/255),
                        Color(red: 1, green: Double(previewG)/255, blue: Double(previewB)/255)
                    ]
                ) { updateFromRGB() }
                ColorChannelSlider(
                    label: "G", value: $previewG,
                    gradientColors: [
                        Color(red: Double(previewR)/255, green: 0, blue: Double(previewB)/255),
                        Color(red: Double(previewR)/255, green: 1, blue: Double(previewB)/255)
                    ]
                ) { updateFromRGB() }
                ColorChannelSlider(
                    label: "B", value: $previewB,
                    gradientColors: [
                        Color(red: Double(previewR)/255, green: Double(previewG)/255, blue: 0),
                        Color(red: Double(previewR)/255, green: Double(previewG)/255, blue: 1)
                    ]
                ) { updateFromRGB() }
            }

            // Accuracy — controls the halo size on the wheel
            HStack(spacing: 6) {
                Text("Range")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Slider(value: $tolerance, in: 5...50)
                    .accessibilityLabel("Color match tolerance")
                    .accessibilityValue("Plus or minus \(Int(tolerance)) RGB levels")
                    .accessibilityHint("Adjusts how far from the selected color a result may be")

                Text("±\(Int(tolerance))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button("Clear") {
                    colorSearch = nil
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Remove the current color filter and close the picker")

                Spacer()

                Button(stagesSelection ? "Use Color" : "Search") {
                    saveToRecentColors(hexInput)
                    applySearch()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isValidHex)
                .accessibilityHint(stagesSelection
                    ? "Stage this color and tolerance; apply with Done in the Color filters"
                    : "Apply this color and tolerance to the library search")
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            if let existing = colorSearch {
                selectedColor = existing.color
                hexInput = String(format: "%02X%02X%02X", existing.r, existing.g, existing.b)
                tolerance = Double(existing.tolerance)
                usePerceptual = existing.usePerceptual
                deltaEThreshold = existing.deltaEThreshold
                previewR = existing.r
                previewG = existing.g
                previewB = existing.b
            }
            syncHSBFromColor()
        }
    }

    // MARK: - Subviews

    private var swatchGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
            ForEach(quickSwatchColors, id: \.hex) { swatch in
                Button { selectColor(hex: swatch.hex) } label: {
                    Circle()
                        .fill(Color(hex: swatch.hex))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle().strokeBorder(
                                hexInput.uppercased() == swatch.hex.uppercased() ? Color.white : Color.white.opacity(0.15),
                                lineWidth: hexInput.uppercased() == swatch.hex.uppercased() ? 2 : 0.5
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel("\(swatch.name) preset color")
                .accessibilityValue(hexInput.uppercased() == swatch.hex.uppercased() ? "Selected" : "Not selected")
                .accessibilityHint("Selects this color")
                .accessibilityAddTraits(hexInput.uppercased() == swatch.hex.uppercased() ? [.isSelected] : [])
            }
        }
    }

    private var hexRow: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(selectedColor)
                .frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                .accessibilityLabel("Current color")
                .accessibilityValue("Hex \(hexInput)")

            HStack(spacing: 2) {
                Text("#").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                TextField("RRGGBB", text: $hexInput)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 60)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: "2A2A2A")))
                    .accessibilityLabel("Hex color")
                    .accessibilityHint("Enter six hexadecimal digits, without the number sign")
                    .onChange(of: hexInput) { _, v in
                        guard !isUpdatingFromPicker else { return }
                        validateAndUpdateColor(v)
                    }
            }

            if !isValidHex {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption2)
                    .accessibilityLabel("Invalid hexadecimal color")
            }

            Spacer()

            eyedropperButton
        }
    }

    private var eyedropperButton: some View {
        Button {
            let sampler = NSColorSampler()
            sampler.show { nsColor in
                if let nsColor = nsColor {
                    isUpdatingFromPicker = true
                    let sampledColor = nsColor.usingColorSpace(.sRGB) ?? nsColor
                    let swiftUIColor = Color(nsColor: sampledColor)
                    selectedColor = swiftUIColor
                    updateHexFromColor(swiftUIColor)
                    syncHSBFromColor()
                    DispatchQueue.main.async { isUpdatingFromPicker = false }
                }
            }
        } label: {
            Image(systemName: "eyedropper")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: "2A2A2A")))
        }
        .buttonStyle(.plain)
        .help("Pick color from screen")
        .accessibilityLabel("Pick color from screen")
        .accessibilityHint("Opens the macOS color sampler")
    }

    // MARK: - Color Sync

    /// HSB wheel/strip changed → update selectedColor, hex, RGB preview
    private func syncColorFromHSB() {
        guard !isUpdatingFromPicker else { return }
        isUpdatingFromPicker = true
        let newColor = Color(hue: hue, saturation: saturation, brightness: brightness)
        selectedColor = newColor
        updateHexFromColor(newColor)
        DispatchQueue.main.async { isUpdatingFromPicker = false }
    }

    /// External color change (swatch, hex, eyedropper) → update HSB state
    private func syncHSBFromColor() {
        let hsb = selectedColor.hsbComponents
        hue = hsb.h
        saturation = hsb.s
        brightness = hsb.b
    }

    private func selectColor(hex: String) {
        isUpdatingFromPicker = true
        selectedColor = Color(hex: hex)
        hexInput = hex.uppercased()
        isValidHex = true
        if let hexValue = UInt32(hex.uppercased(), radix: 16) {
            previewR = Int((hexValue >> 16) & 0xFF)
            previewG = Int((hexValue >> 8) & 0xFF)
            previewB = Int(hexValue & 0xFF)
        }
        syncHSBFromColor()
        DispatchQueue.main.async { isUpdatingFromPicker = false }
    }

    private func updateHexFromColor(_ color: Color) {
        let components = color.rgbComponents
        previewR = max(0, min(255, Int((components.r * 255).rounded())))
        previewG = max(0, min(255, Int((components.g * 255).rounded())))
        previewB = max(0, min(255, Int((components.b * 255).rounded())))
        hexInput = String(format: "%02X%02X%02X", previewR, previewG, previewB)
        isValidHex = true
    }

    private func validateAndUpdateColor(_ hex: String) {
        var sanitized = hex.uppercased()
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: " ", with: "")
            .filter { $0.isHexDigit }

        if sanitized.count == 3 {
            let chars = Array(sanitized)
            sanitized = "\(chars[0])\(chars[0])\(chars[1])\(chars[1])\(chars[2])\(chars[2])"
        }

        guard sanitized.count == 6,
              let hexValue = UInt32(sanitized, radix: 16) else {
            isValidHex = sanitized.isEmpty || sanitized.count < 6
            return
        }

        isValidHex = true
        isUpdatingFromPicker = true
        let r = Double((hexValue >> 16) & 0xFF) / 255.0
        let g = Double((hexValue >> 8) & 0xFF) / 255.0
        let b = Double(hexValue & 0xFF) / 255.0
        selectedColor = Color(red: r, green: g, blue: b)
        previewR = Int((hexValue >> 16) & 0xFF)
        previewG = Int((hexValue >> 8) & 0xFF)
        previewB = Int(hexValue & 0xFF)
        syncHSBFromColor()
        DispatchQueue.main.async { isUpdatingFromPicker = false }
    }

    private func updateFromRGB() {
        isUpdatingFromPicker = true
        selectedColor = Color(red: Double(previewR) / 255.0, green: Double(previewG) / 255.0, blue: Double(previewB) / 255.0)
        hexInput = String(format: "%02X%02X%02X", previewR, previewG, previewB)
        isValidHex = true
        syncHSBFromColor()
        DispatchQueue.main.async { isUpdatingFromPicker = false }
    }

    private func applySearch() {
        var search = ColorSearchRGB(
            r: previewR, g: previewG, b: previewB,
            tolerance: Int(tolerance)
        )
        search.usePerceptual = usePerceptual
        search.deltaEThreshold = deltaEThreshold
        colorSearch = search
    }
}

// MARK: - Color Search Chip

struct ColorSearchChip: View {
    let colorSearch: ColorSearchRGB
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(colorSearch.color)
                .frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))

            Text(colorSearch.hex)
                .font(.system(.caption, design: .monospaced))

            if colorSearch.usePerceptual {
                Text("ΔE\(Int(colorSearch.deltaEThreshold))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("±\(colorSearch.tolerance)")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Button { onRemove() } label: {
                Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(colorSearch.color.opacity(0.15))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(colorSearch.color.opacity(0.4), lineWidth: 1))
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Color Extensions

extension Color {
    var rgbComponents: (r: Double, g: Double, b: Double) {
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) ?? nsColor.usingColorSpace(.deviceRGB) else {
            let cgColor = nsColor.cgColor
            if let components = cgColor.components, components.count >= 3 {
                return (r: components[0], g: components[1], b: components[2])
            }
            return (r: 0.5, g: 0.5, b: 0.5)
        }
        return (r: rgbColor.redComponent, g: rgbColor.greenComponent, b: rgbColor.blueComponent)
    }

    var hsbComponents: (h: Double, s: Double, b: Double) {
        let nsColor = NSColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if let calibrated = nsColor.usingColorSpace(.sRGB) ?? nsColor.usingColorSpace(.deviceRGB) {
            calibrated.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        } else {
            let rgb = rgbComponents
            let maxC = max(rgb.r, rgb.g, rgb.b)
            let minC = min(rgb.r, rgb.g, rgb.b)
            let delta = maxC - minC
            b = CGFloat(maxC)
            s = maxC > 0 ? CGFloat(delta / maxC) : 0
            if delta > 0 {
                if maxC == rgb.r {
                    h = CGFloat((rgb.g - rgb.b) / delta).truncatingRemainder(dividingBy: 6) / 6
                } else if maxC == rgb.g {
                    h = CGFloat((rgb.b - rgb.r) / delta + 2) / 6
                } else {
                    h = CGFloat((rgb.r - rgb.g) / delta + 4) / 6
                }
                if h < 0 { h += 1 }
            }
        }
        return (h: Double(h), s: Double(s), b: Double(b))
    }

    init(hex: String) {
        let sanitized = hex.uppercased().filter { $0.isHexDigit }
        guard sanitized.count == 6,
              let hexValue = UInt32(sanitized, radix: 16) else {
            self = .gray
            return
        }
        self = Color(
            red: Double((hexValue >> 16) & 0xFF) / 255.0,
            green: Double((hexValue >> 8) & 0xFF) / 255.0,
            blue: Double(hexValue & 0xFF) / 255.0
        )
    }
}

// MARK: - Preview

#if DEBUG
struct PrecisionColorSearchPopover_Previews: PreviewProvider {
    static var previews: some View {
        PrecisionColorSearchPopover(colorSearch: .constant(nil))
            .preferredColorScheme(.dark)
    }
}
#endif
