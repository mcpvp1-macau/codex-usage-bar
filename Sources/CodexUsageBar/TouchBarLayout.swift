import AppKit

enum TouchBarLayout: String, CaseIterable, Identifiable, Sendable {
    case compact
    case quotaBars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "紧凑数字"
        case .quotaBars: "双行余量条"
        }
    }

    var lightSizeRange: ClosedRange<Double> {
        switch self {
        case .compact: 6...16.5
        case .quotaBars: 6...25
        }
    }
}

enum SharedQuotaPalette {
    static let track = NSColor.white.withAlphaComponent(0.16)
    static let primary = NSColor.systemGreen
    static let period = NSColor.white.withAlphaComponent(0.88)
    static let label = NSColor.labelColor
    static let unavailable = NSColor.secondaryLabelColor

    static func fill(for window: RateWindow?, role: QuotaBarRole) -> NSColor {
        guard let window else { return unavailable.withAlphaComponent(0.45) }
        if window.remainingPercent <= 10 { return .systemRed }
        if window.remainingPercent <= 25 { return .systemOrange }
        return role == .primary ? primary : period
    }
}

enum QuotaBarRole { case primary, period }

@MainActor
final class QuotaProgressBarView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var fraction: CGFloat = 0
    private var fillColor = SharedQuotaPalette.primary.cgColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 5).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(window: RateWindow?, role: QuotaBarRole) {
        fraction = CGFloat(window?.remainingPercent ?? 0) / 100
        fillColor = SharedQuotaPalette.fill(for: window, role: role).cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let bounds = CGRect(x: 0, y: max(0, (self.bounds.height - 5) / 2),
                            width: self.bounds.width, height: 5).integral
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.cornerRadius = 2.5
        trackLayer.backgroundColor = SharedQuotaPalette.track.cgColor
        let width = max(0, min(bounds.width, bounds.width * fraction))
        fillLayer.frame = CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        fillLayer.cornerRadius = 2.5
        fillLayer.backgroundColor = fillColor
        CATransaction.commit()
    }
}

@MainActor
final class QuotaBarUsageView: NSView {
    private static let defaultBarWidth: CGFloat = 94
    private static let defaultViewWidth: CGFloat = 221

    private let primaryBar = QuotaProgressBarView(frame: .zero)
    private let periodBar = QuotaProgressBarView(frame: .zero)
    private let primaryLabel = NSTextField(labelWithString: "5h:—%  —")
    private let periodLabel = NSTextField(labelWithString: "周:—%  —")
    private let light = WorkStatusLightView(frame: .zero)
    private var viewWidthConstraint: NSLayoutConstraint!
    private var primaryBarWidthConstraint: NSLayoutConstraint!
    private var periodBarWidthConstraint: NSLayoutConstraint!

    // Kept readable for the test harness and useful when diagnosing layout issues.
    private(set) var configuredBarWidth: CGFloat = defaultBarWidth
    private(set) var configuredViewWidth: CGFloat = defaultViewWidth

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: Self.defaultViewWidth,
                                 height: 27))
        translatesAutoresizingMaskIntoConstraints = false
        viewWidthConstraint = widthAnchor.constraint(equalToConstant: Self.defaultViewWidth)
        viewWidthConstraint.isActive = true
        heightAnchor.constraint(lessThanOrEqualToConstant: 28).isActive = true

        configureLabel(primaryLabel)
        configureLabel(periodLabel)
        primaryLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        periodLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        periodLabel.textColor = .secondaryLabelColor

        let primaryRow = makeRow(bar: primaryBar, label: primaryLabel)
        let periodRow = makeRow(bar: periodBar, label: periodLabel)
        let rows = NSStackView(views: [primaryRow, periodRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 1

        let content = NSStackView(views: [light, rows])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 0, left: 1, bottom: 0, right: 1)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            light.widthAnchor.constraint(equalTo: light.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(primary: RateWindow?, period: RateWindow?, periodName: String,
                activity: WorkActivitySnapshot) {
        primaryBar.update(window: primary, role: .primary)
        periodBar.update(window: period, role: .period)
        primaryLabel.stringValue = Self.rowText(prefix: "5h", window: primary)
        periodLabel.stringValue = Self.rowText(prefix: periodName, window: period)
        primaryLabel.toolTip = Self.tooltip(prefix: "5 小时", window: primary)
        periodLabel.toolTip = Self.tooltip(prefix: periodName, window: period)
        light.update(activity)
        needsLayout = true
    }

    func setAnimationsEnabled(_ enabled: Bool) {
        light.setAnimationsEnabled(enabled)
    }

    func setLightDiameter(_ diameter: CGFloat) {
        light.setDiameter(diameter)
    }

    /// Changes both service bars without rebuilding the Touch Bar.
    func setBarWidth(_ width: CGFloat) {
        let clamped = min(110, max(60, width.rounded()))
        configuredBarWidth = clamped
        configuredViewWidth = Self.defaultViewWidth + (clamped - Self.defaultBarWidth)
        primaryBarWidthConstraint.constant = clamped
        periodBarWidthConstraint.constant = clamped
        viewWidthConstraint.constant = configuredViewWidth
        needsLayout = true
    }

    private func makeRow(bar: QuotaProgressBarView, label: NSTextField) -> NSStackView {
        let widthConstraint = bar.widthAnchor.constraint(equalToConstant: Self.defaultBarWidth)
        widthConstraint.isActive = true
        if bar === primaryBar {
            primaryBarWidthConstraint = widthConstraint
        } else {
            periodBarWidthConstraint = widthConstraint
        }
        let row = NSStackView(views: [bar, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        return row
    }

    private func configureLabel(_ label: NSTextField) {
        label.alignment = .left
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
    }

    private static func rowText(prefix: String, window: RateWindow?) -> String {
        guard let window else { return "\(prefix):—%  —" }
        return "\(prefix):\(window.remainingPercent)%  \(resetText(window.resetsAt))"
    }

    private static func tooltip(prefix: String, window: RateWindow?) -> String {
        guard let window else { return "\(prefix)：暂无额度数据" }
        return "\(prefix)剩余 \(window.remainingPercent)%，下次重置 \(resetText(window.resetsAt))"
    }

    private static func resetText(_ date: Date?) -> String {
        guard let date else { return "—" }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return Self.chineseDateFormatter.string(from: date)
    }

    private static let chineseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
