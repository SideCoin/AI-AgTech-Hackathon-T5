# Testing the Gemini LLM Pipeline

Two commands. Run them in order. Total time: ~30s + ~3min.

## Prerequisites

### 1. Gemini API key

Set your key once (in Xcode: Scheme → Test → Arguments → Environment Variables):

```
GEMINI_API_KEY=AIza...
GEMINI_MODEL=gemini-2.0-flash    # optional, default is gemini-2.0-flash
```

Or export inline before `xcodebuild`:

```bash
export GEMINI_API_KEY=AIza...
```

### 2. Pick a simulator that exists on your machine

The commands below use `name=iPhone 16`. If you get
`Unable to find a device matching the provided destination specifier`,
list what you actually have installed:

```bash
xcrun simctl list devices available
```

Pick any name from the output (e.g. `iPhone 16 Pro`, `iPad mini (A17 Pro)`)
and substitute it into the `-destination` flag. Using the device UDID is even
more robust:

```bash
-destination 'platform=iOS Simulator,id=D95D7386-559A-4A44-A6F3-40AC1983804E'
```

---

## 1. Quick test — compress images + verify key (~30s)

Shrinks every `imageBase64` in `data_samples_5.json` to ≤768px / JPEG q=0.5, writes
`data_samples_5_compressed.json` next to it, then makes **one** Gemini call to
confirm the key works.

```bash
xcodebuild test \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:GlassesNotesTests/GeminiPipelineTests/test_Quick_CompressImagesAndPingGemini
```

**What you should see** in logs:
- Per-image `NNN KB → MM KB` lines
- Total ratio (typically 10–20% of original)
- One `[Gemini 响应] importance=… keynotes=N` line

If this passes, your key is valid and the compressed JSON is ready.

---

## 2. Full pipeline — Step 1 (image summary) + Step 2 (categorization) (~3min)

Runs both stages on all 5 entries and writes results to a temp dir.
**Auto-uses the compressed JSON** from step 1 if it exists (much faster uploads).

```bash
xcodebuild test \
  -scheme GlassesNotes \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:GlassesNotesTests/GeminiPipelineTests/test_FullPipeline
```

**What you should see** in logs:
- `Step1 [i/5]` progress lines, one Gemini call per entry
- `✓ 5 条分析完成`
- `[PRIORITY] category: N 条` group summary
- Final `Step1 输出: ...` and `Step2 输出: ...` paths

**Outputs land here** (persistent — not wiped by tearDown):

```
AI-AgTech-Hackathon-T5/services/analysis/my_session/
├── data_samples_5_compressed.json   ← from Test 1
└── results/
    ├── step1_results.json           ← Step 1 per-row analysis
    └── step2_categorized.json       ← Step 2 LLM-grouped categories
```

Re-running overwrites in place.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Unable to find a device matching the provided destination` | Your simulator name doesn't exist locally — run `xcrun simctl list devices available` and swap the name (see Prerequisites §2) |
| `XCTSkip: GEMINI_API_KEY 未设置` | Set the env var (see Prerequisites §1) |
| HTTP 429 / `RESOURCE_EXHAUSTED` | Built-in retry handles it; if it loops, switch model: `GEMINI_MODEL=gemini-2.0-flash` (1500 req/day free) |
| Test 1 always re-compresses | Expected — it reads `rawData5URL` explicitly, so re-runs always start from the original |
| Test 2 unexpectedly slow | Delete `data_samples_5_compressed.json` to fall back to raw, or run Test 1 first |
