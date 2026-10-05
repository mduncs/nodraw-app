import Foundation

/// Feature visibility flags for release gating.
/// Set to `true` to show the feature in the UI; `false` hides it.
/// Code and data are preserved — only UI entry points are gated.
enum FeatureFlags {
    static let rediscover = false
    static let canvas = false
    static let boards = false
    static let deduplicate = true
    static let annotate = true
    /// Table browser: code and tests kept, entry points hidden (2026-09-28).
    static let tableBrowser = false
}
