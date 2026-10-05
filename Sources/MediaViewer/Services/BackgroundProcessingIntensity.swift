import Foundation

enum BackgroundProcessingIntensity: String, CaseIterable, Sendable {
    case reduced
    case balanced
    case fullSpeed

    static let defaultsKey = "backgroundProcessingIntensity"
    static let defaultValue: Self = .reduced

    static var current: Self {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultValue.rawValue
        return Self(rawValue: rawValue) ?? defaultValue
    }

    var label: String {
        switch self {
        case .reduced:
            return "Reduced"
        case .balanced:
            return "Balanced"
        case .fullSpeed:
            return "Full Speed"
        }
    }

    var description: String {
        switch self {
        case .reduced:
            return "Lowest CPU pressure. Best for keeping browsing smooth during big backlogs."
        case .balanced:
            return "Moderate background work. A middle ground between throughput and responsiveness."
        case .fullSpeed:
            return "Highest throughput. Uses more CPU and can compete with browsing and scrolling."
        }
    }

    var visionNormalConcurrency: Int {
        switch self {
        case .reduced:
            return 1
        case .balanced:
            return 2
        case .fullSpeed:
            return 4
        }
    }

    var visionWarningConcurrency: Int {
        switch self {
        case .reduced, .balanced:
            return 1
        case .fullSpeed:
            return 2
        }
    }

    var visionCriticalConcurrency: Int { 1 }

    var visionInterJobDelay: Duration {
        switch self {
        case .reduced:
            return .milliseconds(250)
        case .balanced:
            return .milliseconds(100)
        case .fullSpeed:
            return .zero
        }
    }

    var pipelineNormalConcurrency: Int {
        switch self {
        case .reduced, .balanced:
            return 1
        case .fullSpeed:
            return 2
        }
    }

    var pipelineInterJobDelay: Duration {
        switch self {
        case .reduced:
            return .milliseconds(500)
        case .balanced:
            return .milliseconds(200)
        case .fullSpeed:
            return .zero
        }
    }

    var taskPriority: TaskPriority {
        switch self {
        case .reduced, .balanced:
            return .background
        case .fullSpeed:
            return .utility
        }
    }
}
