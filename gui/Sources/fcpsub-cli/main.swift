import FCPSubtitleCore
import Foundation

// Headless smoke-test CLI: same pipeline as the GUI, no window.
// Usage: fcpsub-cli <audio> <models-dir> [output.fcpxml] [--fps 25]

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "用法: fcpsub-cli <音频文件> <models目录> [输出.fcpxml] [--fps 25]\n".data(using: .utf8)!)
    exit(1)
}

let audioURL = URL(fileURLWithPath: args[1])
let modelsDir = URL(fileURLWithPath: args[2])
var outputPath = audioURL.deletingPathExtension().appendingPathExtension("fcpxml").path
var fps = "25"
var format = SubtitleFormat.fcpxml
var maxChars = 0  // 0 = no splitting
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
        fps = args[i + 1]
        i += 2
    } else if args[i] == "--srt" {
        format = .srt
        i += 1
    } else if args[i] == "--format", i + 1 < args.count {
        guard let f = SubtitleFormat(rawValue: args[i + 1]) else {
            FileHandle.standardError.write(
                "不支持的格式: \(args[i + 1]),可选: \(SubtitleFormat.allCases.map(\.rawValue).joined(separator: "/"))\n"
                    .data(using: .utf8)!)
            exit(1)
        }
        format = f
        i += 2
    } else if args[i] == "--max-chars", i + 1 < args.count {
        maxChars = Int(args[i + 1]) ?? 0
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

        let clock = ContinuousClock()
        let startTime = clock.now
        var segments: [SubtitleSegment]
        if audioURL.pathExtension.lowercased() == "srt" {
            segments = SRTParser.parse(try String(contentsOf: audioURL, encoding: .utf8))
        } else {
            let samples = try await AudioDecoder.decode(url: audioURL)
            segments = try Transcriber.transcribe(
                samples: samples, models: models, language: language)
        }
        if maxChars > 0 {
            segments = SegmentSplitter.split(segments, maxChars: maxChars)
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

        let content = SubtitleExporter.export(segments: segments, format: format, fps: fps)
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
