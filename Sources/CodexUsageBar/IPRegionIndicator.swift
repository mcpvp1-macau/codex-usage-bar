import AppKit
import QuartzCore

enum IPRegionConnectionState: String, Equatable, Sendable {
    case unknown
    case checking
    case online
    case degraded
    case offline
}

struct IPRegionSnapshot: Equatable, Sendable {
    let regionCode: String?
    let regionName: String
    let state: IPRegionConnectionState
    let checkedAt: Date?

    static let unknown = IPRegionSnapshot(
        regionCode: nil,
        regionName: "—",
        state: .unknown,
        checkedAt: nil
    )

    var checking: IPRegionSnapshot {
        IPRegionSnapshot(
            regionCode: regionCode,
            regionName: regionName,
            state: .checking,
            checkedAt: checkedAt
        )
    }
}

enum IPRegionFetchResult: Sendable {
    case success(IPRegionSnapshot)
    case failure(IPRegionConnectionState)
}

enum IPRegionClient {
    private static let endpoint = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    static func fetch() -> IPRegionFetchResult {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("CodexKimiUsageBar/1.0 (macOS; region-only)", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseStatus = 0
        var responseError: Error?
        session.dataTask(with: request) { data, response, error in
            responseData = data
            responseStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            responseError = error
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 10) == .success else {
            return .failure(.degraded)
        }
        if let responseError {
            return .failure(connectionState(for: responseError))
        }
        guard responseStatus == 200,
              let data = responseData,
              data.count <= 32_768,
              let body = String(data: data, encoding: .utf8),
              let regionCode = parseRegionCode(from: body) else {
            return .failure(.degraded)
        }

        // The response also contains the public IP.  Deliberately retain only
        // the two-letter region code so the address is never logged or stored.
        return .success(IPRegionSnapshot(
            regionCode: regionCode,
            regionName: displayName(for: regionCode),
            state: .online,
            checkedAt: Date()
        ))
    }

    private static func parseRegionCode(from body: String) -> String? {
        guard let line = body.split(separator: "\n").first(where: { $0.hasPrefix("loc=") }) else {
            return nil
        }
        let value = line.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count == 2, value.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) else {
            return nil
        }
        return value
    }

    private static func connectionState(for error: Error) -> IPRegionConnectionState {
        guard let urlError = error as? URLError else { return .degraded }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
             .internationalRoamingOff:
            return .offline
        default:
            return .degraded
        }
    }

    private static func displayName(for code: String) -> String {
        let shortNames: [String: String] = [
            "AU": "澳大利亚", "BR": "巴西", "CA": "加拿大", "CH": "瑞士",
            "CN": "中国", "DE": "德国", "ES": "西班牙", "FR": "法国",
            "GB": "英国", "HK": "香港", "ID": "印尼", "IN": "印度",
            "IT": "意大利", "JP": "日本", "KR": "韩国", "MO": "澳门",
            "MY": "马来西亚", "NL": "荷兰", "NZ": "新西兰", "PH": "菲律宾",
            "RU": "俄罗斯", "SE": "瑞典", "SG": "新加坡", "TH": "泰国",
            "TR": "土耳其", "TW": "台湾", "US": "美国", "VN": "越南",
            "ZA": "南非"
        ]
        if let name = shortNames[code] { return name }
        let localized = Locale(identifier: "zh_Hans_CN").localizedString(forRegionCode: code) ?? code
        return localized.count <= 4 ? localized : code
    }
}

@MainActor
final class IPRegionTouchBarView: NSView {
    private let trackLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let innerLayer = CALayer()
    private let regionLabel = NSTextField(labelWithString: "—")
    private var snapshot: IPRegionSnapshot = .unknown
    private var animationsEnabled = true
    var onTap: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 30))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        wantsLayer = true

        trackLayer.fillColor = NSColor.clear.cgColor
        trackLayer.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        trackLayer.lineWidth = 2
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.lineWidth = 2.2
        ringLayer.lineCap = .round
        innerLayer.backgroundColor = NSColor.black.withAlphaComponent(0.34).cgColor

        layer?.addSublayer(innerLayer)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(ringLayer)

        regionLabel.alignment = .center
        regionLabel.textColor = NSColor.white.withAlphaComponent(0.94)
        regionLabel.font = .systemFont(ofSize: 8.5, weight: .semibold)
        regionLabel.lineBreakMode = .byClipping
        regionLabel.translatesAutoresizingMaskIntoConstraints = false
        regionLabel.isEditable = false
        regionLabel.isSelectable = false
        addSubview(regionLabel)
        NSLayoutConstraint.activate([
            regionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            regionLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.25),
            regionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 24)
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleTap)))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        update(.unknown)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 30) }

    @objc private func handleTap() {
        onTap?()
    }

    override func layout() {
        super.layout()
        let diameter: CGFloat = 26
        let ringBounds = CGRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        ).integral
        let path = CGPath(ellipseIn: ringBounds.insetBy(dx: 1.6, dy: 1.6), transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.path = path
        ringLayer.frame = bounds
        ringLayer.path = path
        innerLayer.frame = ringBounds.insetBy(dx: 4, dy: 4)
        innerLayer.cornerRadius = innerLayer.bounds.width / 2
        CATransaction.commit()
    }

    func update(_ snapshot: IPRegionSnapshot) {
        self.snapshot = snapshot
        if let flag = Self.flagEmoji(for: snapshot.regionCode) {
            regionLabel.stringValue = flag
            regionLabel.font = NSFont(name: "Apple Color Emoji", size: 15)
                ?? .systemFont(ofSize: 15)
        } else {
            regionLabel.stringValue = "—"
            regionLabel.font = .systemFont(ofSize: 8.5, weight: .semibold)
        }
        toolTip = Self.tooltip(for: snapshot)
        setAccessibilityLabel("IP 属地")
        setAccessibilityValue("\(snapshot.regionName)，\(Self.stateLabel(snapshot.state))")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch snapshot.state {
        case .online:
            ringLayer.strokeColor = NSColor.systemMint.cgColor
            ringLayer.strokeEnd = 1
        case .checking:
            ringLayer.strokeColor = NSColor.systemCyan.cgColor
            ringLayer.strokeEnd = 0.30
        case .degraded:
            ringLayer.strokeColor = NSColor.systemYellow.cgColor
            ringLayer.strokeEnd = 0.72
        case .offline:
            ringLayer.strokeColor = NSColor.systemRed.cgColor
            ringLayer.strokeEnd = 0.34
        case .unknown:
            ringLayer.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.78).cgColor
            ringLayer.strokeEnd = 0.52
        }
        CATransaction.commit()
        updateAnimations()
    }

    func setAnimationsEnabled(_ enabled: Bool) {
        guard animationsEnabled != enabled else { return }
        animationsEnabled = enabled
        updateAnimations()
    }

    private func updateAnimations() {
        ringLayer.removeAllAnimations()
        guard animationsEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        switch snapshot.state {
        case .checking:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.pi * 2
            spin.duration = 1.15
            spin.repeatCount = .infinity
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            ringLayer.add(spin, forKey: "region-checking-spin")
        case .degraded:
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.45
            breathe.toValue = 1
            breathe.duration = 1.45
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ringLayer.add(breathe, forKey: "region-degraded-breathe")
        default:
            break
        }
    }

    private static func flagEmoji(for regionCode: String?) -> String? {
        guard let regionCode else { return nil }
        let scalars = regionCode.uppercased().unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            return UnicodeScalar(127_397 + scalar.value)
        }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func tooltip(for snapshot: IPRegionSnapshot) -> String {
        switch snapshot.state {
        case .online: return "IP 属地：\(snapshot.regionName)；网络正常。轻点重新检测。"
        case .checking: return "正在检测 IP 属地…"
        case .degraded: return "网络可用，但属地验证暂时失败。轻点重试。"
        case .offline: return "当前网络不可用。轻点重试。"
        case .unknown: return "尚未取得 IP 属地。轻点检测。"
        }
    }

    private static func stateLabel(_ state: IPRegionConnectionState) -> String {
        switch state {
        case .online: return "网络正常"
        case .checking: return "检测中"
        case .degraded: return "属地验证失败"
        case .offline: return "网络不可用"
        case .unknown: return "状态未知"
        }
    }
}
