# FarmNote — Implementation Plan

## Overview

A Meta Glasses + iOS app for field annotation. Users walk around and capture photo + voice note + GPS triplets via voice commands or the glasses button. After a session, a vLLM categorizes all observations, and results are visualized on a map with a filterable sidebar.

**Flow:**
1. User starts a session via voice command
2. User captures observations (photo + optional voice note + GPS) via voice or button
3. User ends session via voice command
4. App sends all observations to a vLLM for categorization
5. App displays categorized pins on a map; sidebar filters by category; tapping a pin shows photo + note

---

## Shared Data Model

Define this first. All three tracks import it.

```swift
// Shared/Models.swift
struct Observation: Codable, Identifiable {
    let id: UUID
    let photoData: Data        // JPEG
    let note: String           // voice-transcribed
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    var category: String?      // nil until Part 2 runs
}
```

**Disk layout:** each observation is stored as a pair of files inside the session folder:

```
Documents/sessions/<sessionID>/
    session.json          # manifest with sessionID, start/end time
    <id>.json             # Observation metadata (no photoData field)
    <id>.jpg              # full-resolution image
    categories.json       # written by Part 2: { "aphid damage": ["<id1>", ...], ... }
```

---

## Part 1 — Photo: Glasses Integration & Capture

**Goal:** Produce a completed session folder containing `Observation` records (photo + note + GPS).

### Responsibilities

**1. SDK setup**
- Integrate Meta Glasses DAT SDK via Swift Package Manager
- Register the app with Meta AI developer portal
- Configure `Info.plist`: camera, microphone, location (always-on), Bluetooth permissions

**2. Session lifecycle**
- Implement `SessionManager` as a state machine: `idle → active → ended`
- Listen for voice commands `"start session"` / `"end session"` via the DAT voice API
- On start: generate `sessionID`, begin `CLLocationManager` updates, write `session.json`
- On end: finalize `session.json` with end timestamp, notify Part 3 via a completion callback

**3. Photo capture**
- Listen for:
  - Glasses capture button press (DAT button event)
  - Voice command `"take photo"` or `"capture"`
- On trigger: capture frame via `DATCameraStream`, snapshot current `CLLocation`
- Immediately show a prompt on the glasses display: `"Add a note? Say it now."`

**4. Voice note**
- After capture, open a 10-second `SFSpeechRecognizer` window
- Transcribe speech to `String`; store empty string on silence
- Assemble `Observation` and call `ObservationStore.save(_:)`

**5. Storage writer**
- `ObservationStore.save(_ obs: Observation)`: writes `<id>.json` + `<id>.jpg` to the session folder

### Key Files

| File | Purpose |
|------|---------|
| `SessionManager.swift` | State machine, voice command listener, session start/end |
| `CaptureCoordinator.swift` | Orchestrates photo → GPS → voice note sequence |
| `ObservationStore.swift` | Disk read/write; shared protocol used by Part 2 |

### Handoff to Part 2

A completed session folder at `Documents/sessions/<sessionID>/` with all `.json` + `.jpg` pairs and a finalized `session.json`.

---

## Part 2 — Grouping: AI Categorization

**Goal:** Read a session folder, assign a short category label to each observation via a vLLM, and write results back to disk.

### Responsibilities

**1. Session reader**
- Implement `ObservationStore.load(sessionID:) -> [Observation]`
- Reads all `<id>.json` + `<id>.jpg` pairs from the session folder

**2. vLLM client**
- Build `CategorizationService` using the Claude API (`claude-sonnet-4-6`) with vision support
- Strategy: one batched prompt containing all notes + thumbnail images, requesting a 2–4 word category label per observation ID
- Parse the structured JSON response mapping `id → category`

**Prompt template:**
```
You are a field scout assistant. For each observation below, assign a 2-4 word category
describing what was observed. Be consistent: use the same label for the same phenomenon.
Return JSON only: { "<id>": "<category>", ... }

Observations:
[{ "id": "...", "note": "...", "image": <base64 thumbnail> }, ...]
```

**3. Category normalization**
- Post-process raw labels: lowercase, trim whitespace
- Deduplicate near-synonyms (e.g. `"aphid damage"` vs `"aphid infestation"`) with a short follow-up normalization prompt or fuzzy string matching

**4. Write-back**
- Update each `<id>.json` with the `category` field
- Write `categories.json`: `{ "<category label>": ["<id1>", "<id2>"], ... }`

**5. Entry point**
- Expose `func categorize(sessionID: String) async throws`
- Part 3 calls this after session end and awaits completion before loading the map

### Key Files

| File | Purpose |
|------|---------|
| `CategorizationService.swift` | Claude API client, prompt construction, response parsing |
| `CategoryIndex.swift` | Loads/writes `categories.json`; used by Part 3 |

### Handoff to Part 3

`categories.json` written to the session folder; all `<id>.json` files updated with `category` populated.

---

## Part 3 — Frontend: Map & Visualization

**Goal:** Display categorized observations on an interactive map with a sidebar for filtering by category.

### Responsibilities

**1. Map view**
- Use MapKit (`Map` in SwiftUI or `MKMapView`)
- Load all observations from the session folder; place a custom `MKAnnotation` pin at each GPS coordinate
- Default pin color: gray. Selected-category pins: accent color, slightly larger

**2. Sidebar**
- Sheet or split-view panel listing all unique categories from `categories.json`
- Each row: category name + observation count
- Supports selection (single category at a time)

**3. Category selection**
- Tapping a category:
  - Highlights matching pins (accent color)
  - Dims or hides unrelated pins
  - Pans and zooms the map to fit selected pins (`MKMapRect` union)

**4. Pin detail**
- Tapping a pin presents a modal sheet containing:
  - Full-resolution photo
  - Transcribed note
  - Timestamp and coordinates

**5. Session status bar**
- Top bar showing current state: `Idle` / `Recording` / `Categorizing` / `Ready`
- Automatically reloads the map when `categorize(sessionID:)` completes

**6. Entry point**
- `"View on Map"` button appears when `categories.json` exists for a session
- Calls `CategoryIndex.load(sessionID:)` to populate the map

### Key Files

| File | Purpose |
|------|---------|
| `MapView.swift` | Map + annotation rendering + selection logic |
| `CategorySidebarView.swift` | Filterable category list |
| `ObservationDetailView.swift` | Photo + note modal |
| `SessionStatusBar.swift` | Session state indicator |

### Mock Data

Part 3 can build and test independently using a hard-coded `categories.json` and a folder of sample photos. No dependency on Parts 1 or 2 until integration week.

---

## Integration Sequence

```
[Meta Glasses] ──voice/button──▶ Part 1: SessionManager
                                       │
                                       │ writes session folder
                                       ▼
                                 Part 2: CategorizationService
                                       │
                                       │ writes categories.json
                                       ▼
                                 Part 3: MapView loads and displays
```

---

## Build Order

| Week | Track | Milestone |
|------|-------|-----------|
| 1 | All | Agree on `Observation` model and session folder schema |
| 1–2 | Part 1 | DAT SDK connected; photo + GPS + voice note capture working end-to-end |
| 1–2 | Part 3 | Map + sidebar + pin detail working against mock data |
| 2 | Part 2 | Claude API call working against a mock session folder |
| 3 | All | Full integration: real session on glasses → categorized map |

The only hard cross-track dependency before integration week is the `categories.json` schema, which Parts 2 and 3 must agree on upfront.
