# Implementation Plan: SAM 2.1 Integration (Zero-Error Path)

**Target System:** iOS (CoreML)  
**Architecture:** Neuro-Spatial (Hybrid Loop)  
**Model Version:** SAM 2.1 (Hiera Small)  
**Version:** 2.0  

---

## 1. Executive Summary
This document details the engineering strategy for integrating **Meta's SAM 2.1** into Langscape using the "Zero-Error Path."

Instead of manually exporting and quantizing PyTorch models (which is prone to environmental errors), we will utilize the **official CoreML converted models provided by Apple**. This ensures maximum compatibility with the Apple Neural Engine (ANE) and guaranteed stability.

**The Asymmetric Pipeline:**
* **Scanner (YOLO-World):** Runs at ~30 FPS to detect objects and generate bounding boxes.
* **Refiner (SAM 2.1):** Runs on specific triggers to convert those boxes into pixel-perfect masks for "Glow" and "Occlusion" effects.

---

## 2. Model Acquisition (The Zero-Error Path)
**Goal:** Acquire optimized `.mlpackage` files without running Python scripts.

### 2.1 Download Official Models
We will use the **SAM 2.1 Small** variant, which offers the best balance of speed (~40ms latency) and accuracy for mobile AR.

* **Source:** Hugging Face (Apple Organization)
* **Repository:** `apple/coreml-sam2.1-small`
* **Files to Download:**
    1.  `SAM2ImageEncoder.mlpackage` (Processes the camera frame)
    2.  `SAM2MaskDecoder.mlpackage` (Generates the mask from prompt)

**Action:**
1.  Visit [huggingface.co/apple/coreml-sam2.1-small](https://huggingface.co/apple/coreml-sam2.1-small)
2.  Go to **Files and versions**.
3.  Download the `.mlpackage` folders.
4.  Drag them into your Xcode project under `SegmentationKit/Resources`.

---

## 3. The Service Layer (`SegmentationKit`)
We will create a dedicated service to orchestrate the two-step segmentation process.

**File:** `SegmentationKit/Sources/SegmentationService.swift`

```swift
import CoreML
import Vision

actor SegmentationService {
    private var encoder: SAM2ImageEncoder?
    private var decoder: SAM2MaskDecoder?
    
    // Caching: We run the heavy encoder ONCE if the camera is stable
    private var cachedEmbeddings: MLMultiArray?
    
    init() throws {
        // Load the official Apple models
        let config = MLModelConfiguration()
        config.computeUnits = .all // Uses Neural Engine
        self.encoder = try SAM2ImageEncoder(configuration: config)
        self.decoder = try SAM2MaskDecoder(configuration: config)
    }
    
    /// Main Entry Point
    /// - Parameters:
    ///   - frame: The current camera frame (resized to 1024x1024)
    ///   - box: The bounding box from YOLO [x, y, width, height] (Normalized)
    func segment(frame: CVPixelBuffer, box: CGRect) async throws -> CIImage {
        
        // 1. Run Encoder (Heavy) - Only if cache is invalid/camera moved
        // Note: You should implement stability logic to skip this step when possible
        let embeddings = try self.encoder!.prediction(image: frame).embeddings
        self.cachedEmbeddings = embeddings
        
        // 2. Prepare Prompt Inputs for Decoder
        // Apple's model expects specific MultiArray shapes for points/boxes
        let (pointCoords, pointLabels) = convertBoxToPrompts(box)
        
        // 3. Run Decoder (Fast)
        let output = try self.decoder!.prediction(
            image_embeddings: embeddings,
            point_coords: pointCoords,
            point_labels: pointLabels,
            mask_input: emptyMask(), // Zero tensor for first pass
            has_mask_input: 0,       // False
            orig_im_size: currentFrameSize
        )
        
        // 4. Post-Process to CIImage
        return convertLogitsToMask(output.masks)
    }
}

--- 

# 4. The "Hybrid Loop" Integration

We manage compute load by defining strict triggers. SAM 2.1 is efficient, but running it 60 times a second is wasteful.

## 4.1 Trigger Logic

| Trigger Type | Condition | Action | Priority |
| :--- | :--- | :--- | :--- |
| **Passive (Cache)** | Camera Velocity < 0.1 m/s (Stable) | Run Encoder & Cache Embeddings | Low (Background) |
| **Active (Visual)** | YOLO Confidence > 85% | Run Decoder using Cached Embeddings | Medium |
| **User (Interaction)** | User taps a Label | Run Decoder immediately | High (Immediate) |

## 4.2 Data Flow

1.  **YOLO-World** detects "Chair" at `[x,y,w,h]`.
2.  **UI** displays a standard 2D label.
3.  **Background Worker** checks stability. If stable, it calls `SegmentationService`.
4.  **Service** uses the bounding box to query the **SAM 2.1 Decoder**.
5.  **Result:** A pixel-perfect mask is returned.
6.  **UI Update:** The generic 2D box **fades out**, replaced by the **Neon Glow** overlay conforming to the chair's shape.

---

# 5. Visualization & Effects

How the binary mask from SAM 2.1 is rendered in the AR view.

## 5.1 The "Neon Glow" (Screen Space)
This creates the "Cyberpunk/High-Tech" aesthetic.

* **Input:** Binary Mask (Black/White).
* **Filter Chain:**
    * **Gaussian Blur:** Radius 15px (Creates the glow halo).
    * **Color Matrix:** Tint pixels to Electric Cyan (#00FFFF).
    * **Compositing:** Overlay onto the video feed using `Lighten` or `Add` blend mode.
* **Result:** The object appears to have a radioactive aura.

## 5.2 True Occlusion (Depth Aware)
This allows labels to hide behind real objects.

* **Input:** SAM Mask + LiDAR Depth Map.
* **Logic:**
    * Calculate `AverageDepth` of pixels inside the Mask.
    * Compare with `LabelAnchor.position.z`.
* **Action:** If `ObjectDepth < LabelDepth`, apply the mask as an **Opacity Matte** to the Label Layer (effectively cutting a hole in the UI where the real object exists).

---

# 6. Implementation Checklist

### Model Acquisition
- [ ] **Download:** `SAM2ImageEncoder.mlpackage` from Hugging Face.
- [ ] **Download:** `SAM2MaskDecoder.mlpackage` from Hugging Face.
- [ ] **Import:** Add to Xcode project targets.

### Codebase
- [ ] **Service:** Create `SegmentationKit` module.
- [ ] **Logic:** Implement `convertBoxToPrompts` helper (normalizes YOLO box to SAM inputs).
- [ ] **Logic:** Implement `convertLogitsToMask` (thresholds SAM output to binary image).
- [ ] **Integration:** Wire `DetectionVM` to trigger `SegmentationService`.

### UI/UX
- [ ] **Shaders:** Write Metal/CoreImage shader for "Neon Glow."
- [ ] **Interaction:** Add "Tap-to-Segment" gesture handler.