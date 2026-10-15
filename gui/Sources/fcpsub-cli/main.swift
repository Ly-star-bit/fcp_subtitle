import FCPSubtitleCore
import Foundation

// Headless smoke-test CLI: same pipeline as the GUI, no window.
// Usage: fcpsub-cli <audio> <models-dir> [output.fcpxml] [--fps 25] [--size 1080x1920]
//        [--max-chars 18] [--punct keep|trim|subtitle] [--no-timing] [--hotwords words.txt]
// Without --fps/--size a video input sets the timeline to match its footage.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    fail("用法: fcpsub-cli <音频文件> <models目录> [输出.fcpxml] [--fps 25] [--size 1920x1080]")
}

let audioURL = URL(fileURLWithPath: args[1])
let modelsDir = URL(fileURLWithPath: args[2])
var outputPath = audioURL.deletingPathExtension().appendingPathExtension("fcpxml").path
var fps: String?
var size: (width: Int, height: Int)?
var format = SubtitleFormat.fcpxml
var maxChars = 18  // 0 = split only at sentence ends
var punctuation = PunctuationStyle.trimEnd
var timingRules = true
var hotwords: [String] = []
var language = ""
var proofread = false
var llmTest = false
var llmBase = "https://api.openai.com/v1"
var llmKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
var llmModel = "gpt-4o-mini"
var llmBatch = 30

var i = 3
while i < args.count {
    if args[i] == "--fps", i + 1 < args.count {
        guard FCPXMLBuilder.fpsLabels.contains(args[i + 1]) else {
            fail("不支持的帧率: \(args[i + 1]),可选: \(FCPXMLBuilder.fpsLabels.joined(separator: " / "))")
        }
        fps = args[i + 1]
        i += 2
    } else if args[i] == "--size", i + 1 < args.count {
        let parts = args[i + 1].lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            fail("画面尺寸格式应为 宽x高,例如 1080x1920")
        }
        size = (parts[0], parts[1])
        i += 2
    } else if args[i] == "--srt" {
        format = .srt
        i += 1
    } else if args[i] == "--format", i + 1 < args.count {
        guard let f = SubtitleFormat(rawValue: args[i + 1]) else {
            fail("不支持的格式: \(args[i + 1]),可选: \(SubtitleFormat.allCases.map(\.rawValue).joined(separator: "/"))")
        }
        format = f
        i += 2
    } else if args[i] == "--max-chars", i + 1 < args.count {
        maxChars = Int(args[i + 1]) ?? 0
        i += 2
    } else if args[i] == "--punct", i + 1 < args.count {
        let styles: [String: PunctuationStyle] = ["keep": .keep, "trim": .trimEnd, "subtitle": .subtitle]
        guard let style = styles[args[i + 1]] else { fail("--punct 可选: keep / trim / subtitle") }
        punctuation = style
        i += 2
    } else if args[i] == "--no-timing" {
        timingRules = false
        i += 1
    } else if args[i] == "--hotwords", i + 1 < args.count {
        guard let list = try? String(contentsOfFile: args[i + 1], encoding: .utf8) else {
            fail("无法读取热词文件: \(args[i + 1])")
        }
        hotwords = list.components(separatedBy: .newlines)
        i += 2
    } else if args[i] == "--lang", i + 1 < args.count {
        language = args[i + 1]
        i += 2
    } else if args[i] == "--proofread" {
        proofread = true
        i += 1
    } else if args[i] == "--llm-test" {
        llmTest = true
        i += 1
    } else if args[i] == "--llm-base", i + 1 < args.count {
        llmBase = args[i + 1]
        i += 2
    } else if args[i] == "--llm-key", i + 1 < args.count {
        llmKey = args[i + 1]
        i += 2
    } else if args[i] == "--llm-model", i + 1 < args.count {
        llmModel = args[i + 1]
        i += 2
    } else if args[i] == "--llm-batch", i + 1 < args.count {
        llmBatch = Int(args[i + 1]) ?? 30
        i += 2
    } else {
        outputPath = args[i]
        i += 1
    }
}

let models = ModelPaths(
    senseVoiceModel: modelsDir.appendingPathComponent("sense-voice/model.int8.onnx").path,
    tokens: modelsDir.appendingPathComponent("sense-voice/tokens.txt").path,
    sileroVad: modelsDir.appendingPathComponent("silero_vad.onnx").path)

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    do {
        if llmTest {
            let model = try await LLMProofreader.testConnection(
                config: LLMConfig(baseURL: llmBase, apiKey: llmKey, model: llmModel))
            print("连接正常,模型: \(model)")
            exit(0)
        }

        // Explicit flags win; otherwise follow the footage, then the defaults.
        let source = await VideoFormat.probe(url: audioURL)
        let timelineFps = fps ?? source.flatMap { FCPXMLBuilder.fpsLabel(matching: $0.frameRate) } ?? "25"
        let timelineSize = size ?? source.map { ($0.width, $0.height) } ?? (1920, 1080)

        let clock = ContinuousClock()
        let startTime = clock.now
        var segments: [SubtitleSegment]
        if audioURL.pathExtension.lowercased() == "srt" {
            segments = try SRTParser.parse(contentsOf: audioURL)
        } else {
            let samples = try await AudioDecoder.decode(url: audioURL)
            let transcript = try Transcriber.transcribe(
                samples: samples, models: models, language: language)
            let timing = timingRules
                ? TimingRules(frameDuration: FCPXMLBuilder.frameSeconds(fps: timelineFps) ?? 0.04) : nil
            segments = SubtitleLayout.segments(
                from: transcript,
                options: LayoutOptions(
                    maxChars: maxChars, punctuation: punctuation, timing: timing, hotwords: hotwords))
        }
        if proofread {
            let config = LLMConfig(
                baseURL: llmBase, apiKey: llmKey, model: llmModel, batchSize: llmBatch)
            let corrections = try await LLMProofreader.proofread(
                segments: segments, config: config
            ) { done, total in
                print("校对 \(done)/\(total) 批")
            }
            for correction in corrections {
                print(
                    String(
                        format: "修正 [%8.3f] %@ → %@", correction.start, correction.original,
                        correction.suggested))
                if let index = segments.firstIndex(where: { $0.id == correction.id }) {
                    segments[index].text = correction.suggested
                }
            }
            print("校对建议 \(corrections.count) 处")
        }

        let elapsed = clock.now - startTime

        for seg in segments {
            print(String(format: "[%8.3f -> %8.3f] %@", seg.start, seg.end, seg.text))
        }

        if let source {
            print(String(format: "视频: %dx%d %.3ffps", source.width, source.height, source.frameRate))
        }
        print("时间线: \(timelineSize.width)x\(timelineSize.height) \(timelineFps)fps")

        let content = try SubtitleExporter.export(
            segments: segments, format: format, fps: timelineFps,
            width: timelineSize.width, height: timelineSize.height)
        if format != .fcpxml, outputPath.hasSuffix(".fcpxml") {
            outputPath = String(outputPath.dropLast(7)) + "." + format.fileExtension
        }
        try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("识别 \(segments.count) 句,耗时 \(elapsed)")
        print("已生成: \(outputPath)")
    } catch {
        FileHandle.standardError.write("错误: \(error.localizedDescription)\n".data(using: .utf8)!)
        exitCode = 1
    }
    semaphore.signal()
}

semaphore.wait()
exit(exitCode)
