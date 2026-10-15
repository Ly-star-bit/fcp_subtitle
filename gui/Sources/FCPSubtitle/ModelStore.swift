import FCPSubtitleCore
import Foundation
import SwiftUI

/// One downloadable model, possibly spanning multiple files (SenseVoice = model + tokens).
struct ModelItem: Identifiable {
    struct File {
        let relativePath: String  // under the models directory
        let hfPath: String?  // path under the HF repo, nil = direct URL
        let directURL: String?
        let sizeHint: String
    }

    let id: String
    let name: String
    let detail: String
    let files: [File]
}

@MainActor
final class ModelStore: ObservableObject {
    enum ItemState: Equatable {
        case notInstalled
        case bundled
        case downloaded
        case downloading(Double)  // 0...1
        case failed(String)
    }

    /// Live download stats shown next to the progress bar.
    struct DownloadInfo: Equatable {
        var speedText: String = ""
        var etaText: String = ""
    }

    static let hfRepo = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"

    static let items: [ModelItem] = [
        ModelItem(
            id: "sense-voice",
            name: "SenseVoice 识别模型",
            detail: "中/英/日/韩/粤 语音识别(int8 量化)",
            files: [
                .init(
                    relativePath: "sense-voice/model.int8.onnx",
                    hfPath: "model.int8.onnx", directURL: nil, sizeHint: "228 MB"),
                .init(
                    relativePath: "sense-voice/tokens.txt",
                    hfPath: "tokens.txt", directURL: nil, sizeHint: "0.3 MB"),
            ]),
        ModelItem(
            id: "silero-vad",
            name: "Silero VAD 模型",
            detail: "语音分段(字幕时间轴来源)",
            files: [
                .init(
                    relativePath: "silero_vad.onnx",
                    hfPath: nil,
                    directURL:
                        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
                    sizeHint: "0.6 MB")
            ]),
    ]

    /// Writable per-user model directory; takes priority over bundled models.
    static let downloadDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FCPSubtitle/models")
    }()

    /// Bundled (read-only) models inside the app, if present.
    static var bundledDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("models")
    }

    @Published var states: [String: ItemState] = [:]
    @Published var downloadInfo: [String: DownloadInfo] = [:]

    // Off by default: released builds ship without the recognition model, so
    // a fresh install has to download it with no setup. URLSession still
    // follows the system proxy settings.
    @AppStorage("useProxy") var useProxy = false
    @AppStorage("proxyURL") var proxyURL = ""
    @AppStorage("useHFMirror") var useHFMirror = true

    private var activeTasks: [String: FileDownloader] = [:]

    init() {
        refresh()
    }

    func refresh() {
        for item in Self.items {
            if case .downloading = states[item.id] { continue }
            states[item.id] = Self.installedState(of: item)
        }
    }

    static func installedState(of item: ModelItem) -> ItemState {
        func allPresent(in dir: URL) -> Bool {
            item.files.allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.relativePath).path)
            }
        }
        if allPresent(in: downloadDir) { return .downloaded }
        if let bundled = bundledDir, allPresent(in: bundled) { return .bundled }
        return .notInstalled
    }

    /// Model path resolution used by the transcription pipeline:
    /// downloaded (App Support) → bundled → dev checkout.
    static func locateModels() -> ModelPaths? {
        var candidates: [URL] = [downloadDir]
        if let bundled = bundledDir { candidates.append(bundled) }
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("models")
        candidates.append(devPath)

        // Allow mixing sources per file (e.g. VAD bundled, SenseVoice downloaded).
        func find(_ relative: String) -> String? {
            for dir in candidates {
                let p = dir.appendingPathComponent(relative).path
                if FileManager.default.fileExists(atPath: p) { return p }
            }
            return nil
        }
        guard
            let model = find("sense-voice/model.int8.onnx"),
            let tokens = find("sense-voice/tokens.txt"),
            let vad = find("silero_vad.onnx")
        else { return nil }
        return ModelPaths(senseVoiceModel: model, tokens: tokens, sileroVad: vad)
    }

    // MARK: - Download

    private func url(for file: ModelItem.File) -> URL? {
        if let direct = file.directURL { return URL(string: direct) }
        guard let hfPath = file.hfPath else { return nil }
        let host = useHFMirror ? "hf-mirror.com" : "huggingface.co"
        return URL(string: "https://\(host)/\(Self.hfRepo)/resolve/main/\(hfPath)")
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        if useProxy,
            let proxy = URL(string: proxyURL),
            let host = proxy.host
        {
            let port = proxy.port ?? 7899
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        return URLSession(configuration: config)
    }

    func download(_ item: ModelItem) {
        if case .downloading = states[item.id] { return }
        states[item.id] = .downloading(0)
        downloadInfo[item.id] = DownloadInfo()

        Task {
            do {
                let session = self.makeSession()
                let fileCount = Double(item.files.count)
                for (index, file) in item.files.enumerated() {
                    guard let url = self.url(for: file) else {
                        throw NSError(
                            domain: "FCPSubtitle", code: 30,
                            userInfo: [NSLocalizedDescriptionKey: "无效的下载地址"])
                    }
                    let dest = Self.downloadDir.appendingPathComponent(file.relativePath)
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

                    let base = Double(index) / fileCount
                    let downloader = FileDownloader(destination: dest) { progress in
                        Task { @MainActor in
                            self.states[item.id] = .downloading(base + progress.fraction / fileCount)
                            self.downloadInfo[item.id] = DownloadInfo(
                                speedText: progress.speedText, etaText: progress.etaText)
                        }
                    }
                    self.activeTasks[item.id] = downloader
                    try await downloader.download(url: url, session: session)
                }
                self.activeTasks[item.id] = nil
                self.downloadInfo[item.id] = nil
                self.states[item.id] = .downloaded
            } catch is CancellationError {
                self.activeTasks[item.id] = nil
                self.downloadInfo[item.id] = nil
                self.states[item.id] = Self.installedState(of: item)
            } catch {
                self.activeTasks[item.id] = nil
                self.downloadInfo[item.id] = nil
                self.states[item.id] = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload(_ item: ModelItem) {
        activeTasks[item.id]?.cancel()
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: Self.downloadDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Self.downloadDir])
    }
}

/// URLSessionDownloadDelegate-based downloader bridged to async/await, with
/// live speed/ETA reporting, cancellation, and post-download size verification.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Progress {
        let fraction: Double
        let speedText: String
        let etaText: String
    }

    private let destination: URL
    private let onProgress: @Sendable (Progress) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var expectedBytes: Int64 = 0

    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private var speed: Double = 0  // bytes/sec, smoothed

    init(destination: URL, onProgress: @escaping @Sendable (Progress) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(url: URL, session: URLSession) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            let task = session.downloadTask(with: url)
            task.delegate = self
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        expectedBytes = totalBytesExpectedToWrite

        let now = Date()
        let dt = now.timeIntervalSince(lastSampleTime)
        if dt >= 0.5 {
            let instant = Double(totalBytesWritten - lastSampleBytes) / dt
            speed = speed == 0 ? instant : speed * 0.7 + instant * 0.3
            lastSampleTime = now
            lastSampleBytes = totalBytesWritten
        }

        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        var speedText = ""
        var etaText = ""
        if speed > 0 {
            speedText = String(format: "%.1f MB/s", speed / 1e6)
            let remaining = Double(totalBytesExpectedToWrite - totalBytesWritten) / speed
            if remaining.isFinite, remaining >= 1 {
                let m = Int(remaining) / 60
                let s = Int(remaining) % 60
                etaText = m > 0 ? "剩余 \(m):" + String(format: "%02d", s) : "剩余 \(s)s"
            }
        }
        onProgress(Progress(fraction: fraction, speedText: speedText, etaText: etaText))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw NSError(
                    domain: "FCPSubtitle", code: 31,
                    userInfo: [NSLocalizedDescriptionKey: "服务器返回 HTTP \(http.statusCode)"])
            }
            // Guard against truncated downloads (proxy drop, disk full).
            let attrs = try? FileManager.default.attributesOfItem(atPath: location.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            if expectedBytes > 0, size < expectedBytes {
                throw NSError(
                    domain: "FCPSubtitle", code: 32,
                    userInfo: [NSLocalizedDescriptionKey: "下载不完整,请重试"])
            }
            // Must move synchronously here: the temp file is deleted on return.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume()
            continuation = nil
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
