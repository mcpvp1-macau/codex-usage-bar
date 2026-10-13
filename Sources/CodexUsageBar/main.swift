import AppKit
import Combine
import Darwin
import ObjectiveC
import Security
import ServiceManagement
import SwiftUI

private let usageDashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")!
private let kimiDashboardURL = URL(string: "https://www.kimi.com/code/console")!

struct RateWindow: Sendable {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

struct UsageSnapshot: Sendable {
    let primary: RateWindow?
    let secondary: RateWindow?
    let plan: String?
    let creditBalance: String?
    let unlimitedCredits: Bool
    let resetCredits: Int
    let fetchedAt: Date
}

struct KimiUsageSnapshot: Sendable {
    let fiveHour: RateWindow?
    let period: RateWindow?
    let periodTitle: String
    let monthlyTotal: RateWindow?
    let fetchedAt: Date
}

enum QuotaReset {
    static func next(_ windows: [(String, RateWindow?)], now: Date = Date()) -> (name: String, date: Date)? {
        windows.compactMap { name, window -> (name: String, date: Date)? in
            guard let date = window?.resetsAt, date > now else { return nil }
            return (name, date)
        }
        .min { $0.date < $1.date }
    }

    static func label(_ reset: (name: String, date: Date)?, now: Date = Date()) -> String {
        guard let reset else { return "未提供" }
        let time = reset.date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(reset.date, inSameDayAs: now) {
            return "\(reset.name) \(time)"
        }
        return "\(reset.name) \(reset.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))) \(time)"
    }
}

enum KimiUsageError: LocalizedError {
    case notSignedIn
    case expired
    case unavailable(Int)
    case invalidResponse
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "未找到 Kimi Code 登录信息。请登录 Kimi Code，或在设置中添加 Kimi Code API Key。"
        case .expired:
            return "Kimi Code 登录已过期。请打开 Kimi Code 刷新登录，或添加 API Key。"
        case .unavailable(let code):
            return "Kimi Code 额度请求失败（HTTP \(code)）。"
        case .invalidResponse:
            return "Kimi Code 返回了无法识别的额度数据。"
        case .refreshFailed:
            return "Kimi Code 登录续期失败。请打开 Kimi Code 重新登录。"
        }
    }
}

enum KimiKeychain {
    private static let service = "com.local.codexkimiusagebar.kimi-code"
    private static let account = "api-key"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func save(_ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            return SecItemDelete(base as CFDictionary) == errSecSuccess
        }
        let data = Data(value.utf8)
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

enum KimiUsageClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    static func fetch() throws -> KimiUsageSnapshot {
        let key = KimiKeychain.read()
        let token = try key ?? validCLIToken()
        let regionURL = isGlobalRegion ? "https://api.kimi.ai" : "https://api.kimi.com"
        var request = URLRequest(url: URL(string: regionURL + "/coding/v1/usages")!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexKimiUsageBar/1.0 (macOS; read-only)", forHTTPHeaderField: "User-Agent")
        let (status, root) = try requestJSON(request)
        guard status == 200 else { throw KimiUsageError.unavailable(status) }
        guard let root else { throw KimiUsageError.invalidResponse }

        let pools = root["usages"] as? [String: Any] ?? [:]
        let fiveHour = parsePool(pools["limit_5h"])
            ?? parseLegacyWindow(root["limits"], minutes: 300)
        let monthlyCode = parsePool(pools["limit_month_code"])
        let weekly = parsePool(pools["limit_week_total"])
            ?? parsePool(pools["limit_7d"])
            ?? parsePool(pools["limit_week"])
            ?? parseLegacyUsage(root["usage"])
        let monthlyTotal = parsePool(pools["limit_month_total"])
        guard fiveHour != nil || monthlyCode != nil || weekly != nil || monthlyTotal != nil else {
            throw KimiUsageError.invalidResponse
        }
        return KimiUsageSnapshot(
            fiveHour: fiveHour,
            period: monthlyCode ?? weekly,
            periodTitle: monthlyCode != nil ? "本月 Code" : "每周",
            monthlyTotal: monthlyTotal,
            fetchedAt: Date()
        )
    }

    private static var isGlobalRegion: Bool {
        let marker = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code/region")
        return (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "global"
    }

    private static func validCLIToken() throws -> String {
        let credentialURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        let lockURL = credentialURL.deletingLastPathComponent().appendingPathComponent("kimi-code.lock")
        guard let original = readCredential(credentialURL) else { throw KimiUsageError.notSignedIn }
        let expiry = (original["expires_at"] as? NSNumber)?.doubleValue ?? 0
        if expiry > Date().timeIntervalSince1970 + 90,
           let access = original["access_token"] as? String, !access.isEmpty { return access }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw KimiUsageError.refreshFailed }
        defer { close(descriptor) }
        var locked = false
        for _ in 0..<30 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            usleep(100_000)
        }
        guard locked else { throw KimiUsageError.refreshFailed }
        defer { flock(descriptor, LOCK_UN) }

        guard var credential = readCredential(credentialURL),
              let refresh = credential["refresh_token"] as? String,
              !refresh.isEmpty else { throw KimiUsageError.notSignedIn }
        let currentExpiry = (credential["expires_at"] as? NSNumber)?.doubleValue ?? 0
        if currentExpiry > Date().timeIntervalSince1970 + 90,
           let access = credential["access_token"] as? String, !access.isEmpty { return access }

        let authBase = isGlobalRegion ? "https://auth.kimi.ai" : "https://auth.kimi.com"
        var request = URLRequest(url: URL(string: authBase + "/api/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: "17e5f671-d194-4dfb-9706-5516cb48c098"),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refresh)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (status, response) = try requestJSON(request)
        guard status == 200,
              let response,
              let access = response["access_token"] as? String,
              let newRefresh = response["refresh_token"] as? String,
              let expiresIn = (response["expires_in"] as? NSNumber)?.doubleValue,
              !access.isEmpty, !newRefresh.isEmpty, expiresIn > 0 else {
            throw KimiUsageError.refreshFailed
        }

        credential["access_token"] = access
        credential["refresh_token"] = newRefresh
        credential["expires_in"] = Int(expiresIn)
        credential["expires_at"] = Int(Date().timeIntervalSince1970 + expiresIn)
        if let scope = response["scope"] as? String { credential["scope"] = scope }
        if let tokenType = response["token_type"] as? String { credential["token_type"] = tokenType }
        try writeCredential(credential, to: credentialURL)
        return access
    }

    private static func readCredential(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value
    }

    private static func writeCredential(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".codex-kimi-usage-\(UUID().uuidString)")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw KimiUsageError.refreshFailed }
        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let count = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    guard count > 0 else { throw KimiUsageError.refreshFailed }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw KimiUsageError.refreshFailed }
            close(descriptor)
            guard rename(temporaryURL.path, url.path) == 0 else { throw KimiUsageError.refreshFailed }
        } catch {
            close(descriptor)
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func requestJSON(_ request: URLRequest) throws -> (Int, [String: Any]?) {
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var status = 0
        var requestError: Error?
        session.dataTask(with: request) { data, response, error in
            responseData = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            requestError = error
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 15) == .success else { throw UsageClientError.timedOut }
        if let requestError { throw requestError }
        let payload = responseData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        return (status, payload)
    }

    private static func parsePool(_ value: Any?) -> RateWindow? {
        guard let pool = value as? [String: Any],
              let ratio = (pool["used_ratio"] as? NSNumber)?.doubleValue,
              ratio.isFinite else { return nil }
        return RateWindow(
            usedPercent: max(0, min(100, Int((ratio * 100).rounded()))),
            durationMinutes: nil,
            resetsAt: parseDate(pool["reset_time"] as? String)
        )
    }

    private static func parseLegacyUsage(_ value: Any?) -> RateWindow? {
        guard let usage = value as? [String: Any] else { return nil }
        return parseDetail(usage, minutes: 10_080)
    }

    private static func parseLegacyWindow(_ value: Any?, minutes: Int) -> RateWindow? {
        guard let windows = value as? [[String: Any]] else { return nil }
        for item in windows {
            let descriptor = item["window"] as? [String: Any] ?? [:]
            guard (descriptor["duration"] as? NSNumber)?.intValue == minutes,
                  descriptor["timeUnit"] as? String == "TIME_UNIT_MINUTE" else { continue }
            if let detail = item["detail"] as? [String: Any] {
                return parseDetail(detail, minutes: minutes)
            }
        }
        return nil
    }

    private static func parseDetail(_ detail: [String: Any], minutes: Int) -> RateWindow? {
        guard let limit = Double("\(detail["limit"] ?? "")"), limit > 0,
              let used = Double("\(detail["used"] ?? "")") else { return nil }
        return RateWindow(
            usedPercent: max(0, min(100, Int((used / limit * 100).rounded()))),
            durationMinutes: minutes,
            resetsAt: parseDate(detail["resetTime"] as? String)
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum UsageClientError: LocalizedError {
    case codexNotFound
    case launchFailed(String)
    case timedOut
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "找不到 Codex CLI。请先安装或更新 ChatGPT/Codex。"
        case .launchFailed(let message):
            return "无法启动 Codex：\(message)"
        case .timedOut:
            return "读取超时，请稍后重试。"
        case .invalidResponse:
            return "Codex 返回了无法识别的 Usage 数据。"
        case .server(let message):
            return "Codex 返回错误：\(message)"
        }
    }
}

enum CodexUsageClient {
    static func fetch() throws -> UsageSnapshot {
        guard let executable = findCodexExecutable() else {
            throw UsageClientError.codexNotFound
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw UsageClientError.launchFailed(error.localizedDescription)
        }

        let timedOut = LockedFlag()
        let timeout = DispatchWorkItem {
            if process.isRunning {
                timedOut.value = true
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)

        let initialize: [String: Any] = [
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-usage-bar",
                    "title": "Codex Usage Bar",
                    "version": "1.0.0"
                ],
                "capabilities": ["experimentalApi": true]
            ]
        ]
        let request: [String: Any] = [
            "id": 2,
            "method": "account/rateLimits/read",
            "params": NSNull()
        ]

        do {
            let payload = try line(for: initialize) + line(for: request)
            try input.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            if process.isRunning { process.terminate() }
            timeout.cancel()
            throw UsageClientError.launchFailed(error.localizedDescription)
        }

        var responseData = Data()
        while process.isRunning {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            responseData.append(chunk)
            if containsResponse(id: 2, in: responseData) {
                process.terminate()
                break
            }
        }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        timeout.cancel()

        if timedOut.value && responseData.isEmpty {
            throw UsageClientError.timedOut
        }

        return try parseResponse(responseData)
    }

    private static func containsResponse(id: Int, in data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { line in
            guard let lineData = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return false
            }
            return (json["id"] as? NSNumber)?.intValue == id
        }
    }

    private static func line(for object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private static func parseResponse(_ data: Data) throws -> UsageSnapshot {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageClientError.invalidResponse
        }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["id"] as? NSNumber)?.intValue == 2 else {
                continue
            }

            if let error = json["error"] as? [String: Any] {
                throw UsageClientError.server(error["message"] as? String ?? "未知错误")
            }

            guard let result = json["result"] as? [String: Any],
                  let limits = preferredLimits(from: result) else {
                throw UsageClientError.invalidResponse
            }

            let credits = limits["credits"] as? [String: Any]
            let resets = result["rateLimitResetCredits"] as? [String: Any]

            return UsageSnapshot(
                primary: parseWindow(limits["primary"]),
                secondary: parseWindow(limits["secondary"]),
                plan: limits["planType"] as? String,
                creditBalance: credits?["balance"] as? String,
                unlimitedCredits: credits?["unlimited"] as? Bool ?? false,
                resetCredits: (resets?["availableCount"] as? NSNumber)?.intValue ?? 0,
                fetchedAt: Date()
            )
        }

        throw UsageClientError.invalidResponse
    }

    private static func preferredLimits(from result: [String: Any]) -> [String: Any]? {
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            return codex
        }
        return result["rateLimits"] as? [String: Any]
    }

    private static func parseWindow(_ value: Any?) -> RateWindow? {
        guard let object = value as? [String: Any],
              let used = (object["usedPercent"] as? NSNumber)?.intValue else {
            return nil
        }
        let duration = (object["windowDurationMins"] as? NSNumber)?.intValue
        let resetTimestamp = (object["resetsAt"] as? NSNumber)?.doubleValue
        return RateWindow(
            usedPercent: used,
            durationMinutes: duration,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func findCodexExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var kimiSnapshot: KimiUsageSnapshot?
    @Published var errorMessage: String?
    @Published var kimiErrorMessage: String?
    @Published var isLoading = false
    @Published private(set) var codexActivity: WorkActivitySnapshot = .unknown
    @Published private(set) var kimiActivity: WorkActivitySnapshot = .unknown
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var menuIconSize: Double {
        didSet { UserDefaults.standard.set(menuIconSize, forKey: "menuIconSize") }
    }
    @Published var menuTextSize: Double {
        didSet { UserDefaults.standard.set(menuTextSize, forKey: "menuTextSize") }
    }
    @Published var touchBarEnabled: Bool {
        didSet {
            UserDefaults.standard.set(touchBarEnabled, forKey: "touchBarEnabled")
            if touchBarEnabled && showIPRegionTouchBar {
                refreshIPRegion(force: true)
            } else {
                stopIPRegionUpdates()
            }
        }
    }
    @Published var touchBarAlwaysVisible: Bool {
        didSet { UserDefaults.standard.set(touchBarAlwaysVisible, forKey: "touchBarAlwaysVisible") }
    }
    @Published var touchBarLayout: TouchBarLayout {
        didSet {
            UserDefaults.standard.set(touchBarLayout.rawValue, forKey: "touchBarLayout")
            let maximum = touchBarLayout.lightSizeRange.upperBound
            if touchBarLightSize > maximum {
                touchBarLightSize = maximum
            }
        }
    }
    @Published var touchBarBarWidth: Double {
        didSet {
            let clamped = min(110, max(60, touchBarBarWidth))
            if touchBarBarWidth != clamped {
                touchBarBarWidth = clamped
                return
            }
            UserDefaults.standard.set(touchBarBarWidth, forKey: "touchBarBarWidth")
        }
    }
    @Published var touchBarLightSize: Double {
        didSet {
            let clamped = min(25, max(6, touchBarLightSize))
            if touchBarLightSize != clamped {
                touchBarLightSize = clamped
                return
            }
            UserDefaults.standard.set(touchBarLightSize, forKey: "touchBarLightSize")
        }
    }
    @Published var showIPRegionTouchBar: Bool {
        didSet {
            UserDefaults.standard.set(showIPRegionTouchBar, forKey: "showIPRegionTouchBar")
            if showIPRegionTouchBar && touchBarEnabled {
                refreshIPRegion(force: true)
            } else {
                stopIPRegionUpdates()
            }
        }
    }
    @Published private(set) var ipRegionSnapshot: IPRegionSnapshot = .unknown
    @Published private(set) var touchBarRecoveryRequest = 0
    @Published private(set) var nextRefreshAt: Date?
    @Published var refreshIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes")
            scheduleNextRefresh()
        }
    }

    private var refreshTask: Task<Void, Never>?
    private var quotaResetTask: Task<Void, Never>?
    private var ipRegionFetchTask: Task<Void, Never>?
    private var ipRegionScheduleTask: Task<Void, Never>?
    private let activityMonitor = WorkActivityMonitor()

    init() {
        let defaults = UserDefaults.standard
        menuIconSize = min(20, max(16, defaults.object(forKey: "menuIconSize") as? Double ?? 16))
        menuTextSize = defaults.object(forKey: "menuTextSize") as? Double ?? 12
        refreshIntervalMinutes = min(60, max(1, defaults.object(forKey: "refreshIntervalMinutes") as? Int ?? 5))
        touchBarEnabled = defaults.object(forKey: "touchBarEnabled") as? Bool ?? true
        touchBarAlwaysVisible = defaults.object(forKey: "touchBarAlwaysVisible") as? Bool ?? true
        touchBarBarWidth = min(110, max(60, defaults.object(forKey: "touchBarBarWidth") as? Double ?? 94))
        touchBarLightSize = min(25, max(6, defaults.object(forKey: "touchBarLightSize") as? Double ?? 12))
        touchBarLayout = TouchBarLayout(rawValue: defaults.string(forKey: "touchBarLayout") ?? "") ?? .compact
        showIPRegionTouchBar = defaults.object(forKey: "showIPRegionTouchBar") as? Bool ?? true
        // Property observers do not run during initialization. Persist the
        // clamped value so preferences saved by an older, wider range are
        // migrated to the current 60–110 pt range immediately.
        defaults.set(touchBarBarWidth, forKey: "touchBarBarWidth")
        refresh()
        scheduleWorkStatusCheck()
    }

    deinit {
        refreshTask?.cancel()
        quotaResetTask?.cancel()
        ipRegionFetchTask?.cancel()
        ipRegionScheduleTask?.cancel()
        activityMonitor.stop()
    }

    var codexQuotaReset: (name: String, date: Date)? {
        QuotaReset.next([("5h", snapshot?.primary), ("周", snapshot?.secondary)])
    }

    var kimiQuotaReset: (name: String, date: Date)? {
        QuotaReset.next([("5h", kimiSnapshot?.fiveHour),
                         (kimiSnapshot?.periodTitle == "本月 Code" ? "月" : "周", kimiSnapshot?.period),
                         ("会员月", kimiSnapshot?.monthlyTotal)])
    }

    func refresh(forceIPRegion: Bool = false) {
        guard !isLoading else { return }
        refreshIPRegion(force: forceIPRegion)
        refreshTask?.cancel()
        quotaResetTask?.cancel()
        nextRefreshAt = nil
        isLoading = true
        errorMessage = nil
        kimiErrorMessage = nil

        Task {
            let codexTask = Task.detached(priority: .userInitiated) {
                Result { try CodexUsageClient.fetch() }
            }
            let kimiTask = Task.detached(priority: .userInitiated) {
                Result { try KimiUsageClient.fetch() }
            }
            switch await codexTask.value {
            case .success(let value): snapshot = value
            case .failure(let error): errorMessage = error.localizedDescription
            }
            switch await kimiTask.value {
            case .success(let value): kimiSnapshot = value
            case .failure(let error): kimiErrorMessage = error.localizedDescription
            }
            isLoading = false
            scheduleNextRefresh()
            scheduleQuotaResetRefresh()
        }
    }

    private func scheduleNextRefresh() {
        refreshTask?.cancel()
        guard !isLoading else { return }
        let interval = TimeInterval(refreshIntervalMinutes * 60)
        nextRefreshAt = Date().addingTimeInterval(interval)
        refreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func scheduleQuotaResetRefresh() {
        quotaResetTask?.cancel()
        guard let reset = [codexQuotaReset?.date, kimiQuotaReset?.date].compactMap({ $0 }).min() else { return }
        let delay = max(1, reset.timeIntervalSinceNow + 2)
        quotaResetTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func scheduleWorkStatusCheck() {
        activityMonitor.start { [weak self] codex, kimi in
            Task { @MainActor [weak self] in
                if self?.codexActivity != codex { self?.codexActivity = codex }
                if self?.kimiActivity != kimi { self?.kimiActivity = kimi }
            }
        }
    }

    func refreshIPRegion(force: Bool = false) {
        guard touchBarEnabled, showIPRegionTouchBar else {
            stopIPRegionUpdates()
            return
        }
        guard ipRegionSnapshot.state != .checking else { return }
        if !force,
           let checkedAt = ipRegionSnapshot.checkedAt,
           Date().timeIntervalSince(checkedAt) < 600 {
            return
        }

        ipRegionFetchTask?.cancel()
        ipRegionScheduleTask?.cancel()
        ipRegionSnapshot = ipRegionSnapshot.checking
        ipRegionFetchTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                IPRegionClient.fetch()
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.touchBarEnabled,
                  self.showIPRegionTouchBar else { return }
            switch result {
            case .success(let snapshot):
                self.ipRegionSnapshot = snapshot
                self.scheduleIPRegionRefresh(after: 600)
            case .failure(let state):
                self.ipRegionSnapshot = IPRegionSnapshot(
                    regionCode: nil,
                    regionName: "—",
                    state: state,
                    checkedAt: Date()
                )
                self.scheduleIPRegionRefresh(after: 120)
            }
            self.ipRegionFetchTask = nil
        }
    }

    private func scheduleIPRegionRefresh(after delay: TimeInterval) {
        ipRegionScheduleTask?.cancel()
        guard touchBarEnabled, showIPRegionTouchBar else { return }
        ipRegionScheduleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.refreshIPRegion(force: true)
        }
    }

    private func stopIPRegionUpdates() {
        ipRegionFetchTask?.cancel()
        ipRegionFetchTask = nil
        ipRegionScheduleTask?.cancel()
        ipRegionScheduleTask = nil
        ipRegionSnapshot = .unknown
    }

    func openDashboard() {
        NSWorkspace.shared.open(usageDashboardURL)
    }

    func openKimiDashboard() {
        NSWorkspace.shared.open(kimiDashboardURL)
    }

    func openCodexApp() {
        openApp(bundleIdentifier: "com.openai.codex", fallbackPath: "/Applications/ChatGPT.app")
    }

    func openKimiApp() {
        openApp(bundleIdentifier: "com.kimi.code.desktop", fallbackPath: "/Applications/Kimi Code.app")
    }

    private func openApp(bundleIdentifier: String, fallbackPath: String) {
        AppLauncher.open(bundleIdentifier: bundleIdentifier, fallbackPath: fallbackPath) { [weak self] error in
            if let error { self?.errorMessage = error.localizedDescription }
        }
    }

    func saveKimiAPIKey(_ key: String) {
        if KimiKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kimiErrorMessage = nil
            refresh()
        } else {
            kimiErrorMessage = "无法将 Kimi Code API Key 保存到钥匙串。"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            errorMessage = "无法更新开机启动设置：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func reconnectTouchBar() {
        touchBarRecoveryRequest += 1
    }
}

struct UsageWindowRow: View {
    let title: String
    let window: RateWindow?

    private var color: Color {
        guard let remaining = window?.remainingPercent else { return .secondary }
        if remaining <= 10 { return .red }
        if remaining <= 25 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(window.map { "\($0.remainingPercent)% 剩余" } ?? "不可用")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(color)
            }

            ProgressView(value: Double(window?.remainingPercent ?? 0), total: 100)
                .tint(color)

            if let reset = window?.resetsAt {
                Text("重置：\(Self.dateFormatter.string(from: reset))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

@MainActor
enum ServiceIcon {
    enum Kind { case codex, kimi }

    private static let codexAppIcon = icon(
        bundleIdentifier: "com.openai.codex", fallbackPath: "/Applications/ChatGPT.app"
    )
    private static let kimiAppIcon = icon(
        bundleIdentifier: "com.kimi.code.desktop", fallbackPath: "/Applications/Kimi Code.app"
    )

    private static func icon(bundleIdentifier: String, fallbackPath: String) -> NSImage {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            ?? URL(fileURLWithPath: fallbackPath)
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func image(_ kind: Kind, size: CGFloat) -> NSImage {
        let source = kind == .codex ? codexAppIcon : kimiAppIcon
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: size, height: size)
        image.isTemplate = false
        return image
    }
}

struct UsagePopover: View {
    @ObservedObject var store: UsageStore
    let onShowSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("用量概览")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("Codex  +  Kimi Code")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            serviceCard(name: "Codex", mark: .codex, tint: .blue, activity: store.codexActivity) {
                if let snapshot = store.snapshot {
                    UsageWindowRow(title: "5 小时", window: snapshot.primary)
                    UsageWindowRow(title: "每周", window: snapshot.secondary)
                    HStack(spacing: 10) {
                        Text(snapshot.plan?.uppercased() ?? "")
                        Text(creditLabel(snapshot))
                        if snapshot.resetCredits > 0 {
                            Text("重置次数 \(snapshot.resetCredits)")
                        }
                        Spacer()
                        Text(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                } else {
                    errorRow(store.errorMessage ?? "正在获取额度…")
                }
                if let message = store.errorMessage, store.snapshot != nil {
                    errorRow(message)
                }
            }

            serviceCard(name: "Kimi Code", mark: .kimi, tint: .blue, activity: store.kimiActivity) {
                if let kimi = store.kimiSnapshot {
                    UsageWindowRow(title: "5 小时", window: kimi.fiveHour)
                    if kimi.period != nil {
                        UsageWindowRow(title: kimi.periodTitle, window: kimi.period)
                    }
                    if kimi.monthlyTotal != nil {
                        UsageWindowRow(title: "会员月总量", window: kimi.monthlyTotal)
                    }
                    Text("更新于 \(kimi.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    errorRow(store.kimiErrorMessage ?? "正在获取额度…")
                }
                if let message = store.kimiErrorMessage, store.kimiSnapshot != nil {
                    errorRow(message)
                }
            }

            Divider()

            HStack {
                Button {
                    store.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)

                Button {
                    store.openDashboard()
                } label: {
                    Text("Codex 官网")
                }

                Button {
                    store.openKimiDashboard()
                } label: {
                    Text("Kimi 官网")
                }

                Spacer()

                Button {
                    onShowSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("设置")
                .fixedSize()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("退出")
                .fixedSize()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func serviceCard<Content: View>(
        name: String,
        mark: ServiceIcon.Kind,
        tint: Color,
        activity: WorkActivitySnapshot,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(nsImage: ServiceIcon.image(mark, size: 16))
                    .frame(width: 16, height: 16)
                Text(name)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Spacer()
                Circle()
                    .fill(activity.state == .unknown ? Color.clear : Color(nsColor: activity.state == .idle ? .secondaryLabelColor : activity.state.color))
                    .overlay(Circle().strokeBorder(activity.state == .unknown ? Color.gray : .clear, lineWidth: 1))
                    .frame(width: 5.5, height: 5.5)
                Text(activity.state.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(activity.detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.20)))
        .tint(tint)
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func creditLabel(_ snapshot: UsageSnapshot) -> String {
        if snapshot.unlimitedCredits { return "积分无限" }
        if let balance = snapshot.creditBalance { return "积分 \(balance)" }
        return "无积分信息"
    }

}

enum TouchBarSystemModal {
    private static let touchBarIdentifier = "com.local.codexkimiusagebar.touchbar.refresh-anchor-v5"
    private static let legacyTouchBarIdentifiers = (1...4).map {
        "com.local.codexkimiusagebar.touchbar.refresh-anchor-v\($0)"
    }
    private static let presentSimpleSelector = NSSelectorFromString(
        "presentSystemModalTouchBar:systemTrayItemIdentifier:"
    )
    private static let presentSelector = NSSelectorFromString(
        "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"
    )
    private static let dismissSelector = NSSelectorFromString("dismissSystemModalTouchBar:")
    private static let addSystemTrayItemSelector = NSSelectorFromString("addSystemTrayItem:")
    private static let removeSystemTrayItemSelector = NSSelectorFromString("removeSystemTrayItem:")
    private static var systemTrayItem: NSCustomTouchBarItem?
    private static var systemTrayButton: NSButton?
    private static var systemTrayRegistered = false
    private static var reassertWorkItems: [DispatchWorkItem] = []
    private static let dfrFoundationHandle: UnsafeMutableRawPointer? = {
        let paths = [
            "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
            "/System/Library/PrivateFrameworks/DFRFoundation.framework/Versions/A/DFRFoundation"
        ]
        for path in paths {
            if let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
                return handle
            }
        }
        return nil
    }()

    static var isAvailable: Bool {
        (class_getClassMethod(NSTouchBar.self, presentSimpleSelector) != nil ||
            class_getClassMethod(NSTouchBar.self, presentSelector) != nil) &&
            class_getClassMethod(NSTouchBar.self, dismissSelector) != nil
    }

    /// Registers one stable Control Strip item for the modal session.  macOS
    /// clears the system-tray presence when a modal bar is dismissed or when
    /// ControlStrip is relaunched; reasserting it keeps the next presentation
    /// from becoming a successful-but-invisible no-op.
    static func registerSystemTrayItem(target: NSObject, action: Selector) {
        let button: NSButton
        if let existing = systemTrayButton {
            button = existing
        } else {
            // A visible system-tray anchor is required to keep the normal
            // Control Strip beside the modal bar.  Make that anchor the real
            // refresh action instead of a second panel-present button; this
            // removes the flashing grid control without wasting its slot.
            button = NSButton(
                image: NSImage(
                    systemSymbolName: "arrow.clockwise",
                    accessibilityDescription: "刷新额度"
                ) ?? NSImage(size: NSSize(width: 16, height: 16)),
                target: target,
                action: action
            )
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.toolTip = "立即同步 Codex 与 Kimi Code 额度"
            button.setButtonType(.momentaryChange)
            systemTrayButton = button

            let item = NSCustomTouchBarItem(
                identifier: NSTouchBarItem.Identifier(touchBarIdentifier)
            )
            item.view = button
            systemTrayItem = item
        }

        button.target = target
        button.action = action
        repairSystemTrayRegistration()
    }

    static func setRefreshEnabled(_ enabled: Bool) {
        systemTrayButton?.isEnabled = enabled
        systemTrayButton?.contentTintColor = enabled ? .labelColor : .tertiaryLabelColor
    }

    static func unregisterSystemTrayItem() {
        guard let item = systemTrayItem else { return }
        let itemClass = NSTouchBarItem.self as AnyObject
        if systemTrayRegistered, itemClass.responds(to: removeSystemTrayItemSelector) {
            _ = itemClass.perform(removeSystemTrayItemSelector, with: item)
        }
        setControlStripPresence(false)
        systemTrayRegistered = false
        reassertWorkItems.forEach { $0.cancel() }
        reassertWorkItems.removeAll()
    }

    static func present(_ touchBar: NSTouchBar) -> Bool {
        registerSystemTrayItemIfNeeded()
        // The two-argument private selector is the stable path used by
        // current Touch Bar utilities.  Keep the placement form as a
        // fallback for older macOS releases that do not expose it.
        if let method = class_getClassMethod(NSTouchBar.self, presentSimpleSelector) {
            typealias Function = @convention(c) (AnyObject, Selector, NSTouchBar, NSString) -> Void
            let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
            function(
                NSTouchBar.self,
                presentSimpleSelector,
                touchBar,
                touchBarIdentifier as NSString
            )
            return true
        }

        guard let method = class_getClassMethod(NSTouchBar.self, presentSelector) else {
            return false
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            NSTouchBar,
            Int,
            NSString
        ) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(
            NSTouchBar.self,
            presentSelector,
            touchBar,
            1,
            touchBarIdentifier as NSString
        )
        return true
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        guard let method = class_getClassMethod(NSTouchBar.self, dismissSelector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBar.self, dismissSelector, touchBar)
        reassertSystemTrayPresence()
    }

    static func reassertSystemTrayPresence() {
        registerSystemTrayItemIfNeeded()
        setControlStripPresence(true)

        // ControlStrip can respawn asynchronously.  Reassert only the small
        // tray registration; do not remount the full bar, which is what caused
        // the visible flash and evicted a healthy modal session in the old
        // recovery loop.
        reassertWorkItems.forEach { $0.cancel() }
        reassertWorkItems.removeAll()
        for delay in [0.25, 1.0] {
            let work = DispatchWorkItem {
                registerSystemTrayItemIfNeeded()
                setControlStripPresence(true)
            }
            reassertWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Replaces the process-local tray registration after login, wake or a
    /// manual reconnect. ControlStrip may discard its copy while this process
    /// still believes the item is registered, so a Boolean alone is not a
    /// sufficient health check.
    static func repairSystemTrayRegistration() {
        clearLegacyControlStripPresence()
        replaceSystemTrayItemRegistration()
        setControlStripPresence(true)

        reassertWorkItems.forEach { $0.cancel() }
        reassertWorkItems.removeAll()
        let work = DispatchWorkItem {
            replaceSystemTrayItemRegistration()
            setControlStripPresence(true)
        }
        reassertWorkItems.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private static func registerSystemTrayItemIfNeeded() {
        guard let item = systemTrayItem else {
            return
        }
        let itemClass = NSTouchBarItem.self as AnyObject
        if !systemTrayRegistered, itemClass.responds(to: addSystemTrayItemSelector) {
            _ = itemClass.perform(addSystemTrayItemSelector, with: item)
            systemTrayRegistered = true
        }
    }

    private static func replaceSystemTrayItemRegistration() {
        guard let item = systemTrayItem else { return }
        let itemClass = NSTouchBarItem.self as AnyObject
        if itemClass.responds(to: removeSystemTrayItemSelector) {
            _ = itemClass.perform(removeSystemTrayItemSelector, with: item)
        }
        systemTrayRegistered = false
        registerSystemTrayItemIfNeeded()
    }

    private static func clearLegacyControlStripPresence() {
        for identifier in legacyTouchBarIdentifiers {
            setControlStripPresence(identifier: identifier, present: false)
        }
    }

    private static func setControlStripPresence(_ present: Bool) {
        setControlStripPresence(identifier: touchBarIdentifier, present: present)
    }

    private static func setControlStripPresence(identifier: String, present: Bool) {
        typealias PresenceFunction = @convention(c) (CFString, Bool) -> Void
        guard let symbol = dfrSymbol("DFRElementSetControlStripPresenceForIdentifier") else { return }
        let function = unsafeBitCast(symbol, to: PresenceFunction.self)
        function(identifier as CFString, present)
    }

    private static func dfrSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        if let handle = dfrFoundationHandle, let symbol = dlsym(handle, name) {
            return symbol
        }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }
}

private extension NSTouchBarItem.Identifier {
    static let modalEscapeSpacer = NSTouchBarItem.Identifier("com.local.codexkimiusagebar.modal-escape-spacer")
    static let codexLaunch = NSTouchBarItem.Identifier("com.local.codexkimiusagebar.open-codex")
    static let codexUsage = NSTouchBarItem.Identifier("com.local.codexkimiusagebar.codex")
    static let kimiLaunch = NSTouchBarItem.Identifier("com.local.codexkimiusagebar.open-kimi")
    static let kimiUsage = NSTouchBarItem.Identifier("com.local.codexkimiusagebar.kimi")
}

@MainActor
final class UsageTouchBarController: NSObject, NSTouchBarDelegate {
    private var touchBar = NSTouchBar()

    private let store: UsageStore
    private var codexPrimaryLabel: NSTextField?
    private var codexPeriodLabel: NSTextField?
    private var kimiPrimaryLabel: NSTextField?
    private var kimiPeriodLabel: NSTextField?
    private var codexLight: WorkStatusLightView?
    private var kimiLight: WorkStatusLightView?
    private var codexBars: QuotaBarUsageView?
    private var kimiBars: QuotaBarUsageView?
    private var ipRegionView: IPRegionTouchBarView?
    private var subscriptions = Set<AnyCancellable>()
    private var recoveryTask: Task<Void, Never>?
    private var anchorMigrationTask: DispatchWorkItem?
    private var reconnectInFlight = false
    private var systemModalVisible = false
    private var isSleeping = false

    init(store: UsageStore) {
        self.store = store
        super.init()
        configureTouchBar()
        TouchBarSystemModal.registerSystemTrayItem(
            target: self,
            action: #selector(refreshUsage)
        )

        Publishers.CombineLatest3(store.$snapshot, store.$kimiSnapshot, store.$isLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateItems() }
            .store(in: &subscriptions)

        Publishers.CombineLatest(store.$codexActivity, store.$kimiActivity)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateLights() }
            .store(in: &subscriptions)

        Publishers.CombineLatest(store.$touchBarEnabled, store.$touchBarAlwaysVisible)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.applyPresentationMode() }
            .store(in: &subscriptions)

        store.$touchBarLayout
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildForLayoutChange() }
            .store(in: &subscriptions)

        store.$touchBarBarWidth
            .receive(on: RunLoop.main)
            .sink { [weak self] width in
                self?.codexBars?.setBarWidth(CGFloat(width))
                self?.kimiBars?.setBarWidth(CGFloat(width))
            }
            .store(in: &subscriptions)

        store.$touchBarLightSize
            .receive(on: RunLoop.main)
            .sink { [weak self] size in
                let diameter = CGFloat(size)
                self?.codexLight?.setDiameter(diameter)
                self?.kimiLight?.setDiameter(diameter)
                self?.codexBars?.setLightDiameter(diameter)
                self?.kimiBars?.setLightDiameter(diameter)
            }
            .store(in: &subscriptions)

        store.$ipRegionSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.ipRegionView?.update(snapshot) }
            .store(in: &subscriptions)

        store.$showIPRegionTouchBar
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildForLayoutChange() }
            .store(in: &subscriptions)

        store.$touchBarRecoveryRequest
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.forceReconnect() }
            .store(in: &subscriptions)

        let workspaceNotifications: [NSNotification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        for name in workspaceNotifications {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.isSleeping = false
                    self?.store.refreshIPRegion(force: true)
                    TouchBarSystemModal.repairSystemTrayRegistration()
                    self?.scheduleRecovery()
                }
                .store(in: &subscriptions)
        }

        let sleepNotifications: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification
        ]
        for name in sleepNotifications {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.suspendPresentation() }
                .store(in: &subscriptions)
        }

        updateItems()
    }

    deinit {
        recoveryTask?.cancel()
        anchorMigrationTask?.cancel()
        if systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
        }
        TouchBarSystemModal.unregisterSystemTrayItem()
    }

    private func configureTouchBar() {
        touchBar.delegate = self
        touchBar.escapeKeyReplacementItemIdentifier = .modalEscapeSpacer
        touchBar.customizationIdentifier = NSTouchBar.CustomizationIdentifier(
            "com.local.codexkimiusagebar.usage-v2"
        )
        // Keep the system-modal bar composable.  Without the proxy, AppKit
        // may evict the bar when another responder becomes Touch Bar eligible
        // (the common "works briefly, then disappears" symptom).
        var identifiers: [NSTouchBarItem.Identifier] = [
            .codexLaunch,
            .codexUsage,
            .fixedSpaceSmall,
            .kimiLaunch,
            .kimiUsage
        ]
        identifiers.append(.fixedSpaceSmall)
        identifiers.append(.otherItemsProxy)
        touchBar.defaultItemIdentifiers = identifiers
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        switch identifier {
        case .modalEscapeSpacer:
            let item = NSCustomTouchBarItem(identifier: identifier)
            if store.showIPRegionTouchBar {
                let regionView = IPRegionTouchBarView(frame: .zero)
                regionView.onTap = { [weak self] in self?.store.refreshIPRegion(force: true) }
                regionView.update(store.ipRegionSnapshot)
                ipRegionView = regionView
                item.view = regionView
                item.customizationLabel = "IP 属地与网络状态"
                return item
            }
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 30))
            view.alphaValue = 0
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 1).isActive = true
            view.heightAnchor.constraint(equalToConstant: 30).isActive = true
            item.view = view
            return item
        case .codexLaunch:
            let item = NSButtonTouchBarItem(identifier: identifier,
                                            image: ServiceIcon.image(.codex, size: 22),
                                            target: self,
                                            action: #selector(openCodex))
            item.customizationLabel = "打开 Codex"
            return item
        case .codexUsage:
            if store.touchBarLayout == .quotaBars {
                let item = NSCustomTouchBarItem(identifier: identifier)
                let view = QuotaBarUsageView(frame: .zero)
                view.setBarWidth(CGFloat(store.touchBarBarWidth))
                view.setLightDiameter(CGFloat(store.touchBarLightSize))
                codexBars = view
                item.view = view
                item.customizationLabel = "Codex 额度条"
                updateItems()
                return item
            }
            let result = makeUsageItem(identifier: identifier, title: "Codex")
            result.light.setDiameter(CGFloat(store.touchBarLightSize))
            codexPrimaryLabel = result.primary
            codexPeriodLabel = result.period
            codexLight = result.light
            updateItems()
            return result.item
        case .kimiLaunch:
            let item = NSButtonTouchBarItem(identifier: identifier,
                                            image: ServiceIcon.image(.kimi, size: 22),
                                            target: self,
                                            action: #selector(openKimi))
            item.customizationLabel = "打开 Kimi Code"
            return item
        case .kimiUsage:
            if store.touchBarLayout == .quotaBars {
                let item = NSCustomTouchBarItem(identifier: identifier)
                let view = QuotaBarUsageView(frame: .zero)
                view.setBarWidth(CGFloat(store.touchBarBarWidth))
                view.setLightDiameter(CGFloat(store.touchBarLightSize))
                kimiBars = view
                item.view = view
                item.customizationLabel = "Kimi Code 额度条"
                updateItems()
                return item
            }
            let result = makeUsageItem(identifier: identifier, title: "Kimi")
            result.light.setDiameter(CGFloat(store.touchBarLightSize))
            kimiPrimaryLabel = result.primary
            kimiPeriodLabel = result.period
            kimiLight = result.light
            updateItems()
            return result.item
        default:
            return nil
        }
    }

    private func makeUsageItem(
        identifier: NSTouchBarItem.Identifier,
        title: String
    ) -> (item: NSCustomTouchBarItem, primary: NSTextField, period: NSTextField, light: WorkStatusLightView) {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let primary = NSTextField(labelWithString: "5h —  周 —")
        primary.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        primary.alignment = .left
        primary.lineBreakMode = .byClipping
        primary.setContentCompressionResistancePriority(.required, for: .horizontal)

        let period = NSTextField(labelWithString: "重置 —")
        period.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        period.textColor = .secondaryLabelColor
        period.alignment = .left
        period.lineBreakMode = .byClipping

        let light = WorkStatusLightView(frame: .zero)
        let row = NSStackView(views: [light, primary])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        let stack = NSStackView(views: [row, period])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 1, bottom: 0, right: 1)
        stack.widthAnchor.constraint(equalToConstant: 128).isActive = true
        stack.heightAnchor.constraint(lessThanOrEqualToConstant: 26).isActive = true

        item.view = stack
        item.customizationLabel = "\(title) 额度"
        return (item, primary, period, light)
    }

    private func updateItems() {
        let codexPeriodName = "周"
        let kimiPeriodName = store.kimiSnapshot?.periodTitle == "本月 Code" ? "月" : "周"
        codexBars?.setBarWidth(CGFloat(store.touchBarBarWidth))
        kimiBars?.setBarWidth(CGFloat(store.touchBarBarWidth))
        codexBars?.setLightDiameter(CGFloat(store.touchBarLightSize))
        kimiBars?.setLightDiameter(CGFloat(store.touchBarLightSize))
        codexLight?.setDiameter(CGFloat(store.touchBarLightSize))
        kimiLight?.setDiameter(CGFloat(store.touchBarLightSize))
        codexBars?.update(primary: store.snapshot?.primary,
                          period: store.snapshot?.secondary,
                          periodName: codexPeriodName,
                          activity: store.codexActivity)
        kimiBars?.update(primary: store.kimiSnapshot?.fiveHour,
                         period: store.kimiSnapshot?.period,
                         periodName: kimiPeriodName,
                         activity: store.kimiActivity)
        updateUsage(
            name: "Codex",
            primary: store.snapshot?.primary,
            period: store.snapshot?.secondary,
            periodName: "周",
            reset: store.codexQuotaReset,
            primaryLabel: codexPrimaryLabel,
            periodLabel: codexPeriodLabel
        )
        updateUsage(
            name: "Kimi",
            primary: store.kimiSnapshot?.fiveHour,
            period: store.kimiSnapshot?.period,
            periodName: store.kimiSnapshot?.periodTitle == "本月 Code" ? "月" : "周",
            reset: store.kimiQuotaReset,
            primaryLabel: kimiPrimaryLabel,
            periodLabel: kimiPeriodLabel
        )
        updateLights()
        ipRegionView?.update(store.ipRegionSnapshot)
        TouchBarSystemModal.setRefreshEnabled(!store.isLoading)
    }

    private func updateUsage(
        name: String,
        primary: RateWindow?,
        period: RateWindow?,
        periodName: String,
        reset: (name: String, date: Date)?,
        primaryLabel: NSTextField?,
        periodLabel: NSTextField?
    ) {
        let primaryValue = primary.map { "\($0.remainingPercent)%" } ?? "—"
        let periodValue = period.map { "\($0.remainingPercent)%" } ?? "—"
        primaryLabel?.stringValue = "5h \(primaryValue)  \(periodName) \(periodValue)"
        primaryLabel?.toolTip = "\(name)：5 小时剩余 \(primaryValue)；\(periodName)额度剩余 \(periodValue)"
        periodLabel?.stringValue = "↻ \(QuotaReset.label(reset))"
        periodLabel?.toolTip = "\(name) 下次额度重置：\(QuotaReset.label(reset))"
    }

    private func updateLights() {
        codexLight?.update(store.codexActivity)
        kimiLight?.update(store.kimiActivity)
        codexBars?.update(primary: store.snapshot?.primary,
                          period: store.snapshot?.secondary,
                          periodName: "周",
                          activity: store.codexActivity)
        kimiBars?.update(primary: store.kimiSnapshot?.fiveHour,
                         period: store.kimiSnapshot?.period,
                         periodName: store.kimiSnapshot?.periodTitle == "本月 Code" ? "月" : "周",
                         activity: store.kimiActivity)
        let enabled = store.touchBarEnabled && !isSleeping
        codexLight?.setAnimationsEnabled(enabled)
        kimiLight?.setAnimationsEnabled(enabled)
        codexBars?.setAnimationsEnabled(enabled)
        kimiBars?.setAnimationsEnabled(enabled)
        ipRegionView?.setAnimationsEnabled(enabled)
    }

    private var shouldShowSystemModal: Bool {
        store.touchBarEnabled && store.touchBarAlwaysVisible && !isSleeping && TouchBarSystemModal.isAvailable
    }

    private func applyPresentationMode() {
        updateLights()
        if shouldShowSystemModal {
            // A system-modal Touch Bar must be the only bar owned by this
            // accessory app.  Keeping the same object on NSApp.touchBar lets
            // a settings window win the responder-chain race and silently
            // replace the modal session when another app becomes frontmost.
            NSApp.touchBar = nil
            TouchBarSystemModal.reassertSystemTrayPresence()
            scheduleRecovery()
            scheduleAnchorMigrationIfNeeded()
        } else {
            NSApp.touchBar = store.touchBarEnabled ? touchBar : nil
            recoveryTask?.cancel()
            recoveryTask = nil
            reconnectInFlight = false
            if systemModalVisible {
                TouchBarSystemModal.dismiss(touchBar)
                systemModalVisible = false
            }
        }
    }

    private func suspendPresentation() {
        isSleeping = true
        updateLights()
        recoveryTask?.cancel()
        recoveryTask = nil
        if systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
            systemModalVisible = false
        }
        NSApp.touchBar = nil
    }

    private func forceReconnect() {
        guard !reconnectInFlight else { return }
        reconnectInFlight = true
        recoveryTask?.cancel()
        recoveryTask = nil
        if systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
            systemModalVisible = false
        }
        NSApp.touchBar = nil

        // Reconnect is deliberately non-destructive.  Restarting ControlStrip
        // tears down the very session we are trying to repair, producing the
        // old one-frame flash.  Re-register the system-tray anchor, build one
        // fresh modal bar, and let the normal wake recovery handle only a
        // genuinely missing presentation.
        TouchBarSystemModal.repairSystemTrayRegistration()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.shouldShowSystemModal else {
                self?.reconnectInFlight = false
                return
            }
            self.rebuildPresentation()
            self.reconnectInFlight = false
            self.scheduleRecovery(afterForcedReconnect: true)
        }
    }

    private func scheduleRecovery(afterForcedReconnect: Bool = false) {
        recoveryTask?.cancel()
        guard shouldShowSystemModal else { return }
        recoveryTask = Task { @MainActor [weak self] in
            // The Touch Bar service can become ready several seconds after
            // login, lid-open, or a manual service restart.
            let delays: [UInt64] = afterForcedReconnect
                ? [1_500_000_000, 4_000_000_000]
                : [300_000_000, 1_500_000_000, 4_000_000_000]
            for delay in delays {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard !Task.isCancelled, let self, self.shouldShowSystemModal else { return }

                // Do not remount an already-presented system modal.  The
                // private NSTouchBar.isVisible value is not a reliable pixel
                // health check here: it can be false while the physical bar
                // is already rendering, and remounting then evicts the
                // working session a few seconds later.
                if self.systemModalVisible { return }
                self.rebuildPresentation()
            }
        }
    }

    private func scheduleAnchorMigrationIfNeeded() {
        let migrationVersion = 5
        guard UserDefaults.standard.integer(forKey: "touchBarAnchorMigrationVersion") < migrationVersion,
              anchorMigrationTask == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldShowSystemModal else {
                self?.anchorMigrationTask = nil
                return
            }
            TouchBarSystemModal.reassertSystemTrayPresence()
            self.rebuildPresentation()
            UserDefaults.standard.set(migrationVersion, forKey: "touchBarAnchorMigrationVersion")
            self.anchorMigrationTask = nil
        }
        anchorMigrationTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func rebuildPresentation() {
        if systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
            systemModalVisible = false
        }
        NSApp.touchBar = nil
        codexPrimaryLabel = nil
        codexPeriodLabel = nil
        kimiPrimaryLabel = nil
        kimiPeriodLabel = nil
        codexLight?.setAnimationsEnabled(false)
        kimiLight?.setAnimationsEnabled(false)
        codexLight = nil
        kimiLight = nil
        codexBars = nil
        kimiBars = nil
        ipRegionView?.setAnimationsEnabled(false)
        ipRegionView = nil
        touchBar = NSTouchBar()
        configureTouchBar()
        NSApp.touchBar = shouldShowSystemModal ? nil : touchBar
        systemModalVisible = TouchBarSystemModal.present(touchBar)
    }

    private func rebuildForLayoutChange() {
        let wasVisible = systemModalVisible
        if wasVisible {
            TouchBarSystemModal.dismiss(touchBar)
            systemModalVisible = false
        }
        NSApp.touchBar = nil
        codexPrimaryLabel = nil
        codexPeriodLabel = nil
        kimiPrimaryLabel = nil
        kimiPeriodLabel = nil
        codexLight = nil
        kimiLight = nil
        codexBars = nil
        kimiBars = nil
        ipRegionView?.setAnimationsEnabled(false)
        ipRegionView = nil
        touchBar = NSTouchBar()
        configureTouchBar()
        NSApp.touchBar = shouldShowSystemModal ? nil : (store.touchBarEnabled ? touchBar : nil)
        if wasVisible && shouldShowSystemModal {
            systemModalVisible = TouchBarSystemModal.present(touchBar)
        }
    }

    @objc private func refreshUsage() {
        store.refresh(forceIPRegion: true)
    }

    @objc private func refreshIPRegion() {
        store.refreshIPRegion(force: true)
    }

    @objc private func openCodex() {
        store.openCodexApp()
    }

    @objc private func openKimi() {
        store.openKimiApp()
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var kimiAPIKey = ""
    @State private var hasKimiAPIKey = KimiKeychain.read() != nil

    var body: some View {
        Form {
            Section("菜单栏") {
                settingSlider(
                    title: "标志大小",
                    value: $store.menuIconSize,
                    range: 16...20,
                    suffix: "\(Int(store.menuIconSize)) pt"
                )

                settingSlider(
                    title: "文字字号",
                    value: $store.menuTextSize,
                    range: 8...18,
                    suffix: "\(Int(store.menuTextSize)) pt"
                )
            }

            Section("通用") {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
                Stepper("后台同步间隔：\(store.refreshIntervalMinutes) 分钟", value: $store.refreshIntervalMinutes, in: 1...60)
            }

            Section("Kimi Code") {
                SecureField("粘贴 Kimi Code API Key", text: $kimiAPIKey)
                HStack {
                    Button("保存到钥匙串") {
                        store.saveKimiAPIKey(kimiAPIKey)
                        hasKimiAPIKey = KimiKeychain.read() != nil
                        kimiAPIKey = ""
                    }
                    .disabled(kimiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKimiAPIKey {
                        Button("移除 API Key") {
                            store.saveKimiAPIKey("")
                            hasKimiAPIKey = false
                        }
                    }
                }
            }

            Section("Touch Bar") {
                Toggle("显示额度", isOn: $store.touchBarEnabled)
                Toggle("在所有 App 中常驻显示", isOn: $store.touchBarAlwaysVisible)
                    .disabled(!store.touchBarEnabled || !TouchBarSystemModal.isAvailable)
                Toggle("显示 IP 属地状态环", isOn: $store.showIPRegionTouchBar)
                    .disabled(!store.touchBarEnabled)
                Picker("布局样式", selection: $store.touchBarLayout) {
                    ForEach(TouchBarLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                settingSlider(
                    title: "余量条长度",
                    value: $store.touchBarBarWidth,
                    range: 60...110,
                    step: nil,
                    suffix: "\(Int(store.touchBarBarWidth)) pt"
                )
                .disabled(store.touchBarLayout != .quotaBars)
                settingSlider(
                    title: "状态灯大小",
                    value: $store.touchBarLightSize,
                    range: store.touchBarLayout.lightSizeRange,
                    step: nil,
                    suffix: String(format: "%.1f pt", store.touchBarLightSize)
                )
                Button("立即重新连接 Touch Bar", systemImage: "arrow.triangle.2.circlepath") {
                    store.reconnectTouchBar()
                }
                .disabled(!store.touchBarEnabled || !store.touchBarAlwaysVisible || !TouchBarSystemModal.isAvailable)

            }
        }
        .formStyle(.grouped)
        .padding(4)
        .frame(width: 470, height: 590)
    }

    @ViewBuilder
    private func settingSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = 1,
        suffix: String
    ) -> some View {
        HStack {
            Text(title)
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
            Text(suffix)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

enum MenuStatusLightImage {
    static func image(for snapshot: WorkActivitySnapshot, size: CGFloat = 8) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: NSSize(width: size, height: size))
        let glowColor = snapshot.state.color.withAlphaComponent(snapshot.state == .idle ? 0.20 : 0.28)
        glowColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25)).fill()

        let coreBounds = bounds.insetBy(dx: max(1.5, size * 0.25), dy: max(1.5, size * 0.25))
        snapshot.state.color.setFill()
        NSBezierPath(ovalIn: coreBounds).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = UsageStore()

    private var statusItem: NSStatusItem?
    private var usageMenu: NSMenu?
    private var menuHostingView: NSHostingView<UsagePopover>?
    private var touchBarController: UsageTouchBarController?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        touchBarController = UsageTouchBarController(store: store)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.alignment = .center
        }

        let menu = makeUsageMenu()
        usageMenu = menu
        item.menu = menu

        Publishers.CombineLatest3(store.$snapshot, store.$kimiSnapshot, store.$isLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.updateStatusItem()
            }
            .store(in: &subscriptions)

        Publishers.CombineLatest(store.$menuIconSize, store.$menuTextSize)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusItem() }
            .store(in: &subscriptions)

        Publishers.CombineLatest(store.$codexActivity, store.$kimiActivity)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusItem() }
            .store(in: &subscriptions)

        updateStatusItem()

    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        resizeMenuContent()

        let pointSize = CGFloat(store.menuTextSize)
        let textFont = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .medium)
        let baselineOffset = -max(0.5, round(pointSize * 0.08 * 2) / 2)
        button.font = textFont
        let title = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: NSColor.labelColor,
            .baselineOffset: baselineOffset
        ]
        func appendMark(
            _ kind: ServiceIcon.Kind,
            value: String,
            activity: WorkActivitySnapshot
        ) {
            let size = CGFloat(store.menuIconSize)
            let attachment = NSTextAttachment()
            attachment.image = ServiceIcon.image(kind, size: size)
            attachment.bounds = NSRect(x: 0, y: baselineOffset, width: size, height: size)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " ", attributes: attributes))
            let light = NSTextAttachment()
            light.image = MenuStatusLightImage.image(for: activity)
            light.bounds = NSRect(x: 0, y: baselineOffset + 1, width: 8, height: 8)
            title.append(NSAttributedString(attachment: light))
            title.append(NSAttributedString(string: " \(value)", attributes: attributes))
        }
        let codexFive = store.snapshot?.primary.map { "\($0.remainingPercent)%" } ?? "–"
        let kimiFive = store.kimiSnapshot?.fiveHour.map { "\($0.remainingPercent)%" } ?? "–"
        let codexReset = QuotaReset.label(store.codexQuotaReset)
        let kimiReset = QuotaReset.label(store.kimiQuotaReset)
        appendMark(.codex,
                   value: "\(codexFive) ↻\(codexReset)",
                   activity: store.codexActivity)
        title.append(NSAttributedString(string: "  ·  ", attributes: attributes))
        appendMark(.kimi,
                   value: "\(kimiFive) ↻\(kimiReset)",
                   activity: store.kimiActivity)
        button.image = nil
        button.attributedTitle = title
        button.toolTip = "Codex：\(store.codexActivity.state.label)，\(codexFive)，下次额度更新 \(codexReset)；Kimi：\(store.kimiActivity.state.label)，\(kimiFive)，下次额度更新 \(kimiReset)"
    }

    private func makeUsageMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 340
        menu.delegate = self

        let contentItem = NSMenuItem()
        let hostingView = NSHostingView(rootView: UsagePopover(
            store: store,
            onShowSettings: { [weak self] in self?.requestSettings() }
        ))
        menuHostingView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        contentItem.view = hostingView
        menu.addItem(contentItem)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        resizeMenuContent()
    }

    private func resizeMenuContent() {
        guard let hostingView = menuHostingView else { return }
        hostingView.setFrameSize(hostingView.fittingSize)
    }

    private func requestSettings() {
        usageMenu?.cancelTrackingWithoutAnimation()
        presentSettingsWindow()
    }

    private func presentSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let shown = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if !shown {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

@main
struct CodexUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--enable-login-item") {
            do {
                try SMAppService.mainApp.register()
                print("LOGIN_ITEM \(SMAppService.mainApp.status == .enabled ? "enabled" : "needs approval")")
                exit(EXIT_SUCCESS)
            } catch {
                fputs("LOGIN_ITEM_ERROR \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.contains("--login-status") {
            print("LOGIN_ITEM \(SMAppService.mainApp.status == .enabled ? "enabled" : "not enabled")")
            exit(EXIT_SUCCESS)
        }
        if CommandLine.arguments.contains("--activity-status") {
            let (codex, kimi) = WorkActivityMonitor.once()
            print("ACTIVITY Codex=\(codex.state.label) (\(codex.detail)) Kimi=\(kimi.state.label) (\(kimi.detail))")
            exit(EXIT_SUCCESS)
        }
        if CommandLine.arguments.contains("--ip-region-status") {
            switch IPRegionClient.fetch() {
            case .success(let snapshot):
                print("IP_REGION \(snapshot.regionCode ?? "--") \(snapshot.regionName) online")
                exit(EXIT_SUCCESS)
            case .failure(let state):
                fputs("IP_REGION_ERROR \(state.rawValue)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.contains("--self-test") {
            do {
                let codex = try CodexUsageClient.fetch()
                let kimi = try KimiUsageClient.fetch()
                let codexFive = codex.primary?.remainingPercent.description ?? "n/a"
                let codexWeek = codex.secondary?.remainingPercent.description ?? "n/a"
                let kimiFive = kimi.fiveHour?.remainingPercent.description ?? "n/a"
                let kimiPeriod = kimi.period?.remainingPercent.description ?? "n/a"
                let codexReset = QuotaReset.label(QuotaReset.next([("5h", codex.primary), ("周", codex.secondary)]))
                let kimiReset = QuotaReset.label(QuotaReset.next([("5h", kimi.fiveHour),
                                                                  (kimi.periodTitle == "本月 Code" ? "月" : "周", kimi.period),
                                                                  ("会员月", kimi.monthlyTotal)]))
                print("OK Codex 5h=\(codexFive)% weekly=\(codexWeek)% reset=\(codexReset) | Kimi 5h=\(kimiFive)% \(kimi.periodTitle)=\(kimiPeriod)% reset=\(kimiReset)")
                exit(EXIT_SUCCESS)
            } catch {
                fputs("ERROR \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
    }

    var body: some Scene {
        Settings {
            SettingsView(store: appDelegate.store)
        }
    }
}
