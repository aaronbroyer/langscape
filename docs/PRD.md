# Langscape MVP – Product Requirements Document

## 1. Vision
Langscape is a mobile app that superimposes language-learning activities onto real-world scenes through the camera. Learners engage with their environment to build vocabulary in context. The MVP focuses on the **Label Scramble** activity — dragging labels in the target language onto detected objects.

---

## 2. MVP Goal
Deliver a fully offline, polished iOS app prototype that demonstrates the core experience of scene-based language learning with accurate object detection, responsive drag-and-drop interaction, and a modern, minimal UI.

---

## 3. Core Features
- **Camera-based scene analysis** using YOLOv8 (on-device CoreML model).
- **Label Scramble activity**:
  - 5–7 labels per round.
  - Labels appear **floating near objects** (snap into place when correct).
  - **Immediate visual feedback** (correct → disappear; incorrect → red, return).
- **Basic language support**: English ↔ Spanish (target-language labels with articles + diacritics).
- **Home overlay** (vertical translucent stack):
  - Langscape logo (top).
  - Activity card for *Label Scramble*.
- **Onboarding flow**:
  - Multi-screen intro (static visuals).
  - Target language selection.
  - Camera permission prompt.
- **Fully offline operation** (YOLO + LLM bundled).
- **Simple pause/resume** button during play.
- **Local error logging** for debugging.

---

## 4. User Flow
1. **Launch** → splash screen with Langscape logo.  
2. **Intro screens** → choose target language.  
3. **Camera view opens** with blurred home overlay → tap *Label Scramble*.  
4. **Object detection** → floating “Start” button appears.  
5. **Gameplay** → drag labels → instant feedback → round complete.  
6. **Return to home overlay** → camera resets.  

---

## 5. Functional Specs
- Platform: **iOS (Swift + SwiftUI + CoreML)**  
- Object Detection: **YOLOv8 (CoreML, local inference)**  
- LLM: **Small on-device model** (e.g., Phi-3-mini for translations/content)  
- Orientation: **Portrait only**  
- Data: **Local only** (no backend)  
- UI: **Light mode**, SF Pro font, translucent panels, spring animations  
- Error handling: **Local logging**, default camera prompt  

---

## 6. Non-Functional Specs
- Load time < 3s (including model init)  
- Real-time detection ≥ 15 FPS on iPhone 12+  
- App size target: ≤ 500MB (models bundled)  
- No network dependencies  

---

## 7. Out of Scope (Future Phases)
- Placement test & adaptive difficulty  
- Progress tracking & spaced review  
- Additional activities (role plays, questions)  
- Multi-language support  
- Accessibility, sound, and haptics  
- Backend analytics & user accounts  
