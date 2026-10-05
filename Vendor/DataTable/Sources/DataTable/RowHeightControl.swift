import SwiftUI

/// Compact slider for adjusting table row height.
public struct RowHeightControl: View {
    @Binding var multiplier: CGFloat
    let range: ClosedRange<CGFloat>

    public init(multiplier: Binding<CGFloat>, range: ClosedRange<CGFloat> = 0.75...2.5) {
        self._multiplier = multiplier
        self.range = range
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Slider(value: $multiplier, in: range, step: 0.25)
                .frame(width: 60)

            Image(systemName: "text.line.last.and.arrowtriangle.forward")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .help("Row height: \(String(format: "%.0f%%", multiplier * 100))")
    }
}
