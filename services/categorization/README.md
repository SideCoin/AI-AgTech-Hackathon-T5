# categorization

Agriculture-aware categorization service for **FarmNote** session folders.

Reads a captured session, asks Google Gemini to assign a short agronomic tag
to each observation's voice-note transcript, and writes results back to disk
in the exact shape Part 3 of [`PLAN.md`](../../PLAN.md) expects.

## Quick start

```bash
# install
pip install -e ".[dev]"

# set up env
cp .env.example .env
# edit .env and paste your Gemini API key

# categorize a session
python -m categorization run /path/to/session-folder

# inspect the taxonomy that has accumulated
python -m categorization list-categories

# wipe the taxonomy (asks for confirmation)
python -m categorization reset-db
```

## What it produces

Given an input folder like:

```
session-folder/
  session.json
  <uuid-1>.json            # { id, note, latitude, longitude, timestamp }
  <uuid-1>.jpg
  <uuid-2>.json
  <uuid-2>.jpg
```

after `run` the service:

1. **Updates each `<uuid>.json`** in place, adding a `"category": "<label>"` field.
2. **Writes `categories.json`** mapping each label to the observation IDs that
   belong to it:
   ```json
   {
     "aphid damage": ["<uuid-1>", "<uuid-2>"],
     "powdery mildew": ["<uuid-3>"]
   }
   ```
3. **Persists the taxonomy** in `taxonomy.db` (SQLite) so subsequent sessions
   reuse the same canonical labels.

## Architecture

```
session_io  ─┐
             │              ┌─ Gemini  (gemini-2.5-flash, JSON-mode)
service ─────┼─ classify ───┤
             │              └─ normalize  (rapidfuzz fuzzy dedup)
taxonomy ────┘                              │
                                            ▼
                                       taxonomy.db (SQLite)
```

See [`../../PLAN.md`](../../PLAN.md) §Part 2 for the integration contract.

## Testing

### 1. Setup

```bash
# Install the package and dev dependencies
pip install -e ".[dev]"

# Create your env file and paste your Gemini API key
cp .env.example .env
# Then open .env and set: GEMINI_API_KEY=<your key>
```

### 2. Offline smoke tests (no API key required)

Covers the full pipeline, normalization, and taxonomy — Gemini is monkey-patched,
no network call is made.

```bash
pytest tests/test_smoke.py -v
```

Expected output:

```
tests/test_smoke.py::TestPipeline::test_loads_all_observations PASSED
tests/test_smoke.py::TestPipeline::test_skips_manifest_files PASSED
tests/test_smoke.py::TestPipeline::test_categorize_writes_categories_json PASSED
tests/test_smoke.py::TestPipeline::test_categorize_patches_each_obs_json PASSED
tests/test_smoke.py::TestPipeline::test_index_covers_all_observations PASSED
tests/test_smoke.py::TestPipeline::test_empty_session_raises PASSED
tests/test_smoke.py::TestNormalize::test_clean_lowercases_and_trims PASSED
tests/test_smoke.py::TestNormalize::test_clean_is_idempotent PASSED
tests/test_smoke.py::TestNormalize::test_canonicalize_merges_near_duplicate PASSED
tests/test_smoke.py::TestNormalize::test_canonicalize_mints_new_label PASSED
tests/test_smoke.py::TestTaxonomy::test_find_or_create_new_label PASSED
tests/test_smoke.py::TestTaxonomy::test_find_or_create_reuses_existing PASSED
tests/test_smoke.py::TestTaxonomy::test_all_labels_sorted_by_usage PASSED
13 passed
```

### 3. End-to-end test with real Gemini API

A pre-built mock session with 7 agricultural observations is included in
`tests/fixtures/sample_session/` (powdery mildew, aphid infestation, leaf blight,
root rot, irrigation issue, nutrient deficiency, and one silent capture).

```bash
# Run categorization against the mock session
python -m categorization run tests/fixtures/sample_session/

# Inspect the category index written to disk
cat tests/fixtures/sample_session/categories.json

# Check what labels were added to the persistent taxonomy
python -m categorization list-categories
```

After a successful run each `<uuid>.json` in the session folder will have a
`"category"` field and `categories.json` will look like:

```json
{
  "powdery mildew": ["11111111-0001-..."],
  "aphid infestation": ["11111111-0002-..."],
  ...
}
```

> **Note:** The mock session data is static and committed to the repo. Re-running
> `python -m categorization run` on it will overwrite the category fields — that is
> expected. To reset it to the original uncategorised state run:
> `python tests/fixtures/gen_sample_session.py`
