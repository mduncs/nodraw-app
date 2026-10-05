import SwiftUI

/// A picker for selecting how table rows should be grouped.
/// Generic over any RawRepresentable + CaseIterable enum.
public struct GroupByPicker<G: RawRepresentable & CaseIterable & Hashable>: View
    where G.RawValue == String, G.AllCases: RandomAccessCollection
{
    let label: String
    @Binding var selection: G

    public init(_ label: String = "Group by", selection: Binding<G>) {
        self.label = label
        self._selection = selection
    }

    public var body: some View {
        Menu {
            ForEach(Array(G.allCases), id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if selection == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 10))
                Text(selection.rawValue == "None" ? label : selection.rawValue)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 120)
    }
}
