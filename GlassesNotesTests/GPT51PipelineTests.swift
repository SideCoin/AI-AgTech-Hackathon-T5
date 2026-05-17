// GPT51PipelineTests.swift
// 测试 OpenAI GPT-5.1 两步流水线：图片理解 + notes 分析 + LLM 分类
// 数据来源：my_session/data_samples_5.json（5 条记录，含图片）
//
// API Key 通过 Secrets.swift 加载（环境变量 + Keychain）。
// 在 Xcode 中运行测试时请在
//   Scheme → Test → Arguments → Environment Variables
// 里设置：
//   OPENAI_API_KEY = sk-...
// 可选：
//   OPENAI_MODEL   = gpt-5.1-mini   (默认 gpt-5.1)
//
// 关键：永远不要把 API key 硬编码到测试源文件里。

import XCTest
@testable import GlassesNotes

final class GPT51PipelineTests: XCTestCase {

    // MARK: - 配置

    /// 通过 Secrets 统一读取（env var 优先，其次 Keychain）。
    /// 缺失时抛 SecretError.notFound — 由 setUp 转为 XCTSkip。
    private var apiKey: String {
        get throws { try Secrets.require(.openAI) }
    }

    /// Model override：设置 OPENAI_MODEL 即可切换变体而不改代码。
    private var model: String {
        ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-5.1"
    }

    // 从源文件位置推导项目根；避免硬编码绝对路径。
    private static let mySessionDir: URL = {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()  // GlassesNotesTests/
            .deletingLastPathComponent()  // AI-AgTech-Hackathon-T5/
            .appendingPathComponent("services/analysis/my_session")
    }()

    private static let data5URL =
        mySessionDir.appendingPathComponent("data_samples_5.json")

    private var tempDir: URL!

    // MARK: - setUp / tearDown

    override func setUpWithError() throws {
        try super.setUpWithError()

        guard FileManager.default.fileExists(atPath: Self.data5URL.path) else {
            throw XCTSkip("data_samples_5.json 不存在：\(Self.data5URL.path)")
        }

        // Key 存在性检查：缺失时直接 skip，避免用空 key 跑出 401。
        // 这样 CI 上未配置 key 时测试会被跳过而不是失败。
        do {
            _ = try apiKey
        } catch {
            throw XCTSkip("OPENAI_API_KEY 未设置。请在 Scheme → Test → Environment Variables 里配置。")
        }

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPT51PipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Test 0：只解析 JSON（不调用 GPT，几秒完成）

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

    // MARK: - Test 1：图片理解 + notes 分析（Step 1）

    func test_Step1_AnalyzeJSON() async throws {
        let key     = try apiKey
        let service = OpenAIAnalysisService(apiKey: key, model: model)

        print("\n── Step 1: 逐条分析（图片 + notes）via GPT-5.1 ──")
        let rows = try await withRetry {
            try await service.analyzeJSON(jsonURL: Self.data5URL) { idx, total in
                print("  [\(idx)/\(total)] GPT-5.1 分析中…")
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
        let key             = try apiKey
        let analysisService = OpenAIAnalysisService(apiKey: key, model: model)
        let rows = try await withRetry {
            try await analysisService.analyzeJSON(jsonURL: Self.data5URL)
        }

        let maxCats    = max(1, Int(Double(rows.count) * 0.4))
        let llmService = OpenAILLMCategorizationService(apiKey: key, model: model)
        let groups = try await withRetry {
            try await llmService.classify(rows: rows, maxCategories: maxCats)
        }

        print("\n── Step 2: GPT-5.1 分类结果（最多 \(maxCats) 组）──")
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
        print("\n══ 完整流水线 (GPT-5.1)：图片理解 → 分类 ══")
        let key = try apiKey

        // Step 1
        let analysisService = OpenAIAnalysisService(apiKey: key, model: model)
        let rows = try await withRetry {
            try await analysisService.analyzeJSON(jsonURL: Self.data5URL) { idx, total in
                print("  Step1 [\(idx)/\(total)]")
            }
        }
        print("  ✓ \(rows.count) 条分析完成")

        let step1URL = tempDir.appendingPathComponent("step1_results.json")
        try OpenAIAnalysisService.saveRows(rows, to: step1URL)

        // Step 2
        let maxCats    = max(1, Int(Double(rows.count) * 0.4))
        let llmService = OpenAILLMCategorizationService(apiKey: key, model: model)
        let groups = try await withRetry {
            try await llmService.classify(rows: rows, maxCategories: maxCats)
        }
        print("  ✓ \(groups.count) 个分类")
        for g in groups {
            print("    [\(g.priority.uppercased())] \(g.category)：\(g.items.count) 条")
        }

        let step2URL = tempDir.appendingPathComponent("step2_categorized.json")
        try OpenAILLMCategorizationService.saveGroups(groups, to: step2URL)

        // 验证
        XCTAssertEqual(try OpenAIAnalysisService.loadRows(from: step1URL).count, rows.count)
        XCTAssertEqual(try OpenAILLMCategorizationService.loadGroups(from: step2URL).count, groups.count)

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
                // OpenAI 错误体里常见 "rate_limit_exceeded" / "Too Many Requests"
                guard msg.contains("429")
                   || msg.contains("rate_limit")
                   || msg.contains("Too Many Requests")
                   || msg.contains("RESOURCE_EXHAUSTED") else { throw error }
                lastError = error
                guard attempt < maxRetries else { break }
                let wait = retryDelay(from: msg, attempt: attempt)
                print("  ⚠ 限流，\(Int(wait))秒后重试 (\(attempt + 1)/\(maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        throw lastError!
    }

    /// 优先从错误信息里抓 "retry in Xs"，否则指数退避（上限 120s）。
    private func retryDelay(from message: String, attempt: Int) -> Double {
        let pattern = #"retry[_ ]in\s+([\d.]+)\s*s"#
        if let regex   = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match   = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           let numRng  = Range(match.range(at: 1), in: message),
           let seconds = Double(message[numRng]) {
            return seconds + 1
        }
        return min(15 * pow(2.0, Double(attempt)), 120)
    }
}
