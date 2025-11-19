# Langscape: The Adaptive Semantic AR Stack
**Architectural Blueprint for High-Performance Mobile AR Language Learning**

## Executive Summary
This document outlines the technical architecture for "Langscape," an AR language learning app. The goal is to achieve high-accuracy object detection with real-time latency (<30ms) on mobile devices (iOS/Android).

**The Core Innovation:** 
We replace standard static object detection with a **Context-Aware Cascade**. The system first identifies *where* the user is (Scene Recognition) to dynamically optimize the detection model (Reparameterized YOLO-World), and uses a heavier Vision-Language Model (SigLIP/CLIP) only as a fallback "Judge" for ambiguous cases.

---

## The 4-Stage Pipeline

### Stage 1: Context Initialization (The "Scout")
*Runs once upon entering a new space or when requested by the user.*

Instead of asking the user to select "Kitchen Lesson," the app analyzes the camera feed to determine the environment. This creates a "Closed Set" of probabilities, drastically reducing the confusion matrix for the object detector.

*   **Model:** **MobileNetV3 (Small)** or **EfficientNet-Lite0**.
*   **Dataset:** Trained on **Places365** (standard dataset for scene recognition).
*   **Latency:** ~10ms (One-shot).
*   **Workflow:**
    1.  User opens camera.
    2.  App captures 1 frame.
    3.  Model classifies scene: e.g., `Class: Kitchen (98%)`.
    4.  **Trigger:** App loads the `Kitchen_Vocabulary_Bundle` into the Stage 2 Detector.

### Stage 2: Real-Time Detection (The "Hunter")
*Runs continuously at 30-60 FPS.*

This is the workhorse. It does not use a text encoder. It uses a lightweight vision model with the specific vocabulary weights loaded from Stage 1 baked into the final layer.

*   **Model:** **YOLO-World (v8/v9)**.
*   **Optimization:** Quantized to **INT8**.
*   **Framework:** CoreML (iOS) / TFLite (Android).
*   **Mechanism:** **Dynamic Reparameterization**.
    *   The app contains pre-computed weight bundles for common scenes (Kitchen, Park, Office, Supermarket).
    *   When Stage 1 says "Kitchen," we swap the final classification layer of the YOLO model to the "Kitchen" weights.
    *   *Result:* The model now effectively becomes a specialist "Kitchen Detector" instantly. It ignores cars, trees, and clouds, focusing its probability distribution on cups, plates, and fridges.

### Stage 3: The Verifier (The "Judge")
*Runs On-Demand (Event Driven).*

This addresses the accuracy fallback. If YOLO is unsure, or if the user interacts with an object, we call in the "heavy artillery."

*   **Model:** **MobileCLIP** (Apple) or **SigLIP** (Google, distilled for mobile).
*   **Trigger Logic (The "Lazy Evaluation" Algorithm):**
    We do **not** run this every frame. We run it only when:
    1.  **Confidence Gap:** YOLO detects an object but confidence is `0.3 < conf < 0.6`.
    2.  **Stability Failure:** An object label flickers between two classes (e.g., "Cup" vs "Glass") over 10 frames.
    3.  **User Demand:** The user Taps a specific object on screen.
*   **Workflow:**
    1.  Get the Bounding Box from Stage 2 (YOLO).
    2.  Crop the raw RGB image to that box (add 10% padding).
    3.  Pass the crop to **SigLIP**.
    4.  Compare against the generic full dictionary (Open Vocabulary).
    5.  **Result:** SigLIP returns "Chalice."
    6.  **Action:** Update the AR label and force-feed this correction back to the Tracker.

### Stage 4: Geometric Tracking (The "Anchor")
*Runs continuously via ARKit/ARCore.*

Once an object is identified and verified, we stop running ML on it to save battery.

*   **Technology:** ARKit Anchors / ARCore Cloud Anchors.
*   **Workflow:**
    1.  Raycast from the center of the Bounding Box to the 3D Mesh/Plane.
    2.  Place a 3D Anchor at world coordinates `(x,y,z)`.
    3.  Attach the text label UI to this Anchor.
    4.  **Optimization:** If the Anchor is visible, *suppress* YOLO detection for that specific screen region. (Why detect a cup again if we already pinned a label to it?).

---

## Detailed Technical Stack & Implementation

### 1. Data Strategy: Synthetic Domain Randomization
Your current weakness is data. Pseudo-labeling is noisy.
*   **Tool:** NVIDIA Isaac Sim or Unity Perception.
*   **Action:** Generate 10,000 images per "Scene" (Kitchen, Park, etc.).
*   **Augmentation:** Apply heavy "Mobile Noise": Motion blur, poor auto-focus, grain, finger-over-lens shadows.
*   **Fine-Tuning:** Train the YOLO-World base model on this synthetic data to learn robust feature extraction, then export the class-specific heads.

### 2. iOS Implementation Strategy
*   **Scene Model:** `MobileNetV3.mlmodel` (Use Vision framework).
*   **Detector:** `YOLO_World_Int8.mlmodel`.
    *   *Note:* CoreML does not easily support swapping layers at runtime.
    *   *Workaround:* Export separate models for top 5 scenes (`KitchenDetector.mlmodel`, `StreetDetector.mlmodel`). They share the same input size. The memory footprint is small enough (6MB each) to bundle 5-10 of them.
*   **Verifier:** `MobileCLIP_S2.mlmodel`.

### 3. Android Implementation Strategy
*   **Framework:** TensorFlow Lite (with NNAPI Delegate).
*   **Dynamic Loading:** TFLite allows you to load a model file from the assets folder at runtime. You can keep one "Base" model and dynamically load different `.tflite` files based on the scene detected.

---

## The User Experience Flow (Step-by-Step)

1.  **App Launch:** Camera opens. UI shows "Scanning Environment..."
2.  **Context Lock:** (500ms later) UI flashes "Environment Detected: **Kitchen**".
    *   *System:* Unloads generic model, loads `Kitchen_Bundle`.
3.  **Exploration:** User pans phone around.
    *   *System:* YOLO picks up "Chair," "Table," "Apple."
    *   *UI:* Labels float over objects.
4.  **The Edge Case:** User points phone at a weird blender that YOLO thinks is a "Bowl" (Low Confidence).
    *   *System:* Confidence < 50%. Trigger **Verifier**.
    *   *System:* Sends crop to SigLIP. SigLIP identifies "Blender."
    *   *UI:* Label updates to "Blender" (High Confidence).
5.  **Interaction:** User drags the word "La Licuadora" (Blender) from the vocab list onto the AR label.
    *   *System:* Lock confirmed. Particle effect.

## Latency Budget (Estimated)

| Component | Frequency | Target Latency | Hardware |
| :--- | :--- | :--- | :--- |
| **Scene Classifier** | Once (Start) | 15ms | CPU/GPU |
| **YOLO-World (Int8)** | Every Frame | 18ms | NPU (ANE/DSP) |
| **SigLIP (Verifier)** | Rare (<5%) | 150ms | GPU |
| **AR Tracking** | Every Frame | 4ms | DSP |
| **Total Loop** | **Continuous** | **~22-25ms** | **(45+ FPS)** |

---

## Next Steps for Development

1.  **Prototype Stage 1:** Train a MobileNet on Places365 and test if it accurately detects rooms in your house.
2.  **Synthesize Data:** Create a "Kitchen" dataset in Unity/Unreal.
3.  **Quantize:** Export YOLO-World to CoreML Int8 and measure exact fps on an iPhone 12 or newer.
4.  **Build the Logic:** Implement the "Lazy Evaluation" trigger for the Verifier.