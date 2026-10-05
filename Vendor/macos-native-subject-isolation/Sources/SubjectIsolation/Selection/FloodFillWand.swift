import CoreGraphics

/// Result of a flood fill operation — a binary mask buffer.
public struct FloodFillResult: @unchecked Sendable {
    /// Raw mask data: 0x00 = unselected, 0xFF = selected.
    public let data: [UInt8]
    public let width: Int
    public let height: Int

    /// Convert mask buffer to a CGImage (grayscale, 8-bit).
    public func toCGImage() -> CGImage? {
        var pixels = data
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
}

/// Queue-based scanline flood fill for magic wand selection.
///
/// Algorithm from Ghidra RE of Preview.app's TRWand (§14):
/// 1. Seed point sets reference color
/// 2. Color distance: `sqrt(dR² + dG² + dB² + dA²) / maxDistance` normalized to [0,1]
/// 3. Queue-based scanline fill — if distance ≤ tolerance → selected
/// 4. Tolerance controlled by drag distance: `clamp(hypot(dx,dy) / 200, 0, 1)`
public struct FloodFillWand {
    private let pixels: [UInt8]  // RGBA interleaved
    private let width: Int
    private let height: Int
    private let seedX: Int
    private let seedY: Int
    private let seedR: UInt8
    private let seedG: UInt8
    private let seedB: UInt8
    private let seedA: UInt8

    // Max possible distance in RGBA space: sqrt(255² * 4)
    private static let maxDistance: Double = sqrt(Double(255 * 255) * 4.0)

    /// Initialize with RGBA pixel data and seed point.
    ///
    /// - Parameters:
    ///   - rgba: Raw RGBA pixel data (4 bytes per pixel, row-major, top-left origin).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - seedX: Seed X coordinate (pixel space).
    ///   - seedY: Seed Y coordinate (pixel space).
    public init?(rgba: [UInt8], width: Int, height: Int, seedX: Int, seedY: Int) {
        guard rgba.count == width * height * 4 else { return nil }
        guard seedX >= 0, seedX < width, seedY >= 0, seedY < height else { return nil }

        self.pixels = rgba
        self.width = width
        self.height = height
        self.seedX = seedX
        self.seedY = seedY

        let seedOffset = (seedY * width + seedX) * 4
        self.seedR = rgba[seedOffset]
        self.seedG = rgba[seedOffset + 1]
        self.seedB = rgba[seedOffset + 2]
        self.seedA = rgba[seedOffset + 3]
    }

    /// Compute the selection mask at the given tolerance.
    ///
    /// - Parameter tolerance: Selection threshold in [0, 1]. 0 = exact match only, 1 = select everything.
    /// - Returns: Binary mask where 0xFF = selected, 0x00 = not selected.
    public func computeMask(tolerance: CGFloat) -> FloodFillResult {
        let tol = max(0, min(1, Double(tolerance)))
        var mask = [UInt8](repeating: 0, count: width * height)
        var visited = [Bool](repeating: false, count: width * height)

        // Queue-based scanline flood fill
        var queue: [(Int, Int)] = [(seedX, seedY)]
        var queueIndex = 0
        let seedIdx = seedY * width + seedX
        visited[seedIdx] = true
        mask[seedIdx] = 0xFF

        while queueIndex < queue.count {
            let (cx, cy) = queue[queueIndex]
            queueIndex += 1

            // Scan left
            var left = cx
            while left > 0 {
                let nextIdx = cy * width + (left - 1)
                if visited[nextIdx] { break }
                if colorDistance(at: nextIdx) > tol { break }
                left -= 1
            }

            // Scan right
            var right = cx
            while right < width - 1 {
                let nextIdx = cy * width + (right + 1)
                if visited[nextIdx] { break }
                if colorDistance(at: nextIdx) > tol { break }
                right += 1
            }

            // Fill the scanline and check rows above/below
            for x in left...right {
                let idx = cy * width + x
                if !visited[idx] && colorDistance(at: idx) <= tol {
                    visited[idx] = true
                    mask[idx] = 0xFF
                }

                // Check row above
                if cy > 0 {
                    let aboveIdx = (cy - 1) * width + x
                    if !visited[aboveIdx] && colorDistance(at: aboveIdx) <= tol {
                        visited[aboveIdx] = true
                        mask[aboveIdx] = 0xFF
                        queue.append((x, cy - 1))
                    }
                }

                // Check row below
                if cy < height - 1 {
                    let belowIdx = (cy + 1) * width + x
                    if !visited[belowIdx] && colorDistance(at: belowIdx) <= tol {
                        visited[belowIdx] = true
                        mask[belowIdx] = 0xFF
                        queue.append((x, cy + 1))
                    }
                }
            }
        }

        return FloodFillResult(data: mask, width: width, height: height)
    }

    // MARK: - Private

    /// Euclidean color distance normalized to [0, 1].
    private func colorDistance(at pixelIndex: Int) -> Double {
        let offset = pixelIndex * 4
        let dR = Double(pixels[offset]) - Double(seedR)
        let dG = Double(pixels[offset + 1]) - Double(seedG)
        let dB = Double(pixels[offset + 2]) - Double(seedB)
        let dA = Double(pixels[offset + 3]) - Double(seedA)
        return sqrt(dR * dR + dG * dG + dB * dB + dA * dA) / Self.maxDistance
    }
}

// MARK: - RGBA Extraction

extension FloodFillWand {
    /// Extract RGBA pixel data from a CGImage.
    ///
    /// - Parameter image: Source image.
    /// - Returns: Tuple of (rgba bytes, width, height), or nil on failure.
    public static func extractRGBA(from image: CGImage) -> (rgba: [UInt8], width: Int, height: Int)? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }
}
