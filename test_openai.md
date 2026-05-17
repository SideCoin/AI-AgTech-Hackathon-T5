# OpenAI (GPT-5.1) Pipeline Testing Guide

Tests for the two-step OpenAI pipeline: image analysis → LLM categorization.

**Test file:** `GlassesNotesTests/GPT51PipelineTests.swift`
**Test data:** `services/analysis/my_session/data_samples_5.json` (5 poultry farm observations with JPEG images)
**Simulator:** iPhone 16 Pro (`E01584D0-38FD-45A4-9575-1EEC332F1A61`) — already booted
**Default model:** `gpt-5.1`  (override with `OPENAI_MODEL` env var, e.g. `gpt-5.1-mini`)

---

## Prerequisites

### 1. Generate test data (run once — same as Gemini guide)

If `services/analysis/my_session/data_samples_5.json` already exists from running
the Gemini tests, **skip this step**. Otherwise see `TESTING.md` §Prerequisites for
the Python snippet.

### 2. API Key

The test reads `OPENAI_API_KEY` via `Secrets.swift`, which checks the env var first
and the Keychain second. **No hardcoded fallback** — if the key is missing the
test self-skips with a clear message.

**One-time setup:**

```bash
# Create the gitignored key file (already done if you followed the chat steps)
cat > ~/.openai_key.sh <<'EOF'
export OPENAI_API_KEY="sk-proj-PASTE_YOUR_KEY_HERE"
# Optional: export OPENAI_MODEL="gpt-5.1-mini"
EOF
chmod 600 ~/.openai_key.sh

# Auto-load in every new terminal (already added to ~/.zshrc)
echo '[ -f ~/.openai_key.sh ] && source ~/.openai_key.sh' >> ~/.zshrc
```

**Before each test session** (current terminal only):

```bash
source ~/.openai_key.sh
echo "Key loaded: ${OPENAI_API_KEY:0:10}..."   # should print sk-proj-XX...
```

**Important:** `xcodebuild` reads env vars from the shell it inherits.
If you launch Xcode from the Dock, the GUI process won't see `OPENAI_API_KEY` —
either launch Xcode from a sourced terminal (`open GlassesNotes.xcodeproj`) or
also configure the variable in Xcode Scheme → Test → Environment Variables.

---

## Test Commands

All commands run from the project root:

```bash
cd /Users/zhengmiao/UCDavis/Competition/AIFS_Hackathon/AI-AgTech-Hackathon-T5
source ~/.openai_key.sh   # if not auto-loaded
```

---

### Test 0 — Parse JSON only (no API calls, ~5s)

Verifies `data_samples_5.json` is readable and contains 5 entries with images.
Also confirms `Secrets.swift` finds the key (will `XCTSkip` cleanly if missing).

```bash
xcodebuild test \
  -project GlassesNotes.xcodeproj \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,id=E01584D0-38FD-45A4-9575-1EEC332F1A61' \
  -only-testing:GlassesNotesTests/GPT51PipelineTests/test_Step0_ParseDataSamples5 \
  2>&1 | grep -E "Test|PASS|FAIL|error:|note:|skipped"
```

Expected output:
```
── data_samples_5.json 解析结果 ──
  [xxxxxxxx…] 有图片
    note: A-03: I heard coughing near the middle fan row...
  ...
Test Case 'test_Step0_ParseDataSamples5' passed
```

---

### Test 1 — Image + notes analysis via GPT-5.1 (~30–60s, 5 API calls)

Sends each observation (voice note + JPEG) to `gpt-5.1` (or your `OPENAI_MODEL`
override) and returns `importance`, `keynotes`, `image_report`.

```bash
xcodebuild test \
  -project GlassesNotes.xcodeproj \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,id=E01584D0-38FD-45A4-9575-1EEC332F1A61' \
  -only-testing:GlassesNotesTests/GPT51PipelineTests/test_Step1_AnalyzeJSON \
  2>&1 | grep -E "\[OpenAI\]|\[HIGH\]|\[MEDIUM\]|\[LOW\]|Step|图片描述|Test|PASS|FAIL|⚠"
```

Expected output:
```
[OpenAI] → gpt-5.1 | note: "A-03: I heard coughing..." | image: true
[OpenAI] ✓ importance=high keynotes=2 hasImage=true
  [1/5] GPT-5.1 分析中…
...
── Step 1 结果 ──
  [HIGH] 06:35  A-03: I heard coughing near the middle fan row...
    • Birds showing respiratory distress symptoms
    • Reduced activity level observed
    [图片描述] The image shows...
Test Case 'test_Step1_AnalyzeJSON' passed
```

---

### Test 2 — LLM categorization (~60–90s, Step 1 + 1 classify call)

Runs Step 1 then groups all rows into at most 2 thematic categories via a single
GPT-5.1 call.

```bash
xcodebuild test \
  -project GlassesNotes.xcodeproj \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,id=E01584D0-38FD-45A4-9575-1EEC332F1A61' \
  -only-testing:GlassesNotesTests/GPT51PipelineTests/test_Step2_Classify \
  2>&1 | grep -E "\[OpenAI\]|\[OpenAILLMCategorize\]|Step|分类|HIGH|MEDIUM|LOW|Test|PASS|FAIL|⚠"
```

Expected output:
```
[OpenAILLMCategorize] → classify 5 rows, maxCats=2
[OpenAILLMCategorize] ✓ 5 classifications received
── Step 2: GPT-5.1 分类结果（最多 2 组）──
  [HIGH] Respiratory / Health Issues：3 条
  [MEDIUM] Environmental / Husbandry：2 条
Test Case 'test_Step2_Classify' passed
```

---

### Test 3 — Full pipeline + save to disk (~90–120s)

Runs Step 1 → Step 2 → saves both result files to a temp directory and verifies
they can be reloaded.

```bash
xcodebuild test \
  -project GlassesNotes.xcodeproj \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,id=E01584D0-38FD-45A4-9575-1EEC332F1A61' \
  -only-testing:GlassesNotesTests/GPT51PipelineTests/test_FullPipeline \
  2>&1 | grep -E "\[OpenAI\]|\[OpenAILLMCategorize\]|Step|分类|✓|✗|Test|PASS|FAIL|输出|⚠"
```

Expected output:
```
══ 完整流水线 (GPT-5.1)：图片理解 → 分类 ══
  Step1 [1/5]
  ...
  ✓ 5 条分析完成
  ✓ 2 个分类
    [HIGH] Respiratory / Health Issues：3 条
  Step1 输出：/tmp/GPT51PipelineTests-.../step1_results.json
  Step2 输出：/tmp/GPT51PipelineTests-.../step2_categorized.json
Test Case 'test_FullPipeline' passed
```

---

### Run all 4 tests in sequence

```bash
xcodebuild test \
  -project GlassesNotes.xcodeproj \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,id=E01584D0-38FD-45A4-9575-1EEC332F1A61' \
  -only-testing:GlassesNotesTests/GPT51PipelineTests \
  2>&1 | grep -E "\[OpenAI\]|\[OpenAILLMCategorize\]|Step|图片描述|分类|✓|✗|Test Suite|PASS|FAIL|error:|⚠"
```

---

## Rate Limit Handling

The test suite retries automatically on HTTP 429. You will see:

```
⚠ 限流，31秒后重试 (1/5)
```

Retry triggers on any of: `429`, `rate_limit`, `Too Many Requests`,
`RESOURCE_EXHAUSTED`. Delays use exponential backoff (15s → 30s → 60s → 120s, capped)
or the `retry in Xs` hint from the API response.

---

## Switching Models

The default is `gpt-5.1`. To use a cheaper / faster variant without editing code:

```bash
export OPENAI_MODEL="gpt-5.1-mini"
# then run any test command above
```

To switch back, `unset OPENAI_MODEL` or close the terminal.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Test skipped: OPENAI_API_KEY 未设置` | Key missing from env + Keychain | `source ~/.openai_key.sh` in the same shell that runs `xcodebuild` |
| `Test skipped: data_samples_5.json 不存在` | Missing test data | Run `TESTING.md` §Prerequisites Python snippet |
| `OpenAI HTTP 401` | Invalid / revoked API key | Generate a new key on platform.openai.com, edit `~/.openai_key.sh`, re-source |
| `OpenAI HTTP 400 model_not_found` | Model name typo or no access | Verify with `curl https://api.openai.com/v1/models -H "Authorization: Bearer $OPENAI_API_KEY" \| grep gpt-5` |
| `OpenAI HTTP 429` printed but no retry | Error message doesn't contain trigger keywords | Check raw response in `[OpenAI] ✗` log; expand `withRetry` triggers if needed |
| `Could not parse OpenAI response` | Model returned non-JSON | Check raw response printed by `[OpenAI] ✗`; verify `response_format: json_object` is supported by the chosen model |
| Test times out | Slow network or large images | Run Test 0 first to confirm data loads; try Test 1 alone |
| `No such module 'XCTest'` in IDE | SourceKit false positive | Ignore — compiles fine in Xcode |
| Xcode GUI test says key missing but CLI works | GUI didn't inherit shell env | Launch Xcode from a sourced terminal (`open GlassesNotes.xcodeproj`) OR add `OPENAI_API_KEY` to Scheme → Test → Environment Variables |

---

## Cost Estimate (rough)

Per `test_FullPipeline` run on `data_samples_5.json` (5 entries, 1024px images):

- Step 1: 5 vision calls × ~3 000 input tokens + ~200 output = ~16 K tokens
- Step 2: 1 text call × ~1 500 input + ~500 output = ~2 K tokens
- **Total: ~18 K tokens per full run**

Multiply by GPT-5.1 pricing for $/run. Use `OPENAI_MODEL=gpt-5.1-mini` for a
cheaper iteration loop while developing.
