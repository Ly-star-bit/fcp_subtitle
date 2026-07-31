import Foundation

/// Connection settings for an OpenAI-compatible chat-completions endpoint.
/// Works with api.openai.com and any gateway speaking the same schema
/// (DeepSeek / 通义 / Ollama / one-api ...).
public struct LLMConfig: Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var batchSize: Int
    public var proxyHost: String?
    public var proxyPort: Int

    public init(
        baseURL: String,
        apiKey: String,
        model: String,
        batchSize: Int = 30,
        proxyHost: String? = nil,
        proxyPort: Int = 0
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.batchSize = max(batchSize, 1)
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
    }

    /// Tolerates a base URL written with or without a trailing slash, and one
    /// that already spells out the full `/chat/completions` path.
    public var endpoint: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("/chat/completions") { return URL(string: text) }
        return URL(string: text + "/chat/completions")
    }
}

/// One suggested edit. `id` is the id of the segment it applies to.
public struct LLMCorrection: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let start: Double
    public let original: String
    public let suggested: String
    /// The specific wrong/right word pair, when the model isolated one —
    /// lets an accepted fix be promoted into the persistent replace dictionary.
    public let from: String
    public let to: String
}

public enum LLMProofreader {
    public enum Failure: LocalizedError {
        case noEndpoint
        case noKey
        case http(Int, String)
        case badResponse(String)
        case allBatchesFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noEndpoint:
                return "接口地址无效,填写形如 https://api.openai.com/v1"
            case .noKey:
                return "还没有填写 API Key"
            case .http(let code, let body):
                // Omitting the /v1 path segment is the most common setup mistake.
                let hint = code == 404 ? " —— 接口地址可能少了 /v1" : ""
                // An HTML error page means we hit a web server, not the API;
                // dumping its markup helps nobody.
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail =
                    trimmed.hasPrefix("<") || trimmed.isEmpty ? "" : ": \(trimmed.prefix(300))"
                return "接口返回 HTTP \(code)\(hint)\(detail)"
            case .badResponse(let detail):
                return "无法解析接口返回内容: \(detail)"
            case .allBatchesFailed(let detail):
                return detail
            }
        }
    }

    private static let systemPrompt = """
        你是中文视频字幕的校对员。用户会给你若干行语音识别(ASR)生成的字幕,每行格式为「序号|文本」。

        只修正这几类问题:
        1. 同音或近音造成的错别字(例如「字母」应为「字幕」)
        2. 人名、品牌名、专业术语的明显误写
        3. 明显缺失或多余的标点

        绝对不要做的事:
        - 改写句子结构、润色语气、增删内容
        - 合并或拆分行
        - 翻译成其他语言
        - 修改没有把握的地方;不确定就跳过这一行

        没有问题的行不要输出。

        只输出 JSON,不要附加任何解释文字或代码块标记:
        {"corrections":[{"index":序号,"text":"修正后的完整整行文本","from":"原词","to":"改后的词"}]}

        如果所有行都没有问题,输出 {"corrections":[]}
        """

    /// Check every segment for ASR typos. Returns only the lines the model wants
    /// to change; applying them is left to the caller.
    /// `onProgress` receives (finished batches, total batches).
    public static func proofread(
        segments: [SubtitleSegment],
        config: LLMConfig,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [LLMCorrection] {
        guard !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.noKey }
        guard let endpoint = config.endpoint else { throw Failure.noEndpoint }
        guard !segments.isEmpty else { return [] }

        let chunks = stride(from: 0, to: segments.count, by: config.batchSize).map {
            Array(segments[$0..<min($0 + config.batchSize, segments.count)])
        }
        let session = makeSession(config)

        var collected: [LLMCorrection] = []
        var firstError: String?
        var failures = 0
        var finished = 0

        await withTaskGroup(of: BatchOutcome.self) { group in
            var pending = chunks.makeIterator()
            // Keep a few requests in flight; most endpoints rate-limit above this.
            for _ in 0..<min(3, chunks.count) {
                guard let chunk = pending.next() else { break }
                group.addTask { await run(chunk, config: config, endpoint: endpoint, session: session) }
            }
            while let outcome = await group.next() {
                switch outcome {
                case .ok(let items):
                    collected += items
                case .failed(let message):
                    failures += 1
                    if firstError == nil { firstError = message }
                }
                finished += 1
                onProgress?(finished, chunks.count)
                if Task.isCancelled { break }
                if let chunk = pending.next() {
                    group.addTask { await run(chunk, config: config, endpoint: endpoint, session: session) }
                }
            }
            group.cancelAll()
        }

        // A few dropped batches still leave useful suggestions; only give up if
        // nothing at all got through.
        if failures == chunks.count, let firstError { throw Failure.allBatchesFailed(firstError) }

        let order = Dictionary(
            uniqueKeysWithValues: segments.enumerated().map { ($1.id, $0) })
        return collected.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    /// Round-trip one throwaway line to confirm the address, key and model name
    /// all work, without spending a full proofreading pass. Returns the model's
    /// own reported name when it gives one.
    public static func testConnection(config: LLMConfig) async throws -> String {
        guard !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.noKey }
        guard let endpoint = config.endpoint else { throw Failure.noEndpoint }

        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0,
            "messages": [["role": "user", "content": "回复 OK 两个字母,不要其他内容。"]],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await makeSession(config).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.badResponse("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            message["content"] is String
        else {
            throw Failure.badResponse(
                "返回的不是 OpenAI 格式,请检查接口地址是否应以 /v1 结尾。"
                    + (String(data: data, encoding: .utf8)?.prefix(200).description ?? ""))
        }
        return (root["model"] as? String) ?? config.model
    }

    private static func run(
        _ chunk: [SubtitleSegment], config: LLMConfig, endpoint: URL, session: URLSession
    ) async -> BatchOutcome {
        do {
            return .ok(
                try await proofreadChunk(chunk, config: config, endpoint: endpoint, session: session))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func proofreadChunk(
        _ chunk: [SubtitleSegment], config: LLMConfig, endpoint: URL, session: URLSession
    ) async throws -> [LLMCorrection] {
        let numbered = chunk.enumerated()
            .map { "\($0.offset)|\($0.element.text)" }
            .joined(separator: "\n")

        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": numbered],
            ],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.badResponse("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw Failure.badResponse(String(data: data, encoding: .utf8)?.prefix(300).description ?? "")
        }
        return parse(content, chunk: chunk)
    }

    // MARK: - Response parsing

    /// Models often wrap JSON in prose or ```json fences, so slice out the
    /// outermost object rather than decoding the raw string.
    private static func parse(_ content: String, chunk: [SubtitleSegment]) -> [LLMCorrection] {
        guard let start = content.firstIndex(of: "{"),
            let end = content.lastIndex(of: "}"),
            start < end,
            let data = String(content[start...end]).data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["corrections"] as? [[String: Any]]
        else { return [] }

        var out: [LLMCorrection] = []
        for item in items {
            guard let index = intValue(item["index"]), chunk.indices.contains(index) else { continue }
            let segment = chunk[index]
            let suggested = (item["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suggested.isEmpty, suggested != segment.text else { continue }
            out.append(
                LLMCorrection(
                    id: segment.id,
                    start: segment.start,
                    original: segment.text,
                    suggested: suggested,
                    from: item["from"] as? String ?? "",
                    to: item["to"] as? String ?? ""))
        }
        return out
    }

    /// Some models return the index as a string.
    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let text = raw as? String { return Int(text) }
        if let number = raw as? Double { return Int(number) }
        return nil
    }

    private static func makeSession(_ config: LLMConfig) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        if let host = config.proxyHost, !host.isEmpty, config.proxyPort > 0 {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: config.proxyPort,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: config.proxyPort,
            ]
        }
        return URLSession(configuration: configuration)
    }
}

/// Per-batch result. A failed batch carries only its message so the value stays
/// `Sendable` while crossing the task group.
enum BatchOutcome: Sendable {
    case ok([LLMCorrection])
    case failed(String)
}
