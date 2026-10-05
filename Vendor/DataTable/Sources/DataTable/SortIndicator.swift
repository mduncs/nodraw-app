import SwiftUI

/// Sort direction indicator for column headers (when using custom headers).
/// SwiftUI's native Table already shows sort indicators, but this is useful
/// for custom table implementations.
public struct SortIndicator: View {
    public enum Direction {
        case ascending, descending, none
    }

    let direction: Direction

    public init(_ direction: Direction) {
        self.direction = direction
    }

    public var body: some View {
        switch direction {
        case .ascending:
            Image(systemName: "chevron.up")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        case .descending:
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }
}
