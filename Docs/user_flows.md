# Langscape MVP – User Flows

## 1. Onboarding Flow
**Goal:** Introduce the app, gather language preference, and obtain camera permission.

**Steps:**
1. **Splash Screen**
   - Displays the Langscape logo on white background for ~1.5s.
   - Fades into onboarding slides.

2. **Intro Slides (3 screens)**
   - **Slide 1:** “Discover the world through language.” (simple illustration)
   - **Slide 2:** “Point your camera and learn real words in real places.”
   - **Slide 3:** “Drag words to objects to master vocabulary in context.”
   - Navigation: Swipe or “Next” button → final “Get Started” button.

3. **Language Selection**
   - Prompt: “Choose your target language.”
   - Options: English → Spanish / Spanish → English.
   - Selection stored in local memory for current session.

4. **Camera Permission Prompt**
   - Uses default iOS permission dialog.
   - If denied → friendly message overlay: “Camera access is needed to detect objects.”

5. **Transition → Home Overlay**

---

## 2. Home Overlay Flow
**Goal:** Let user choose an activity without leaving live camera view.

**UI Elements:**
- Subtle **Langscape logo** at top center.
- **Vertical translucent stack** (centered):
  - Card: *Label Scramble* (icon + text)
  - Future placeholder cards (grayed-out)
- Slight background **blur** for readability.
- Camera preview runs in background.

**User Actions:**
- Tap *Label Scramble* card → small **scale animation**.
- Transition instantly to **object detection phase**.

---

## 3. Label Scramble Flow
**Goal:** Detect objects, display labels, and allow drag-and-drop matching.

**Steps:**
1. **Object Detection**
   - YOLOv8 model runs on live camera.
   - Random subset (5–7) of recognized objects chosen.
   - Once detections lock → display **floating circular “Start” button**.

2. **Start Round**
   - User taps “Start” → button fades out.
   - Labels (Spanish nouns with articles) appear **floating near objects**.
   - Each label rendered on **translucent panel** with spring-like motion.

3. **Gameplay**
   - User drags a label → if dropped near correct object:
     - Snaps into place.
     - Label **disappears**.
   - Incorrect:
     - Label turns **red briefly**, snaps back.
     - No sound or haptics.

4. **Completion**
   - When all labels are correctly placed:
     - Quick blank frame (camera reset).
     - Return to **Home Overlay**.

---

## 4. Pause Flow
**Goal:** Allow user to temporarily stop play.

**Steps:**
- User taps **pause icon** (top corner).
- Overlay appears: “Paused” + **Resume** button.
- Tap **Resume** → return to previous state.

---

## 5. Error Handling Flow
**Camera or Model Error:**
- Show minimal overlay:
  - “Something went wrong. Please restart Langscape.”
  - Log error locally for debugging.

**No Objects Detected:**
- Overlay: “Try pointing your camera at a scene with more objects.”
- Option: “Retry” button restarts detection loop.

---

## 6. Exit Flow
- User can exit via **pause → home** or system gesture (swipe up).
- App resumes at last screen state when reopened.
