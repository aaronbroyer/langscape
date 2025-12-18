import Foundation
import Utilities

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(CoreImage)
import CoreImage
#endif

#if canImport(CoreML)
@preconcurrency import CoreML
#endif

#if canImport(CoreVideo)
import CoreVideo
#endif

public actor EfficientSAMSegmenter {
    private let logger: Logger
    private let ciContext: CIContext
    private var prepared = false

    #if canImport(CoreML)
    private var model: MLModel?
    #endif

    #if canImport(CoreVideo)
    private var modelInputPixelBuffer: CVPixelBuffer?
    #endif

    public init(logger: Logger = .shared) {
        self.logger = logger
        self.ciContext = CIContext(options: [.cacheIntermediates: false])
    }

    public func prepare() async throws {
        guard !prepared else { return }
        #if canImport(CoreML)
        guard let url = locateModelURL() else {
            await logger.log("EfficientSAMSegmenter: model resource missing", level: .error, category: "DetectionKit.EfficientSAMSegmenter")
            throw DetectionError.modelNotFound
        }
        let compiled = try await compileModelIfNeeded(url)
        let configuration = MLModelConfiguration()
        #if os(iOS)
        configuration.computeUnits = .all
        #endif
        model = try MLModel(contentsOf: compiled, configuration: configuration)
        prepared = true
        await logger.log("EfficientSAMSegmenter: model ready", level: .info, category: "DetectionKit.EfficientSAMSegmenter")
        #else
        throw DetectionError.modelNotFound
        #endif
    }

    #if canImport(CoreVideo) && canImport(CoreGraphics) && canImport(CoreML) && canImport(CoreImage)
    public func segment(
        pixelBuffer: CVPixelBuffer,
        boundingBox: NormalizedRect,
        orientationRaw: UInt32?
    ) async throws -> CGImage {
        try await prepare()
        guard let model else { throw DetectionError.modelNotFound }

        let orientedImage = orientedCIImage(from: pixelBuffer, orientationRaw: orientationRaw)
        let originalExtent = orientedImage.extent
        let originalWidth = Int(originalExtent.width.rounded(.toNearestOrAwayFromZero))
        let originalHeight = Int(originalExtent.height.rounded(.toNearestOrAwayFromZero))
        guard originalWidth > 0, originalHeight > 0 else { throw DetectionError.invalidInput }

        let (inputPB, scale, padX, padY) = try prepareModelInput(from: orientedImage)
        let promptBox = promptBoxInModelSpace(
            normalizedBox: boundingBox,
            originalWidth: CGFloat(originalWidth),
            originalHeight: CGFloat(originalHeight),
            scale: scale,
            padX: padX,
            padY: padY
        )

        let boxes = try boxesMultiArray(x0: promptBox.x0, y0: promptBox.y0, x1: promptBox.x1, y1: promptBox.y1)
        let input = try MLDictionaryFeatureProvider(
            dictionary: [
                "image": MLFeatureValue(pixelBuffer: inputPB),
                "boxes": MLFeatureValue(multiArray: boxes)
            ]
        )
        let output = try await model.prediction(from: input)
        guard let maskArray = output.featureValue(for: "var_1361")?.multiArrayValue else {
            throw DetectionError.inferenceFailed("EfficientSAM mask output missing")
        }

        let alphaMask = try mappedAlphaMask(
            from: maskArray,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            scale: scale,
            padX: padX,
            padY: padY
        )

        return alphaMask
    }

    public func segmentOutline(
        pixelBuffer: CVPixelBuffer,
        boundingBox: NormalizedRect,
        orientationRaw: UInt32?,
        minimumAlpha: UInt8 = 160,
        edgeRadius: CGFloat = 4
    ) async throws -> CGImage {
        try await prepare()
        guard let model else { throw DetectionError.modelNotFound }

        let orientedImage = orientedCIImage(from: pixelBuffer, orientationRaw: orientationRaw)
        let originalExtent = orientedImage.extent
        let originalWidth = Int(originalExtent.width.rounded(.toNearestOrAwayFromZero))
        let originalHeight = Int(originalExtent.height.rounded(.toNearestOrAwayFromZero))
        guard originalWidth > 0, originalHeight > 0 else { throw DetectionError.invalidInput }

        let (inputPB, scale, padX, padY) = try prepareModelInput(from: orientedImage)
        let promptBox = promptBoxInModelSpace(
            normalizedBox: boundingBox,
            originalWidth: CGFloat(originalWidth),
            originalHeight: CGFloat(originalHeight),
            scale: scale,
            padX: padX,
            padY: padY
        )

        let boxes = try boxesMultiArray(x0: promptBox.x0, y0: promptBox.y0, x1: promptBox.x1, y1: promptBox.y1)
        let input = try MLDictionaryFeatureProvider(
            dictionary: [
                "image": MLFeatureValue(pixelBuffer: inputPB),
                "boxes": MLFeatureValue(multiArray: boxes)
            ]
        )
        let output = try await model.prediction(from: input)
        guard let maskArray = output.featureValue(for: "var_1361")?.multiArrayValue else {
            throw DetectionError.inferenceFailed("EfficientSAM mask output missing")
        }

        let alpha = try mappedAlphaMaskBytes(
            from: maskArray,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            scale: scale,
            padX: padX,
            padY: padY
        )

        let outlineAlpha = try outlineAlphaBytes(
            from: alpha,
            boundingBox: boundingBox,
            minimumAlpha: minimumAlpha,
            edgeRadius: edgeRadius
        )

        return try rgbaMaskImage(from: outlineAlpha)
    }
    #endif
}

#if canImport(CoreVideo) && canImport(CoreGraphics) && canImport(CoreML) && canImport(CoreImage)
private extension EfficientSAMSegmenter {
    private struct AlphaMask {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private struct PromptBox {
        let x0: Float
        let y0: Float
        let x1: Float
        let y1: Float
    }

    private func locateModelURL() -> URL? {
        if let url = Bundle.module.url(forResource: "EfficientSAMVITS", withExtension: "mlmodelc") {
            return url
        }
        if let pkg = Bundle.module.url(forResource: "EfficientSAMVITS", withExtension: "mlpackage") {
            return pkg
        }
        if let raw = Bundle.module.url(forResource: "EfficientSAMVITS", withExtension: "mlmodel") {
            return raw
        }
        return nil
    }

    private func compileModelIfNeeded(_ url: URL) async throws -> URL {
        if url.pathExtension == "mlmodelc" { return url }
        return try await Task.detached(priority: .utility) {
            try MLModel.compileModel(at: url)
        }.value
    }

    private func orientedCIImage(from pixelBuffer: CVPixelBuffer, orientationRaw: UInt32?) -> CIImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = orientationRaw.flatMap { ciImage.oriented(forExifOrientation: Int32($0)) } ?? ciImage
        let extent = oriented.extent
        if extent.origin != .zero {
            return oriented.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
        }
        return oriented
    }

    private func prepareModelInput(from orientedImage: CIImage) throws -> (CVPixelBuffer, CGFloat, CGFloat, CGFloat) {
        let target: CGFloat = 1024
        let width = orientedImage.extent.width
        let height = orientedImage.extent.height

        let scale = min(target / width, target / height)
        let newW = width * scale
        let newH = height * scale
        let padX = (target - newW) / 2
        let padY = (target - newH) / 2

        let resized = orientedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let padded = resized.transformed(by: CGAffineTransform(translationX: padX, y: padY))

        let outputBuffer = try ensureModelInputPixelBuffer(width: Int(target), height: Int(target))
        ciContext.render(padded, to: outputBuffer)
        return (outputBuffer, scale, padX, padY)
    }

    private func ensureModelInputPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if let existing = modelInputPixelBuffer,
           CVPixelBufferGetWidth(existing) == width,
           CVPixelBufferGetHeight(existing) == height,
           CVPixelBufferGetPixelFormatType(existing) == kCVPixelFormatType_32BGRA {
            return existing
        }

        var output: CVPixelBuffer?
        let options: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            options as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let created = output else {
            throw DetectionError.modelLoadFailed("Failed to allocate model input buffer")
        }
        modelInputPixelBuffer = created
        return created
    }

    private func promptBoxInModelSpace(
        normalizedBox: NormalizedRect,
        originalWidth: CGFloat,
        originalHeight: CGFloat,
        scale: CGFloat,
        padX: CGFloat,
        padY: CGFloat
    ) -> PromptBox {
        let x0 = CGFloat(normalizedBox.origin.x) * originalWidth
        let y0 = CGFloat(normalizedBox.origin.y) * originalHeight
        let x1 = CGFloat(normalizedBox.origin.x + normalizedBox.size.width) * originalWidth
        let y1 = CGFloat(normalizedBox.origin.y + normalizedBox.size.height) * originalHeight

        let mx0 = (x0 * scale) + padX
        let my0 = (y0 * scale) + padY
        let mx1 = (x1 * scale) + padX
        let my1 = (y1 * scale) + padY

        let clamped = (
            x0: max(0, min(1023, mx0)),
            y0: max(0, min(1023, my0)),
            x1: max(0, min(1023, mx1)),
            y1: max(0, min(1023, my1))
        )

        return PromptBox(x0: Float(clamped.x0), y0: Float(clamped.y0), x1: Float(clamped.x1), y1: Float(clamped.y1))
    }

    private func boxesMultiArray(x0: Float, y0: Float, x1: Float, y1: Float) throws -> MLMultiArray {
        let boxes = try MLMultiArray(shape: [1, 1, 4], dataType: .float16)
        boxes[0] = NSNumber(value: x0)
        boxes[1] = NSNumber(value: y0)
        boxes[2] = NSNumber(value: x1)
        boxes[3] = NSNumber(value: y1)
        return boxes
    }

    private func mappedAlphaMask(
        from maskArray: MLMultiArray,
        originalWidth: Int,
        originalHeight: Int,
        scale: CGFloat,
        padX: CGFloat,
        padY: CGFloat
    ) throws -> CGImage {
        let alpha = try mappedAlphaMaskBytes(
            from: maskArray,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            scale: scale,
            padX: padX,
            padY: padY
        )
        return try rgbaMaskImage(from: alpha)
    }

    private func mappedAlphaMaskBytes(
        from maskArray: MLMultiArray,
        originalWidth: Int,
        originalHeight: Int,
        scale: CGFloat,
        padX: CGFloat,
        padY: CGFloat
    ) throws -> AlphaMask {
        let lowRes = try sigmoidMaskBytes(from: maskArray)

        let grayProvider = CGDataProvider(data: Data(lowRes) as CFData)!
        let graySpace = CGColorSpaceCreateDeviceGray()
        let lowResImage = CGImage(
            width: 256,
            height: 256,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: 256,
            space: graySpace,
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: grayProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!

        let mapped = CIImage(cgImage: lowResImage)
            .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
            .transformed(by: CGAffineTransform(translationX: -padX, y: -padY))
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(originalWidth), height: CGFloat(originalHeight)))

        var alpha = [UInt8](repeating: 0, count: originalWidth * originalHeight)
        ciContext.render(
            mapped,
            toBitmap: &alpha,
            rowBytes: originalWidth,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(originalWidth), height: CGFloat(originalHeight)),
            format: .R8,
            colorSpace: nil
        )

        return AlphaMask(width: originalWidth, height: originalHeight, bytes: alpha)
    }

    private func rgbaMaskImage(from alpha: AlphaMask) throws -> CGImage {
        var rgba = [UInt8](repeating: 255, count: alpha.width * alpha.height * 4)
        var aIndex = 0
        var rgbaIndex = 0
        while aIndex < alpha.bytes.count {
            let a = alpha.bytes[aIndex]
            rgba[rgbaIndex] = 255
            rgba[rgbaIndex + 1] = 255
            rgba[rgbaIndex + 2] = 255
            rgba[rgbaIndex + 3] = a
            aIndex += 1
            rgbaIndex += 4
        }

        let rgbSpace = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = CGImage(
            width: alpha.width,
            height: alpha.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: alpha.width * 4,
            space: rgbSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw DetectionError.inferenceFailed("Failed to build alpha mask image")
        }

        return image
    }

    private func outlineAlphaBytes(
        from alpha: AlphaMask,
        boundingBox: NormalizedRect,
        minimumAlpha: UInt8,
        edgeRadius: CGFloat
    ) throws -> AlphaMask {
        let paddedBox = paddedPixelRect(
            for: boundingBox,
            width: alpha.width,
            height: alpha.height,
            padding: max(2, Int(edgeRadius.rounded(.up)) * 2)
        )

        let threshold = adaptiveThreshold(
            alpha: alpha.bytes,
            width: alpha.width,
            pixelRect: paddedBox,
            minimumAlpha: minimumAlpha
        )

        var binary = [UInt8](repeating: 0, count: alpha.bytes.count)
        for y in paddedBox.minY..<paddedBox.maxY {
            let rowStart = y * alpha.width
            for x in paddedBox.minX..<paddedBox.maxX {
                let index = rowStart + x
                binary[index] = alpha.bytes[index] >= threshold ? 255 : 0
            }
        }

        let binaryData = Data(binary)
        let ciBinary = CIImage(
            bitmapData: binaryData,
            bytesPerRow: alpha.width,
            size: CGSize(width: CGFloat(alpha.width), height: CGFloat(alpha.height)),
            format: .R8,
            colorSpace: nil
        )

        guard let filter = CIFilter(name: "CIMorphologyGradient") else {
            throw DetectionError.inferenceFailed("CIMorphologyGradient unavailable")
        }
        filter.setValue(ciBinary, forKey: kCIInputImageKey)
        filter.setValue(edgeRadius, forKey: kCIInputRadiusKey)
        guard let outlined = filter.outputImage?
            .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(alpha.width), height: CGFloat(alpha.height))) else {
            throw DetectionError.inferenceFailed("Failed to compute outline mask")
        }

        var outline = [UInt8](repeating: 0, count: alpha.width * alpha.height)
        ciContext.render(
            outlined,
            toBitmap: &outline,
            rowBytes: alpha.width,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(alpha.width), height: CGFloat(alpha.height)),
            format: .R8,
            colorSpace: nil
        )

        return AlphaMask(width: alpha.width, height: alpha.height, bytes: outline)
    }

    private struct PixelRect {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
    }

    private func paddedPixelRect(for normalizedBox: NormalizedRect, width: Int, height: Int, padding: Int) -> PixelRect {
        let nx0 = max(0.0, min(1.0, normalizedBox.origin.x))
        let ny0 = max(0.0, min(1.0, normalizedBox.origin.y))
        let nx1 = max(0.0, min(1.0, normalizedBox.origin.x + normalizedBox.size.width))
        let ny1 = max(0.0, min(1.0, normalizedBox.origin.y + normalizedBox.size.height))

        let x0 = Int((nx0 * Double(width)).rounded(.down))
        let y0 = Int((ny0 * Double(height)).rounded(.down))
        let x1 = Int((nx1 * Double(width)).rounded(.up))
        let y1 = Int((ny1 * Double(height)).rounded(.up))

        let minX = max(0, min(width, x0) - padding)
        let minY = max(0, min(height, y0) - padding)
        let maxX = min(width, max(0, x1) + padding)
        let maxY = min(height, max(0, y1) + padding)

        if maxX <= minX || maxY <= minY {
            return PixelRect(minX: 0, minY: 0, maxX: width, maxY: height)
        }

        return PixelRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func adaptiveThreshold(alpha: [UInt8], width: Int, pixelRect: PixelRect, minimumAlpha: UInt8) -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        var maxValue = 0
        var total = 0

        for y in pixelRect.minY..<pixelRect.maxY {
            let rowStart = y * width
            for x in pixelRect.minX..<pixelRect.maxX {
                let value = Int(alpha[rowStart + x])
                histogram[value] += 1
                maxValue = max(maxValue, value)
                total += 1
            }
        }

        guard total > 0 else { return minimumAlpha }

        let otsu = otsuThreshold(histogram: histogram, total: total)
        var threshold = max(Int(minimumAlpha), otsu)

        if maxValue <= threshold {
            threshold = max(0, maxValue - 8)
        }

        return UInt8(max(0, min(255, threshold)))
    }

    private func otsuThreshold(histogram: [Int], total: Int) -> Int {
        guard total > 0 else { return 0 }
        var sumAll = 0
        for i in 0..<256 {
            sumAll += i * histogram[i]
        }

        var sumBackground = 0
        var weightBackground = 0
        var bestThreshold = 0
        var bestVariance = -1.0

        for t in 0..<256 {
            weightBackground += histogram[t]
            guard weightBackground > 0 else { continue }
            let weightForeground = total - weightBackground
            guard weightForeground > 0 else { break }

            sumBackground += t * histogram[t]
            let meanBackground = Double(sumBackground) / Double(weightBackground)
            let meanForeground = Double(sumAll - sumBackground) / Double(weightForeground)

            let variance = Double(weightBackground) * Double(weightForeground) * pow(meanBackground - meanForeground, 2)
            if variance > bestVariance {
                bestVariance = variance
                bestThreshold = t
            }
        }

        return bestThreshold
    }

    private func sigmoidMaskBytes(from maskArray: MLMultiArray) throws -> [UInt8] {
        let expectedCount = 256 * 256
        guard maskArray.count >= expectedCount else {
            throw DetectionError.inferenceFailed("Unexpected mask output size")
        }
        var bytes = [UInt8](repeating: 0, count: expectedCount)
        for i in 0..<expectedCount {
            let logit = maskArray[i].floatValue
            let prob = 1.0 / (1.0 + exp(-Double(logit)))
            bytes[i] = UInt8(max(0, min(255, Int(prob * 255.0))))
        }
        return bytes
    }
}
#endif
