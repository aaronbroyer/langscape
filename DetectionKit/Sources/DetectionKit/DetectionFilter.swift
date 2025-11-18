import Foundation

/// Filtered detection results with confidence-based bucketing
public struct FilteredDetections: Sendable {
    /// High confidence detections (>0.60) - auto-accept, skip VLM verification
    public let autoAccept: [Detection]

    /// Mid confidence detections (0.30-0.60) - requires VLM verification
    public let needsVerification: [Detection]

    /// Low-mid confidence detections (0.15-0.30) - requires VLM with strict gate
    public let requiresStrictGate: [Detection]

    public init(autoAccept: [Detection], needsVerification: [Detection], requiresStrictGate: [Detection]) {
        self.autoAccept = autoAccept
        self.needsVerification = needsVerification
        self.requiresStrictGate = requiresStrictGate
    }

    /// All detections combined
    public var all: [Detection] {
        autoAccept + needsVerification + requiresStrictGate
    }
}

/// Fast heuristic filtering for detection triage before expensive VLM verification
public struct DetectionFilter: Sendable {
    /// Minimum box size in pixels (normalized to frame)
    public let minBoxSize: Double

    /// Maximum box size as percentage of frame area
    public let maxBoxAreaRatio: Double

    /// IoU threshold for fast NMS deduplication
    public let nmsIouThreshold: Double

    /// Maximum instances per class (optional, 0 = unlimited)
    public let maxInstancesPerClass: Int

    public init(
        minBoxSize: Double = 0.01,  // 1% of min(width, height) - roughly 10x10 for 1000px frame
        maxBoxAreaRatio: Double = 0.9,  // 90% of frame area
        nmsIouThreshold: Double = 0.5,
        maxInstancesPerClass: Int = 0  // 0 = unlimited
    ) {
        self.minBoxSize = minBoxSize
        self.maxBoxAreaRatio = maxBoxAreaRatio
        self.nmsIouThreshold = nmsIouThreshold
        self.maxInstancesPerClass = maxInstancesPerClass
    }

    /// Filter detections with lightweight heuristics
    public func filter(_ detections: [Detection]) -> FilteredDetections {
        // 1. Size filtering (O(n), ~0.1ms for 5000 detections)
        let validSize = sizeFilter(detections)

        // 2. Spatial deduplication (O(n log n), ~2-5ms)
        let deduped = fastNMS(validSize, iouThreshold: nmsIouThreshold)

        // 3. Class-aware limits (O(n), ~0.5ms, optional)
        let limited = maxInstancesPerClass > 0
            ? limitPerClass(deduped, maxPerClass: maxInstancesPerClass)
            : deduped

        // 4. Confidence bucketing (O(n), ~0.1ms)
        return bucketByConfidence(limited)
    }

    // MARK: - Size Filtering

    private func sizeFilter(_ detections: [Detection]) -> [Detection] {
        detections.filter { detection in
            let bbox = detection.boundingBox
            let boxArea = bbox.size.width * bbox.size.height

            // Remove tiny boxes (likely noise)
            let minDimension = min(bbox.size.width, bbox.size.height)
            guard minDimension >= minBoxSize else { return false }

            // Remove huge boxes (likely false positives)
            guard boxArea <= maxBoxAreaRatio else { return false }

            return true
        }
    }

    // MARK: - Confidence Bucketing

    private func bucketByConfidence(_ detections: [Detection]) -> FilteredDetections {
        var high: [Detection] = []
        var mid: [Detection] = []
        var lowMid: [Detection] = []

        for detection in detections {
            if detection.confidence > 0.80 {
                high.append(detection)
            } else if detection.confidence >= 0.20 {
                mid.append(detection)
            } else {
                // 0.10 - 0.20 range (YOLO threshold is 0.15)
                lowMid.append(detection)
            }
        }

        return FilteredDetections(
            autoAccept: high,
            needsVerification: mid,
            requiresStrictGate: lowMid
        )
    }

    // MARK: - Fast NMS

    private func fastNMS(_ detections: [Detection], iouThreshold: Double) -> [Detection] {
        guard !detections.isEmpty else { return [] }

        // Sort by confidence descending
        let sorted = detections.sorted { $0.confidence > $1.confidence }
        var keep: [Detection] = []
        var suppressed = Set<UUID>()

        for detection in sorted {
            guard !suppressed.contains(detection.id) else { continue }

            keep.append(detection)

            // Suppress overlapping lower-confidence detections
            for other in sorted {
                guard !suppressed.contains(other.id) else { continue }
                guard detection.id != other.id else { continue }

                let iou = calculateIoU(detection.boundingBox, other.boundingBox)
                if iou >= iouThreshold {
                    suppressed.insert(other.id)
                }
            }
        }

        return keep
    }

    // MARK: - Class-Aware Limits

    private func limitPerClass(_ detections: [Detection], maxPerClass: Int) -> [Detection] {
        var classCount: [String: Int] = [:]
        var result: [Detection] = []

        // Detections are already sorted by confidence, so we keep highest-confidence instances
        for detection in detections {
            let count = classCount[detection.label, default: 0]
            if count < maxPerClass {
                result.append(detection)
                classCount[detection.label] = count + 1
            }
        }

        return result
    }

    // MARK: - IoU Calculation

    /// Calculate Intersection over Union for two normalized bounding boxes
    private func calculateIoU(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        // Calculate intersection rectangle
        let x1 = max(a.origin.x, b.origin.x)
        let y1 = max(a.origin.y, b.origin.y)
        let x2 = min(a.origin.x + a.size.width, b.origin.x + b.size.width)
        let y2 = min(a.origin.y + a.size.height, b.origin.y + b.size.height)

        // No intersection
        guard x2 > x1 && y2 > y1 else { return 0.0 }

        let intersection = (x2 - x1) * (y2 - y1)
        let areaA = a.size.width * a.size.height
        let areaB = b.size.width * b.size.height
        let union = areaA + areaB - intersection

        return intersection / union
    }
}
