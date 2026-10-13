import AppKit
import Darwin
import Foundation

enum WorkState: String, Sendable, Equatable {
    case active, waiting, idle, completed, failed, unknown

    var color: NSColor {
        switch self {
        case .active, .completed: .systemGreen
        case .waiting: .systemOrange
        case .failed: .systemRed
        case .idle: .white
        case .unknown: .systemGray
        }
    }

    var label: String {
        switch self {
        case .active: "正在处理"
        case .waiting: "等你处理"
        case .idle: "空闲"
        case .completed: "刚刚完成"
        case .failed: "任务失败"
        case .unknown: "状态未知"
        }
    }
}

struct WorkActivitySnapshot: Sendable, Equatable {
    var state: WorkState
    var detail: String
    var observedAt: Date?
    var activeCount = 0
    var waitingCount = 0

    static let unknown = WorkActivitySnapshot(state: .unknown, detail: "正在检查本机任务", observedAt: nil)
}

enum WorkService: Sendable, Equatable { case codex, kimi }

struct WorkJournalState: Sendable {
    var phase: WorkState = .unknown
    var observedAt: Date?
    var changedAt: Date?
    var turnID: String?
    var pendingQuestion = false
    var retrying = false
    // work_changed is authoritative for the whole Kimi session, including background work.
    var hasKimiWorkStatus = false

    mutating func consume(_ root: [String: Any], service: WorkService) {
        switch service {
        case .codex: consumeCodex(root)
        case .kimi: consumeKimi(root)
        }
    }

    private mutating func consumeCodex(_ root: [String: Any]) {
        guard root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return }
        let date = WorkJournalReader.date(root["timestamp"])
        switch type {
        case "task_started":
            phase = .active
            turnID = payload["turn_id"] as? String
            observedAt = date
            pendingQuestion = false
        case "task_complete", "turn_aborted", "task_failed":
            if let current = turnID, let ending = payload["turn_id"] as? String, current != ending { return }
            let reason = payload["reason"] as? String ?? ""
            phase = type == "task_complete" ? .completed
                : type == "task_failed" || ["failed", "error"].contains(reason) ? .failed : .idle
            observedAt = date
            pendingQuestion = false
        case "thread_status_changed":
            // Only explicit runtime flags establish waiting; optional async questions do not.
            guard let status = payload["status"] as? [String: Any] else { return }
            applyCodexRuntimeStatus(status, at: date)
        default: return
        }
    }

    mutating func applyCodexRuntimeStatus(_ status: [String: Any], at date: Date?) {
        switch status["type"] as? String {
        case "active":
            let flags = status["activeFlags"] as? [String] ?? []
            phase = flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") ? .waiting : .active
        case "idle": phase = .idle
        case "systemError": phase = .failed
        default: phase = .unknown
        }
        observedAt = date
    }

    private mutating func consumeKimi(_ root: [String: Any]) {
        guard let envelope = root["envelope"] as? [String: Any],
              let type = envelope["type"] as? String,
              let payload = envelope["payload"] as? [String: Any] else { return }
        let date = WorkJournalReader.date(envelope["timestamp"] ?? payload["time"])
        switch type {
        case "event.session.work_changed":
            guard let busy = payload["busy"] as? Bool else { return }
            hasKimiWorkStatus = true
            let pending = payload["pending_interaction"] as? String ?? "none"
            pendingQuestion = pending == "approval" || pending == "question"
            retrying = false
            if pendingQuestion { phase = .waiting }
            else if busy { phase = .active }
            else {
                switch payload["last_turn_reason"] as? String {
                case "failed": phase = .failed
                case "completed": phase = .completed
                default: phase = .idle
                }
            }
            observedAt = date
        case "event.approval.requested", "event.question.requested":
            pendingQuestion = true
            phase = .waiting
            observedAt = date
        case "event.approval.resolved", "event.question.answered", "event.question.dismissed":
            pendingQuestion = false
            phase = .active
            observedAt = date
        case "turn.started", "prompt.started", "turn.step.started":
            if !pendingQuestion { phase = .active }
            retrying = false
            observedAt = date
        case "turn.step.retrying":
            if !pendingQuestion { phase = .active }
            retrying = true
            observedAt = date
        case "turn.ended":
            // An individual agent ending must not clear another agent's busy/waiting state.
            guard !hasKimiWorkStatus else { return }
            let reason = payload["reason"] as? String
            guard reason == "failed" || reason == "completed" || reason == "cancelled" else { return }
            phase = reason == "failed" ? .failed : reason == "completed" ? .completed : .idle
            pendingQuestion = false
            retrying = false
            observedAt = date
        default: return
        }
    }
}

final class WorkJournalReader {
    private(set) var record = WorkJournalState()
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var pending = Data()
    private var skippingOversizedLine = false

    func update(_ url: URL, service: WorkService) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return }
        if inode != number || size < offset {
            inode = number
            offset = 0
            record = WorkJournalState()
            pending.removeAll(keepingCapacity: true)
            skippingOversizedLine = false
        }
        record.changedAt = attributes[.modificationDate] as? Date
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        while let chunk = try? handle.read(upToCount: 262_144), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            consumeBytes(chunk, service: service)
        }
    }

    private func consumeBytes(_ bytes: Data, service: WorkService) {
        var start = bytes.startIndex
        for newline in bytes.indices where bytes[newline] == 0x0A {
            if !skippingOversizedLine {
                pending.append(bytes[start..<newline])
                parseLine(service: service)
            }
            pending.removeAll(keepingCapacity: true)
            skippingOversizedLine = false
            start = newline + 1
        }
        if start < bytes.endIndex, !skippingOversizedLine {
            pending.append(bytes[start..<bytes.endIndex])
            if pending.count > 2_097_152 {
                pending.removeAll(keepingCapacity: true)
                skippingOversizedLine = true
            }
        }
    }

    private func parseLine(service: WorkService) {
        // Avoid decoding transcripts and large tool outputs. Only lifecycle records are used.
        let candidate: Bool
        switch service {
        case .codex:
            candidate = pending.range(of: Data("\"event_msg\"".utf8)) != nil &&
                ["task_started", "task_complete", "turn_aborted", "task_failed", "thread_status_changed"]
                .contains { pending.range(of: Data("\"\($0)\"".utf8)) != nil }
        case .kimi:
            candidate = pending.range(of: Data("\"envelope\"".utf8)) != nil &&
                ["event.session.work_changed", "event.approval.", "event.question.",
                 "turn.started", "turn.ended", "prompt.started", "turn.step.started", "turn.step.retrying"]
                .contains { pending.range(of: Data($0.utf8)) != nil }
        }
        guard candidate, let root = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] else { return }
        record.consume(root, service: service)
    }

    static func date(_ value: Any?) -> Date? {
        if let timestamp = value as? NSNumber {
            let seconds = timestamp.doubleValue
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum WorkActivityReducer {
    static func reduce(_ records: [WorkJournalState], service: WorkService,
                       runtimeStartedAt: Date?, now: Date = Date()) -> WorkActivitySnapshot {
        guard let runtimeStartedAt else {
            return WorkActivitySnapshot(state: .unknown, detail: "应用未运行，或未连接本机任务", observedAt: nil)
        }
        let current = records.filter { ($0.observedAt ?? .distantPast) >= runtimeStartedAt.addingTimeInterval(-2) }
        guard !current.isEmpty else {
            return WorkActivitySnapshot(state: .unknown, detail: "尚未收到本次运行的任务状态", observedAt: nil)
        }
        let stale = current.filter {
            service == .codex && ($0.phase == .active || $0.phase == .waiting) &&
                now.timeIntervalSince($0.changedAt ?? $0.observedAt ?? .distantPast) > 600
        }
        let fresh = current.filter { record in !stale.contains { $0.observedAt == record.observedAt && $0.turnID == record.turnID } }
        let waiting = fresh.filter { $0.phase == .waiting }
        let active = fresh.filter { $0.phase == .active }
        let latest = current.max { ($0.observedAt ?? .distantPast) < ($1.observedAt ?? .distantPast) }!
        let observedAt = latest.observedAt
        // Codex journals have no runtime heartbeat; stale activity remains unknown, never idle.
        if !waiting.isEmpty {
            return WorkActivitySnapshot(state: .waiting, detail: "\(waiting.count) 个任务等你批准或回答",
                                        observedAt: observedAt, activeCount: active.count, waitingCount: waiting.count)
        }
        if !active.isEmpty {
            let retrying = active.contains { $0.retrying }
            return WorkActivitySnapshot(state: .active,
                                        detail: retrying ? "正在自动重试" : "\(active.count) 个本机任务正在处理",
                                        observedAt: observedAt, activeCount: active.count)
        }
        if !stale.isEmpty || latest.phase == .unknown {
            return WorkActivitySnapshot(state: .unknown, detail: "任务状态长时间未更新或无法确认", observedAt: observedAt)
        }
        if latest.phase == .failed {
            return WorkActivitySnapshot(state: .failed, detail: "最近一次任务失败", observedAt: observedAt)
        }
        if latest.phase == .completed, now.timeIntervalSince(observedAt ?? .distantPast) < 3 {
            return WorkActivitySnapshot(state: .completed, detail: "任务已完成", observedAt: observedAt)
        }
        return WorkActivitySnapshot(state: .idle, detail: "本次运行的已知任务均已结束", observedAt: observedAt)
    }
}

final class WorkActivityMonitor: @unchecked Sendable {
    typealias Update = @Sendable (WorkActivitySnapshot, WorkActivitySnapshot) -> Void
    private let queue = DispatchQueue(label: "com.local.codexkimiusagebar.activity", qos: .utility)
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var readers: [URL: WorkJournalReader] = [:]
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var completionExpiry: DispatchWorkItem?
    private var onUpdate: Update?
    private var stopped = false

    func start(onUpdate: @escaping Update) {
        queue.async { [self] in
            self.onUpdate = onUpdate
            refresh()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            debounce?.cancel()
            completionExpiry?.cancel()
            timer?.cancel()
            sources.values.forEach { $0.cancel() }
            sources.removeAll()
            readers.removeAll()
            onUpdate = nil
        }
    }

    @discardableResult
    private func refresh(watching: Bool = true) -> (WorkActivitySnapshot, WorkActivitySnapshot) {
        guard !stopped else { return (.unknown, .unknown) }
        let codexRuntime = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .first?.launchDate
        let kimiRuntime = runningKimiServerStart()
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.kimi.code.desktop").first?.launchDate
        let codexDirectory = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let kimiDirectory = home.appendingPathComponent(".kimi-code/server/events", isDirectory: true)
        let codexFiles = files(in: codexDirectory, since: codexRuntime)
        let kimiFiles = files(in: kimiDirectory, since: kimiRuntime).filter { $0.lastPathComponent.hasPrefix("session_") }
        let selected = Set(codexFiles + kimiFiles)
        for url in Array(readers.keys) where !selected.contains(url) {
            readers.removeValue(forKey: url)
        }
        for (service, urls) in [(WorkService.codex, codexFiles), (.kimi, kimiFiles)] {
            for url in urls {
                let reader = readers[url] ?? WorkJournalReader()
                reader.update(url, service: service)
                readers[url] = reader
                if watching { watch(url) }
            }
        }
        let wantedSources = selected.union([codexDirectory, kimiDirectory])
        for url in Array(sources.keys) where !wantedSources.contains(url) {
            sources.removeValue(forKey: url)?.cancel()
        }
        if watching {
            watch(codexDirectory)
            watch(kimiDirectory)
        }
        let codex = WorkActivityReducer.reduce(codexFiles.compactMap { readers[$0]?.record }, service: .codex,
                                               runtimeStartedAt: codexRuntime)
        let kimi = WorkActivityReducer.reduce(kimiFiles.compactMap { readers[$0]?.record }, service: .kimi,
                                              runtimeStartedAt: kimiRuntime)
        onUpdate?(codex, kimi)
        completionExpiry?.cancel()
        if watching, let completedAt = [codex, kimi].filter({ $0.state == .completed })
            .compactMap(\.observedAt).min() {
            let expiry = DispatchWorkItem { [weak self] in self?.refresh() }
            completionExpiry = expiry
            queue.asyncAfter(deadline: .now() + max(0.05, completedAt.addingTimeInterval(3).timeIntervalSinceNow), execute: expiry)
        }
        return (codex, kimi)
    }

    private func watch(_ url: URL) {
        guard sources[url] == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend, .delete, .rename],
                                                               queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if let flags = self.sources[url]?.data, !flags.intersection([.delete, .rename]).isEmpty {
                self.sources.removeValue(forKey: url)?.cancel()
            }
            self.debounce?.cancel()
            let pending = DispatchWorkItem { [weak self] in self?.refresh() }
            self.debounce = pending
            self.queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: pending)
        }
        source.setCancelHandler { close(descriptor) }
        sources[url] = source
        source.resume()
    }

    private func files(in directory: URL, since start: Date?) -> [URL] {
        guard let start else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                           options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in entries where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= start.addingTimeInterval(-2) else { continue }
            result.append(url)
        }
        return result
    }

    private func runningKimiServerStart() -> Date? {
        let directory = home.appendingPathComponent(".kimi-code/server/instances", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return files.compactMap { url -> Date? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let instance = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (instance["pid"] as? NSNumber)?.int32Value, pid > 1, kill(pid, 0) == 0,
                  let heartbeat = WorkJournalReader.date(instance["heartbeat_at"]),
                  heartbeat.timeIntervalSinceNow > -90 else { return nil }
            return WorkJournalReader.date(instance["started_at"])
        }.min()
    }

    static func once() -> (WorkActivitySnapshot, WorkActivitySnapshot) {
        let monitor = WorkActivityMonitor()
        return monitor.refresh(watching: false)
    }
}
