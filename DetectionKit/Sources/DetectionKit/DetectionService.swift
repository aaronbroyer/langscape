import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(CoreVideo)
import CoreVideo
public typealias DetectionPixelBuffer = CVPixelBuffer
#else
public typealias DetectionPixelBuffer = AnyObject
#endif

public struct DetectionRequest {
    public let id: UUID
    public let timestamp: Date
    public let pixelBuffer: DetectionPixelBuffer
    // Raw CGImagePropertyOrientation rawValue to avoid directly depending on ImageIO in clients
    public let imageOrientationRaw: UInt32?

    public init(id: UUID = UUID(), timestamp: Date = Date(), pixelBuffer: DetectionPixelBuffer, imageOrientationRaw: UInt32? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.pixelBuffer = pixelBuffer
        self.imageOrientationRaw = imageOrientationRaw
    }
}

extension DetectionRequest: @unchecked Sendable {}

public enum DetectionError: Error, Sendable, Equatable {
    case modelNotFound
    case modelLoadFailed(String)
    case notPrepared
    case invalidInput
    case inferenceFailed(String)
    case unknown(String)

    public var errorDescription: String {
        switch self {
        case .modelNotFound:
            return "The CoreML model could not be located in the bundle."
        case .modelLoadFailed(let message):
            return "The CoreML model failed to load: \(message)."
        case .notPrepared:
            return "The detection service has not been prepared. Call prepare() before detecting."
        case .invalidInput:
            return "The supplied frame is not compatible with the detection service."
        case .inferenceFailed(let message):
            return "The detection request failed: \(message)."
        case .unknown(let message):
            return "An unknown detection error occurred: \(message)."
        }
    }
}

public protocol DetectionService: Sendable {
    func prepare() async throws
    func detect(on request: DetectionRequest) async throws -> [Detection]
}
