# Langscape MVP Implementation Plan

This roadmap transforms the product vision into iterative sprints that surface a working prototype quickly while layering in the remaining UX, content, and stability requirements. Every sprint references the PRD, tech specs, user flows, and mockups to ensure fidelity to the intended experience. Sprints 2 through 5 explicitly align UI and interaction details with the provided mockups and user flows.

## Sprint 0 – Workspace, Tooling, and Design System Scaffold (Week 1)
**Objective:** Establish modular foundations, shared design tokens, and CI hooks so subsequent feature work proceeds smoothly.

- Initialize `Langscape.xcworkspace` with the App target plus Swift Packages (`DetectionKit`, `GameKitLS`, `UIComponents`, `DesignSystem`, `Utilities`, `LLMKit`) wired through Swift Package Manager, matching the technical spec module layout.
- Add repository-wide configuration assets: SwiftLint/SwiftFormat configs, layered `.xcconfig` files, pre-build scripts (`prebuild_lint.sh`, `verify_models.sh`), and placeholder resource folders.
- Implement the design system scaffold (core palette, typography, spacing constants) and previewable SwiftUI components to validate the light-mode visual language.
- Create shared utilities (logging facade, local error store, app settings wrapper) to support later error handling requirements.
- Run smoke tests (`xcodebuild`, lint/format) to ensure the scaffold builds cleanly on CI.

## Sprint 1 – Camera Pipeline and Detection Prototype (Week 2)
**Objective:** Deliver an interactive camera preview backed by the real YOLOv8 CoreML model so stakeholders can validate on-device detection performance early.

- Implement `DetectionService` and `YOLOInterpreter` in `DetectionKit`, loading the bundled YOLOv8 CoreML artifact and returning live detections with FPS instrumentation.
- Build `DetectionVM` using `async/await` to process frames from `AVCaptureSession`, with throttling and error propagation tests.
- Create a SwiftUI `CameraPreviewView` that renders the live feed plus debug bounding boxes for validation.
- Ship a demo build that launches directly into the camera preview with detection overlay and performance logging.

## Sprint 2 – Label Scramble Core Game Loop (Week 3)
**Objective:** Layer in game logic and interactive UI for the Label Scramble activity, matching mockups and user flows exactly for layout, animations, and feedback.

- Complete `GameKitLS` models (`DetectedObject`, `Label`, `Round`) and round generation using detection outputs and placeholder vocab.
- Build SwiftUI components in `UIComponents` (translucent label panels, draggable tokens, snap-to-target overlays) adhering to visual spacing, translucency, and animation cues from the mockups.
- Implement `LabelScrambleVM` to orchestrate the round lifecycle, immediate feedback rules (snap-to-place, disappear on correct, red flash on incorrect), pause handling, and completion callbacks exactly as the user flow specifies.
- Integrate the pause overlay UI and ensure return-to-home behavior aligns with the documented flow.
- Deliver a prototype that transitions from detection to one full round using the home overlay entry point defined in the user flows.

## Sprint 3 – Navigation, Onboarding, and Home Overlay (Week 4)
**Objective:** Implement onboarding, language selection, and the home overlay with fidelity to the mockups and prescribed user flow sequencing.

- Develop the onboarding screens (splash, three intro slides, language selection, camera permission) following copy, timing, and navigation interactions detailed in the user flows and mockups.
- Store language preference via `AppSettings` and gate camera access per the permission flow, including the friendly denial overlay.
- Construct the home overlay (logo placement, translucent stacked activity card layout, blur levels, tap animation) to match mockup spacing and transitions.
- Wire navigation with `NavigationStack`, ensuring the flow launch → onboarding → home overlay → detection gate occurs exactly as documented.
- Add integration tests or scripted UI previews verifying the flow order, transitions, and visual fidelity against the provided assets.

## Sprint 4 – Language Assets, LLM Integration, and Vocab Accuracy (Week 5)
**Objective:** Replace placeholder content with real bilingual assets and offline language services while preserving UI/UX details from mockups and user flows.

- Bundle the Marian translation assets in `LLMKit` (models + tokenizers + vocab) and validate accuracy for common nouns.
- Implement `LLMService` in `LLMKit` with caching, bundled model checks, and deterministic fallbacks to stay offline-only.
- Update `LabelEngine` to pull localized labels per the selected language and detection classes, adhering to the floating label positioning defined in the mockups.
- Expand tests covering vocab loading, language switching, and label rendering, including offline verification paths.
- Conduct manual QA runs validating gameplay pacing, start button behavior, and return-to-home transitions remain consistent with the documented flows.

## Sprint 5 – Offline Polish, Error Handling, and MVP Readiness (Week 6)
**Objective:** Harden the experience, finalize styling, and meet PRD-level performance and reliability targets without deviating from mockup and user-flow guidance.

- Refine UI styling using design system tokens to align with the light-mode mockups, including logo treatments, translucent panels, and motion polish.
- Implement resilient error flows (camera/model failure overlays, “No objects detected” retry) and log persistence exactly as described in the user flows.
- Verify pause/resume, home overlay reset, and app lifecycle restoration through integration testing, ensuring transitions mirror the documented behavior.
- Optimize detection throughput (profiling CoreML, frame cadence) to meet the 15+ FPS and <3s launch goals while staying within offline constraints.
- Prepare the TestFlight build (assets, release notes, smoke-test checklist) and validate the bundled model sizes against the app budget.

## Cross-Sprint Testing and Validation
- Maintain a rolling exploratory test matrix covering onboarding, home overlay, detection accuracy, language toggles, pause/resume, and error handling each sprint.
- Automate unit/UI tests via Xcode build scripts starting in Sprint 1, adding lightweight performance benchmarks in Sprint 2.
- Schedule end-of-sprint demos for stakeholder feedback, prioritizing visual comparisons to mockups and walkthroughs using the documented user flows to confirm fidelity.
