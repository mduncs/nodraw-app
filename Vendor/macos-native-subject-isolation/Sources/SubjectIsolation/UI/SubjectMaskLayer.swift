import QuartzCore
import AppKit

/// Manages the mask shape layer and dimming color layer.
/// Handles animated transitions when highlighted subjects change.
internal final class SubjectMaskLayer {

    /// Semi-transparent overlay that dims non-subject areas.
    let colorLayer: CALayer
    /// Shape layer used as mask on the highlight layer — white = subject visible.
    let maskShapeLayer: CAShapeLayer

    private var previousPath: CGPath?

    init(dimmingAlpha: CGFloat = 0.4) {
        colorLayer = CALayer()
        let dimColor = NSColor.controlBackgroundColor.withAlphaComponent(dimmingAlpha)
        colorLayer.backgroundColor = dimColor.cgColor
        colorLayer.opacity = 0.0

        maskShapeLayer = CAShapeLayer()
        maskShapeLayer.fillColor = NSColor.white.cgColor
        maskShapeLayer.fillRule = .evenOdd
    }

    /// Update the dimming color alpha.
    func updateDimmingAlpha(_ alpha: CGFloat) {
        let dimColor = NSColor.controlBackgroundColor.withAlphaComponent(alpha)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorLayer.backgroundColor = dimColor.cgColor
        CATransaction.commit()
    }

    /// Update the mask path for currently highlighted subjects.
    /// When animated, cross-fades between old and new mask paths.
    func updateMask(path: CGPath?, animated: Bool) {
        if !animated { maskShapeLayer.removeAnimation(forKey: "pathTransition") }
        guard let path else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            maskShapeLayer.path = nil
            CATransaction.commit()
            previousPath = nil
            return
        }

        if animated, previousPath != nil {
            // Cross-fade: animate opacity of the shape layer
            let anim = CABasicAnimation(keyPath: "path")
            anim.fromValue = previousPath
            anim.toValue = path
            anim.duration = GlowParameters.opacityTransitionDuration
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = true
            maskShapeLayer.add(anim, forKey: "pathTransition")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskShapeLayer.path = path
        CATransaction.commit()

        previousPath = path
    }

    /// Set dimming active/inactive (animate opacity of colorLayer).
    func setDimming(active: Bool, animated: Bool) {
        let targetOpacity: Float = active ? 1.0 : 0.0
        let currentOpacity = colorLayer.presentation()?.opacity ?? colorLayer.opacity
        colorLayer.removeAnimation(forKey: "dimming")

        if animated {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = currentOpacity
            anim.toValue = targetOpacity
            anim.duration = GlowParameters.opacityTransitionDuration
            anim.fillMode = .both
            colorLayer.add(anim, forKey: "dimming")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorLayer.opacity = targetOpacity
        CATransaction.commit()
    }

    /// Layout sublayers to match parent bounds.
    func layout(bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorLayer.frame = bounds
        maskShapeLayer.frame = bounds
        CATransaction.commit()
    }
}
