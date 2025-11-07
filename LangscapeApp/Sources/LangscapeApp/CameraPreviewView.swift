#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import AVFoundation
import DetectionKit
import GameKitLS
import GameKitLS
import UIComponents
import DesignSystem
import Utilities
#if canImport(UIKit)
import UIKit
#endif

struct CameraPreviewView: View {
    @ObservedObject var viewModel: DetectionVM
    @ObservedObject var gameViewModel: LabelScrambleVM
    @StateObject private var controller = CameraSessionController()

    @State private var showCompletionFlash = false
    @State private var homeCardPressed = false
    @State private var startPulse = false
    @State private var showDetections = true

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CameraPreviewLayer(session: controller.session)
                    .ignoresSafeArea()

                overlays(in: proxy.size)

                if showCompletionFlash {
                    Color.white
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                debugHUD
            }
            .coordinateSpace(name: "experience")
            .background(Color.black)
            .task {
                await controller.setViewModel(viewModel)
                controller.startSession()
            }
            .onDisappear {
                controller.stopSession()
            }
            .onChange(of: viewModel.detections) { newDetections in
                gameViewModel.ingestDetections(newDetections)
            }
            .onChange(of: gameViewModel.phase, perform: handlePhaseChange)
        }
    }

    @ViewBuilder
    private func overlays(in size: CGSize) -> some View {
        ZStack {
            switch gameViewModel.phase {
            case .home:
                homeOverlay
            case .scanning:
                if showDetections { detectionOverlay(for: viewModel.detections, in: size) }
                scanningIndicator
            case .ready:
                if showDetections { detectionOverlay(for: viewModel.detections, in: size) }
                startButton
            case .playing:
                roundOverlay(in: size, interactive: true)
            case .paused:
                roundOverlay(in: size, interactive: false)
            case .completed:
                EmptyView()
            }

            if gameViewModel.phase == .paused {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()

                PauseOverlay(resumeAction: gameViewModel.resume, exitAction: exitToHome)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var homeOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.25).ignoresSafeArea())

            VStack(spacing: Spacing.large.cgFloat) {
                LangscapeLogo(style: .full, glyphSize: 56)
                    .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 8)
                    .padding(.top, Spacing.xLarge.cgFloat * 1.4)

                Spacer()

                VStack(spacing: Spacing.medium.cgFloat) {
                    Button(action: beginScanning) {
                        HomeActivityCard(
                            iconName: "character.book.closed",
                            title: "Label Scramble",
                            subtitle: "Match words to what you see"
                        )
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(homeCardPressed ? 0.96 : 1)
                    .animation(.spring(response: 0.45, dampingFraction: 0.72), value: homeCardPressed)

                    HomeActivityCard(
                        iconName: "sparkles",
                        title: "More activities",
                        subtitle: "Coming soon",
                        enabled: false
                    )
                }
                .padding(Spacing.large.cgFloat)
                .background(
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 36, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
                .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 12)
                .padding(.horizontal, Spacing.large.cgFloat)

                Spacer()
            }
            .padding(.bottom, Spacing.xLarge.cgFloat * 2.2)
        }
    }

    private var scanningIndicator: some View {
        VStack {
            Spacer()

            TranslucentPanel(cornerRadius: 20) {
                HStack(spacing: Spacing.small.cgFloat) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Locking onto objects…")
                        .font(Typography.body.font)
                        .foregroundStyle(ColorPalette.primary.swiftUIColor)
                }
                .padding(.vertical, Spacing.small.cgFloat)
            }
            .padding(.bottom, Spacing.xLarge.cgFloat * 1.2)
        }
        .allowsHitTesting(false)
    }

    private var startButton: some View {
        VStack {
            Spacer()

            Button(action: startRound) {
                ZStack {
                    Circle()
                        .fill(ColorPalette.accent.swiftUIColor)
                        .frame(width: 120, height: 120)
                        .shadow(color: ColorPalette.accent.swiftUIColor.opacity(0.45), radius: 22, x: 0, y: 10)

                    Text("Start")
                        .font(Typography.body.font.weight(.bold))
                        .foregroundStyle(Color.white)
                }
            }
            .buttonStyle(.plain)
            .scaleEffect(startPulse ? 1.08 : 1)
            .padding(.bottom, Spacing.xLarge.cgFloat * 1.6)
        }
        .onAppear { startPulseAnimation() }
        .onDisappear { startPulse = false }
    }

    @ViewBuilder
    private func roundOverlay(in size: CGSize, interactive: Bool) -> some View {
        if let round = gameViewModel.round {
            RoundPlayLayer(
                round: round,
                placedLabels: gameViewModel.placedLabels,
                lastIncorrectLabelID: gameViewModel.lastIncorrectLabelID,
                interactive: interactive,
                showTargets: !interactive,
                frameProvider: { frame(for: $0, in: size) },
                attemptMatch: { labelID, objectID in
                    gameViewModel.attemptMatch(labelID: labelID, on: objectID)
                },
                onPause: gameViewModel.pause
            )
        }
    }

    @ViewBuilder
    private var debugHUD: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SHOW_HUD"] == "1" {
            VStack(alignment: .leading, spacing: 8) {
                Text("FPS: \(viewModel.fps, specifier: "%.1f")")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(Color.white)

                if let error = viewModel.lastError {
                    Text(error.errorDescription)
                        .font(.system(size: 12, weight: .regular))
                        .padding(8)
                        .background(Color.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Color.white)
                }

                Spacer()
            }
            .padding()
        }
        #endif
    }

    private func exitToHome() {
        showCompletionFlash = false
        gameViewModel.exitToHome()
    }

    private func handlePhaseChange(_ phase: LabelScrambleVM.Phase) {
        switch phase {
        case .completed:
            showCompletionFlash = true
            Task { [gameViewModel] in
                try? await Task.sleep(nanoseconds: 280_000_000)
                await MainActor.run {
                    showCompletionFlash = false
                    gameViewModel.acknowledgeCompletion()
                }
            }
        case .ready:
            startPulseAnimation()
            withAnimation(.easeInOut(duration: 0.2)) { showDetections = true }
        case .scanning:
            withAnimation(.easeInOut(duration: 0.2)) { showDetections = true }
        case .playing, .paused:
            withAnimation(.easeInOut(duration: 0.2)) { showDetections = false }
        default:
            if startPulse {
                withAnimation(.easeInOut(duration: 0.25)) {
                    startPulse = false
                }
            }
        }
    }

    private func startPulseAnimation() {
        guard !startPulse else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            startPulse = true
        }
    }

    private func startRound() {
        guard gameViewModel.phase == .ready else { return }
        gameViewModel.startRound()
    }

    private func beginScanning() {
        guard gameViewModel.phase == .home else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
            homeCardPressed = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            await MainActor.run {
                homeCardPressed = false
            }
        }
        gameViewModel.beginScanning()
    }

    private func detectionOverlay(for detections: [Detection], in size: CGSize) -> some View {
        ZStack {
            ForEach(detections) { detection in
                let rect = frame(for: detection, in: size)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ColorPalette.accent.swiftUIColor.opacity(0.9), lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.black.opacity(0.18))
                    )
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detection.label.capitalized)
                                .font(Typography.caption.font.weight(.semibold))
                                .foregroundStyle(Color.white)

                            Text("\(Int(detection.confidence * 100))%")
                                .font(Typography.caption.font)
                                .foregroundStyle(Color.white.opacity(0.75))
                        }
                        .padding(Spacing.xSmall.cgFloat)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .offset(x: 6, y: 6)
                    }
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
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
        #if canImport(ImageIO)
        let cgOrientationRaw: UInt32 = {
            // Map AVCaptureVideoOrientation (back camera) to CGImagePropertyOrientation
            switch connection.videoOrientation {
            case .portrait: return CGImagePropertyOrientation.right.rawValue
            case .portraitUpsideDown: return CGImagePropertyOrientation.left.rawValue
            case .landscapeRight: return CGImagePropertyOrientation.up.rawValue
            case .landscapeLeft: return CGImagePropertyOrientation.down.rawValue
            @unknown default: return CGImagePropertyOrientation.up.rawValue
            }
        }()
        #else
        let cgOrientationRaw: UInt32? = nil
        #endif
        let request = DetectionRequest(timestamp: Date(), pixelBuffer: pixelBuffer, imageOrientationRaw: cgOrientationRaw)
        Task { @MainActor [weak self] in
            let pbw = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let pbh = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            // Use oriented input dimensions to match Vision's coordinate space
            let orientedSize: CGSize
            switch connection.videoOrientation {
            case .portrait, .portraitUpsideDown:
                orientedSize = CGSize(width: pbh, height: pbw)
            default:
                orientedSize = CGSize(width: pbw, height: pbh)
            }
            self?.viewModel?.setInputSize(orientedSize)
            self?.viewModel?.enqueue(request)
        }
    }
}

private struct RoundPlayLayer: View {
    let round: Round
    let placedLabels: Set<GameKitLS.Label.ID>
    let lastIncorrectLabelID: GameKitLS.Label.ID?
    let interactive: Bool
    let showTargets: Bool
    let frameProvider: (DetectedObject) -> CGRect
    let attemptMatch: (GameKitLS.Label.ID, DetectedObject.ID) -> LabelScrambleVM.MatchResult
    let onPause: () -> Void

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    private var frames: [DetectedObject.ID: CGRect] {
        Dictionary(uniqueKeysWithValues: round.objects.map { ($0.id, frameProvider($0)) })
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if showTargets {
                ForEach(round.objects) { object in
                    if let frame = frames[object.id] {
                        ObjectTargetOverlay(
                            frame: frame,
                            state: isSatisfied(objectID: object.id) ? .satisfied : .pending
                        )
                        .allowsHitTesting(false)
                    }
                }
            }

            VStack {
                Spacer()

                TranslucentPanel(cornerRadius: 28) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(round.labels) { label in
                            let state = tokenState(for: label)
                            DraggableToken(
                                label: label,
                                state: state,
                                interactive: interactive,
                                dropHandler: { point in
                                    guard let destinationID = destination(for: point) else { return .ignored }
                                    return attemptMatch(label.id, destinationID)
                                }
                            )
                        }
                    }
                    .padding(.top, Spacing.small.cgFloat)
                    .padding(.bottom, Spacing.small.cgFloat)
                }
                .padding(.horizontal, Spacing.large.cgFloat)
                .padding(.bottom, Spacing.xLarge.cgFloat)
            }

            if interactive {
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ColorPalette.primary.swiftUIColor)
                        .padding(Spacing.small.cgFloat)
                        .background(Color.white.opacity(0.8), in: Circle())
                        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
                }
                .padding(.top, 50)
                .padding(.trailing, Spacing.large.cgFloat)
            }
        }
    }

    private func isSatisfied(objectID: DetectedObject.ID) -> Bool {
        round.labels.contains { $0.objectID == objectID && placedLabels.contains($0.id) }
    }

    private func tokenState(for label: GameKitLS.Label) -> LabelToken.VisualState {
        if placedLabels.contains(label.id) { return .placed }
        if lastIncorrectLabelID == label.id { return .incorrect }
        return .idle
    }

    private func destination(for point: CGPoint) -> DetectedObject.ID? {
        // 1) Prefer a direct hit inside an expanded frame
        if let hit = frames.first(where: { expand(frame: $0.value).contains(point) })?.key {
            return hit
        }
        // 2) Otherwise, snap to the nearest object within a reasonable radius
        var best: (id: DetectedObject.ID, distance: CGFloat, frame: CGRect)?
        for (id, frame) in frames {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let dx = center.x - point.x
            let dy = center.y - point.y
            let d = sqrt(dx*dx + dy*dy)
            if best == nil || d < best!.distance { best = (id, d, frame) }
        }
        if let best {
            let radius = max(44, min(best.frame.width, best.frame.height) * 0.6)
            return best.distance <= radius ? best.id : nil
        }
        return nil
    }

    private func expand(frame: CGRect) -> CGRect {
        let inset = max(24, min(frame.width, frame.height) * 0.2)
        return frame.insetBy(dx: -inset, dy: -inset)
    }
}

private struct DraggableToken: View {
    let label: GameKitLS.Label
    let state: LabelToken.VisualState
    let interactive: Bool
    let dropHandler: (CGPoint) -> LabelScrambleVM.MatchResult

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("experience"))
            LabelToken(text: label.text, state: state)
                .opacity(state == .placed ? 0 : 1)
                .scaleEffect(isDragging ? 1.05 : 1)
                .offset(dragOffset)
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: dragOffset)
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: state)
                .allowsHitTesting(interactive && state != .placed)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            guard interactive, state != .placed else { return }
                            dragOffset = value.translation
                            isDragging = true
                        }
                        .onEnded { value in
                            guard interactive, state != .placed else { return }
                            let dropPoint = CGPoint(
                                x: frame.midX + value.translation.width,
                                y: frame.midY + value.translation.height
                            )
                            _ = dropHandler(dropPoint)
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                dragOffset = .zero
                                isDragging = false
                            }
                        }
                )
                .onChange(of: state) { newState in
                    if newState == .placed {
                        dragOffset = .zero
                        isDragging = false
                    }
                }
        }
        .frame(height: 56)
    }
}

private struct HomeActivityCard: View {
    let iconName: String
    let title: String
    let subtitle: String
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: Spacing.medium.cgFloat) {
            Image(systemName: iconName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(ColorPalette.accent.swiftUIColor.opacity(enabled ? 1 : 0.4))

            VStack(alignment: .leading, spacing: Spacing.xSmall.cgFloat) {
                Text(title)
                    .font(Typography.body.font.weight(.semibold))
                    .foregroundStyle(ColorPalette.primary.swiftUIColor)

                Text(subtitle)
                    .font(Typography.caption.font)
                    .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.7))
            }

            Spacer()

            if enabled {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.6))
            }
        }
        .padding(.vertical, Spacing.medium.cgFloat)
        .padding(.horizontal, Spacing.medium.cgFloat)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(ColorPalette.surface.swiftUIColor.opacity(enabled ? 0.35 : 0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .opacity(enabled ? 1 : 0.55)
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
    func frame(for detection: Detection, in viewSize: CGSize) -> CGRect {
        frame(for: detection.boundingBox, in: viewSize)
    }

    func frame(for object: DetectedObject, in viewSize: CGSize) -> CGRect {
        frame(for: object.boundingBox, in: viewSize)
    }

    func frame(for normalizedRect: NormalizedRect, in viewSize: CGSize) -> CGRect {
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
            let x = offsetX + CGFloat(normalizedRect.origin.x) * dw
            let y = offsetY + CGFloat(normalizedRect.origin.y) * dh
            let w = CGFloat(normalizedRect.size.width) * dw
            let h = CGFloat(normalizedRect.size.height) * dh
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return normalizedRect.rect(in: viewSize)
    }
}
#endif
