import QuartzCore
import AppKit

/// Public-Core-Animation subject outline: crisp strokes plus shadow bloom.
/// Repeated updates preserve unchanged stroke layers and their animation phase.
internal final class GlowLayer: CALayer {
    private let innerLayer = CALayer()
    private var layerMap: [Int: [CALayer]] = [:]
    private struct Configuration {
        let path: CGPath
        let viewScale: CGFloat
        let screenScale: CGFloat
        let reduceMotion: Bool
    }
    private var configurations: [Int: Configuration] = [:]

    override init() {
        super.init()
        addSublayer(innerLayer)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSublayer(innerLayer)
    }

    func beginAnimation(path: CGPath, subjectIndex: Int, viewScale: CGFloat,
                        screenScale: CGFloat, totalSubjects: Int, subjectOffset: Int,
                        animated: Bool = true, reduceMotion: Bool = false) {
        if let previous = configurations[subjectIndex], previous.path == path,
           previous.viewScale == viewScale, previous.screenScale == screenScale,
           previous.reduceMotion == reduceMotion { return }
        stopAnimation(for: subjectIndex)
        configurations[subjectIndex] = Configuration(path: path, viewScale: viewScale,
                                                     screenScale: screenScale, reduceMotion: reduceMotion)
        let thin = GlowParameters.thin(viewScale: viewScale, screenScale: screenScale)
        let thick = GlowParameters.thick(viewScale: viewScale)
        let reversed = PathUtilities.reversePath(path)
        let duration = GlowParameters.cycleDuration(pathLength: PathUtilities.estimatePathLength(reversed))
        let stagger = totalSubjects > 1 ? duration / CGFloat(totalSubjects) * CGFloat(subjectOffset) : 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var containers: [CALayer] = []
        for parameters in [thick, thin] {
            let container = CALayer()
            containers.append(container)
            // One quiet full outline replaces perpetual chasing when Reduce Motion is enabled.
            let count = reduceMotion ? 1 : parameters.strokeCount
            for index in 0..<count {
                let t = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0.5
                let width = parameters.minThickness + t * (parameters.maxThickness - parameters.minThickness)
                let opacity = parameters.minOpacity + t * (parameters.maxOpacity - parameters.minOpacity)
                for phase in 0..<(reduceMotion ? 1 : 2) {
                    let stroke = CAShapeLayer()
                    stroke.strokeColor = NSColor(calibratedRed: 0.90, green: 0.96, blue: 1, alpha: 1).cgColor
                    stroke.lineWidth = width
                    stroke.fillColor = nil
                    stroke.lineCap = .round
                    stroke.opacity = Float(opacity)
                    stroke.path = reversed
                    stroke.strokeStart = 0
                    stroke.strokeEnd = reduceMotion ? 1 : 0
                    // CALayer shadows are public API and follow the animated stroke's alpha.
                    stroke.shadowColor = NSColor(calibratedRed: 0.65, green: 0.82, blue: 1, alpha: 1).cgColor
                    stroke.shadowOpacity = 0.8
                    stroke.shadowRadius = parameters.blurRadius
                    stroke.shadowOffset = .zero
                    if !reduceMotion {
                        addChaseAnimation(to: stroke, cycleDuration: duration,
                                          strokeLength: duration * parameters.strokeLengthFraction,
                                          offset: duration * CGFloat(index) / CGFloat(count) + stagger,
                                          phase: duration * CGFloat(phase))
                    }
                    container.addSublayer(stroke)
                }
            }
            innerLayer.addSublayer(container)
            if animated {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.22
                container.add(fade, forKey: "appearance")
            }
        }
        layerMap[subjectIndex] = containers
        CATransaction.commit()
    }

    func stopAnimation(for subjectIndex: Int, animated: Bool = false) {
        guard let containers = layerMap.removeValue(forKey: subjectIndex) else { return }
        configurations.removeValue(forKey: subjectIndex)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for container in containers {
            if animated {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = container.presentation()?.opacity ?? container.opacity
                fade.toValue = 0
                fade.duration = 0.22
                container.opacity = 0
                container.add(fade, forKey: "appearance")
            } else {
                container.removeFromSuperlayer()
            }
        }
        CATransaction.commit()
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) {
                // Captured old containers only: a subsequent preview cannot be removed accidentally.
                for container in containers { container.removeFromSuperlayer() }
            }
        }
    }
    func removeAnimations(except indexes: IndexSet, animated: Bool) {
        for index in Array(layerMap.keys) where !indexes.contains(index) {
            stopAnimation(for: index, animated: animated)
        }
    }
    func stopAllAnimations(animated: Bool = true) { removeAnimations(except: [], animated: animated) }
    var isActive: Bool { !layerMap.isEmpty }
    internal var activeSubjectIndexes: IndexSet { IndexSet(layerMap.keys) }

    func layoutToFit(bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        innerLayer.bounds = bounds
        innerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    private func addChaseAnimation(to layer: CAShapeLayer, cycleDuration: CGFloat,
                                   strokeLength: CGFloat, offset: CGFloat, phase: CGFloat) {
        let end = CABasicAnimation(keyPath: "strokeEnd")
        end.fromValue = 0.0
        end.toValue = 1.0
        end.beginTime = offset + phase
        end.duration = strokeLength
        end.fillMode = .forwards
        let start = CABasicAnimation(keyPath: "strokeStart")
        start.fromValue = 0.0
        start.toValue = 1.0
        start.beginTime = offset + phase + strokeLength * 0.1
        start.duration = strokeLength
        start.fillMode = .forwards
        let group = CAAnimationGroup()
        group.duration = cycleDuration * 2
        group.repeatCount = .infinity
        group.animations = [end, start]
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "chase")
    }
}
