import SwiftUI

enum FocusInspectorTab: String, CaseIterable {
    case info = "Info"
    case related = "Related"

    func available(showInfo: Bool, showRelated: Bool) -> Self {
        if self == .info && !showInfo { return .related }
        if self == .related && !showRelated { return .info }
        return self
    }
}

/// The detail inspector shares one right-hand column between metadata and related items.
struct FocusInspectorColumn<Info: View, Related: View>: View {
    let showInfo: Bool
    let showRelated: Bool
    @Binding var selection: FocusInspectorTab
    @ViewBuilder let info: () -> Info
    @ViewBuilder let related: () -> Related

    var body: some View {
        VStack(spacing: 0) {
            if showInfo && showRelated {
                Picker("Inspector", selection: $selection) {
                    ForEach(FocusInspectorTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                .accessibilityIdentifier("focus-inspector-tabs")
                Divider()
            }
            if selection.available(showInfo: showInfo, showRelated: showRelated) == .related {
                related()
            } else {
                info()
            }
        }
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 360)
        .background(Color(hex: 0x1f1f1f))
    }
}
