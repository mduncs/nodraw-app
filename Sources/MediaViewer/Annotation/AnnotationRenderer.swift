import Foundation
import AppKit
import CoreText
import CoreImage
import ImageIO

// MARK: - AnnotationRenderer

/// Unified rendering path for all annotation shape types.
/// Supports CGContext rendering (export/copy) with full layer compositing.
/// Handles masks, extracted subjects, and all standard shape types.
struct AnnotationRenderer {
    private static let imageContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - Render Full Annotation Set

    /// Render annotations onto a source image.
    /// Pre-loads extracted subject assets before rendering.
    /// - Parameters:
    ///   - annotations: The annotation set to render
    ///   - sourceImage: The base image to annotate
    ///   - assetStore: Store for loading extracted subject images
    /// - Returns: Composited image with all annotations applied, or nil on failure
    static func render(
        annotations: AnnotationSet,
        onto sourceImage: CGImage,
        assetStore: AnnotationAssetStore? = nil,
        maximumDimension: CGFloat? = nil,
        applyCrop: Bool = true,
        coordinateSize: CGSize? = nil
    ) async -> NSImage? {
        let sourceSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        // A preview buffer may already be downsampled; annotations still use original
        // image pixels for fonts, strokes and feathering. Raster limits use actual input.
        let imageSize = coordinateSize ?? sourceSize
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = maximumDimension.map { min(1, max(1, $0) / max(sourceSize.width, sourceSize.height)) } ?? 1
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))

        // Pre-load all extracted subject assets
        var subjectImages: [String: NSImage] = [:]
        var maskImages: [UUID: CGImage] = [:]
        for layer in annotations.layers where layer.isVisible {
            for shape in layer.shapes {
                guard !Task.isCancelled else { return nil }
                if case .extractedSubject(_, let assetKey, _, _, _, _) = shape {
                    // A missing layer is a failed render, never a successful partial export.
                    let store = assetStore ?? .shared
                    guard let image = await store.loadImage(assetKey) else { return nil }
                    subjectImages[assetKey] = image
                }
                if case .mask(let id, let data, _, _, _, _) = shape {
                    // Never report a successful export with a silently omitted corrupt mask.
                    guard let image = decodeMask(data) else { return nil }
                    maskImages[id] = image
                }
            }
        }

        // Create bitmap context
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: outputColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.scaleBy(x: CGFloat(width) / imageSize.width, y: CGFloat(height) / imageSize.height)
        context.interpolationQuality = .high

        // Apply photo adjustments to source image if present
        let adjustedSource: CGImage
        if let adjustments = annotations.adjustments, adjustments.isModified {
            adjustedSource = applyPhotoAdjustments(to: sourceImage, adjustments: adjustments,
                                                   outputSize: CGSize(width: width, height: height),
                                                   coordinateSize: imageSize) ?? sourceImage
        } else {
            adjustedSource = sourceImage
        }

        // Draw source image (with adjustments applied)
        context.draw(adjustedSource, in: CGRect(origin: .zero, size: imageSize))

        // Ordinary layer content is isolated for group opacity/blending. Destructive
        // mask shapes operate on the accumulated canvas, never an empty layer bitmap.
        // Split ordinary runs around masks to preserve the document's shape order.
        for layer in annotations.layers where layer.isVisible && layer.opacity > 0 {
            guard !Task.isCancelled else { return nil }
            func renderRun(_ shapes: [AnnotationShape]) -> Bool {
                guard !shapes.isEmpty else { return true }
                if layer.opacity == 1 && layer.blendMode == .normal {
                    for shape in shapes {
                        renderShape(shape, context: context, imageSize: imageSize, subjectImages: subjectImages, maskImages: maskImages)
                    }
                    return true
                }
                guard let layerContext = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: outputColorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                layerContext.scaleBy(x: CGFloat(width) / imageSize.width, y: CGFloat(height) / imageSize.height)
                layerContext.interpolationQuality = .high
                for shape in shapes {
                    renderShape(shape, context: layerContext, imageSize: imageSize, subjectImages: subjectImages, maskImages: maskImages)
                }
                guard let layerImage = layerContext.makeImage() else { return false }
                context.saveGState()
                context.setAlpha(layer.opacity)
                context.setBlendMode(cgBlendMode(from: layer.blendMode))
                context.draw(layerImage, in: CGRect(origin: .zero, size: imageSize))
                context.restoreGState()
                return true
            }
            var run: [AnnotationShape] = []
            for shape in layer.shapes {
                if case .mask(let id, let data, let bounds, let mode, let opacity, let feather) = shape,
                   mode == .maskRemove || mode == .maskKeep || mode == .maskRestore {
                    guard renderRun(run) else { return nil }
                    run.removeAll(keepingCapacity: true)
                    renderMask(maskData: data, bounds: bounds, blendMode: mode,
                               opacity: opacity * layer.opacity, featherRadius: feather,
                               context: context, imageSize: imageSize, sourceImage: adjustedSource,
                               decodedMask: maskImages[id])
                } else {
                    run.append(shape)
                }
            }
            guard renderRun(run) else { return nil }
        }

        // Stored annotations and CGImage cropping both use a top-left origin.
        // Only CGContext drawing coordinates need the Y conversion used in renderShape.
        if applyCrop, let crop = annotations.cropRegion {
            let cropRect = crop.scaled(to: CGSize(width: width, height: height)).integral
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !cropRect.isEmpty, let full = context.makeImage(),
                  let cropped = full.cropping(to: cropRect) else { return nil }
            return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        }

        guard let resultCG = context.makeImage() else { return nil }
        return NSImage(cgImage: resultCG, size: NSSize(width: width, height: height))
    }

    // MARK: - Individual Shape Rendering

    /// Render a single shape to a CGContext.
    static func renderShape(
        _ shape: AnnotationShape,
        context: CGContext,
        imageSize: CGSize,
        subjectImages: [String: NSImage] = [:],
        maskImages: [UUID: CGImage] = [:]
    ) {
        let width = imageSize.width
        let height = imageSize.height

        switch shape {
        case .rectangle(_, let rect, let style):
            let pixelRect = CGRect(
                x: rect.x * width,
                y: (1 - rect.y - rect.height) * height,
                width: rect.width * width,
                height: rect.height * height
            )
            context.setStrokeColor(cgColor(from: style.strokeColor))
            context.setLineWidth(style.strokeWidth)
            if let fillColor = style.fillColor {
                context.setFillColor(cgColor(from: fillColor))
                context.fill(pixelRect)
            }
            context.stroke(pixelRect)

        case .ellipse(_, let rect, let style):
            let pixelRect = CGRect(
                x: rect.x * width,
                y: (1 - rect.y - rect.height) * height,
                width: rect.width * width,
                height: rect.height * height
            )
            context.setStrokeColor(cgColor(from: style.strokeColor))
            context.setLineWidth(style.strokeWidth)
            if let fillColor = style.fillColor {
                context.setFillColor(cgColor(from: fillColor))
                context.fillEllipse(in: pixelRect)
            }
            context.strokeEllipse(in: pixelRect)

        case .arrow(_, let start, let end, let style):
            let startPoint = CGPoint(x: start.x * width, y: (1 - start.y) * height)
            let endPoint = CGPoint(x: end.x * width, y: (1 - end.y) * height)

            context.setStrokeColor(cgColor(from: style.strokeColor))
            context.setLineWidth(style.strokeWidth)
            context.setLineCap(.round)

            context.move(to: startPoint)
            context.addLine(to: endPoint)
            context.strokePath()

            // Arrow head
            let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
            let headLength: CGFloat = style.strokeWidth * 3
            let headAngle: CGFloat = .pi / 6

            let head1 = CGPoint(
                x: endPoint.x - headLength * cos(angle - headAngle),
                y: endPoint.y - headLength * sin(angle - headAngle)
            )
            let head2 = CGPoint(
                x: endPoint.x - headLength * cos(angle + headAngle),
                y: endPoint.y - headLength * sin(angle + headAngle)
            )

            context.move(to: endPoint)
            context.addLine(to: head1)
            context.move(to: endPoint)
            context.addLine(to: head2)
            context.strokePath()

        case .freeform(_, let points, let style):
            guard points.count >= 2 else { return }

            context.setStrokeColor(cgColor(from: style.strokeColor))
            context.setLineWidth(style.strokeWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            let firstPoint = CGPoint(x: points[0].x * width, y: (1 - points[0].y) * height)
            context.move(to: firstPoint)

            for point in points.dropFirst() {
                let cgPoint = CGPoint(x: point.x * width, y: (1 - point.y) * height)
                context.addLine(to: cgPoint)
            }
            context.strokePath()

        case .text(_, let position, let content, let style):
            // `position` is the top-left of the text box, matching selection bounds, hit testing
            // and the editor's text entry. CoreGraphics draws baselines upward from the bottom.
            let layout = textLayout(content: content, style: style)
            let left = position.x * width
            let top = position.y * height

            var attributes: [NSAttributedString.Key: Any] = [
                .font: layout.font,
                .foregroundColor: NSColor(cgColor: cgColor(from: style.textColor)) ?? .white
            ]

            // Add stroke if specified
            if let strokeColorValue = style.strokeColor, style.strokeWidth > 0 {
                attributes[.strokeColor] = NSColor(cgColor: cgColor(from: strokeColorValue)) ?? .black
                // Negative stroke width means fill + stroke
                attributes[.strokeWidth] = -style.strokeWidth
            }

            // Draw background
            if let bgColorValue = style.backgroundColor {
                let bgColor = NSColor(cgColor: cgColor(from: bgColorValue)) ?? .clear
                let padding = textBackgroundPadding(for: style)
                let bgRect = CGRect(
                    x: left - padding,
                    y: height - top - layout.size.height - padding,
                    width: layout.size.width + padding * 2,
                    height: layout.size.height + padding * 2
                )
                context.saveGState()
                context.setFillColor(bgColor.cgColor)
                let radius = min(padding, bgRect.height / 2)
                let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                context.addPath(bgPath)
                context.fillPath()
                context.restoreGState()
            }

            // Draw shadow if specified
            if let shadowColorValue = style.shadowColor, style.shadowRadius > 0 {
                context.saveGState()
                context.setShadow(
                    offset: CGSize(width: style.shadowOffset, height: -style.shadowOffset),
                    blur: style.shadowRadius,
                    color: cgColor(from: shadowColorValue)
                )
            }

            for (index, text) in layout.lines.enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let inset: CGFloat
                switch style.alignment {
                case .left: inset = 0
                case .center: inset = (layout.size.width - lineWidth) / 2
                case .right: inset = layout.size.width - lineWidth
                }
                let baseline = top + layout.ascent + CGFloat(index) * layout.lineHeight
                context.textPosition = CGPoint(x: left + inset, y: height - baseline)
                CTLineDraw(line, context)
            }

            if style.shadowColor != nil && style.shadowRadius > 0 {
                context.restoreGState()
            }

        case .mask(let id, let maskData, let bounds, let blendMode, let opacity, let featherRadius):
            renderMask(
                maskData: maskData,
                bounds: bounds,
                blendMode: blendMode,
                opacity: opacity,
                featherRadius: featherRadius,
                context: context,
                imageSize: imageSize,
                decodedMask: maskImages[id]
            )

        case .extractedSubject(_, let assetKey, let bounds, let opacity, let transform, _):
            renderExtractedSubject(
                assetKey: assetKey,
                bounds: bounds,
                opacity: opacity,
                transform: transform,
                context: context,
                imageSize: imageSize,
                subjectImages: subjectImages
            )
        }
    }

    // MARK: - Text Layout

    struct TextLayout {
        let font: NSFont
        let lines: [String]
        let ascent: CGFloat
        let lineHeight: CGFloat
        let size: CGSize
    }

    static func textFont(for style: TextStyle) -> NSFont {
        let weight: NSFont.Weight
        switch style.fontWeight {
        case .light: weight = .light
        case .regular: weight = .regular
        case .medium: weight = .medium
        case .semibold: weight = .semibold
        case .bold: weight = .bold
        }
        let size = max(1, style.fontSize)
        if let family = style.fontFamily, let custom = NSFont(name: family, size: size) { return custom }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Source-pixel text metrics shared by rendering, selection bounds and hit testing.
    static func textLayout(content: String, style: TextStyle) -> TextLayout {
        let font = textFont(for: style)
        let lines = content.components(separatedBy: .newlines)
        let ascent = font.ascender
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var width: CGFloat = 0
        for text in lines {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            width = max(width, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        return TextLayout(font: font, lines: lines, ascent: ascent, lineHeight: lineHeight,
                          size: CGSize(width: ceil(width), height: lineHeight * CGFloat(max(1, lines.count))))
    }

    static func textBackgroundPadding(for style: TextStyle) -> CGFloat {
        max(3, style.fontSize * 0.22)
    }

    // MARK: - Mask Rendering

    private static func decodeMask(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return image
    }

    private static func renderMask(
        maskData: Data,
        bounds: NormalizedRect,
        blendMode: BlendMode,
        opacity: CGFloat,
        featherRadius: CGFloat,
        context: CGContext,
        imageSize: CGSize,
        sourceImage: CGImage? = nil,
        decodedMask: CGImage? = nil
    ) {
        guard let maskImage = decodedMask ?? decodeMask(maskData) else {
            return
        }

        let destRect = CGRect(
            x: bounds.x * imageSize.width,
            y: (1 - bounds.y - bounds.height) * imageSize.height,
            width: bounds.width * imageSize.width,
            height: bounds.height * imageSize.height
        )
        guard destRect.width > 0, destRect.height > 0 else { return }

        context.saveGState()
        // Mask opacity is effect strength: 0 is a no-op for either polarity.
        let strength = min(1, max(0, opacity))
        context.setAlpha(blendMode == .maskKeep ? 1 : strength)

        // Apply blend mode
        switch blendMode {
        case .maskRemove:
            context.setBlendMode(.destinationOut)
        case .maskKeep:
            // For maskKeep, we need destination-in compositing
            context.setBlendMode(.destinationIn)
        case .maskRestore:
            context.setBlendMode(.normal)
        case .normal:
            context.setBlendMode(.normal)
        case .multiply:
            context.setBlendMode(.multiply)
        case .screen:
            context.setBlendMode(.screen)
        case .overlay:
            context.setBlendMode(.overlay)
        }

        // Vision masks are grayscale without alpha. Convert luminance to alpha
        // before destination-in/out; drawing grayscale directly erases the whole rectangle.
        let alphaScale: CGFloat = blendMode == .maskKeep ? strength : 1
        let alphaBias: CGFloat = blendMode == .maskKeep ? 1 - strength : 0
        let maskCI = CIImage(cgImage: maskImage, options: [.colorSpace: NSNull()]).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: alphaScale, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: alphaBias)
        ]).cropped(to: CGRect(x: 0, y: 0, width: maskImage.width, height: maskImage.height))
        guard let alphaMask = imageContext.createCGImage(maskCI, from: maskCI.extent) else {
            context.restoreGState()
            return
        }
        let maskPixelScale = min(CGFloat(maskImage.width) / destRect.width,
                                 CGFloat(maskImage.height) / destRect.height)
        let renderedMask = featherRadius > 0
            ? (applyGaussianBlur(to: alphaMask, radius: featherRadius * maskPixelScale) ?? alphaMask) : alphaMask
        if blendMode == .maskRestore {
            // Restore the original adjusted canvas beneath a white brush stroke. Clipping
            // with this RGBA image uses its alpha (not inverse CGImage-mask polarity).
            // A standalone shape render has no source and intentionally cannot restore.
            if let sourceImage {
                context.clip(to: destRect, mask: renderedMask)
                context.draw(sourceImage, in: CGRect(origin: .zero, size: imageSize))
            }
        } else {
            context.draw(renderedMask, in: destRect)
        }

        context.restoreGState()
    }

    // MARK: - Extracted Subject Rendering

    private static func renderExtractedSubject(
        assetKey: String,
        bounds: NormalizedRect,
        opacity: CGFloat,
        transform: ShapeTransform,
        context: CGContext,
        imageSize: CGSize,
        subjectImages: [String: NSImage]
    ) {
        guard let subjectImage = subjectImages[assetKey],
              let cgImage = subjectImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        let baseRect = CGRect(
            x: (bounds.x + transform.offset.x) * imageSize.width,
            y: (1 - bounds.y - bounds.height * transform.scale - transform.offset.y) * imageSize.height,
            width: bounds.width * transform.scale * imageSize.width,
            height: bounds.height * transform.scale * imageSize.height
        )

        context.saveGState()
        context.setAlpha(opacity)

        // Apply rotation around center
        if abs(transform.rotation) > 0.001 {
            let center = CGPoint(x: baseRect.midX, y: baseRect.midY)
            context.translateBy(x: center.x, y: center.y)
            // Editor/model angles are clockwise in top-left coordinates; Quartz is Y-up.
            context.rotate(by: -transform.rotation * .pi / 180)
            context.translateBy(x: -center.x, y: -center.y)
        }

        context.draw(cgImage, in: baseRect)
        context.restoreGState()
    }

    // MARK: - Helpers

    /// Convert UInt32 packed RGBA to CGColor
    static func cgColor(from value: UInt32) -> CGColor {
        let r = CGFloat((value >> 24) & 0xFF) / 255.0
        let g = CGFloat((value >> 16) & 0xFF) / 255.0
        let b = CGFloat((value >> 8) & 0xFF) / 255.0
        let a = CGFloat(value & 0xFF) / 255.0
        return CGColor(colorSpace: outputColorSpace, components: [r, g, b, a])!
    }

    /// Convert LayerBlendMode to CGBlendMode
    private static func cgBlendMode(from mode: LayerBlendMode) -> CGBlendMode {
        switch mode {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        }
    }

    /// Apply non-destructive photo adjustments using CIFilter pipeline
    private static func applyPhotoAdjustments(to image: CGImage, adjustments: PhotoAdjustments,
                                              outputSize: CGSize, coordinateSize: CGSize) -> CGImage? {
        var ciImage = CIImage(cgImage: image)
        let coordinateScale = min(CGFloat(image.width) / coordinateSize.width,
                                  CGFloat(image.height) / coordinateSize.height)

        // Brightness, contrast, saturation
        if adjustments.brightness != 0 || adjustments.contrast != 1.0 || adjustments.saturation != 1.0 {
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(adjustments.brightness, forKey: kCIInputBrightnessKey)
                filter.setValue(adjustments.contrast, forKey: kCIInputContrastKey)
                filter.setValue(adjustments.saturation, forKey: kCIInputSaturationKey)
                if let output = filter.outputImage {
                    ciImage = output
                }
            }
        }

        // Temperature and tint
        if adjustments.temperature != 6500 || adjustments.tint != 0 {
            if let filter = CIFilter(name: "CITemperatureAndTint") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(CIVector(x: adjustments.temperature, y: 0), forKey: "inputNeutral")
                filter.setValue(CIVector(x: 6500, y: adjustments.tint), forKey: "inputTargetNeutral")
                if let output = filter.outputImage {
                    ciImage = output
                }
            }
        }

        // Sharpness
        if adjustments.sharpness > 0 {
            if let filter = CIFilter(name: "CISharpenLuminance") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(adjustments.sharpness, forKey: kCIInputSharpnessKey)
                if filter.inputKeys.contains(kCIInputRadiusKey),
                   let radius = filter.value(forKey: kCIInputRadiusKey) as? NSNumber {
                    filter.setValue(radius.doubleValue * Double(coordinateScale), forKey: kCIInputRadiusKey)
                }
                if let output = filter.outputImage {
                    ciImage = output
                }
            }
        }

        // Vignette
        if adjustments.vignette > 0 {
            if let filter = CIFilter(name: "CIVignette") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(adjustments.vignette, forKey: kCIInputIntensityKey)
                filter.setValue(adjustments.vignette * 2 * coordinateScale, forKey: kCIInputRadiusKey)
                if let output = filter.outputImage {
                    ciImage = output
                }
            }
        }

        // CI stays lazy in source coordinates until the final scale. A bounded preview
        // never materializes a full-resolution adjusted intermediate CGImage.
        ciImage = ciImage.transformed(by: CGAffineTransform(
            scaleX: outputSize.width / CGFloat(image.width),
            y: outputSize.height / CGFloat(image.height)
        ))
        return imageContext.createCGImage(ciImage, from: CGRect(origin: .zero, size: outputSize))
    }

    /// Apply Gaussian blur to a CGImage (for mask feathering)
    private static func applyGaussianBlur(to image: CGImage, radius: CGFloat) -> CGImage? {
        guard let ciImage = CIImage(cgImage: image)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: CGRect(origin: .zero, size: CGSize(width: image.width, height: image.height))) as CIImage? else {
            return nil
        }

        return imageContext.createCGImage(ciImage, from: ciImage.extent)
    }
}
