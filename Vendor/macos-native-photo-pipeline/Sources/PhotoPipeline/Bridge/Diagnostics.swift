import Foundation

/// Comprehensive diagnostics for framework and model availability.
///
/// Use this before attempting any pipeline operations to verify
/// the current system can support the requested features.
///
/// ```swift
/// let report = Diagnostics.systemReport()
/// print(report)
/// ```
public enum Diagnostics {

    /// Full system compatibility report.
    public struct SystemReport: CustomStringConvertible {
        public let macOSVersion: String
        public let architecture: String
        public let sipEnabled: Bool?
        public let frameworkStatus: [FrameworkLoader.Framework: FrameworkStatus]
        public let modelAvailability: [String: Bool]
        public let issues: [String]

        public var isFullyCompatible: Bool { issues.isEmpty }

        public var description: String {
            var lines: [String] = []
            lines.append("PhotoPipeline System Report")
            lines.append("  macOS: \(macOSVersion)")
            lines.append("  arch:  \(architecture)")
            if let sip = sipEnabled {
                lines.append("  SIP:   \(sip ? "enabled" : "disabled")")
            }
            lines.append("")
            lines.append("Frameworks:")
            for fw in FrameworkLoader.Framework.allCases {
                let status = frameworkStatus[fw] ?? .missing
                lines.append("  \(fw.rawValue): \(status)")
            }
            lines.append("")
            lines.append("Models:")
            for (model, ok) in modelAvailability.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(model): \(ok ? "found" : "MISSING")")
            }
            if !issues.isEmpty {
                lines.append("")
                lines.append("Issues:")
                for issue in issues {
                    lines.append("  - \(issue)")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Generate a full system report.
    public static func systemReport() -> SystemReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionStr = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif

        let fwStatus = FrameworkLoader.availability()
        let models = checkModelAvailability()

        var issues: [String] = []

        // Check macOS version
        if version.majorVersion < 14 {
            issues.append("macOS 14+ required (running \(versionStr))")
        }

        // Check architecture
        #if arch(x86_64)
        issues.append("Apple Silicon recommended — Intel may lack ANE acceleration")
        #endif

        // Check critical frameworks
        let critical: [FrameworkLoader.Framework] = [.mediaAnalysis, .espresso, .visionCore]
        for fw in critical {
            if fwStatus[fw]?.isAvailable != true {
                issues.append("Critical framework missing: \(fw.rawValue)")
            }
        }

        // Check critical models
        let criticalModels = ["MonzaV4_1.mlmodelc", "mubb_md7.mlmodelc"]
        for model in criticalModels {
            if models[model] != true {
                issues.append("Critical model missing: \(model)")
            }
        }

        return SystemReport(
            macOSVersion: versionStr,
            architecture: arch,
            sipEnabled: nil, // Can't reliably detect from userspace
            frameworkStatus: fwStatus,
            modelAvailability: models,
            issues: issues
        )
    }

    /// Check if specific framework classes exist.
    public static func classExists(_ name: String) -> Bool {
        NSClassFromString(name) != nil
    }

    /// Check availability of on-disk ML models.
    public static func checkModelAvailability() -> [String: Bool] {
        let fm = FileManager.default
        var results: [String: Bool] = [:]

        // MediaAnalysis models
        let maResources = FrameworkLoader.Framework.mediaAnalysis.resourcesPath
        let maModels = [
            "MonzaV4_1.mlmodelc",
            "mubb_md7.mlmodelc",
            "cnn_blur.espresso.net",
            "cnn_saliency.espresso.net",
            "cnn_human_pose.espresso.net",
            "feature_extraction.espresso.net",
            "video_backbone.espresso.net",
            "text_safety_md3-7.espresso.net",
        ]
        for model in maModels {
            results[model] = fm.fileExists(atPath: "\(maResources)/\(model)")
        }

        // Text embedding models
        let textModels = [
            "md4_text_model.bundle",
            "md5_text_model.bundle",
            "text_threshold_md7_v1.espresso.net",
            "text_calibration_md3.espresso.net",
        ]
        for model in textModels {
            results[model] = fm.fileExists(atPath: "\(maResources)/\(model)")
        }

        // Vision framework models
        let visionResources = "/System/Library/Frameworks/Vision.framework/Versions/A/Resources"
        let visionModels = [
            "facerec_fa1.3_lightweight_fp16.espresso.net",
            "personsegmentation-si-01.espresso.net",
        ]
        for model in visionModels {
            results[model] = fm.fileExists(atPath: "\(visionResources)/\(model)")
        }

        // VisualLookUp models
        let vlResources = FrameworkLoader.Framework.visualLookup.resourcesPath
        results["VisualLookUp resources"] = fm.fileExists(atPath: vlResources)

        return results
    }

    /// Quick check — is this system capable of running the pipeline?
    public static func isCompatible() -> Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 14 else { return false }

        // Check the most critical framework
        let path = FrameworkLoader.Framework.mediaAnalysis.path
        if let handle = dlopen(path, RTLD_LAZY) {
            dlclose(handle)
            return true
        }
        return false
    }
}
