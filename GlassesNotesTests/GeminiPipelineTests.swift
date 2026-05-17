// GeminiPipelineTests.swift
// 测试 Gemini 两步流水线：图片理解 + notes 分析 + LLM 分类
// 数据来源：my_session/data_samples_5.json（5 条记录，含图片）
//
// API Key 优先从环境变量 GEMINI_API_KEY 读取；
// 在 Xcode 中运行时可在 Scheme → Test → Arguments → Environment Variables 里设置。

import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import GlassesNotes

final class GeminiPipelineTests: XCTestCase {

    // MARK: - 配置

    // Fix: read API key from environment variable; fall back to local dev value.
    // Set GEMINI_API_KEY in Xcode Scheme → Test → Arguments → Environment Variables.
    private var apiKey: String {
        ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
            ?? "AIzaSyDVsBCmz4anSWV8Wkim6HR-7Kfc1dtfyh8"
    }

    // Model override: set GEMINI_MODEL env var to switch without editing code.
    // gemini-2.5-flash: 20 req/day free   gemini-2.0-flash: 1500 req/day free
    private var model: String {
        ProcessInfo.processInfo.environment["GEMINI_MODEL"] ?? "gemini-2.0-flash"
    }

    // Fix: derive path from this source file's location instead of a hardcoded absolute path.
    // #filePath is resolved at compile time to the absolute path of this .swift file.
    // Layout: GlassesNotesTests/GeminiPipelineTests.swift
    //         → up 2 levels → project root
    //         → services/analysis/my_session
    private static let mySessionDir: URL = {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()  // GlassesNotesTests/
            .deletingLastPathComponent()  // AI-AgTech-Hackathon-T5/
            .appendingPathComponent("services/analysis/my_session")
    }()

    // 原始（永远指向 raw 全分辨率图）—— 仅 quick 压缩测试读它。
    private static let rawData5URL =
        mySessionDir.appendingPathComponent("data_samples_5.json")

    // 压缩输出位置。quick 测试写这里；其它测试若文件存在就优先读这里。
    private static let compressedData5URL =
        mySessionDir.appendingPathComponent("data_samples_5_compressed.json")

    /// 所有 Step 1 / Step 2 / FullPipeline 测试的输入入口。
    /// 若 quick 测试已生成压缩 JSON 则自动用压缩版，否则回退到原始。
    /// 用计算属性而不是 let —— let 在类加载时只算一次，跑完 quick 后第二次跑不会刷新。
    private static var data5URL: URL {
        FileManager.default.fileExists(atPath: compressedData5URL.path)
            ? compressedData5URL
            : rawData5URL
    }

    private var tempDir: URL!

    /// 持久化输出目录：FullPipeline 把 step1 / step2 JSON 写到这里供后续查看。
    /// 与 Python 端 services/analysis/results/ 对齐，便于和 Python 输出对照。
    private static let resultsDir =
        mySessionDir.appendingPathComponent("results")

    // MARK: - setUp / tearDown

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.fileExists(atPath: Self.data5URL.path) else {
            throw XCTSkip("data_samples_5.json 不存在：\(Self.data5URL.path)")
        }
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiPipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Test 0：只解析 JSON（不调用 Gemini，几秒完成）

    func test_Step0_ParseDataSamples5() throws {
        let entries = try DataJSONLoader.iterEntries(from: Self.data5URL)
        XCTAssertEqual(entries.count, 5, "data_samples_5.json 应有 5 条 entry")

        print("\n── data_samples_5.json 解析结果 ──")
        for e in entries {
            let hasImage = e.imageData != nil ? "有图片" : "无图片"
            print("  [\(e.entryID.prefix(8))…] \(hasImage)")
            print("    note: \(e.note.prefix(60))")
        }
    }

    // MARK: - Quick Test：压缩 base64 图片 + 单条 Gemini key 活性检测
    //
    // 目的：data_samples_5.json 里每张图都是原始全分辨率 base64，5 条全跑 LLM
    // 单次要 3-5 分钟。这里只做两件事：
    //   1) 把每条 entry 的 imageBase64 缩到 ≤768px / JPEG q=0.5，写一份
    //      data_samples_5_compressed.json，体积通常降到 1/5 ~ 1/10。
    //   2) 用压缩后的第 1 条调一次 Gemini，验证 key 可用、返回结构正常。
    // 总耗时 < 30s，可以独立跑：
    //   -only-testing:GlassesNotesTests/GeminiPipelineTests/test_Quick_CompressImagesAndPingGemini
    func test_Quick_CompressImagesAndPingGemini() async throws {
        // ── Part 1: 压缩 ─────────────────────────────────────────────
        // 始终读 raw，否则跑第二次会压缩已经压过的 JSON
        guard FileManager.default.fileExists(atPath: Self.rawData5URL.path) else {
            throw XCTSkip("原始 data_samples_5.json 不存在：\(Self.rawData5URL.path)")
        }
        let rawData = try Data(contentsOf: Self.rawData5URL)
        print("\n[原始 JSON] \(rawData.count / 1024) KB")

        guard var json = try JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              var entries = json["entries"] as? [[String: Any]] else {
            XCTFail("data_samples_5.json 顶层不是 {entries: [...]}")
            return
        }

        var totalBefore = 0
        var totalAfter  = 0
        var compressedCount = 0

        for i in entries.indices {
            guard let b64 = entries[i]["imageBase64"] as? String,
                  !b64.isEmpty, b64 != "...",
                  let orig = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
            else { continue }

            totalBefore += orig.count
            guard let small = Self.compressJPEG(orig, maxPixelSize: 768, quality: 0.5) else {
                print("  ⚠ entry \(i) 解码失败，原样保留")
                totalAfter += orig.count
                continue
            }
            totalAfter += small.count
            entries[i]["imageBase64"] = small.base64EncodedString()
            compressedCount += 1
            print("  [\(i)] \(orig.count / 1024) KB → \(small.count / 1024) KB")
        }
        json["entries"] = entries

        let outURL = Self.mySessionDir.appendingPathComponent("data_samples_5_compressed.json")
        let outData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try outData.write(to: outURL)

        let beforeKB = totalBefore / 1024
        let afterKB  = totalAfter  / 1024
        let ratio = totalBefore > 0
            ? Int(Double(totalAfter) / Double(totalBefore) * 100)
            : 0
        print("\n[图片合计] \(beforeKB) KB → \(afterKB) KB  (\(ratio)%)")
        print("[输出 JSON] \(outData.count / 1024) KB  →  \(outURL.path)")

        XCTAssertGreaterThan(compressedCount, 0, "至少应压缩 1 张图")
        XCTAssertLessThan(outData.count, rawData.count, "压缩后 JSON 应小于原始")

        // ── Part 2: 用压缩后的第 1 条 ping Gemini，验证 key ─────────────
        let entriesCompressed = try DataJSONLoader.iterEntries(from: outURL)
        guard let first = entriesCompressed.first(where: { $0.imageData != nil }) else {
            XCTFail("压缩后 JSON 找不到带图的 entry")
            return
        }

        print("\n[Gemini ping] model=\(model)  image=\(first.imageData?.count ?? 0) bytes")
        let service = GeminiAnalysisService(apiKey: apiKey, model: model)
        let result = try await withRetry {
            try await service.analyzeSingle(
                note:      first.note,
                latitude:  first.latitude,
                longitude: first.longitude,
                timestamp: first.timestamp,
                imageData: first.imageData
            )
        }

        print("[Gemini 响应] importance=\(result.importance) keynotes=\(result.keynotes.count)")
        for k in result.keynotes { print("  • \(k)") }
        if result.imageReport != "(no image)" {
            print("[图片描述] \(result.imageReport.prefix(120))")
        }

        XCTAssertFalse(result.keynotes.isEmpty, "Gemini 应返回至少 1 条 keynote")
        XCTAssertNotEqual(result.imageReport, "(no image)", "带图的 entry 应有图片描述")
    }

    /// 用 ImageIO 生成缩略图后用 JPEG 重新编码。
    /// 比 UIImage(data:).jpegData(quality:) 更省内存 — 不会把全分辨率位图载入。
    private static func compressJPEG(_ data: Data, maxPixelSize: Int, quality: Double) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform:   true,
            kCGImageSourceShouldCacheImmediately:         true,
            kCGImageSourceThumbnailMaxPixelSize:          maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        let utiJPEG = UTType.jpeg.identifier as CFString
        guard let dst = CGImageDestinationCreateWithData(out, utiJPEG, 1, nil) else { return nil }
        let dstOpts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(dst, cg, dstOpts as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }

    // MARK: - Test 1：图片理解 + notes 分析（Step 1）

    func test_Step1_AnalyzeJSON() async throws {
        let service = AnalysisService(apiKey: apiKey, model: model)

        print("\n── Step 1: 逐条分析（图片 + notes）──")
        let rows = try await withRetry {
            try await service.analyzeJSON(jsonURL: Self.data5URL) { idx, total in
                print("  [\(idx)/\(total)] Gemini 分析中…")
            }
        }

        XCTAssertEqual(rows.count, 5)

        print("\n── Step 1 结果 ──")
        for row in rows {
            print("  [\(row.importance.rawValue.uppercased())] \(row.time)  \(row.note.prefix(50))")
            for k in row.keynotes { print("    • \(k)") }
            if row.imageReport != "(no image)" {
                print("    [图片描述] \(row.imageReport.prefix(100))")
            }
        }

        for row in rows {
            XCTAssertFalse(row.keynotes.isEmpty, "Row \(row.id) 缺少 keynotes")
            XCTAssertNotEqual(row.imageReport, "(no image)", "Row \(row.id) 应有图片描述")
        }
    }

    // MARK: - Test 2：LLM 分类（Step 2）

    func test_Step2_Classify() async throws {
        let analysisService = AnalysisService(apiKey: apiKey, model: model)
        let rows = try await withRetry {
            try await analysisService.analyzeJSON(jsonURL: Self.data5URL)
        }

        let maxCats = max(1, Int(Double(rows.count) * 0.4))
        let llmService = LLMCategorizationService(apiKey: apiKey, model: model)
        let groups = try await withRetry {
            try await llmService.classify(rows: rows, maxCategories: maxCats)
        }

        print("\n── Step 2: LLM 分类结果（最多 \(maxCats) 组）──")
        for g in groups {
            print("  [\(g.priority.uppercased())] \(g.category)：\(g.items.count) 条")
            for item in g.items {
                print("    [\(item.time)] \(item.note.prefix(50))")
                print("    → \(item.reason.prefix(80))")
            }
        }

        XCTAssertFalse(groups.isEmpty)
        XCTAssertLessThanOrEqual(groups.count, maxCats)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.items.count }, rows.count,
                       "所有记录都应被分配到某个分类")
    }

    // MARK: - Test 3：完整流水线 + 保存文件

    func test_FullPipeline() async throws {
        print("\n══ 完整流水线：图片理解 → 分类 ══")

        // 持久化输出目录 — tearDown 不会动这里，跑完可以直接 Finder 打开
        try FileManager.default.createDirectory(
            at: Self.resultsDir, withIntermediateDirectories: true
        )

        // Step 1
        let analysisService = AnalysisService(apiKey: apiKey, model: model)
        let rows = try await withRetry {
            try await analysisService.analyzeJSON(jsonURL: Self.data5URL) { idx, total in
                print("  Step1 [\(idx)/\(total)]")
            }
        }
        print("  ✓ \(rows.count) 条分析完成")

        let step1URL = Self.resultsDir.appendingPathComponent("step1_results.json")
        try AnalysisService.saveRows(rows, to: step1URL)

        // Step 2
        let maxCats = max(1, Int(Double(rows.count) * 0.4))
        let llmService = LLMCategorizationService(apiKey: apiKey, model: model)
        let groups = try await withRetry {
            try await llmService.classify(rows: rows, maxCategories: maxCats)
        }
        print("  ✓ \(groups.count) 个分类")
        for g in groups {
            print("    [\(g.priority.uppercased())] \(g.category)：\(g.items.count) 条")
        }

        let step2URL = Self.resultsDir.appendingPathComponent("step2_categorized.json")
        try LLMCategorizationService.saveGroups(groups, to: step2URL)

        // 验证
        XCTAssertEqual(try AnalysisService.loadRows(from: step1URL).count, rows.count)
        XCTAssertEqual(try LLMCategorizationService.loadGroups(from: step2URL).count, groups.count)

        print("\n  Step1 输出：\(step1URL.path)")
        print("  Step2 输出：\(step2URL.path)")
    }

    // MARK: - 重试（429 限流时指数退避）

    private func withRetry<T>(
        maxRetries: Int = 5,
        _ body: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await body()
            } catch {
                let msg = error.localizedDescription
                guard msg.contains("429") || msg.contains("RESOURCE_EXHAUSTED") else { throw error }
                lastError = error
                guard attempt < maxRetries else { break }
                let wait = retryDelay(from: msg, attempt: attempt)
                print("  ⚠ 限流，\(Int(wait))秒后重试 (\(attempt + 1)/\(maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        throw lastError!
    }

    // Fix: the original inline regex was matching the whole "retry in Xs" substring then
    // trying to parse it as a Double, which always fails. Use a capture group instead.
    private func retryDelay(from message: String, attempt: Int) -> Double {
        let pattern = #"retry[_ ]in\s+([\d.]+)\s*s"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           let numRange = Range(match.range(at: 1), in: message),
           let seconds = Double(message[numRange]) {
            return seconds + 1
        }
        // Exponential backoff capped at 2 minutes
        return min(15 * pow(2.0, Double(attempt)), 120)
    }
}
