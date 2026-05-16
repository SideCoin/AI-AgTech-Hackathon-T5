# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**FarmNote** (Xcode target name: `GlassesNotes`) — an iOS + Meta Ray-Ban Glasses app for
field annotation. A user walks a field, captures *photo + voice note + GPS* triplets via
voice command or the glasses capture button, then the app categorizes the session with a
vLLM and visualizes the result on a filterable map.

Authoritative design doc: [`PLAN.md`](./PLAN.md). Read it before non-trivial work — it
defines the three tracks (Part 1 capture / Part 2 categorization / Part 3 map) and the
shared `Observation` model and on-disk session schema that all three depend on.

Current code state: fresh Xcode template (SwiftUI "Hello, world!"). None of the Part 1–3
modules described in `PLAN.md` exist yet.

## File Structure

```
AI-AgTech-Hackathon-T5/
├── README.md                              # Repo name only — no content yet
├── PLAN.md                                # Full design / implementation plan (source of truth)
├── CLAUDE.md                              # This file
├── .gitignore                             # Standard Xcode/Swift ignores
│
├── GlassesNotes.xcodeproj/                # Xcode project
│   ├── project.pbxproj                    # Xcode build settings, targets, file refs
│   └── project.xcworkspace/
│       ├── contents.xcworkspacedata
│       └── xcshareddata/swiftpm/
│           └── Package.resolved           # Pins meta-wearables-dat-ios @ 0.7.0
│
├── GlassesNotes/                          # Main app target (iOS)
│   ├── GlassesNotesApp.swift              # @main App entry; mounts ContentView
│   ├── ContentView.swift                  # Root SwiftUI view (currently template stub)
│   └── Assets.xcassets/                   # App icons, accent color, image assets
│       ├── Contents.json
│       ├── AccentColor.colorset/Contents.json
│       └── AppIcon.appiconset/Contents.json
│
├── GlassesNotesTests/                     # Unit test target (Swift Testing framework)
│   └── GlassesNotesTests.swift            # Placeholder @Test stub
│
└── GlassesNotesUITests/                   # UI test target (XCTest)
    ├── GlassesNotesUITests.swift          # Placeholder XCUIApplication test
    └── GlassesNotesUITestsLaunchTests.swift  # Launch screenshot test
```

## File-by-File Introduction

### Documentation
- **`PLAN.md`** — Implementation plan. Defines the shared `Observation` struct, on-disk
  session folder layout (`Documents/sessions/<sessionID>/`), and the responsibilities of
  Parts 1/2/3 plus their handoff contracts. **Treat this as authoritative.**
- **`README.md`** — Currently a one-line title placeholder.

### App source (`GlassesNotes/`)
- **`GlassesNotesApp.swift`** — `@main` entry point. SwiftUI `App` that opens a single
  `WindowGroup` containing `ContentView`.
- **`ContentView.swift`** — Root view. Still the Xcode template (globe icon + "Hello,
  world!"). Will be replaced by Part 3's `MapView` / session UI.
- **`Assets.xcassets/`** — Asset catalog for app icon, accent color, and any future
  images.

### Tests
- **`GlassesNotesTests/GlassesNotesTests.swift`** — Unit tests using Apple's new
  `Testing` framework (`@Test` macros). Currently empty.
- **`GlassesNotesUITests/GlassesNotesUITests.swift`** — XCTest UI tests; launches the
  app and asserts. Currently a stub.
- **`GlassesNotesUITests/GlassesNotesUITestsLaunchTests.swift`** — Captures a launch
  screenshot per UI configuration; useful for App Store screenshots.

### Project config
- **`GlassesNotes.xcodeproj/project.pbxproj`** — Xcode project file (targets, build
  settings, file references). Don't hand-edit unless necessary; prefer changes through
  Xcode so the file stays valid.
- **`project.xcworkspace/xcshareddata/swiftpm/Package.resolved`** — Swift Package
  Manager lockfile. Pins `meta-wearables-dat-ios` (Meta's DAT SDK for Ray-Ban Glasses)
  to version `0.7.0` from `github.com/facebook/meta-wearables-dat-ios`. This SDK is
  the basis for Part 1 (voice commands, capture button, camera stream).

## Where future code is expected to land

Following `PLAN.md`'s layout, expect to create:

- `GlassesNotes/Shared/Models.swift` — the shared `Observation` struct (build this first).
- `GlassesNotes/Capture/` — Part 1: `SessionManager.swift`, `CaptureCoordinator.swift`,
  `ObservationStore.swift`.
- `GlassesNotes/Categorization/` — Part 2: `CategorizationService.swift` (Claude API
  client, model `claude-sonnet-4-6` with vision), `CategoryIndex.swift`.
- `GlassesNotes/Map/` — Part 3: `MapView.swift`, `CategorySidebarView.swift`,
  `ObservationDetailView.swift`, `SessionStatusBar.swift`.

These directories don't exist yet — create them as work begins on each track.

## Conventions / gotchas

- **Swift Testing, not XCTest, for unit tests.** Unit target uses `import Testing` +
  `@Test`. The UI target still uses `XCTest` (that's the Xcode default — leave it).
- **Required Info.plist permissions** (see `PLAN.md` §Part 1): camera, microphone,
  location *always-on*, Bluetooth. Add usage description strings when wiring up the DAT
  SDK or the app will crash on first permission request.
- **Session folder is the integration contract.** Parts 1, 2, and 3 communicate only
  through files under `Documents/sessions/<sessionID>/`. Don't introduce in-memory
  cross-module coupling that bypasses this.
- **Categories schema must be agreed upfront.** Per `PLAN.md`, the only hard
  cross-track dependency before integration week is `categories.json`'s shape:
  `{ "<category>": ["<obsId>", ...] }`.
- **Model IDs:** use `claude-sonnet-4-6` for vision categorization (per the plan). When
  building the Anthropic SDK client, enable prompt caching for the batched prompt.

## Build / run

Open `GlassesNotes.xcodeproj` in Xcode and run on an iOS simulator or a paired device.
There is no CLI build script; SwiftPM dependencies resolve automatically on first open.
