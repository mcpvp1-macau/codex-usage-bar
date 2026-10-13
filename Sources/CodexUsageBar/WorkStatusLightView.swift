import AppKit
import QuartzCore

struct WorkLightMotion {
    let duration: TimeInterval
    let core: [Float]
    let halo: [Float]
    let repeats: Bool

    var times: [NSNumber] {
        core.indices.map { NSNumber(value: Double($0) / Double(core.count - 1)) }
    }

    static func profile(for state: WorkState) -> WorkLightMotion? {
        let count = 91
        let progress = (0..<count).map { Double($0) / Double(count - 1) }
        let wave: [Double]
        let duration: TimeInterval
        let low: Double
        let high: Double
        let repeats: Bool
        switch state {
        case .active:
            // Shorter inhale, longer exhale. Zero velocity at both ends makes the loop seamless.
            wave = progress.map { t in
                t <= 0.38 ? (1 - cos(.pi * t / 0.38)) / 2
                    : (1 + cos(.pi * (t - 0.38) / 0.62)) / 2
            }
            duration = 4.2; low = 0.60; high = 0.94; repeats = true
        case .waiting:
            wave = progress.map { t in t < 0.52 ? pow(sin(.pi * t / 0.52), 2) : 0 }
            duration = 5.8; low = 0.70; high = 0.94; repeats = true
        case .completed:
            wave = progress.map { pow(sin(2 * .pi * $0), 2) }
            duration = 3; low = 0.70; high = 0.94; repeats = false
        case .failed:
            wave = progress.map { t in
                [0.23, 0.67].map { center in
                    let distance = abs(t - center) / 0.18
                    return distance < 1 ? (1 + cos(.pi * distance)) / 2 : 0
                }.max() ?? 0
            }
            duration = 2.8; low = 0.76; high = 0.94; repeats = false
        case .idle, .unknown: return nil
        }
        var core = wave.map { Float(low + (high - low) * $0) }
        var halo = wave.map { Float(0.04 + 0.15 * $0) }
        if state == .completed {
            // Ease into dim white at the end, rather than snapping from a bright colour.
            for index in core.indices where progress[index] > 0.85 {
                let t = (progress[index] - 0.85) / 0.15
                let fade = (1 - cos(.pi * t)) / 2
                core[index] = Float(Double(core[index]) * (1 - fade) + 0.45 * fade)
                halo[index] *= Float(1 - fade)
            }
        }
        return WorkLightMotion(duration: duration, core: core, halo: halo, repeats: repeats)
    }
}

enum WorkLightPalette {
    static let idle = NSColor(srgbRed: 0.95, green: 0.97, blue: 1, alpha: 1)

    static func color(for state: WorkState) -> NSColor {
        if state == .completed || state == .idle { return idle }
        return state.color.blended(withFraction: 0.08, of: .white) ?? state.color
    }

    static func glow(_ color: NSColor) -> [CGColor] {
        [color.withAlphaComponent(0.85).cgColor, color.withAlphaComponent(0.30).cgColor,
         color.withAlphaComponent(0).cgColor]
    }

    // Muted rainbow, ending in the same soft white used by idle.
    static let completionColors: [NSColor] = [0.38, 0.49, 0.61, 0.75, 0.88, 0.99, 0.07, 0.15, 0.33]
        .map { NSColor(calibratedHue: $0, saturation: 0.58, brightness: 0.98, alpha: 1)
            .usingColorSpace(.sRGB) ?? idle } + [idle]
}

/// A configurable-size compositor animation; resizing it never invalidates quota text or the Touch Bar.
@MainActor
final class WorkStatusLightView: NSView {
    private let core = CAShapeLayer()
    private let halo = CAGradientLayer()
    private let glint = CAGradientLayer()
    private var state: WorkState = .unknown
    private var hasState = false
    private var animationsEnabled = true
    private var accessibilityObserver: NSObjectProtocol?
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private(set) var configuredDiameter: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        wantsLayer = true
        halo.frame = bounds
        halo.type = .radial
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.locations = [0, 0.42, 1]
        core.frame = bounds
        core.path = CGPath(ellipseIn: CGRect(x: 3.25, y: 3.25, width: 5.5, height: 5.5), transform: nil)
        core.lineWidth = 0.8
        glint.frame = CGRect(x: 3.25, y: 3.25, width: 5.5, height: 5.5)
        glint.startPoint = CGPoint(x: 0.25, y: 1)
        glint.endPoint = CGPoint(x: 0.75, y: 0)
        glint.colors = [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        let mask = CAShapeLayer()
        mask.path = CGPath(ellipseIn: glint.bounds, transform: nil)
        glint.mask = mask
        core.addSublayer(glint)
        layer?.addSublayer(halo)
        layer?.addSublayer(core)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: configuredDiameter)
        heightConstraint = heightAnchor.constraint(equalToConstant: configuredDiameter)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        setAccessibilityElement(true)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyAppearance() }
        }
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    func update(_ snapshot: WorkActivitySnapshot) {
        toolTip = snapshot.detail
        setAccessibilityLabel(snapshot.state.label)
        guard !hasState || state != snapshot.state else { return }
        state = snapshot.state
        hasState = true
        applyAppearance()
    }

    func setAnimationsEnabled(_ enabled: Bool) {
        guard animationsEnabled != enabled else { return }
        animationsEnabled = enabled
        applyAppearance()
    }

    func setDiameter(_ diameter: CGFloat) {
        let clamped = min(25, max(6, diameter))
        guard abs(configuredDiameter - clamped) > 0.01 else { return }
        configuredDiameter = clamped
        widthConstraint.constant = clamped
        heightConstraint.constant = clamped
        setFrameSize(NSSize(width: clamped, height: clamped))
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let diameter = min(bounds.width, bounds.height)
        guard diameter > 0 else { return }
        let coreDiameter = diameter * (5.5 / 12)
        let coreRect = CGRect(
            x: (bounds.width - coreDiameter) / 2,
            y: (bounds.height - coreDiameter) / 2,
            width: coreDiameter,
            height: coreDiameter
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.frame = bounds
        core.frame = bounds
        core.path = CGPath(ellipseIn: coreRect, transform: nil)
        core.lineWidth = max(0.5, diameter * (0.8 / 12))
        glint.frame = coreRect
        if let mask = glint.mask as? CAShapeLayer {
            mask.frame = glint.bounds
            mask.path = CGPath(ellipseIn: mask.bounds, transform: nil)
        }
        CATransaction.commit()
    }

    private func applyAppearance() {
        let previousCoreOpacity = core.presentation()?.opacity ?? core.opacity
        let previousHaloOpacity = halo.presentation()?.opacity ?? halo.opacity
        let previousColor = core.presentation()?.fillColor ?? core.fillColor
        let previousStroke = core.presentation()?.strokeColor ?? core.strokeColor
        let previousGlow = halo.presentation()?.colors ?? halo.colors
        let previousGlintOpacity = glint.presentation()?.opacity ?? glint.opacity
        core.removeAllAnimations()
        halo.removeAllAnimations()
        glint.removeAllAnimations()
        let motion = WorkLightMotion.profile(for: state)
        let color = WorkLightPalette.color(for: state).cgColor
        let glow = WorkLightPalette.glow(WorkLightPalette.color(for: state))
        let coreOpacity: Float = state == .idle ? 0.45 : state == .unknown ? 0.55
            : state == .completed ? 0.45 : motion?.core.last ?? 0.76
        let haloOpacity: Float = state == .idle || state == .unknown || state == .completed ? 0
            : motion?.halo.last ?? 0.04
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        core.fillColor = state == .unknown ? NSColor.clear.cgColor : color
        core.strokeColor = state == .unknown ? color : NSColor.clear.cgColor
        core.opacity = coreOpacity
        halo.colors = glow
        halo.opacity = haloOpacity
        glint.opacity = state == .unknown ? 0 : 1
        CATransaction.commit()

        guard animationsEnabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let entryDuration = 0.28
        transition(glint, keyPath: "opacity", from: previousGlintOpacity, to: glint.opacity, duration: entryDuration)
        transition(core, keyPath: "strokeColor", from: previousStroke, to: core.strokeColor, duration: entryDuration)
        if state == .completed, let motion {
            var coreValues = motion.core
            var haloValues = motion.halo
            coreValues[0] = previousCoreOpacity
            haloValues[0] = previousHaloOpacity
            animate(core, values: coreValues, motion: motion)
            animate(halo, values: haloValues, motion: motion)
            let colors = WorkLightPalette.completionColors
            let firstColor = previousColor ?? colors[0].cgColor
            let colorValues = [firstColor] + colors.map(\.cgColor)
            let times = colorValues.indices.map { NSNumber(value: Double($0) / Double(colorValues.count - 1)) }
            colorAnimation(core, keyPath: "fillColor", values: colorValues, times: times)
            let glowValues = [previousGlow ?? WorkLightPalette.glow(colors[0])] + colors.map(WorkLightPalette.glow)
            colorAnimation(halo, keyPath: "colors", values: glowValues, times: times)
        } else {
            transition(core, keyPath: "fillColor", from: previousColor, to: core.fillColor, duration: entryDuration)
            transition(halo, keyPath: "colors", from: previousGlow, to: glow, duration: entryDuration)
            transition(core, keyPath: "opacity", from: previousCoreOpacity, to: motion?.core.first ?? coreOpacity, duration: entryDuration)
            transition(halo, keyPath: "opacity", from: previousHaloOpacity, to: motion?.halo.first ?? haloOpacity, duration: entryDuration)
            if let motion {
                animate(core, values: motion.core, motion: motion, delay: entryDuration)
                animate(halo, values: motion.halo, motion: motion, delay: entryDuration)
            }
        }
    }

    private func animate(_ target: CALayer, values: [Float], motion: WorkLightMotion, delay: TimeInterval = 0) {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = motion.times
        animation.duration = motion.duration
        animation.repeatCount = motion.repeats ? .infinity : 0
        animation.calculationMode = .linear
        animation.beginTime = target.convertTime(CACurrentMediaTime(), from: nil) + delay
        target.add(animation, forKey: "work-light")
    }

    private func colorAnimation(_ target: CALayer, keyPath: String, values: [Any], times: [NSNumber]) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.duration = 3
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: values.count - 1)
        animation.beginTime = target.convertTime(CACurrentMediaTime(), from: nil)
        target.add(animation, forKey: "completion-rainbow")
    }

    private func transition(_ target: CALayer, keyPath: String, from: Any?, to: Any?, duration: TimeInterval) {
        guard let from, let to else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(animation, forKey: "transition-\(keyPath)")
    }
}
