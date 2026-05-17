# analysis

Field report generator for **FarmNote** inspection sessions.

Takes a completed session folder (same format as `services/categorization`),
sends all voice notes + photos to Google Gemini in one call, and produces a
structured `report.json` describing problems found, severity, recommended
actions, and an executive summary.

Runs **after** (or independently of) the categorization service.

## Quick start

```bash
# install
cd services/analysis
pip install -e ".[dev]"

# set up env (same API key as categorization)
cp .env.example .env
# edit .env: GEMINI_API_KEY=<your key>

# generate a report (iOS session folder)
python -m analysis generate /path/to/session-folder

# generate a report from a CSV file + JPG directory
python -m analysis generate-csv \
    --csv my_session/poultry_raw_notes_10_rows_llm_ready.csv \
    --jpg-dir my_session/jpg \
    --results-dir results

# view an existing report
python -m analysis show /path/to/session-folder
```

## What it produces

Given an input session folder, the service writes `report.json`:

```json
{
  "session_id": "my-session-001",
  "generated_at": "2026-05-16T09:50:00Z",
  "time_range": "09:00–09:45 on 2026-05-16",
  "location_summary": "Agricultural field, rows 3-7, approx. 38.54°N 121.76°W",
  "total_observations": 7,
  "problems_found": ["powdery mildew", "aphid infestation", "blocked drip emitter"],
  "executive_summary": "The inspection identified 3 distinct issues...",
  "action_items": [
    "Fix blocked drip emitter on row 3 immediately.",
    "Apply insecticidal soap to aphid-infested plants within 24 hours."
  ],
  "observations": [
    {
      "observation_id": "<uuid>",
      "timestamp": "2026-05-16T09:03:00Z",
      "latitude": 38.5382,
      "longitude": -121.7617,
      "problem": "White powdery coating on lower leaves.",
      "severity": "medium",
      "recommendation": "Apply fungicide and improve air circulation."
    }
  ]
}
```

## Testing

### 1. Setup

```bash
pip install -e ".[dev]"
cp .env.example .env
# edit .env: GEMINI_API_KEY=<your key>
```

### 2. Offline smoke tests (no API key required)

```bash
pytest tests/test_smoke.py -v
```

Reuses the mock session from `services/categorization/tests/fixtures/sample_session/`.

### 3. End-to-end with real Gemini API

```bash
# Reuse the categorization mock session
python -m analysis generate ../categorization/tests/fixtures/sample_session/

# View the report in the terminal
python -m analysis show ../categorization/tests/fixtures/sample_session/

# Or read the raw JSON
cat ../categorization/tests/fixtures/sample_session/report.json
```

### CSV session (flat file + JPG folder)

```bash
python -m analysis generate-csv \
    --csv my_session/poultry_raw_notes_10_rows_llm_ready.csv \
    --jpg-dir my_session/jpg \
    --results-dir results

# View the JSON result
cat results/poultry_raw_notes_10_rows_llm_ready.json
```

## Running both services on the same session

```bash
# Step 1: Categorise (assigns short labels)
cd services/categorization
python -m categorization run /path/to/session

# Step 2: Analyse (generates full report)
cd services/analysis
python -m analysis generate /path/to/session
```

Both services write to the same session folder without conflicting:
- `categorization` writes `categories.json` + patches `category` in each `<uuid>.json`
- `analysis` writes `report.json` only

## Deployment Roadmap

### Phase 1 — Mac / Python ✅ Current
Python service runs on Mac, reads session folder from disk, calls Gemini API.

### Phase 2 — iOS / Swift 🔜 Next
Port `GeminiAnalyzer` + `analyze()` to Swift as
`GlassesNotes/Categorization/AnalysisService.swift`, calling the Gemini REST API
directly from the iOS app with images sent from memory.
