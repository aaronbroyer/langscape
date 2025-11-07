#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import AVFoundation
import DetectionKit
import Utilities
#if canImport(UIKit)
import UIKit
#endif

struct CameraPreviewView: View {
    @ObservedObject var viewModel: DetectionVM
    @StateObject private var controller = CameraSessionController()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CameraPreviewLayer(session: controller.session)
                    .ignoresSafeArea()

                detectionOverlay(in: proxy.size)

                #if DEBUG
                if ProcessInfo.processInfo.environment["SHOW_HUD"] == "1" {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FPS: \(viewModel.fps, specifier: "%.1f")")
                            .font(.headline)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(Color.white)

                        if let error = viewModel.lastError {
                            Text(error.errorDescription)
                                .font(.footnote)
                                .padding(8)
                                .background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(Color.white)
                        }

                        Spacer()
                    }
                    .padding()
                }
                #endif
            }
            .background(Color.black)
            .task {
                await controller.setViewModel(viewModel)
                controller.startSession()
            }
            .onDisappear {
                controller.stopSession()
            }
        }
    }

    @ViewBuilder
    private func detectionOverlay(in size: CGSize) -> some View {
        ZStack {
            ForEach(viewModel.detections) { detection in
                let rect = rect(for: detection, in: size)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.green, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(detection.label)
                                .font(.caption)
                                .bold()
                            Text("\(Int(detection.confidence * 100))%")
                                .font(.caption2)
                        }
                        .padding(6)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Color.white)
                        .offset(x: 4, y: 4)
                    }
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct CameraPreviewLayer: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

@MainActor
private final class CameraSessionController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    private let logger = Logger.shared
    private let sessionQueue = DispatchQueue(label: "CameraSessionController.queue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private weak var viewModel: DetectionVM?
    private var isConfigured = false

    func setViewModel(_ viewModel: DetectionVM) async {
        self.viewModel = viewModel
        await logger.log("Camera view model attached", level: .info, category: "LangscapeApp.Camera")
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
                self.isConfigured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
                Task { await self.logger.log("AVCaptureSession started", level: .info, category: "LangscapeApp.Camera") }
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            Task { await self.logger.log("AVCaptureSession stopped", level: .info, category: "LangscapeApp.Camera") }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            Task { await logger.log("No camera device available", level: .error, category: "LangscapeApp.Camera") }
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            Task { await logger.log("Failed to create camera input: \(error.localizedDescription)", level: .error, category: "LangscapeApp.Camera") }
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        session.commitConfiguration()

        Task { await logger.log("Camera session configured", level: .info, category: "LangscapeApp.Camera") }
    }
}

extension CameraSessionController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = DetectionRequest(timestamp: Date(), pixelBuffer: pixelBuffer)
        Task { @MainActor [weak self] in
            let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            self?.viewModel?.setInputSize(CGSize(width: w, height: h))
            self?.viewModel?.enqueue(request)
        }
    }
}

private extension NormalizedRect {
    func rect(in size: CGSize) -> CGRect {
        let width = CGFloat(self.size.width) * size.width
        let height = CGFloat(self.size.height) * size.height
        let x = CGFloat(origin.x) * size.width
        let y = CGFloat(origin.y) * size.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension CameraPreviewView {
    func rect(for detection: Detection, in viewSize: CGSize) -> CGRect {
        if let imgSize = viewModel.inputImageSize, imgSize.width > 0, imgSize.height > 0 {
            let sw = viewSize.width
            let sh = viewSize.height
            let iw = imgSize.width
            let ih = imgSize.height
            let scale = max(sw / iw, sh / ih)
            let dw = iw * scale
            let dh = ih * scale
            let offsetX = (sw - dw) / 2
            let offsetY = (sh - dh) / 2
            let bb = detection.boundingBox
            let x = offsetX + CGFloat(bb.origin.x) * dw
            let y = offsetY + CGFloat(bb.origin.y) * dh
            let w = CGFloat(bb.size.width) * dw
            let h = CGFloat(bb.size.height) * dh
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return detection.boundingBox.rect(in: viewSize)
    }
}
#endif
