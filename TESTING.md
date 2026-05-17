# LLM Pipeline Testing Guide

Tests for the two-step Gemini pipeline: image analysis → LLM categorization.

**Test file:** `GlassesNotesTests/GeminiPipelineTests.swift`  
**Test data:** `services/analysis/my_session/data_samples_5.json` (5 poultry farm observations with JPEG images)  
**Simulator:** iPhone 16 Pro (`E01584D0-38FD-45A4-9575-1EEC332F1A61`) — already booted

---

## Prerequisites

### 1. Generate test data (run once)

`data_samples_5.json` is built from the existing CSV + JPG files.
Images are resized to **1024px longest edge** before embedding — the original 5–6 MB JPEGs
cost ~47 000 tokens each; at 1024px they cost ~3 000 tokens (~94% cheaper).

```bash
cd services/analysis/my_session

# Uses anaconda Python which has Pillow installed
/Users/zhengmiao/anaconda3/bin/python3 - <<'EOF'
import csv, base64, json, uuid, io
from pathlib import Path
from datetime import datetime, timezone
from PIL import Image

csv_path = Path("poultry_raw_notes_10_rows_llm_ready.csv")
jpg_dir  = Path("jpg")
MAX_PX   = 1024   # longest edge — Gemini's sweet spot for quality vs cost

entries = []
with open(csv_path) as f:
    reader = csv.DictReader(f)
    for i, row in enumerate(reader):
        if i >= 5:
            break
        dt = datetime.strptime(row["time"], "%m/%d/%Y %H:%M").replace(tzinfo=timezone.utc)
        jpg_path = jpg_dir / row["jpg_name"]
        if jpg_path.exists():
            img = Image.open(jpg_path)
            ratio = MAX_PX / max(img.width, img.height)
            if ratio < 1:
                img = img.resize((int(img.width * ratio), int(img.height * ratio)), Image.LANCZOS)
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=82)
            print(f"  {row['jpg_name']}: {jpg_path.stat().st_size//1024} KB → {len(buf.getvalue())//1024} KB")
            img_b64 = base64.b64encode(buf.getvalue()).decode()
        else:
            img_b64 = ""
        entries.append({
            "id":          str(uuid.uuid4()),
            "time":        dt.isoformat().replace("+00:00", "Z"),
            "latitude":    float(row["gps_lat"]),
            "longitude":   float(row["gps_lng"]),
            "notes":       row["note"],
            "imageBase64": img_b64,
        })

Path("data_samples_5.json").write_text(
    json.dumps({"entries": entries}, ensure_ascii=False, indent=2)
)
print(f"✓ {len(entries)} entries written — total {Path('data_samples_5.json').stat().st_size//1024} KB")
EOF
```

### 2. API Key

The test reads `GEMINI_API_KEY` from the environment and falls back to the value hardcoded in `GeminiPipelineTests.swift`. No extra setup needed for local runs.

To override:
```bash
export GEMINI_API_KEY=your_key_here
```

---

## Test Commands

All commands run from the project root:

```bash
cd /Users/zhengmiao/UCDavis/Competition/AIFS_Hackathon/AI-AgTech-Hackathon-T5
```

---

### Test 0 — Parse JSON only (no API calls, ~5s)

Verifies `data_samples_5.json` is readable and contains 5 entries with images.

```bash
xcodebuild test \
  -project GlassesNotes.xcodeproj \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,id=E01584D0-38FD-45A4-9575-1EEC332F1A61' \
  -only-testing:GlassesNotesTests/GeminiPipelineTests/test_Step0_ParseDataSamples5 \
  2>&1 | grep -E "Test|PASS|FAIL|error:|note:"
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

### Test 1 — Image + notes analysis via Gemini (~30–60s, 5 API calls)

Sends each observation (voice note + JPEG) to `gemini-2.5-flash` and returns `importance`, `keynotes`, `image_report`.

```bash
xcodebuild test \
  -project GlassesNotes.xcodeproj \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,id=E01584D0-38FD-45A4-9575-1EEC332F1A61' \
  -only-testing:GlassesNotesTests/GeminiPipelineTests/test_Step1_AnalyzeJSON \
  2>&1 | grep -E "\[Gemini\]|\[HIGH\]|\[MEDIUM\]|\[LOW\]|Step|图片描述|Test|PASS|FAIL|⚠"
```

Expected output:
```
[Gemini] → gemini-2.5-flash | note: "A-03: I heard coughing..." | image: true
[Gemini] ✓ importance=high keynotes=2 hasImage=true
  [1/5] Gemini 分析中…
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

Runs Step 1 then groups all rows into at most 2 thematic categories via a single Gemini call.

```bash
xcodebuild test \
  -project GlassesNotes.xcodeproj \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,id=E01584D0-38FD-45A4-9575-1EEC332F1A61' \
  -only-testing:GlassesNotesTests/GeminiPipelineTests/test_Step2_Classify \
  2>&1 | grep -E "\[Gemini\]|\[LLMCategorize\]|Step|分类|HIGH|MEDIUM|LOW|Test|PASS|FAIL|⚠"
```

Expected output:
```
[LLMCategorize] → classify 5 rows, maxCats=2
[LLMCategorize] ✓ 5 classifications received
── Step 2: LLM 分类结果（最多 2 组）──
  [HIGH] Respiratory / Health Issues：3 条
  [MEDIUM] Environmental / Husbandry：2 条
Test Case 'test_Step2_Classify' passed
```

---

### Test 3 — Full pipeline + save to disk (~90–120s)

Runs Step 1 → Step 2 → saves both result files to a temp directory and verifies they can be reloaded.

```bash
xcodebuild test \
  -project GlassesNotes.xcodeproj \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,id=E01584D0-38FD-45A4-9575-1EEC332F1A61' \
  -only-testing:GlassesNotesTests/GeminiPipelineTests/test_FullPipeline \
  2>&1 | grep -E "\[Gemini\]|\[LLMCategorize\]|Step|分类|✓|✗|Test|PASS|FAIL|输出|⚠"
```

Expected output:
```
══ 完整流水线：图片理解 → 分类 ══
  Step1 [1/5]
  ...
  ✓ 5 条分析完成
  ✓ 2 个分类
    [HIGH] Respiratory / Health Issues：3 条
  Step1 输出：/tmp/GeminiPipelineTests-.../step1_results.json
  Step2 输出：/tmp/GeminiPipelineTests-.../step2_categorized.json
Test Case 'test_FullPipeline' passed
```

---

### Run all 4 tests in sequence

```bash
xcodebuild test \
  -project GlassesNotes.xcodeproj \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,id=E01584D0-38FD-45A4-9575-1EEC332F1A61' \
  -only-testing:GlassesNotesTests/GeminiPipelineTests \
  2>&1 | grep -E "\[Gemini\]|\[LLMCategorize\]|Step|图片描述|分类|✓|✗|Test Suite|PASS|FAIL|error:|⚠"
```

---

## Rate Limit Handling

The test suite retries automatically on HTTP 429. You will see:

```
⚠ 限流，31秒后重试 (1/5)
```

Retry delays use exponential backoff (15s → 30s → 60s → 120s, capped) or the `retry in Xs` hint from the API response.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Test skipped: data_samples_5.json 不存在` | Missing test data | Run the Prerequisites step above |
| `Gemini HTTP 400` | Bad request body | Check `GeminiAnalysisService.buildRequestBody` |
| `Gemini HTTP 403` | Invalid API key | Set `GEMINI_API_KEY` env var or update fallback in test file |
| `Could not parse Gemini response` | Model returned non-JSON | Check raw response printed by `[Gemini] ✗` |
| Test times out | Slow network or large images | Run Test 0 first to confirm data loads; try Test 1 alone |
| `No such module 'XCTest'` in IDE | SourceKit false positive | Ignore — compiles fine in Xcode |
