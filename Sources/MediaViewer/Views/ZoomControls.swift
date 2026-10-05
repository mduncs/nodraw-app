import SwiftUI

// MARK: - ZoomControlsOverlay

/// Semi-transparent zoom controls that appear on hover.
/// Shows +/- buttons, current zoom percentage, fit button, and 1:1 actual size button.
struct ZoomControlsOverlay: View {
    @Binding var zoomScale: CGFloat
    @Binding var isVisible: Bool
    /// Actual size scale factor (image pixels / display points) - when set, enables 1:1 button
    var actualSizeScale: CGFloat? = nil

    private let minZoom: CGFloat = 0.5
    private let maxZoom: CGFloat = 4.0
    private let zoomStep: CGFloat = 0.25

    private var zoomPercentage: Int {
        Int(round(zoomScale * 100))
    }

    private var isAtActualSize: Bool {
        guard let actual = actualSizeScale else { return false }
        return abs(zoomScale - actual) < 0.01
    }

    var body: some View {
        HStack(spacing: 0) {
            // Minus button
            Button(action: zoomOut) {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ZoomButtonStyle())
            .disabled(zoomScale <= minZoom)
            .help("Zoom out")

            Divider()
                .frame(height: 16)
                .background(Color.white.opacity(0.2))

            // Zoom percentage
            Text("\(zoomPercentage)%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 44, alignment: .center)

            Divider()
                .frame(height: 16)
                .background(Color.white.opacity(0.2))

            // Plus button
            Button(action: zoomIn) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ZoomButtonStyle())
            .disabled(zoomScale >= maxZoom)
            .help("Zoom in")

            Divider()
                .frame(height: 16)
                .background(Color.white.opacity(0.2))

            // Fit to view button
            Button(action: fitToView) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ZoomButtonStyle())
            .disabled(zoomScale == 1.0)
            .help("Fit to view")

            // 1:1 Actual size button (only shown when actualSizeScale is provided)
            if let actual = actualSizeScale {
                Divider()
                    .frame(height: 16)
                    .background(Color.white.opacity(0.2))

                Button(action: { zoomToActualSize(actual) }) {
                    Text("1:1")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(ZoomButtonStyle())
                .disabled(isAtActualSize)
                .help("Actual size (1:1 pixels)")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.7))
        )
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .onHover { hovering in
            // Keep controls visible while hovering over them
            if hovering {
                isVisible = true
            }
        }
    }

    private func zoomIn() {
        withAnimation(.easeInOut(duration: 0.15)) {
            zoomScale = min(maxZoom, zoomScale + zoomStep)
        }
    }

    private func zoomOut() {
        withAnimation(.easeInOut(duration: 0.15)) {
            zoomScale = max(minZoom, zoomScale - zoomStep)
        }
    }

    private func fitToView() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = 1.0
        }
    }

    private func zoomToActualSize(_ scale: CGFloat) {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = min(maxZoom, max(minZoom, scale))
        }
    }
}

// MARK: - ZoomButtonStyle

/// Button style for zoom controls
struct ZoomButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isEnabled ? .white.opacity(configuration.isPressed ? 0.6 : 0.9) : .white.opacity(0.3))
            .contentShape(Rectangle())
    }
}
