# Categorization Service — Function Reference

> **Setup first:** see [README.md](./README.md) for installation and environment configuration.

This document is a module-by-module reference for every public symbol in the service.
For the integration contract with the iOS app see [`../../PLAN.md`](../../PLAN.md) §Part 2.

---

## Public API (top-level imports)

```python
from categorization import categorize, GeminiClassifier, Taxonomy
```

| Symbol | Kind | One-liner |
|--------|------|-----------|
| `categorize` | function | Run the full pipeline on a session folder |
| `GeminiClassifier` | class | Low-level Gemini API wrapper |
| `Taxonomy` | class | SQLite-backed canonical label store |

---

## `models.py` — Data Schemas

Pydantic models that mirror the on-disk JSON written by the iOS capture pipeline.

### `Observation`

```python
class Observation(BaseModel):
    id: UUID
    note: str                  # voice-transcribed; empty string on silence
    latitude: float
    longitude: float
    timestamp: datetime
    category: Optional[str]    # None until this service writes it back
```

Represents one field observation. Field names match the Swift struct exactly so
`<uuid>.json` files written by the iOS app are directly readable.

### `SessionManifest`

```python
class SessionManifest(BaseModel):
    sessionID: str
    start: datetime
    end: Optional[datetime]    # None while the session is still active
```

Metadata for the whole session. Written by Part 1 (capture); this service only reads it.

### `CategorizedItem`

```python
class CategorizedItem(BaseModel):
    observation_id: UUID
    raw_label: str             # label as returned by Gemini
    canonical_label: str       # resolved canonical after fuzzy dedup
```

Internal bookkeeping record. Not written to disk; useful for logging and debugging
fuzzy-match decisions.

---

## `normalize.py` — Label Cleaning

Deterministic string normalization and fuzzy-match deduplication.

### `clean(raw: str) -> str`

Lowercase, strip leading/trailing whitespace, and collapse internal whitespace to
single spaces. Idempotent: `clean(clean(x)) == clean(x)`.

```python
clean("  Aphid   Damage  ")   # → "aphid damage"
clean("LEAF RUST")            # → "leaf rust"
```

### `canonicalize(raw, existing, threshold=88) -> tuple[str, Optional[str]]`

Pick the canonical label for `raw` given the current taxonomy.

**Parameters**

| Parameter | Type | Description |
|-----------|------|-------------|
| `raw` | `str` | Label as returned by Gemini (or already cleaned) |
| `existing` | `list[str]` | All current canonical labels |
| `threshold` | `int` | rapidfuzz `token_sort_ratio` score (0–100) above which two labels are treated as synonyms. Default `88`. |

**Returns** `(canonical, matched)` where:
- `canonical` — the label to use going forward.
- `matched` — the existing label `raw` was merged into, or `None` when a new label was minted.

**Threshold calibration**

| Pair | Score | Result |
|------|-------|--------|
| `"aphid damage"` vs `"aphid damages"` | ~96 | merged |
| `"powdery mildew"` vs `"downy mildew"` | ~70 | kept distinct |
| `"leaf rust"` vs `"stem rust"` | ~60 | kept distinct |

---

## `taxonomy.py` — Canonical Label Store

SQLite-backed master taxonomy shared across all sessions.

### `Taxonomy(db_path: Path | str)`

Open (or create) the taxonomy database. Use as a context manager:

```python
with Taxonomy("./taxonomy.db") as tax:
    label = tax.find_or_create("aphid damage")
```

Pass `":memory:"` for a transient in-process DB (useful in tests).

**Schema**

```sql
categories  (id PK, label UNIQUE, first_seen TEXT, usage_count INT)
aliases     (alias PK, category_id FK → categories.id)
```

### `all_labels() -> list[str]`

Return every canonical label sorted by descending usage count then alphabetically.
Fed to the Gemini prompt so the most-used labels appear first.

### `find_or_create(raw_label: str) -> str`

Resolve `raw_label` to a canonical label, creating one if needed.

Resolution order:
1. `clean(raw_label)`.
2. Alias short-circuit (cached from a previous fuzzy match — cheaper than re-running rapidfuzz).
3. Fuzzy match via `canonicalize()` against existing canonicals.
4. Mint a brand-new canonical and insert it into `categories`.

Bumps the canonical's `usage_count` by 1 on every call.

```python
tax.find_or_create("Aphid Damage")   # → "aphid damage"  (new canonical, count=1)
tax.find_or_create("aphid damages")  # → "aphid damage"  (fuzzy merged, count=2)
```

### `add_alias(alias: str, canonical: str) -> None`

Register `alias` as an explicit synonym for `canonical`. No-op when they are equal.
Raises `KeyError` if `canonical` is not yet in the taxonomy.

### `usage_count(label: str) -> int`

Return how many times `label` has been resolved to. Returns `0` if unknown.

### `summary() -> list[tuple[str, int, str]]`

Return `(label, usage_count, first_seen)` rows sorted by descending usage then
alphabetically. Used by the `list-categories` CLI command.

---

## `gemini_client.py` — Gemini API Wrapper

### `GeminiClassifier(api_key=None, model=None)`

**Parameters**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `api_key` | `$GEMINI_API_KEY` | Gemini API key |
| `model` | `$GEMINI_MODEL` or `"gemini-2.5-flash"` | Model ID |

### `classify(observations, existing_labels, session_dir=None) -> dict[str, str]`

Classify a batch of observations in **one** Gemini API call.

**Parameters**

| Parameter | Type | Description |
|-----------|------|-------------|
| `observations` | `list[Observation]` | Observations to categorize |
| `existing_labels` | `list[str]` | Known canonical labels (model is prompted to prefer these) |
| `session_dir` | `Optional[Path]` | If given, loads `<uuid>.jpg` thumbnails for vision-augmented classification |

**Returns** `{ str(obs.id): raw_label }` for every observation in the batch.
Missing IDs (model skipped them) default to `"uncategorized"` in the caller.

**Prompt design**
- System instruction: instructs Gemini to prefer existing labels, use 2–4 word lowercase labels, return JSON only.
- User message: header listing up to 30 known labels, then one Part per observation (JSON metadata + optional inline JPEG), then a JSON-format footer.
- Config: `response_mime_type="application/json"`, `temperature=0.2`.
- **Image encoding:** images are loaded from disk as raw `bytes` (`jpg_path.read_bytes()`)
  and wrapped in `types.Blob(mime_type="image/jpeg", data=bytes)`. The `google-genai` SDK
  base64-encodes the bytes automatically when building the HTTP request — no manual
  base64 handling is needed in application code.

---

## `service.py` — Main Pipeline

### `categorize(session_dir, db_path=DEFAULT_DB, *, api_key=None, model=None) -> dict[str, list[str]]`

Run the full categorization pipeline on a session folder.

**Parameters**

| Parameter | Type | Description |
|-----------|------|-------------|
| `session_dir` | `Path \| str` | Session folder containing `<uuid>.json` + `<uuid>.jpg` pairs |
| `db_path` | `Path \| str` | Taxonomy SQLite DB (created on first run). Defaults to `$TAXONOMY_DB_PATH` or `./taxonomy.db` |
| `api_key` | `str \| None` | Gemini API key override |
| `model` | `str \| None` | Model ID override |

**Returns** `{ "aphid damage": ["<uuid1>", "<uuid2>"], ... }` — the same mapping
written to `categories.json`.

**Raises** `ValueError` if no observations are found in `session_dir`.

**Side effects**
1. Each `<uuid>.json` is updated in place with `"category": "<label>"`.
2. `categories.json` is written (or overwritten) in `session_dir`.
3. New canonical labels are persisted in the taxonomy DB.

**Pipeline steps**

```
load <uuid>.json files
        │
        ▼
GeminiClassifier.classify()   ← one batched API call
        │
        ▼  raw label per observation
Taxonomy.find_or_create()     ← fuzzy dedup + persistence
        │
        ▼  canonical label per observation
write <uuid>.json (category field)
write categories.json
```

### Internal helpers (not exported)

| Function | Description |
|----------|-------------|
| `_load_observations(session_dir)` | Scan for `<uuid>.json` files, skip `session.json` and `categories.json` |
| `_write_observation_back(session_dir, obs)` | Patch `category` into a single `<uuid>.json` without touching other fields |
| `_write_categories_json(session_dir, observations)` | Build and write the `{ label: [uuid, ...] }` index |

---

## `cli.py` — Command-Line Interface

Invoked as `python -m categorization <command>` or via the `categorization` script
installed by `pip install -e .`.

### Global option

```
--db PATH    Taxonomy SQLite DB path (default: $TAXONOMY_DB_PATH or ./taxonomy.db)
```

### `run <session_dir>`

Categorize all observations in the given session folder. Prints a per-category count
summary on completion.

```bash
python -m categorization run ./Documents/sessions/abc-123/
# Categorizing ./Documents/sessions/abc-123/ …
# Done. 3 categories across 7 observations.
#   aphid damage (3)
#   irrigation issue (2)
#   powdery mildew (2)
```

### `list-categories`

Print all canonical labels with usage counts and the date they were first seen.

```bash
python -m categorization list-categories
# Label                                     Uses  First seen
# ---------------------------------------------------------------
# aphid damage                                 5  2026-05-15
# powdery mildew                               2  2026-05-16
```

### `reset-db`

Interactively drop the taxonomy database. Asks for explicit `y` confirmation before
deleting; any other input aborts.

```bash
python -m categorization reset-db
# Delete './taxonomy.db' and reset all taxonomy? [y/N] y
# Deleted ./taxonomy.db.
```

---

## Data-Flow Overview

```
iOS app (Part 1)
    writes session folder
        Documents/sessions/<sessionID>/
            session.json
            <uuid-1>.json  ←──┐
            <uuid-1>.jpg  ←──┤  read by service.py
            <uuid-2>.json  ←──┤
            <uuid-2>.jpg  ←──┘

categorize(session_dir)
    │
    ├─ GeminiClassifier.classify()
    │       sends notes + thumbnails → gemini-2.5-flash → { uuid: raw_label }
    │
    ├─ Taxonomy.find_or_create()
    │       fuzzy dedup → canonical label
    │       persists in taxonomy.db
    │
    └─ writes back:
            <uuid-1>.json  (+ "category": "aphid damage")
            <uuid-2>.json  (+ "category": "powdery mildew")
            categories.json  →  { "aphid damage": ["<uuid-1>"], ... }

iOS app (Part 3)
    reads categories.json → renders map + sidebar
```

---

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GEMINI_API_KEY` | Yes | — | Gemini API key from [aistudio.google.com](https://aistudio.google.com/apikey) |
| `GEMINI_MODEL` | No | `gemini-2.5-flash` | Model ID override (e.g. `gemini-2.5-pro`) |
| `TAXONOMY_DB_PATH` | No | `./taxonomy.db` | Path to the persistent SQLite taxonomy DB |
