import SwiftUI

struct PlaybackSettingsTab: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSection(
                    title: "Video Playback",
                    icon: "play.rectangle",
                    description: "Control how videos behave in grid and focus views."
                ) {
                    SettingsToggle(
                        "Autoplay in focus view",
                        description: "Start playback automatically when a video is opened.",
                        isOn: Binding(
                            get: { settings.videoAutoplay },
                            set: { settings.videoAutoplay = $0 }
                        )
                    )

                    SettingsToggle(
                        "Mute by default",
                        description: "Open videos with audio muted.",
                        isOn: Binding(
                            get: { settings.videoMuteByDefault },
                            set: { settings.videoMuteByDefault = $0 }
                        )
                    )

                    SettingsToggle(
                        "Hover preview in grid",
                        description: "Play short previews while hovering video thumbnails.",
                        isOn: Binding(
                            get: { settings.videoHoverPreview },
                            set: { settings.videoHoverPreview = $0 }
                        )
                    )

                    SettingsToggle(
                        "Loop videos",
                        description: "Automatically restart when playback reaches the end.",
                        isOn: Binding(
                            get: { settings.videoLoopEnabled },
                            set: { settings.videoLoopEnabled = $0 }
                        )
                    )
                }
                // Focus View sidebar toggle removed - now uses NavigationSplitView sidebar
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
