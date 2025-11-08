# High-Scale Detection Architecture Design

**Date:** 2025-11-08
**Status:** Design Complete
**Goal:** Scale object detection from ~124 to 5000+ objects with near-100% accuracy (balanced precision/recall)

---

## Requirements Summary

### Functional Requirements
- **Detection capacity:** 5000+ objects per frame (up from ~124)
- **Accuracy:** Near-100% with balanced precision and recall (both >90%)
- **Object diversity:** 500-1000 unique object classes
- **Scene types:** Mixed indoor/outdoor with extreme variety
- **Latency:** 100-500ms acceptable (near real-time)

### Hardware Constraints
- **Target devices:** iPhone 12+ and recent iPads
- **Neural Engine:** Available but shared across models
- **Memory:** Limited compared to desktop/server

### Current Limitations
- YOLO hard cap: 60 detections
- VLM proposals: 64 max
- Total capacity: ~124 detections
- High precision gates (0.85) limit recall
- Sequential processing (VLM → YOLO → Referee)

---

## Architectural Approach

### Strategy: Dense Proposal + Lightweight Filtering

**High-level flow:**
```
YOLO (high recall, low threshold)
    ↓
Lightweight filtering (confidence, size, spatial)
    ↓
Selective VLM verification (mid-confidence only)
    ↓
Temporal tracking with spatial indexing
```

### Key Principles
1. **YOLO-first:** Fast Neural Engine inference for high recall
2. **Intelligent triage:** Only verify uncertain detections with VLM
3. **Staged filtering:** Cheap heuristics before expensive verification
4. **Spatial optimization:** Scale tracking algorithms for 5000 objects

---

## Component Changes

### 1. YOLO Interpreter Modifications

**File:** `DetectionKit/Sources/DetectionKit/YOLOInterpreter.swift`

**Changes:**

```swift
// Before
private let maxDetections: Int = 60
public let modelConfidenceThreshold: Double = 0.30
public let modelIouThreshold: Double = 0.45

// After
private let maxDetections: Int = 5000
public let modelConfidenceThreshold: Double = 0.15
public let modelIouThreshold: Double = 0.35
```

**Rationale:**
- **Lower confidence (0.15):** Maximize recall, catch almost everything
- **Lower IoU (0.35):** Allow more overlapping detections in crowded scenes
- **Higher limit (5000):** Remove artificial cap (model may output up to 8400 predictions)

**New features:**

1. **Quality scoring:**
   ```swift
   qualityScore = confidence × sqrt(boxArea)
   ```
   - Prioritizes larger, more confident boxes
   - Used for ranking when truncating to 5000

2. **Memory-aware fallback:**
   ```swift
   if memoryPressure == .high:
       maxDetections = 2000
   if memoryPressure == .critical:
       maxDetections = 500
   ```
   - Prevents crashes on older devices
   - Graceful degradation under memory pressure

**Performance:** ~40-60ms (unchanged, but returning more detections)

---

### 2. Detection Filter (New Component)

**File:** `DetectionKit/Sources/DetectionKit/DetectionFilter.swift` (new)

**Purpose:** Fast heuristic filtering before expensive VLM verification

**Pipeline:**

```swift
func filter(_ detections: [Detection]) -> FilteredDetections {
    // 1. Size filtering (O(n), ~0.1ms)
    removeInvalidSizes(detections)

    // 2. Confidence bucketing (O(n), ~0.1ms)
    let buckets = bucketByConfidence(detections)
    // High (>0.60): Auto-accept, no VLM
    // Mid (0.30-0.60): VLM verification needed
    // Low-mid (0.15-0.30): VLM + stricter gate

    // 3. Spatial deduplication (O(n log n), ~2-5ms)
    let deduped = fastNMS(detections, iouThreshold: 0.5)

    // 4. Class-aware limits (O(n), ~0.5ms, optional)
    let limited = limitPerClass(deduped, maxPerClass: 100)

    return FilteredDetections(
        autoAccept: buckets.high,
        needsVerification: buckets.mid + buckets.lowMid,
        requiresStrictGate: buckets.lowMid
    )
}
```

**Size filtering:**
- Remove boxes < 10×10 pixels (noise)
- Remove boxes > 90% of frame (false positives)

**Confidence bucketing:**
| Bucket | Confidence Range | Treatment |
|--------|-----------------|-----------|
| High | >0.60 | Auto-accept, skip VLM (~30% of detections) |
| Mid | 0.30-0.60 | VLM verification (~40% of detections) |
| Low-mid | 0.15-0.30 | VLM + strict gate (~30% of detections) |

**Result:** ~5000 detections → ~1500-2000 after filtering → ~800 sent to VLM

**Performance:** ~3-6ms total

---

### 3. VLM Verification Strategy

**Files:**
- `DetectionKit/Sources/DetectionKit/VLMReferee.swift`
- `DetectionKit/Sources/DetectionKit/VLMDetector.swift`

**Changes:**

**1. Batch processing:**
```swift
// Before: Process one detection at a time
for detection in detections {
    let crop = extractCrop(detection)
    let result = vlm.classify(crop)
}

// After: Batch processing
let batches = detections.chunked(into: 32)
for batch in batches {
    let crops = batch.map { extractCrop($0) }
    let results = vlm.classifyBatch(crops)  // 2-3x faster
}
```

**Benefits:**
- CoreML processes batches more efficiently on Neural Engine
- Reduces overhead by ~2-3x
- Batch size 32 chosen for memory/speed balance

**2. Adaptive acceptance gates:**

| Input Confidence | VLM Similarity | Action |
|-----------------|----------------|--------|
| 0.30-0.60 (mid) | ≥0.80 | Accept (relabel if different) |
| 0.30-0.60 (mid) | 0.75-0.80 | Accept original label |
| 0.30-0.60 (mid) | <0.75 | Drop |
| 0.15-0.30 (low) | ≥0.85 | Accept (strict gate) |
| 0.15-0.30 (low) | <0.85 | Drop |

**Note:** Slightly relaxed from current 0.85 → 0.80 for mid-confidence to improve recall

**3. Remove grid proposal generation:**
- Current VLMReferee generates grid proposals when count < 4
- **Remove entirely:** Trust YOLO with lowered threshold for recall
- Saves 50-100ms per frame
- VLM focuses solely on verification, not proposal generation

**4. Parallel YOLO + VLM pipeline:**
```swift
async let yoloResults = yolo.detect(image)
async let vlmVerification = verifyBatch(firstBatch)

// Pipeline the operations instead of sequential
// Reduces latency by ~30-40%
```

**5. Early stopping:**
```swift
if acceptedCount >= 3000 && verifiedCount >= 500 {
    // Stop VLM verification
    // Accept remaining high-confidence (>0.60) without verification
    break
}
```

**Performance:** ~800 detections ÷ 32 batch × 3ms/batch = ~75-100ms

---

### 4. Label Bank Expansion

**Files:**
- `DetectionKit/Sources/DetectionKit/Resources/labelbank_en_xlarge.txt` (new)
- `DetectionKit/Sources/DetectionKit/VLMDetector.swift` (modified)

**Expansion: 253 → 1000 classes**

**Sources for additional labels:**
- LVIS dataset (1203 classes, well-balanced)
- OpenImages v7 (~600 common classes)
- Remove duplicates, keep most frequent 1000

**Hierarchical organization:**
```
Vehicle family:
  - car (parent)
    - sedan
    - SUV
    - truck

Furniture family:
  - chair (parent)
    - office chair
    - dining chair
    - stool
```

**Fallback strategy:**
- If VLM uncertain between "sedan" vs "SUV", use parent "car"
- Reduces confusion between similar classes
- Maintains accuracy while expanding vocabulary

**CLIP encoding optimization:**

```swift
// Before: Encode on-the-fly (slow)
let labelEmbedding = clipTextEncoder.encode(label)

// After: Pre-compute and bundle
// At build time: Generate embeddings, save to labelbank_embeddings.bin
// At runtime: Load pre-computed embeddings (1000 × 512 × 2 bytes = 1MB)
```

**Benefits:**
- Saves ~50-100ms initialization
- Faster runtime verification
- Memory cost negligible: ~1MB

**Vocabulary pruning (optional):**
```swift
// Detect scene type in first 3-5 frames
if sceneType == .indoor {
    activeVocabulary = indoorLabels  // ~300-400 labels
} else if sceneType == .outdoor {
    activeVocabulary = outdoorLabels // ~300-400 labels
}
```

**Benefits:**
- Improves classification accuracy (smaller confusion set)
- Slightly faster VLM verification
- Adaptive to scene context

**Label normalization:**
Expand alias map in `ClassificationRefiner.swift`:
```swift
let aliases = [
    "cellphone": "cell phone",
    "mobile phone": "cell phone",
    "smartphone": "cell phone",
    "diningtable": "dining table",
    // ... expand to ~200 aliases
]
```

**Tradeoff:** Larger vocabulary increases VLM compute by ~10-15% but dramatically improves classification accuracy on diverse scenes (500-1000 classes).

---

### 5. Temporal Tracking Modifications

**File:** `DetectionKit/Sources/DetectionKit/DetectionVM.swift`

**Challenge:** Current O(n²) track association doesn't scale to 5000 objects

**Solution: Spatial indexing**

```swift
// Before: O(n²) - check all detections against all tracks
for detection in detections {
    for track in activeTracks {
        if iou(detection, track) > threshold {
            // Associate
        }
    }
}

// After: O(n log n) - spatial grid hash
class SpatialIndex {
    private var grid: [[Track]] // 10×10 grid cells

    func findNearby(_ detection: Detection) -> [Track] {
        let cell = getCellIndex(detection.bbox)
        return grid[cell] + adjacentCells(cell)
        // Only check ~1-5% of tracks instead of 100%
    }
}
```

**Benefits:**
- Reduces track association from O(n²) to O(n log n)
- Keeps latency <10ms even with 5000 objects
- Memory overhead: ~50KB for grid structure

**Parameter adjustments:**

```swift
// Before
private let iouThreshold: Double = 0.40
private let requiredHits: Int = 3
private let maxTrackAge: TimeInterval = 0.6
private let smoothingAlpha: Double = 0.5

// After
private let iouThreshold: Double = 0.35  // Tighter matching for crowded scenes
private let requiredHits: Int = 2        // Faster initialization
private let maxTrackAge: TimeInterval = 0.4  // Prune stale tracks faster
private let smoothingAlpha: Double = 0.3     // More responsive to movement
```

**Track capacity limits:**
```swift
let maxActiveTracks = 5000

func pruneTracksIfNeeded() {
    if activeTracks.count > maxActiveTracks {
        // Remove lowest-confidence tracks first
        activeTracks.sort(by: { $0.confidence > $1.confidence })
        activeTracks = Array(activeTracks.prefix(maxActiveTracks))
    }
}
```

**Confidence-based track promotion:**

| Track Confidence | Required Hits | Rationale |
|-----------------|---------------|-----------|
| High (>0.70) | 1 hit | Emit immediately, high certainty |
| Mid (0.40-0.70) | 2 hits | Current: 3, reduced for responsiveness |
| Low (0.15-0.40) | 3 hits | Require evidence, drop if no improvement |

**Label stability voting:**
```swift
class Track {
    private var labelHistory: [(label: String, confidence: Double)] = []
    private let votingWindowSize = 5

    func updateLabel(_ label: String, _ confidence: Double) {
        labelHistory.append((label, confidence))
        if labelHistory.count > votingWindowSize {
            labelHistory.removeFirst()
        }

        // Weighted voting: recent frames count more (exponential decay)
        let weights = (0..<labelHistory.count).map { i in
            pow(0.8, Double(labelHistory.count - 1 - i))
        }

        stableLabel = weightedMajorityVote(labelHistory, weights)
    }
}
```

**Performance:** <10ms for track association with 5000 objects (spatial indexing)

---

## Complete Pipeline Performance Budget

```
┌─────────────────────────────────────────────────────────┐
│ YOLO inference (5000 detections @ 0.15 threshold)       │  ~40-60ms
├─────────────────────────────────────────────────────────┤
│ Detection filtering (spatial, confidence, size)         │  ~5ms
├─────────────────────────────────────────────────────────┤
│ VLM batch verification (~800 detections, batch=32)      │  ~75-100ms
├─────────────────────────────────────────────────────────┤
│ Temporal tracking (spatial indexed)                     │  ~8-10ms
└─────────────────────────────────────────────────────────┘
  Total latency:                                            ~130-175ms ✓
```

**Result:** Well within 100-500ms budget, with headroom for variability

---

## Memory Footprint Analysis

| Component | Memory Usage |
|-----------|--------------|
| YOLO detections (5000 × ~80 bytes) | 400 KB |
| VLM crops batch (32 × 224×224×3) | ~5 MB |
| Label embeddings (1000 × 512 × 2 bytes) | 1 MB |
| Active tracks (5000 × ~100 bytes) | 500 KB |
| Spatial index grid | 50 KB |
| **Total increase** | **~7 MB** |

**Assessment:** Acceptable for iPhone 12+ (typically 4-6GB RAM, DetectionKit uses <50MB total)

---

## Migration Strategy

### Phase 1: Core Changes (Break Nothing)
**Goal:** Increase capacity without changing architecture

1. Modify `YOLOInterpreter.swift`:
   - Increase `maxDetections` to 5000
   - Lower `modelConfidenceThreshold` to 0.15
   - Lower `modelIouThreshold` to 0.35
   - Add quality scoring

2. Create `DetectionFilter.swift`:
   - Implement size filtering
   - Implement confidence bucketing
   - Implement fast NMS
   - Add class-aware limits (optional)

3. Keep `CombinedDetector.swift` working:
   - Wire in DetectionFilter between YOLO and VLM
   - No breaking changes to protocol

**Success criteria:**
- Existing tests still pass
- No regressions in current behavior
- Detection count increases to 1000+

**Estimated effort:** 1-2 days

---

### Phase 2: Optimize VLM
**Goal:** Scale VLM verification efficiently

1. Modify `VLMReferee.swift`:
   - Implement batch processing (batch size 32)
   - Adjust acceptance gates (0.80 for mid-confidence)
   - Remove grid proposal generation
   - Add early stopping logic

2. Optimize `VLMDetector.swift`:
   - Support batch inference
   - Pre-compute label embeddings
   - Load from bundled embeddings file

3. Create label bank:
   - Generate `labelbank_en_xlarge.txt` (1000 classes)
   - Pre-compute CLIP embeddings
   - Bundle embeddings as `labelbank_embeddings.bin`

**Success criteria:**
- VLM verification completes in <100ms for 800 detections
- Classification accuracy improves on diverse scenes
- No memory pressure on iPhone 12

**Estimated effort:** 2-3 days

---

### Phase 3: Scale Tracking
**Goal:** Handle 5000 simultaneous tracks

1. Modify `DetectionVM.swift` `DetectionProcessor`:
   - Implement spatial indexing (grid hash)
   - Adjust tracking parameters (IoU, hits, age, smoothing)
   - Add track capacity limits (max 5000)
   - Implement confidence-based promotion

2. Enhance label voting:
   - Expand voting window to 5 frames
   - Implement weighted voting (exponential decay)
   - Improve label stability

**Success criteria:**
- Track association <10ms with 5000 objects
- Stable labels (no flicker)
- Memory stays within budget

**Estimated effort:** 2-3 days

---

### Phase 4: Expand Vocabulary
**Goal:** Support 1000 object classes

1. Curate label bank:
   - Combine LVIS + OpenImages
   - Remove duplicates
   - Organize hierarchically
   - Create fallback mappings

2. Expand label normalization:
   - Update `ClassificationRefiner.swift` alias map
   - Add ~200 common aliases
   - Test on diverse scenes

3. Optional: Scene-adaptive vocabulary:
   - Implement scene type detection
   - Create indoor/outdoor label subsets
   - Dynamically switch active vocabulary

**Success criteria:**
- Classification accuracy >90% on 500-1000 classes
- No significant latency increase
- Graceful fallbacks on ambiguous classes

**Estimated effort:** 2-3 days

---

### Total Implementation Time: ~8-12 days

---

## Rollback Safety

**Feature flag:**
```swift
enum DetectionMode {
    case legacy    // Current system (60 detections, VLM-first)
    case highScale // New system (5000 detections, YOLO-first)
}

let detectionMode: DetectionMode = .highScale
```

**Fallback triggers:**
1. Memory pressure warning → Reduce max detections
2. Thermal state critical → Fall back to legacy mode
3. Latency exceeds 500ms for 3 consecutive frames → Reduce batch sizes
4. Crash/error → Log and fall back to legacy

**A/B testing:**
- Deploy with feature flag off by default
- Enable for 10% of users, monitor metrics
- Gradually roll out to 100%

---

## Success Metrics

### Accuracy Targets
- **Recall:** >95% on scenes with 100-5000 objects
- **Precision:** >90% (balanced as required)
- **Classification accuracy:** >90% on 1000-class vocabulary

### Performance Targets
- **Latency:**
  - p50 < 200ms
  - p95 < 300ms
  - p99 < 500ms
- **Memory:** <50MB total DetectionKit footprint
- **Thermal:** No throttling under continuous operation

### Reliability Targets
- **Crash rate:** <0.1% on target devices (iPhone 12+)
- **Label stability:** <5% label flicker rate (track changes label)
- **Track persistence:** >90% tracks survive 1 second in stable scenes

---

## Testing Strategy

### Unit Tests
- `YOLOInterpreter`: Verify 5000 detection limit, quality scoring
- `DetectionFilter`: Validate filtering logic, bucketing correctness
- `VLMReferee`: Test batch processing, acceptance gates
- `DetectionProcessor`: Verify spatial indexing, track association

### Integration Tests
- End-to-end pipeline with synthetic 5000-object scenes
- Memory pressure simulation
- Thermal throttling scenarios

### Performance Benchmarks
- Measure latency at 100, 500, 1000, 5000 object counts
- Profile memory usage over 5-minute sessions
- Test on iPhone 12, iPhone 14, iPhone 15 Pro, iPad Pro M1

### Accuracy Evaluation
- Curate test dataset with ground truth (100 images, 100-5000 objects each)
- Measure precision, recall, F1 score
- Evaluate on diverse scenes (indoor, outdoor, crowded, sparse)

---

## Future Enhancements

### Short-term (Next 1-2 months)
1. **Adaptive thresholds:** Dynamically adjust confidence gates based on scene complexity
2. **Scene-adaptive vocabulary:** Auto-detect indoor/outdoor, switch label sets
3. **Multi-scale YOLO:** Run at 2-3 resolutions for better small object detection

### Medium-term (3-6 months)
1. **Model quantization:** Use INT8 YOLO for 2x faster inference
2. **Attention-based NMS:** Replace IoU-based NMS with learned attention weights
3. **Temporal fusion:** Use previous frame detections to guide current frame

### Long-term (6-12 months)
1. **End-to-end learned pipeline:** Train unified detector with 5000-detection capacity
2. **3D tracking:** Leverage ARKit depth for robust 3D object tracking
3. **Active learning:** Collect hard examples, retrain models incrementally

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| YOLO model doesn't support 5000 outputs | High | Check model output tensor size; use multiple YOLO passes if needed |
| Memory pressure on iPhone 12 | High | Implement adaptive detection limits; fall back gracefully |
| VLM verification too slow | Medium | Early stopping; batch size tuning; optimize CLIP model |
| Label bank too large (>1000) | Medium | Scene-adaptive vocabulary; hierarchical fallbacks |
| Thermal throttling | Medium | Monitor thermal state; reduce processing when hot |
| Poor classification on long-tail classes | Low | Fallback to parent classes; accept "unknown" label |

---

## Conclusion

This design scales the detection system from ~124 to 5000+ objects while maintaining near-100% balanced accuracy. The approach is pragmatic, leveraging existing YOLO + VLM infrastructure with targeted optimizations:

1. **YOLO-first** for high recall at low cost
2. **Lightweight filtering** to reduce VLM workload
3. **Batch VLM verification** for efficient precision boosting
4. **Spatial indexing** for scalable tracking
5. **Expanded vocabulary** for diverse scene coverage

The migration is phased to minimize risk, with rollback mechanisms at every stage. Performance estimates show 130-175ms latency, well within the 100-500ms budget, with acceptable memory overhead (~7MB increase).

**Ready for implementation.**
