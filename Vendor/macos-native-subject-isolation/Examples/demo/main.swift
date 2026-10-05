import Foundation
import SubjectIsolation
import CoreGraphics
import ImageIO

// MARK: - Demo CLI

/// Usage: Demo <image-path> [output-path]
/// Runs subject isolation on an image and saves the cutout.
@main
struct DemoApp {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: Demo <image-path> [output-path]")
            print("  Runs subject isolation on an image.")
            print("  If output-path is given, saves the cutout PNG there.")
            return
        }

        let inputPath = args[1]
        let outputPath = args.count >= 3 ? args[2] : nil

        guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            print("Error: Could not load image at \(inputPath)")
            return
        }

        print("Image: \(cgImage.width)x\(cgImage.height)")
        print("Available: \(SubjectIsolator.isAvailable)")

        let isolator = SubjectIsolator()
        print("Available types: \(isolator.availableTypes)")
        print("Compound request: \(isolator.hasCompoundRequest)")

        do {
            // Full isolation
            let result = try await isolator.isolate(image: cgImage, options: .default)
            print("\nSubjects detected: \(result.subjectCount)")

            for subject in result.subjects {
                print("  Subject \(subject.index):")
                print("    Bounding box: \(subject.boundingBox)")
                print("    Has contour path: \(subject.contourPath != nil)")
                print("    Has outer path: \(subject.outerContourPath != nil)")
            }

            // Save cutout if requested
            if let outputPath, result.hasSubjects {
                let cutout = try await isolator.removeBackground(image: cgImage)
                if savePNG(cutout, to: outputPath) {
                    print("\nCutout saved to: \(outputPath)")
                } else {
                    print("\nError: Could not save cutout")
                }
            }

            // Person segmentation at all quality levels
            print("\nPerson segmentation:")
            for quality in [SegmentationQuality.fast, .balanced, .accurate] {
                let personResult = try await isolator.segmentPersons(image: cgImage, quality: quality)
                print("  \(quality): person=\(personResult.personDetected), mask=\(personResult.mask != nil)")
            }

            // Semantic masks if available
            let semanticOpts = IsolationOptions(
                requestedTypes: isolator.availableTypes,
                generatePaths: false
            )
            let semanticResult = try await isolator.isolate(image: cgImage, options: semanticOpts)
            if !semanticResult.semanticMasks.isEmpty {
                print("\nSemantic masks:")
                for (type, mask) in semanticResult.semanticMasks {
                    print("  \(type): \(mask.width)x\(mask.height)")
                }
            }

        } catch {
            print("Error: \(error)")
        }
    }
}

func savePNG(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}
