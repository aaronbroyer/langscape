# Implementation Plan: SAM 3 Integration

**Target System:** iOS (CoreML)  
**Architecture:** Neuro-Spatial (Hybrid Loop)  
**Version:** 1.0  

---

## 1. Executive Summary
This document details the engineering strategy for integrating **Meta's SAM 3 (Segment Anything Model 3)** into Langscape. 

Unlike standard object detection (YOLO), SAM 3 provides pixel-perfect masks. To run this computationally heavy model on mobile without thermal throttling, we will use an **Asymmetric Pipeline**:
* **Scanner (YOLO):** Runs at 30 FPS to find objects.
* **Refiner (SAM 3):** Runs only on specific triggers to "beautify" and segment those objects.

---

## 2. Model Optimization Strategy
**Goal:** Fit SAM 3 onto the Apple Neural Engine (ANE) with a memory footprint < 200MB and latency < 100ms.

### 2.1 The "Split-Brain" Architecture
SAM 3 consists of a heavy Image Encoder (ViT) and a light Mask Decoder. We must export them as separate CoreML models to enable caching.

#### Model A: The Encoder (`sam3_encoder.mlpackage`)
* **Responsibility:** Processes the raw image frame once to create a latent representation.
* **Input:** 1024x1024 Image (RGB).
* **Output:** Image Embeddings (Tensor).
* **Optimization:** **Int8 Quantization** is mandatory. Float32 is too large for mobile RAM.
* **Export Note:** If available, use a distilled "MobileSAM 3" backbone to reduce latency from ~150ms to ~20ms.

#### Model B: The Decoder (`sam3_decoder.mlpackage`)
* **Responsibility:** Takes embeddings and a prompt to generate the mask.
* **Input:** Image Embeddings + Bounding Box Prompt `[x, y, w, h]`.
* **Output:** Binary Mask (1024x1024).
* **Optimization:** Float16 (Standard CoreML).

---

## 3. The Service Layer (`SegmentationKit`)
We will create a dedicated service to handle segmentation to keep `DetectionKit` clean.

**File:** `SegmentationKit/Sources/SegmentationService.swift`

```swift
actor SegmentationService {
    private var encoder: MLModel?
    private var decoder: MLModel?
    
    // Cache the heavy embeddings so we don't re-run the encoder if the camera is still
    private var cachedEmbeddings: MLMultiArray?
    private var lastFrameTimestamp: TimeInterval = 0
    
    /// Main entry point
    func segment(frame: CVPixelBuffer, promptBox: CGRect) async throws -> CIImage {
        // 1. Stability Check: If frame changed significantly, run Encoder (Heavy)
        if !isStable(frame) {
            self.cachedEmbeddings = try runEncoder(frame)
        }
        
        // 2. Run Decoder (Light/Fast) using cached embeddings
        return try runDecoder(embeddings: self.cachedEmbeddings, prompt: promptBox)
    }
}

---

# 4. The "Hybrid Loop" Integration

We do not run SAM 3 every frame. We use a **Trigger System** to manage compute load.

## 4.1 Trigger Logic

| Trigger Type | Condition | Action | Priority |
| :--- | :--- | :--- | :--- |
| **Passive (Cache)** | Camera Velocity < 0.1 m/s (Stable) | Run Encoder & Cache Embeddings | Low (Background) |
| **Active (Visual)** | YOLO Confidence > 85% | Run Decoder on specific object | Medium |
| **User (Interaction)** | User taps a Label | Run Decoder immediately | High (Immediate) |

## 4.2 Data Flow

1.  **YOLO-World** detects "Chair" at `[x,y,w,h]`.
2.  **UI** displays a standard 2D label.
3.  **Background Worker** checks stability. If stable, it calls `SegmentationService`.
4.  **Service** returns a `CIImage` (Binary Mask).
5.  **UI** receives the mask and triggers the **"Neon Glow"** animation, fading out the generic 2D box.

---

# 5. Visualization & Effects

How the binary mask is rendered in the AR view.

## 5.1 The "Neon Glow" (Screen Space)
This creates the "Cyberpunk/High-Tech" aesthetic.

* **Input:** Binary Mask (Black/White).
* **Filter Chain:**
    * **Gaussian Blur:** Radius 15px (Creates the glow).
    * **Color Matrix:** Tint pixels to Electric Cyan (#00FFFF).
    * **Compositing:** Overlay onto the video feed using `Lighten` blend mode.
* **Result:** The object appears to have a radioactive aura.

## 5.2 True Occlusion (Depth Aware)
This allows labels to hide behind real objects.

* **Input:** SAM Mask + LiDAR Depth Map.
* **Logic:**
    * Calculate `AverageDepth` of pixels inside the Mask.
    * Compare with `LabelAnchor.position.z`.
* **Action:** If `ObjectDepth < LabelDepth`, apply the mask as an **Opacity Matte** to the Label Layer.

---

# 6. Implementation Checklist

### Preparation
- [ ] **Export:** Convert SAM 3 Encoder to CoreML (Int8).
- [ ] **Export:** Convert SAM 3 Decoder to CoreML (Float16).
- [ ] **Benchmark:** Verify Encoder runs < 100ms on iPhone 15 Pro / M1 iPad.

### Codebase
- [ ] **Service:** Create `SegmentationKit` module.
- [ ] **Caching:** Implement `lastFrameTimestamp` and stability logic.
- [ ] **Integration:** Connect `DetectionVM` to `SegmentationService`.

### UI/UX
- [ ] **Shaders:** Write Metal/CoreImage shader for "Neon Glow."
- [ ] **Interaction:** Add "Tap-to-Segment" gesture handler.