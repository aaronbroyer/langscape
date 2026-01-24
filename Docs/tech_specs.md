# Langscape MVP – Technical Specs (Swift Best Practices)

> iOS-only MVP. SwiftUI + CoreML. Fully offline. Portrait-only.  
> Goals: simple, testable architecture; clean repo; easy to scale.

---

## 1) Architecture & Patterns
- **App architecture:** **MVVM** with unidirectional data flow.
- **Modularity:** Split into Swift Packages to keep compile times down and boundaries clear.
- **State management:** `@State`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject` (sparingly). Avoid singletons except for immutable config.
- **Async:** `async/await` + `Task` for model loading and detection. Avoid callbacks.
- **Dependency injection:** Lightweight DI via initializers/protocols.
- **Error handling:** `Error` enums per module; surface user-safe messages via view models.
- **Design system:** Centralized colors/typography/components.

---

## 2) Modules (Swift Packages)
```
Langscape.xcworkspace
├─ App/                      # iOS app target (thin)
│  ├─ AppDelegate.swift
│  ├─ LangscapeApp.swift
│  └─ Resources/Assets.xcassets
├─ Packages/
│  ├─ DetectionKit/          # YOLOv8 CoreML wrapper + Vision utilities
│  │  ├─ Sources/DetectionKit/
│  │  │  ├─ DetectionService.swift
│  │  │  ├─ YOLOInterpreter.swift
│  │  │  └─ Models/YOLOv8.mlmodelc
│  ├─ LLMKit/                # On‑device LLM utilities (Phi‑3 mini, quantized)
│  │  ├─ Sources/LLMKit/
│  │  │  ├─ LLMService.swift
│  │  │  └─ Models/phi3.gguf (or similar)
│  ├─ GameKitLS/             # Label Scramble game logic (no UI)

│  │  ├─ Sources/GameKitLS/
│  │  │  ├─ LabelEngine.swift
│  │  │  ├─ RoundGenerator.swift
│  │  │  └─ Entities/{DetectedObject.swift, Label.swift}
│  ├─ UIComponents/          # Reusable SwiftUI views (cards, badges, overlays)
│  │  ├─ Sources/UIComponents/
│  │  │  ├─ ActivityCard.swift
│  │  │  ├─ TranslucentPanel.swift
│  │  │  └─ PauseOverlay.swift
│  ├─ DesignSystem/          # Colors, typography, spacing, icons
│  │  ├─ Sources/DesignSystem/
│  │  │  ├─ DSColor.swift
│  │  │  ├─ DSType.swift
│  │  │  └─ DSIcon.swift
│  ├─ Utilities/             # Logging, Settings, Extensions
│  │  ├─ Sources/Utilities/
│  │  │  ├─ Logger.swift
│  │  │  ├─ AppSettings.swift
│  │  │  └─ Geometry+Ext.swift
│  └─ LLMKit/                # Translation service + local Marian models
└─ Config/
   ├─ SwiftLint.yml
   ├─ SwiftFormat/.swiftformat
   ├─ XCConfig/ (per‑config build settings)
   └─ Scripts/
      ├─ prebuild_lint.sh
      └─ verify_models.sh
```
**Why this split?** Clear boundaries: detection, LLM, game logic, UI, and design tokens evolve independently and are testable in isolation.

---

## 3) View Layer (high level)
- **Onboarding** -> **HomeOverlay** -> **DetectionGate** -> **LabelScrambleView**.
- **ViewModels** per screen: `OnboardingVM`, `HomeVM`, `DetectionVM`, `LabelScrambleVM`.
- **Navigation:** Single `NavigationStack`. Home overlay presented over camera preview.

---

## 4) Core Services (protocol-first)
```swift
public protocol ObjectDetectionService {
  func detect(in pixelBuffer: CVPixelBuffer) async throws -> [DetectedObject]
}

public protocol LLMServiceProtocol {
  func translate(_ english: String, to target: Language) async throws -> String
}
```
- Concrete implementations live in `DetectionKit` and `LLMKit`.
- `LabelEngine` (in `GameKitLS`) orchestrates rounds from detected objects + translation rules.

---

## 5) Data & Models
- **DetectedObject:** id, className, bbox, confidence.
- **Label:** id, surfaceForm (e.g., *el árbol*), targetClassName.
- **Round:** id, labels[5–7], objects[5–7].
- **Language:** `.english`, `.spanish` (UI text remains English in MVP).

---

## 6) Resources
- **Models bundled in packages** (`.mlmodelc`, quantized LLM file).
- **Translation assets** (Marian CoreML models, tokenizers, vocab JSON).
- **Assets:** logo (PDF vector), icons (SF Symbols where possible).

---

## 7) Coding Standards
- **Style tools:** SwiftLint + SwiftFormat.
- **Nomenclature:** lowerCamelCase vars; UpperCamelCase types; `final` on non‑open classes; `private` by default.
- **Immutability:** prefer `let`; avoid shared mutable state.
- **Concurrency:** isolate long‑running work off main actor; mark view models `@MainActor` when needed.
- **Layout:** SwiftUI + `LayoutPriority`; avoid magic numbers—use `DesignSystem` spacing.

### SwiftLint (excerpt)
```yaml
disabled_rules:
  - trailing_whitespace
opt_in_rules:
  - explicit_init
  - collection_alignment
  - vertical_whitespace_opening_braces
included:
  - App
  - Packages
identifier_name:
  min_length: 2
line_length:
  warning: 140
  error: 200
type_body_length:
  warning: 300
```
### SwiftFormat (excerpt)
```
--rules indent,wrapArguments,wrapCollections,numberFormatting,organizeDeclarations
--ifdef no-indent
--indent 2
--maxwidth 140
```

---

## 8) Build Config & Scripts
- **XCConfig layers:** `Base.xcconfig`, `Debug.xcconfig`, `Release.xcconfig`.
- **Build Phases:**
  - *Run Script:* `prebuild_lint.sh` -> run SwiftLint + SwiftFormat (fail on error in CI; warn locally).
  - *Run Script:* `verify_models.sh` -> assert presence + checksum of model files.
- **SPM only** (no CocoaPods).

Example `prebuild_lint.sh`:
```sh
if which swiftlint >/dev/null; then
  swiftlint --config Config/SwiftLint.yml
else
  echo "warning: SwiftLint not installed"
fi
if which swiftformat >/dev/null; then
  swiftformat . --config Config/SwiftFormat/.swiftformat
else
  echo "warning: SwiftFormat not installed"
fi
```

---

## 9) Logging & Errors
- `Logger` facade wraps `os.Logger` (Debug: verbose; Release: errors only).
- Persist last 100 errors to a rolling file for manual QA (no network).
- User‑visible errors are minimal (“Please restart Langscape”).

---

## 10) Performance Targets
- Camera preview ≥ **30 FPS** on iPhone 12+.
- Detection loop budget **< 150 ms** per frame.
- Model size budget **≤ 500 MB** (YOLO + LLM + assets).

---

## 11) Git & Project Hygiene
- **Branching:** `main` (protected), `feature/*`, `fix/*`.
- **Commits:** Conventional style (e.g., `feat(game): add snap-to-place`).
- **PR checks (later):** build + lint (CI optional post‑MVP).
- **Code review checklist:** module boundaries, thread safety, no force unwraps, no TODOs in release.

---

## 12) Roadmap Hooks (post‑MVP)
- Add **ProgressStore** package; **ReviewKit** (spaced repetition).
- Add **SceneContextKit** for café/park inference.
- Add **AudioKit** wrapper for TTS/pronunciation (optional).

---

## 13) Minimum iOS Capabilities
- `NSCameraUsageDescription` string in Info.plist.
- Background modes: **none**.
- App Transport Security: default.

---

## 14) Build Targets
- **Xcode:** 15+
- **Swift:** 5.9
- **iOS:** 17.0+

---

### TL;DR
Use MVVM with clear SwiftPM modules: DetectionKit, LLMKit, GameKitLS, UIComponents, DesignSystem, Utilities. Enforce lint/format, script checks, and keep the app target thin.
