import AppKit
import FCPSubtitleCore
import Foundation
import SwiftUI
import UserNotifications

/// Thread-safe cancellation flag polled by the background transcription loop.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

struct QueueFile: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case decoding(Double)
        case transcribing(Double)
        case done
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var status: Status = .pending
    var segments: [SubtitleSegment] = []
    var peaks: [Float] = []
    var elapsed: Double = 0
    var workStarted: Date?

    var name: String { url.lastPathComponent }
    var isSubtitleImport: Bool { url.pathExtension.lowercased() == "srt" }
    var isBusy: Bool {
        switch status {
        case .decoding, .transcribing: return true
        default: return false
        }
    }
}

/// A persistent auto-correction rule applied after recognition (e.g. 字母→字幕).
struct ReplaceRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var find: String
    var replace: String
}

enum ProofreadPhase: Equatable {
    case idle
    case running(done: Int, total: Int)
    case finished(Int)
    case failed(String)
}

/// Outcome of the 测试连接 button. `ok` carries the model name the endpoint
/// echoed back, which catches "wrong model name silently ignored" setups.
enum LLMTestResult: Equatable {
    case ok(String)
    case failed(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var files: [QueueFile] = []
    @Published var selectedFileID: UUID?
    @Published var dictionary: [ReplaceRule] = []
    @Published var lastExport: (url: URL, label: String)?

    @Published var proofread: ProofreadPhase = .idle
    @Published var corrections: [LLMCorrection] = []
    @Published var acceptedCorrections: Set<UUID> = []
    private var proofreadFileID: UUID?
    private var proofreadTask: Task<Void, Never>?

    @AppStorage("fps") var fps = "25"
    @AppStorage("fontName") var fontName = "PingFang SC"
    @AppStorage("fontSize") var fontSize = 60
    @AppStorage("splitLongLines") var splitLongLines = true
    @AppStorage("maxLineChars") var maxLineChars = 18
    @AppStorage("exportFormat") var exportFormat = "fcpxml"
    @AppStorage("language") var language = "auto"
    @AppStorage("playSoundOnFinish") var playSoundOnFinish = true
    @AppStorage("autoApplyDictionary") var autoApplyDictionary = true

    @AppStorage("llmBaseURL") var llmBaseURL = "https://api.openai.com/v1"
    @AppStorage("llmAPIKey") var llmAPIKey = ""
    @AppStorage("llmModel") var llmModel = "gpt-4o-mini"
    @AppStorage("llmBatchSize") var llmBatchSize = 30
    @AppStorage("llmUseProxy") var llmUseProxy = false

    static let languages: [(code: String, label: String)] = [
        ("auto", "自动检测"), ("zh", "中文"), ("en", "英语"),
        ("ja", "日语"), ("ko", "韩语"), ("yue", "粤语"),
    ]

    private var processTask: Task<Void, Never>?
    private var cancelFlag = CancelFlag()
    private var activityToken: NSObjectProtocol?

    private static let sessionURL = ModelStore.downloadDir
        .deletingLastPathComponent()
        .appendingPathComponent("session.json")
    private static let dictionaryURL = ModelStore.downloadDir
        .deletingLastPathComponent()
        .appendingPathComponent("dictionary.json")

    init() {
        restoreSession()
        loadDictionary()
    }

    var selectedIndex: Int? {
        files.firstIndex { $0.id == selectedFileID }
    }

    var selectedFile: QueueFile? {
        selectedIndex.map { files[$0] }
    }

    var isWorking: Bool {
        files.contains(where: \.isBusy)
    }

    var windowTitle: String {
        if let file = files.first(where: \.isBusy) {
            let position = (files.firstIndex(of: file) ?? 0) + 1
            switch file.status {
            case .decoding(let f):
                return "解码 \(Int(f * 100))% · \(file.name) (\(position)/\(files.count))"
            case .transcribing(let f):
                return "识别 \(Int(f * 100))% · \(file.name) (\(position)/\(files.count))"
            default: break
            }
        }
        return "FCP 字幕"
    }

    func eta(for file: QueueFile) -> String? {
        guard case .transcribing(let fraction) = file.status,
            fraction > 0.03,
            let started = file.workStarted
        else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        let remaining = elapsed / fraction * (1 - fraction)
        guard remaining.isFinite, remaining >= 1 else { return nil }
        let m = Int(remaining) / 60
        let s = Int(remaining) % 60
        return m > 0 ? "剩余约 \(m) 分 \(s) 秒" : "剩余约 \(s) 秒"
    }

    // MARK: - Queue

    func enqueue(urls: [URL]) {
        var newFiles: [QueueFile] = []
        for url in urls {
            var file = QueueFile(url: url)
            if file.isSubtitleImport {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    file.segments = applyDictionary(SRTParser.parse(content))
                    file.status = .done
                } else {
                    file.status = .failed("无法读取 SRT 文件")
                }
            }
            newFiles.append(file)
        }
        guard !newFiles.isEmpty else { return }
        files.append(contentsOf: newFiles)
        if selectedFileID == nil { selectedFileID = newFiles.first?.id }
        startNextIfIdle()
        saveSession()
    }

    func removeFile(id: UUID) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        if files[index].isBusy { cancelCurrent() }
        files.remove(at: index)
        if selectedFileID == id { selectedFileID = files.first?.id }
        saveSession()
    }

    func clearAll() {
        cancelCurrent()
        files.removeAll()
        selectedFileID = nil
        saveSession()
    }

    private func startNextIfIdle() {
        guard !isWorking, processTask == nil else { return }
        guard let index = files.firstIndex(where: { $0.status == .pending }) else {
            queueFinished()
            return
        }
        process(at: index)
    }

    func cancelCurrent() {
        cancelFlag.set()
    }

    func retry(id: UUID) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].status = .pending
        startNextIfIdle()
    }

    private func process(at index: Int) {
        guard let models = ModelStore.locateModels() else {
            files[index].status = .failed("找不到模型文件,请先到「模型管理」页下载")
            return
        }

        let fileID = files[index].id
        let url = files[index].url
        files[index].status = .decoding(0)
        files[index].workStarted = Date()
        cancelFlag = CancelFlag()
        let flag = cancelFlag
        beginActivity()

        let lang = language
        let split = splitLongLines
        let maxChars = maxLineChars

        processTask = Task {
            let clock = ContinuousClock()
            let startTime = clock.now
            do {
                let samples = try await AudioDecoder.decode(url: url) { fraction in
                    Task { @MainActor [weak self] in
                        self?.updateStatus(fileID: fileID, status: .decoding(fraction))
                    }
                }
                let peaks = AudioDecoder.waveformPeaks(samples: samples)
                self.updateStatus(fileID: fileID, status: .transcribing(0))
                if let i = self.files.firstIndex(where: { $0.id == fileID }) {
                    self.files[i].peaks = peaks
                    self.files[i].workStarted = Date()  // restart clock for transcription ETA
                }

                var result = try await Task.detached(priority: .userInitiated) {
                    try Transcriber.transcribe(samples: samples, models: models, language: lang) { fraction in
                        Task { @MainActor [weak self] in
                            self?.updateStatus(fileID: fileID, status: .transcribing(fraction))
                        }
                    } shouldCancel: {
                        flag.isSet
                    }
                }.value
                if split {
                    result = SegmentSplitter.split(result, maxChars: maxChars)
                }
                result = self.applyDictionary(result)

                let duration = clock.now - startTime
                let elapsed = Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1e18
                self.finish(fileID: fileID, segments: result, elapsed: elapsed)
            } catch is CancellationError {
                self.updateStatus(fileID: fileID, status: .failed("已取消"))
            } catch {
                self.updateStatus(fileID: fileID, status: .failed(error.localizedDescription))
            }
            self.endActivity()
            self.processTask = nil
            self.startNextIfIdle()
        }
    }

    private func updateStatus(fileID: UUID, status: QueueFile.Status) {
        guard let index = files.firstIndex(where: { $0.id == fileID }) else { return }
        files[index].status = status
        updateDockProgress()
    }

    private func finish(fileID: UUID, segments: [SubtitleSegment], elapsed: Double) {
        guard let index = files.firstIndex(where: { $0.id == fileID }) else { return }
        files[index].segments = segments
        files[index].elapsed = elapsed
        files[index].status = .done
        notifyDone(fileName: files[index].name, count: segments.count, elapsed: elapsed)
        saveSession()
    }

    private func queueFinished() {
        updateDockProgress()
        guard files.contains(where: { $0.status == .done }), playSoundOnFinish else { return }
        NSSound(named: "Glass")?.play()
    }

    // MARK: - App Nap / Dock

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "语音识别处理中")
    }

    private func endActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private func updateDockProgress() {
        let busy = files.first(where: \.isBusy)
        let pending = files.filter { $0.status == .pending }.count
        DockProgress.update(
            fraction: busy.flatMap { file in
                if case .transcribing(let f) = file.status { return f }
                if case .decoding(let f) = file.status { return f * 0.2 }
                return nil
            },
            badge: pending > 0 ? "\(pending)" : nil)
    }

    // MARK: - Dictionary (auto-correction rules)

    func applyDictionary(_ segments: [SubtitleSegment]) -> [SubtitleSegment] {
        guard autoApplyDictionary, !dictionary.isEmpty else { return segments }
        var out = segments
        for i in out.indices {
            for rule in dictionary where !rule.find.isEmpty {
                out[i].text = out[i].text.replacingOccurrences(of: rule.find, with: rule.replace)
            }
        }
        return out
    }

    func addRule(find: String, replace: String) {
        guard !find.isEmpty else { return }
        if let existing = dictionary.firstIndex(where: { $0.find == find }) {
            dictionary[existing].replace = replace
        } else {
            dictionary.append(ReplaceRule(find: find, replace: replace))
        }
        saveDictionary()
    }

    func removeRule(id: UUID) {
        dictionary.removeAll { $0.id == id }
        saveDictionary()
    }

    /// Apply all dictionary rules to the selected file now; returns replacement count.
    func applyDictionaryToSelected() -> Int {
        guard let index = selectedIndex else { return 0 }
        var count = 0
        for i in files[index].segments.indices {
            for rule in dictionary where !rule.find.isEmpty {
                let before = files[index].segments[i].text
                let after = before.replacingOccurrences(of: rule.find, with: rule.replace)
                if before != after {
                    count += before.components(separatedBy: rule.find).count - 1
                    files[index].segments[i].text = after
                }
            }
        }
        if count > 0 { saveSession() }
        return count
    }

    private func loadDictionary() {
        guard let data = try? Data(contentsOf: Self.dictionaryURL),
            let rules = try? JSONDecoder().decode([ReplaceRule].self, from: data)
        else { return }
        dictionary = rules
    }

    private func saveDictionary() {
        try? FileManager.default.createDirectory(
            at: Self.dictionaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(dictionary) {
            try? data.write(to: Self.dictionaryURL)
        }
    }

    // MARK: - Segment editing

    func mergeWithPrevious(fileID: UUID, segmentID: UUID) {
        guard let fi = files.firstIndex(where: { $0.id == fileID }),
            let si = files[fi].segments.firstIndex(where: { $0.id == segmentID }),
            si > 0
        else { return }
        let current = files[fi].segments[si]
        var previous = files[fi].segments[si - 1]
        previous.duration = current.end - previous.start
        previous.text += current.text
        files[fi].segments[si - 1] = previous
        files[fi].segments.remove(at: si)
        saveSession()
    }

    func splitAtPunctuation(fileID: UUID, segmentID: UUID) {
        guard let fi = files.firstIndex(where: { $0.id == fileID }),
            let si = files[fi].segments.firstIndex(where: { $0.id == segmentID })
        else { return }
        let pieces = SegmentSplitter.split([files[fi].segments[si]], maxChars: 1)
        guard pieces.count > 1 else { return }
        files[fi].segments.replaceSubrange(si...si, with: pieces)
        saveSession()
    }

    func deleteSegment(fileID: UUID, segmentID: UUID) {
        guard let fi = files.firstIndex(where: { $0.id == fileID }) else { return }
        files[fi].segments.removeAll { $0.id == segmentID }
        saveSession()
    }

    func nudge(fileID: UUID, segmentID: UUID, startDelta: Double, durationDelta: Double) {
        guard let fi = files.firstIndex(where: { $0.id == fileID }),
            let si = files[fi].segments.firstIndex(where: { $0.id == segmentID })
        else { return }
        var seg = files[fi].segments[si]
        seg.start = max(0, seg.start + startDelta)
        seg.duration = max(0.1, seg.duration + durationDelta)
        files[fi].segments[si] = seg
        saveSession()
    }

    func replaceAll(find: String, replace: String) -> Int {
        guard let index = selectedIndex, !find.isEmpty else { return 0 }
        var count = 0
        for i in files[index].segments.indices {
            let before = files[index].segments[i].text
            let after = before.replacingOccurrences(of: find, with: replace)
            if before != after {
                count += before.components(separatedBy: find).count - 1
                files[index].segments[i].text = after
            }
        }
        if count > 0 { saveSession() }
        return count
    }

    // MARK: - Session persistence

    private struct SessionFile: Codable {
        let path: String
        let segments: [SubtitleSegment]
        let elapsed: Double
    }

    func saveSession() {
        let snapshot = files
            .filter { $0.status == .done && !$0.segments.isEmpty }
            .map { SessionFile(path: $0.url.path, segments: $0.segments, elapsed: $0.elapsed) }
        try? FileManager.default.createDirectory(
            at: Self.sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.sessionURL)
        }
    }

    private func restoreSession() {
        guard let data = try? Data(contentsOf: Self.sessionURL),
            let snapshot = try? JSONDecoder().decode([SessionFile].self, from: data)
        else { return }
        for item in snapshot where FileManager.default.fileExists(atPath: item.path) {
            var file = QueueFile(url: URL(fileURLWithPath: item.path))
            file.segments = item.segments
            file.elapsed = item.elapsed
            file.status = .done
            files.append(file)
        }
        selectedFileID = files.first?.id
    }

    // MARK: - Export

    private func subtitleContent(for file: QueueFile) -> (String, String) {
        let format = SubtitleFormat(rawValue: exportFormat) ?? .fcpxml
        let content = SubtitleExporter.export(
            segments: file.segments, format: format,
            fps: fps, font: fontName, fontSize: fontSize)
        return (content, format.fileExtension)
    }

    func exportSelected() {
        guard let file = selectedFile, !file.segments.isEmpty else { return }
        let (content, ext) = subtitleContent(for: file)

        let panel = NSSavePanel()
        panel.title = "导出字幕"
        panel.nameFieldStringValue =
            file.url.deletingPathExtension().lastPathComponent + "." + ext
        panel.directoryURL = file.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            lastExport = (url, "已导出 \(url.lastPathComponent)")
        } catch {
            updateStatus(fileID: file.id, status: .failed("导出失败: \(error.localizedDescription)"))
        }
    }

    func exportAll() {
        var count = 0
        var lastURL: URL?
        for file in files where file.status == .done && !file.segments.isEmpty {
            let (content, ext) = subtitleContent(for: file)
            let dest = file.url.deletingPathExtension().appendingPathExtension(ext)
            if (try? content.write(to: dest, atomically: true, encoding: .utf8)) != nil {
                count += 1
                lastURL = dest
            }
        }
        if let lastURL {
            lastExport = (lastURL, "已导出 \(count) 个文件到源目录")
        }
    }

    func revealLastExport() {
        guard let export = lastExport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([export.url])
    }

    /// Write the selection as FCPXML and hand it to Final Cut Pro, which opens
    /// its XML import dialog directly — saves the export/switch-app/locate-file
    /// round trip. Always FCPXML regardless of the chosen export format.
    func sendSelectedToFCP() {
        guard let file = selectedFile, !file.segments.isEmpty else { return }
        guard
            let fcp = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.FinalCut")
        else {
            presentAlert(
                title: "没有找到 Final Cut Pro",
                message: "请确认已安装 Final Cut Pro,或改用「导出当前」手动导入。")
            return
        }

        let content = SubtitleExporter.export(
            segments: file.segments, format: .fcpxml,
            fps: fps, font: fontName, fontSize: fontSize)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                file.url.deletingPathExtension().lastPathComponent + ".fcpxml")
        do {
            try content.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            presentAlert(title: "无法写入临时文件", message: error.localizedDescription)
            return
        }

        NSWorkspace.shared.open(
            [dest], withApplicationAt: fcp, configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.presentAlert(
                        title: "无法交给 Final Cut Pro", message: error.localizedDescription)
                } else {
                    self?.lastExport = (dest, "已发送到 Final Cut Pro")
                }
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - LLM proofreading

    var canProofread: Bool {
        selectedFile?.status == .done && !(selectedFile?.segments.isEmpty ?? true)
    }

    /// Reuses the proxy configured on the 模型管理 page so one setting covers
    /// both model downloads and API calls.
    private var sharedProxy: (host: String, port: Int)? {
        guard let raw = UserDefaults.standard.string(forKey: "proxyURL"),
            let url = URL(string: raw),
            let host = url.host
        else { return nil }
        return (host, url.port ?? 7899)
    }

    func startProofread() {
        guard let file = selectedFile, !file.segments.isEmpty else { return }
        proofreadTask?.cancel()

        let proxy = llmUseProxy ? sharedProxy : nil
        let config = LLMConfig(
            baseURL: llmBaseURL,
            apiKey: llmAPIKey,
            model: llmModel,
            batchSize: llmBatchSize,
            proxyHost: proxy?.host,
            proxyPort: proxy?.port ?? 0)

        let segments = file.segments
        proofreadFileID = file.id
        corrections = []
        acceptedCorrections = []
        proofread = .running(done: 0, total: 0)

        proofreadTask = Task {
            do {
                let found = try await LLMProofreader.proofread(segments: segments, config: config) {
                    done, total in
                    Task { @MainActor [weak self] in
                        self?.proofread = .running(done: done, total: total)
                    }
                }
                guard !Task.isCancelled else { return }
                self.corrections = found
                self.acceptedCorrections = Set(found.map(\.id))
                self.proofread = .finished(found.count)
            } catch {
                guard !Task.isCancelled else { return }
                self.proofread = .failed(error.localizedDescription)
            }
            self.proofreadTask = nil
        }
    }

    /// nil until 测试连接 has been pressed at least once.
    @Published var llmTestResult: LLMTestResult?
    @Published var llmTesting = false

    func testLLMConnection() {
        guard !llmTesting else { return }
        llmTesting = true
        llmTestResult = nil

        let proxy = llmUseProxy ? sharedProxy : nil
        let config = LLMConfig(
            baseURL: llmBaseURL,
            apiKey: llmAPIKey,
            model: llmModel,
            proxyHost: proxy?.host,
            proxyPort: proxy?.port ?? 0)

        Task {
            do {
                let model = try await LLMProofreader.testConnection(config: config)
                self.llmTestResult = .ok(model)
            } catch {
                self.llmTestResult = .failed(error.localizedDescription)
            }
            self.llmTesting = false
        }
    }

    func cancelProofread() {
        proofreadTask?.cancel()
        proofreadTask = nil
        proofread = .idle
    }

    /// Apply the checked suggestions. Lines edited by hand since the check ran
    /// are skipped rather than silently overwritten; the returned pair is
    /// (applied, skipped).
    @discardableResult
    func applyAcceptedCorrections() -> (applied: Int, skipped: Int) {
        guard let fileID = proofreadFileID,
            let fi = files.firstIndex(where: { $0.id == fileID })
        else { return (0, 0) }

        var applied = 0
        var skipped = 0
        for correction in corrections where acceptedCorrections.contains(correction.id) {
            guard let si = files[fi].segments.firstIndex(where: { $0.id == correction.id }) else {
                skipped += 1
                continue
            }
            guard files[fi].segments[si].text == correction.original else {
                skipped += 1
                continue
            }
            files[fi].segments[si].text = correction.suggested
            applied += 1
        }
        if applied > 0 { saveSession() }
        corrections.removeAll { acceptedCorrections.contains($0.id) }
        acceptedCorrections = []
        proofread = .finished(corrections.count)
        return (applied, skipped)
    }

    // MARK: - Notification

    private func notifyDone(fileName: String, count: Int, elapsed: Double) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "字幕生成完成"
            content.body = String(format: "%@:%d 句,耗时 %.1f 秒", fileName, count, elapsed)
            center.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
