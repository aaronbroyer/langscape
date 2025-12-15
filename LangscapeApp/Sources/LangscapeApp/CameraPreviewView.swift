#if canImport(SwiftUI) && canImport(ARKit)
import SwiftUI
import ARKit
import RealityKit
import DetectionKit
import GameKitLS
import UIComponents
import DesignSystem
import Utilities
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(Vision)
import Vision
#endif
private typealias DetectionRect = DetectionKit.NormalizedRect

struct CameraPreviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: DetectionVM
    @ObservedObject var gameViewModel: LabelScrambleVM
    @ObservedObject var contextManager: ContextManager

    @State private var showCompletionFlash = false
    @State private var homeCardPressed = false
    @State private var startPulse = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ARCameraView(viewModel: viewModel, gameViewModel: gameViewModel, contextManager: contextManager)
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
            .onChange(of: viewModel.detections) { _, newDetections in
                guard gameViewModel.phase == .scanning else { return }
                gameViewModel.ingestDetections(newDetections)
            }
            .onChange(of: gameViewModel.phase) { _, newPhase in
                handlePhaseChange(newPhase)
            }
            .onChange(of: viewModel.lastError) { _, newError in
                if newError != nil {
                    gameViewModel.presentFatalError()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                viewModel.updateAppLifecycle(isActive: phase == .active)
            }
        }
        .overlay(alignment: .topLeading) {
            if shouldShowContextBadge {
                contextBadge
                    .padding(.top, 24)
                    .padding(.leading, 24)
            }
        }
        .onAppear {
            viewModel.updateAppLifecycle(isActive: scenePhase == .active)
        }
        .onDisappear {
            viewModel.updateAppLifecycle(isActive: false)
        }
    }

    @ViewBuilder
    private func overlays(in size: CGSize) -> some View {
        ZStack {
            switch gameViewModel.phase {
            case .home:
                homeOverlay
            case .scanning:
                scanningIndicator
            case .ready:
                startButton
            case .playing:
                roundOverlay(in: size, interactive: true, showTargets: true)
            case .paused:
                roundOverlay(in: size, interactive: false, showTargets: true)
            case .completed:
                EmptyView()
            }

            if gameViewModel.phase == .paused && gameViewModel.overlay == nil {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()

                PauseOverlay(resumeAction: gameViewModel.resume, exitAction: exitToHome)
                    .transition(.scale.combined(with: .opacity))
            }

            if let overlay = gameViewModel.overlay {
                blockingOverlay(for: overlay)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: gameViewModel.overlay)
    }

    private var contextBadge: some View {
        HStack(spacing: Spacing.xSmall.cgFloat) {
            Image(systemName: "viewfinder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
            Text(contextManager.contextDisplayName)
                .font(Typography.caption.font.weight(.semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)

            if contextManager.isDetecting {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.8)
            } else if contextManager.canManuallyChange {
                Button("Change") {
                    contextManager.reset()
                }
                .font(Typography.caption.font.weight(.semibold))
                .foregroundStyle(ColorPalette.accent.swiftUIColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, Spacing.medium.cgFloat)
        .padding(.vertical, Spacing.xSmall.cgFloat)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 4)
    }

    private var homeOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                // Slightly reduce the darkening overlay for a more translucent feel
                .overlay(Color.black.opacity(0.14).ignoresSafeArea())

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

    @ViewBuilder
    private func blockingOverlay(for overlay: LabelScrambleVM.Overlay) -> some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack {
                Spacer()

                TranslucentPanel(cornerRadius: 32) {
                    VStack(spacing: Spacing.medium.cgFloat) {
                        LangscapeLogo(style: .mark, glyphSize: 56)
                            .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 6)

                        switch overlay {
                        case .noObjects:
                            Text("No objects detected")
                                .font(Typography.title.font.weight(.semibold))
                                .foregroundStyle(ColorPalette.primary.swiftUIColor)

                            Text("Try pointing your camera at a scene with more objects.")
                                .font(Typography.body.font)
                                .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.8))
                                .multilineTextAlignment(.center)

                            PrimaryButton(title: "Retry") {
                                gameViewModel.retryAfterNoObjects()
                            }
                        case .fatal:
                            Text("We're having trouble")
                                .font(Typography.title.font.weight(.semibold))
                                .foregroundStyle(ColorPalette.primary.swiftUIColor)

                            Text("Something went wrong. Please restart Langscape.")
                                .font(Typography.body.font)
                                .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.8))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, Spacing.large.cgFloat)
                    .padding(.vertical, Spacing.large.cgFloat)
                }
                .padding(.horizontal, Spacing.large.cgFloat)

                Spacer()
            }
        }
        .allowsHitTesting(true)
    }

    private var scanningIndicator: some View {
        VStack {
            Spacer()

            TranslucentPanel(cornerRadius: 20) {
                HStack(spacing: Spacing.small.cgFloat) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Scanning the room…")
                        .font(Typography.body.font)
                        .foregroundStyle(ColorPalette.primary.swiftUIColor)
                }
                .padding(.vertical, Spacing.small.cgFloat)
            }
            .padding(.bottom, Spacing.xLarge.cgFloat * 1.2)
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onAppear { startPulseAnimation() }
        .onDisappear { startPulse = false }
    }

    @ViewBuilder
    private func roundOverlay(in size: CGSize, interactive: Bool, showTargets: Bool) -> some View {
        if let round = gameViewModel.round {
            RoundPlayLayer(
                round: round,
                placedLabels: gameViewModel.placedLabels,
                lastIncorrectLabelID: gameViewModel.lastIncorrectLabelID,
                interactive: interactive,
                showTargets: showTargets,
                frameProvider: { boundingRect(for: $0, in: size) },
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
        contextManager.reset()
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
            print("CameraPreviewView: State .ready")
        case .scanning:
            print("CameraPreviewView: State .scanning")
        case .playing, .paused:
            print("CameraPreviewView: State .playing/.paused - showing targets")
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
        contextManager.enableClassification()
        gameViewModel.beginScanning()
    }

    private func boundingRect(for detection: Detection, in viewSize: CGSize) -> CGRect {
        boundingRect(forNormalizedRect: detection.boundingBox, in: viewSize)
    }

    private func boundingRect(for object: DetectedObject, in viewSize: CGSize) -> CGRect {
        boundingRect(forNormalizedRect: object.boundingBox, in: viewSize)
    }

    private func boundingRect(forNormalizedRect normalizedRect: DetectionRect, in viewSize: CGSize) -> CGRect {
        if let mapped = projectedRect(for: normalizedRect, inputImageSize: viewModel.inputImageSize, viewSize: viewSize) {
            return mapped
        }
        return normalizedRect.rect(in: viewSize)
    }

    private var shouldShowContextBadge: Bool {
        gameViewModel.phase != .home
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
        Dictionary(
            round.objects.map { ($0.id, frameProvider($0)) },
            uniquingKeysWith: { _, new in new }
        )
    }

    private var placedLabelOverlays: [(label: GameKitLS.Label, frame: CGRect)] {
        round.labels.compactMap { label in
            guard placedLabels.contains(label.id), let frame = frames[label.objectID] else { return nil }
            return (label, frame)
        }
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

            ForEach(placedLabelOverlays, id: \.label.id) { entry in
                StickyLabelOverlay(text: entry.label.text, frame: entry.frame)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: placedLabels)

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
                                },
                                destinationAt: { point in destination(for: point) }
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
            let radius = max(64, min(best.frame.width, best.frame.height) * 0.8)
            return best.distance <= radius ? best.id : nil
        }
        return nil
    }

    private func expand(frame: CGRect) -> CGRect {
        let inset = max(28, min(frame.width, frame.height) * 0.3)
        return frame.insetBy(dx: -inset, dy: -inset)
    }
}

private struct StickyLabelOverlay: View {
    let text: String
    let frame: CGRect

    var body: some View {
        Text(text)
            .font(Typography.caption.font.weight(.semibold))
            .foregroundStyle(ColorPalette.primary.swiftUIColor)
            .padding(.horizontal, Spacing.medium.cgFloat)
            .padding(.vertical, Spacing.xSmall.cgFloat)
            .background(ColorPalette.surface.swiftUIColor.opacity(0.9), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 6)
            .position(x: frame.midX, y: frame.midY)
    }
}

private struct DraggableToken: View {
    let label: GameKitLS.Label
    let state: LabelToken.VisualState
    let interactive: Bool
    let dropHandler: (CGPoint) -> LabelScrambleVM.MatchResult
    var destinationAt: ((CGPoint) -> DetectedObject.ID?)? = nil

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var isNearTarget = false

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("experience"))
            LabelToken(text: label.text, state: state)
                .opacity(state == .placed ? 0 : 1)
                .scaleEffect(isDragging ? (isNearTarget ? 1.08 : 1.05) : 1)
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
                            if let dest = destinationAt {
                                let dropPoint = CGPoint(x: frame.midX + value.translation.width,
                                                        y: frame.midY + value.translation.height)
                                isNearTarget = dest(dropPoint) != nil
                            }
                        }
                        .onEnded { value in
                            guard interactive, state != .placed else { return }
                            let dropPoint = CGPoint(
                                x: frame.midX + value.translation.width,
                                y: frame.midY + value.translation.height
                            )
                            let result = dropHandler(dropPoint)
                            #if canImport(UIKit)
                            let generator = UINotificationFeedbackGenerator()
                            generator.prepare()
                            switch result {
                            case .matched:
                                generator.notificationOccurred(.success)
                            case .mismatched:
                                generator.notificationOccurred(.error)
                            case .ignored:
                                generator.notificationOccurred(.warning)
                            default:
                                break
                            }
                            #endif
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                dragOffset = .zero
                                isDragging = false
                                isNearTarget = false
                            }
                        }
                )
                .onChange(of: state) { _, newState in
                    if newState == .placed {
                        dragOffset = .zero
                        isDragging = false
                        isNearTarget = false
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

private extension DetectionRect {
    func rect(in size: CGSize) -> CGRect {
        let width = CGFloat(self.size.width) * size.width
        let height = CGFloat(self.size.height) * size.height
        let x = CGFloat(origin.x) * size.width
        let y = CGFloat(origin.y) * size.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct ARCameraView: UIViewRepresentable {
    let viewModel: DetectionVM
    let gameViewModel: LabelScrambleVM
    let contextManager: ContextManager

    func makeCoordinator() -> ARSessionCoordinator {
        ARSessionCoordinator(viewModel: viewModel, gameViewModel: gameViewModel, contextManager: contextManager)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.updateStickyLabels(
            arView: uiView,
            phase: gameViewModel.phase,
            round: gameViewModel.round,
            placedLabels: gameViewModel.placedLabels,
            inputImageSize: viewModel.inputImageSize
        )
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: ARSessionCoordinator) {
        coordinator.detach(from: uiView)
        uiView.session.pause()
    }
}

private final class ARSessionCoordinator: NSObject, ARSessionDelegate {
    private let viewModel: DetectionVM
    private let gameViewModel: LabelScrambleVM
    private let contextManager: ContextManager
    private weak var arView: ARView?
    private var lastFrameTime: TimeInterval = 0
    private let captureInterval: TimeInterval = 0.08
    private let logger = Logger.shared
    private var labelAnchors: [UUID: LabelAnchor] = [:]

    #if canImport(Vision) && canImport(ImageIO)
    private let trackingQueue = DispatchQueue(label: "LangscapeApp.TargetTracking", qos: .userInitiated)
    private let trackingHandler = VNSequenceRequestHandler()
    private let trackingSemaphore = DispatchSemaphore(value: 1)
    private var trackedTargets: [UUID: TrackedTarget] = [:]
    private var trackingExifOrientation: CGImagePropertyOrientation = .right
    private var lastTrackingTimestamp: TimeInterval = 0
    private let trackingInterval: TimeInterval = 1.0 / 30.0
    #endif

    init(viewModel: DetectionVM, gameViewModel: LabelScrambleVM, contextManager: ContextManager) {
        self.viewModel = viewModel
        self.gameViewModel = gameViewModel
        self.contextManager = contextManager
    }

    @MainActor
    func attach(to arView: ARView) {
        self.arView = arView
        arView.session.delegate = self
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        Task { await logger.log("AR session configured", level: .info, category: "LangscapeApp.Camera") }
    }

    @MainActor
    func detach(from arView: ARView) {
        clearAnchors(from: arView)
        arView.session.delegate = nil
        self.arView = nil
    }

    @MainActor
    func clearAnchors(from arView: ARView) {
        for anchor in labelAnchors.values {
            anchor.anchor.removeFromParent()
        }
        labelAnchors.removeAll()
    }

    @MainActor
    func updateStickyLabels(
        arView: ARView,
        phase: LabelScrambleVM.Phase,
        round: Round?,
        placedLabels: Set<GameKitLS.Label.ID>,
        inputImageSize: CGSize?
    ) {
        updateTrackingTargets(phase: phase, round: round)
        guard shouldRenderLabels(for: phase), let round else {
            clearAnchors(from: arView)
            return
        }
        guard let inputImageSize, let frame = arView.session.currentFrame else {
            clearAnchors(from: arView)
            return
        }

        let placedObjects: [(id: UUID, label: String, box: DetectionRect)] = placedLabels.compactMap { labelID in
            guard let objectID = round.target(for: labelID),
                  let label = round.label(with: labelID)?.text ?? round.labels.first(where: { $0.objectID == objectID })?.text,
                  let object = round.object(with: objectID) else { return nil }
            return (objectID, label, object.boundingBox)
        }

        guard !placedObjects.isEmpty else {
            clearAnchors(from: arView)
            return
        }

        var activeAnchors: Set<UUID> = []
        for entry in placedObjects {
            guard let viewRect = projectedRect(for: entry.box, inputImageSize: inputImageSize, viewSize: arView.bounds.size),
                  viewRect.width > 2, viewRect.height > 2,
                  let raycastResult = raycast(at: CGPoint(x: viewRect.midX, y: viewRect.midY), in: arView),
                  isRaycastValid(raycastResult, camera: frame.camera) else { continue }

            let depth = distanceFromCamera(to: raycastResult.worldTransform.translation, camera: frame.camera)
            let planeSize = planeSizeInMeters(for: entry.box, depth: depth, inputImageSize: inputImageSize, camera: frame.camera) ?? SIMD2<Float>(0.22, 0.12)

            placeLabel(
                id: entry.id,
                text: entry.label,
                size: planeSize,
                raycastResult: raycastResult,
                camera: frame.camera,
                arView: arView
            )
            activeAnchors.insert(entry.id)
        }

        pruneInactiveAnchors(keeping: activeAnchors)
    }

    private func shouldRenderLabels(for phase: LabelScrambleVM.Phase) -> Bool {
        switch phase {
        case .playing, .paused:
            return true
        default:
            return false
        }
    }

    @MainActor
    private func updateTrackingTargets(phase: LabelScrambleVM.Phase, round: Round?) {
        #if canImport(Vision) && canImport(ImageIO)
        let shouldTrack: Bool
        switch phase {
        case .ready, .playing, .paused:
            shouldTrack = true
        default:
            shouldTrack = false
        }

        let targets = shouldTrack ? (round?.objects ?? []) : []
        #if canImport(UIKit)
        let interfaceOrientation = arView?.window?.windowScene?.interfaceOrientation ?? .portrait
        let exifOrientation = exifOrientationForBackCamera(interfaceOrientation)
        #else
        let exifOrientation: CGImagePropertyOrientation = .right
        #endif

        trackingQueue.async { [weak self] in
            guard let self else { return }
            self.trackingExifOrientation = exifOrientation

            guard shouldTrack else {
                self.trackedTargets.removeAll()
                return
            }

            let ids = Set(targets.map(\.id))
            if ids == Set(self.trackedTargets.keys) {
                return
            }

            var next: [UUID: TrackedTarget] = [:]
            next.reserveCapacity(targets.count)
            for object in targets {
                let observation = VNDetectedObjectObservation(boundingBox: toVisionBoundingBox(object.boundingBox))
                let request = VNTrackObjectRequest(detectedObjectObservation: observation)
                request.trackingLevel = .fast
                next[object.id] = TrackedTarget(label: object.sourceLabel, confidence: object.confidence, request: request)
            }
            self.trackedTargets = next
        }
        #endif
    }

    private func trackTargetsIfNeeded(_ frame: ARFrame) {
        #if canImport(Vision) && canImport(ImageIO)
        let now = frame.timestamp
        guard now - lastTrackingTimestamp >= trackingInterval else { return }
        lastTrackingTimestamp = now

        let semaphore = trackingSemaphore
        guard semaphore.wait(timeout: .now()) == .success else { return }

        let pixelBuffer = frame.capturedImage
        let gameViewModel = gameViewModel
        trackingQueue.async { [weak self] in
            defer { semaphore.signal() }
            guard let self else { return }
            guard !self.trackedTargets.isEmpty else { return }

            let snapshot = self.trackedTargets
            var ids: [UUID] = []
            var requests: [VNTrackObjectRequest] = []
            ids.reserveCapacity(snapshot.count)
            requests.reserveCapacity(snapshot.count)

            for (id, target) in snapshot {
                ids.append(id)
                requests.append(target.request)
            }

            do {
                try self.trackingHandler.perform(requests, on: pixelBuffer, orientation: self.trackingExifOrientation)
            } catch {
                return
            }

            var updates: [Detection] = []
            updates.reserveCapacity(requests.count)
            for (index, id) in ids.enumerated() {
                let request = requests[index]
                guard let obs = request.results?.first as? VNDetectedObjectObservation else { continue }
                request.inputObservation = obs
                guard let target = self.trackedTargets[id] else { continue }
                updates.append(
                    Detection(
                        id: id,
                        label: target.label,
                        confidence: target.confidence,
                        boundingBox: fromVisionBoundingBox(obs.boundingBox)
                    )
                )
            }

            guard !updates.isEmpty else { return }
            Task { @MainActor in
                gameViewModel.ingestDetections(updates)
            }
        }
        #endif
    }

    private func raycast(at point: CGPoint, in arView: ARView) -> ARRaycastResult? {
        if let query = arView.makeRaycastQuery(from: point, allowing: .existingPlaneGeometry, alignment: .any),
           let result = arView.session.raycast(query).first {
            return result
        }
        if let estimatedQuery = arView.makeRaycastQuery(from: point, allowing: .estimatedPlane, alignment: .any),
           let fallback = arView.session.raycast(estimatedQuery).first {
            return fallback
        }
        return nil
    }

    private func isRaycastValid(_ result: ARRaycastResult, camera: ARCamera) -> Bool {
        let position = result.worldTransform.translation
        let components = [position.x, position.y, position.z]
        guard components.allSatisfy({ $0.isFinite }) else { return false }
        return distanceFromCamera(to: position, camera: camera) > 0.05
    }

    private func distanceFromCamera(to position: SIMD3<Float>, camera: ARCamera) -> Float {
        let cameraPosition = camera.transform.translation
        return simd_length(position - cameraPosition)
    }

    private func planeSizeInMeters(
        for boundingBox: DetectionRect,
        depth: Float,
        inputImageSize: CGSize,
        camera: ARCamera
    ) -> SIMD2<Float>? {
        guard depth > 0 else { return nil }
        let fx = Float(camera.intrinsics.columns.0.x)
        let fy = Float(camera.intrinsics.columns.1.y)
        guard fx > 0, fy > 0 else { return nil }
        let pixelWidth = Float(boundingBox.size.width) * Float(inputImageSize.width)
        let pixelHeight = Float(boundingBox.size.height) * Float(inputImageSize.height)
        let widthMeters = max(0.01, (pixelWidth / fx) * depth)
        let heightMeters = max(0.01, (pixelHeight / fy) * depth)
        return SIMD2<Float>(widthMeters, heightMeters)
    }

    @MainActor
    private func placeLabel(
        id: UUID,
        text: String,
        size: SIMD2<Float>,
        raycastResult: ARRaycastResult,
        camera: ARCamera,
        arView: ARView
    ) {
        let width = max(size.x * 0.6, 0.14)
        let height = max(size.y * 0.35, 0.10)
        let transform = Transform(matrix: raycastResult.worldTransform)
        let cameraPosition = camera.transform.translation

        if let anchor = labelAnchors[id] {
            anchor.anchor.transform = transform
            anchor.card.look(at: cameraPosition, from: transform.translation, relativeTo: nil)
        } else {
            let anchor = AnchorEntity(world: raycastResult.worldTransform)
            let card = makeLabelCard(text: text, size: CGSize(width: CGFloat(width), height: CGFloat(height)))
            card.look(at: cameraPosition, from: transform.translation, relativeTo: nil)
            anchor.addChild(card)
            arView.scene.addAnchor(anchor)
            labelAnchors[id] = LabelAnchor(anchor: anchor, card: card)
        }
    }

    private func pruneInactiveAnchors(keeping activeIDs: Set<UUID>) {
        guard !activeIDs.isEmpty else {
            for anchor in labelAnchors.values {
                anchor.anchor.removeFromParent()
            }
            labelAnchors.removeAll()
            return
        }

        let stale = labelAnchors.keys.filter { !activeIDs.contains($0) }
        for id in stale {
            if let anchor = labelAnchors[id] {
                anchor.anchor.removeFromParent()
            }
            labelAnchors.removeValue(forKey: id)
        }
    }

    private func makeLabelCard(text: String, size: CGSize) -> ModelEntity {
        let plane = MeshResource.generatePlane(width: Float(size.width), height: Float(size.height))
        var background = UnlitMaterial()
        let accent = UIColor(ColorPalette.accent.swiftUIColor)
        background.color = .init(tint: accent.withAlphaComponent(0.82))
        let card = ModelEntity(mesh: plane, materials: [background])

        if let textMesh = try? MeshResource.generateText(
            text,
            extrusionDepth: 0.002,
            font: .systemFont(ofSize: 0.16),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        ) {
            var textMaterial = UnlitMaterial()
            textMaterial.color = .init(tint: UIColor.white)
            let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
            textEntity.scale = SIMD3<Float>(repeating: 0.01)
            textEntity.position = SIMD3<Float>(0, 0, 0.01)
            textEntity.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            card.addChild(textEntity)
        }

        card.generateCollisionShapes(recursive: true)
        return card
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        trackTargetsIfNeeded(frame)

        let now = frame.timestamp
        guard now - lastFrameTime >= captureInterval else { return }
        lastFrameTime = now

        let capturedImage = frame.capturedImage
        let logger = logger
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let state = await MainActor.run { () -> (shouldClassify: Bool, isLocked: Bool, shouldDetect: Bool, shouldMaintainTargets: Bool, interfaceOrientationRawValue: Int) in
                #if canImport(UIKit)
                let orientationRawValue = self.arView?.window?.windowScene?.interfaceOrientation.rawValue ?? UIInterfaceOrientation.portrait.rawValue
                #else
                let orientationRawValue = 0
                #endif
                let shouldDetect = self.gameViewModel.phase == .scanning
                let shouldMaintainTargets: Bool
                switch self.gameViewModel.phase {
                case .ready, .playing, .paused:
                    shouldMaintainTargets = true
                default:
                    shouldMaintainTargets = false
                }
                self.updateTrackingTargets(phase: self.gameViewModel.phase, round: self.gameViewModel.round)
                return (self.contextManager.shouldClassifyScene, self.contextManager.isLocked, shouldDetect, shouldMaintainTargets, orientationRawValue)
            }
            guard state.shouldClassify || (state.isLocked && (state.shouldDetect || state.shouldMaintainTargets)) else { return }

            let width = CGFloat(CVPixelBufferGetWidth(capturedImage))
            let height = CGFloat(CVPixelBufferGetHeight(capturedImage))
            let inputSize = CGSize(width: width, height: height)
            #if canImport(UIKit) && canImport(ImageIO)
            let interfaceOrientation = UIInterfaceOrientation(rawValue: state.interfaceOrientationRawValue) ?? .portrait
            let exifOrientation = exifOrientationForBackCamera(interfaceOrientation)
            let orientationRaw = exifOrientation.rawValue
            let orientedInputSize = orientedSize(inputSize, for: exifOrientation)
            #else
            let orientationRaw: UInt32? = nil
            let orientedInputSize = inputSize
            #endif

            await MainActor.run {
                if viewModel.inputImageSize != orientedInputSize {
                    viewModel.setInputSize(orientedInputSize)
                }
            }

            if state.shouldClassify {
                guard let pixelBuffer = clonePixelBuffer(capturedImage) else {
                    await logger.log("Camera pipeline dropped a frame because the pixel buffer could not be cloned.", level: .warning, category: "LangscapeApp.Camera")
                    return
                }
                await contextManager.classify(pixelBuffer)
                return
            }

            guard state.isLocked, state.shouldDetect else { return }

            guard let pixelBuffer = clonePixelBuffer(capturedImage) else {
                await logger.log("Camera pipeline dropped a frame because the pixel buffer could not be cloned.", level: .warning, category: "LangscapeApp.Camera")
                return
            }

            let request = DetectionRequest(pixelBuffer: pixelBuffer, imageOrientationRaw: orientationRaw)

            await MainActor.run {
                viewModel.enqueue(request)
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        Task { await logger.log("AR session failed: \(error.localizedDescription)", level: .error, category: "LangscapeApp.Camera") }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        Task { await logger.log("AR session interrupted", level: .warning, category: "LangscapeApp.Camera") }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        Task { await logger.log("AR session interruption ended", level: .info, category: "LangscapeApp.Camera") }
    }
}

private struct LabelAnchor {
    let anchor: AnchorEntity
    let card: ModelEntity
}

#if canImport(Vision) && canImport(ImageIO)
private struct TrackedTarget {
    var label: String
    var confidence: Double
    var request: VNTrackObjectRequest
}

private func clamp01(_ value: Double) -> Double {
    max(0.0, min(1.0, value))
}

private func toVisionBoundingBox(_ rect: DetectionRect) -> CGRect {
    let x = clamp01(rect.origin.x)
    let yTop = clamp01(rect.origin.y)
    let w = max(0.0, min(1.0 - x, rect.size.width))
    let h = max(0.0, min(1.0 - yTop, rect.size.height))
    let yBottom = 1.0 - yTop - h
    let clampedYBottom = clamp01(yBottom)
    let clampedH = max(0.0, min(1.0 - clampedYBottom, h))
    return CGRect(x: x, y: clampedYBottom, width: w, height: clampedH)
}

private func fromVisionBoundingBox(_ rect: CGRect) -> DetectionRect {
    let x = clamp01(Double(rect.origin.x))
    let yBottom = clamp01(Double(rect.origin.y))
    let w = max(0.0, min(1.0 - x, Double(rect.size.width)))
    let h = max(0.0, min(1.0 - yBottom, Double(rect.size.height)))
    let yTop = 1.0 - yBottom - h
    return DetectionRect(
        origin: .init(x: x, y: clamp01(yTop)),
        size: .init(width: w, height: h)
    )
}
#endif

private func projectedRect(
    for normalizedRect: DetectionRect,
    inputImageSize: CGSize?,
    viewSize: CGSize
) -> CGRect? {
    guard let cameraRect = projectedCameraFrameRect(inputImageSize: inputImageSize, viewSize: viewSize) else {
        return nil
    }
    let dw = cameraRect.width
    let dh = cameraRect.height
    let x = cameraRect.origin.x + CGFloat(normalizedRect.origin.x) * dw
    let y = cameraRect.origin.y + CGFloat(normalizedRect.origin.y) * dh
    let w = CGFloat(normalizedRect.size.width) * dw
    let h = CGFloat(normalizedRect.size.height) * dh
    return CGRect(x: x, y: y, width: w, height: h)
}

private func projectedCameraFrameRect(inputImageSize: CGSize?, viewSize: CGSize) -> CGRect? {
    guard let imgSize = inputImageSize, imgSize.width > 0, imgSize.height > 0 else {
        return nil
    }
    let sw = viewSize.width
    let sh = viewSize.height
    let iw = CGFloat(imgSize.width)
    let ih = CGFloat(imgSize.height)
    let scale = max(sw / iw, sh / ih)
    let dw = iw * scale
    let dh = ih * scale
    let offsetX = (sw - dw) / 2
    let offsetY = (sh - dh) / 2
    return CGRect(x: offsetX, y: offsetY, width: dw, height: dh)
}

#if canImport(CoreVideo)
private func clonePixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let format = CVPixelBufferGetPixelFormatType(source)
    var output: CVPixelBuffer?
    let options: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    guard CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        format,
        options as CFDictionary,
        &output
    ) == kCVReturnSuccess, let copy = output else {
        return nil
    }
    CVBufferPropagateAttachments(source, copy)
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(copy, [])
    defer {
        CVPixelBufferUnlockBaseAddress(copy, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    guard let srcBase = CVPixelBufferGetBaseAddress(source),
          let dstBase = CVPixelBufferGetBaseAddress(copy) else {
        return nil
    }
    let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
    let dstBytesPerRow = CVPixelBufferGetBytesPerRow(copy)
    let rows = CVPixelBufferGetHeight(source)
    for row in 0..<rows {
        let src = srcBase.advanced(by: row * srcBytesPerRow)
        let dst = dstBase.advanced(by: row * dstBytesPerRow)
        memcpy(dst, src, min(srcBytesPerRow, dstBytesPerRow))
    }
    return copy
}
#endif

fileprivate extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

#if canImport(UIKit) && canImport(ImageIO)
private func exifOrientationForBackCamera(_ interfaceOrientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
    switch interfaceOrientation {
    case .portrait:
        return .right
    case .portraitUpsideDown:
        return .left
    case .landscapeLeft:
        return .up
    case .landscapeRight:
        return .down
    default:
        return .right
    }
}

private func orientedSize(_ size: CGSize, for orientation: CGImagePropertyOrientation) -> CGSize {
    switch orientation {
    case .left, .leftMirrored, .right, .rightMirrored:
        return CGSize(width: size.height, height: size.width)
    default:
        return size
    }
}
#endif

@MainActor
final class ContextManager: ObservableObject {
    enum State: Equatable {
        case unknown
        case detecting
        case locked(String)
    }

    @Published private(set) var state: State = .unknown
    private var classificationEnabled = false

    private let sceneClassifier: VLMDetector
    private var classifierPrepared = false
    private let detector: CombinedDetector
    private let logger: Logger

    init(detector: CombinedDetector, logger: Logger = .shared) {
        self.sceneClassifier = VLMDetector(logger: logger)
        self.detector = detector
        self.logger = logger
    }

    var shouldClassifyScene: Bool {
        if !classificationEnabled { return false }
        if case .unknown = state { return true }
        return false
    }

    var contextDisplayName: String {
        switch state {
        case .unknown:
            return "Identifying context…"
        case .detecting:
            return "Identifying context…"
        case .locked(let value):
            return "Context: \(value.capitalized)"
        }
    }

    var isDetecting: Bool {
        if case .detecting = state { return true }
        return false
    }

    var isLocked: Bool {
        if case .locked = state { return true }
        return false
    }

    var canManuallyChange: Bool {
        if case .locked = state { return true }
        return false
    }

    func reset() {
        state = .unknown
        classificationEnabled = false
    }

    func enableClassification() {
        classificationEnabled = true
    }

#if canImport(CoreVideo)
    func classify(_ pixelBuffer: CVPixelBuffer) async {
        guard case .unknown = state else { return }
        state = .detecting
        do {
            if !classifierPrepared {
                try await sceneClassifier.prepare()
                classifierPrepared = true
            }
            let sensed = await sceneClassifier.classifyScene(pixelBuffer: pixelBuffer)
            let normalized = sensed.isEmpty ? "General" : sensed
            if normalized.caseInsensitiveCompare("general") == .orderedSame {
                state = .unknown
                await logger.log("Context classification inconclusive", level: .debug, category: "LangscapeApp.Context")
                return
            }
            let loaded = await detector.loadContext(normalized)
            if loaded {
                state = .locked(normalized)
                await logger.log("Context locked: \(normalized)", level: .info, category: "LangscapeApp.Context")
            } else {
                state = .unknown
            }
        } catch {
            state = .unknown
            await logger.log("Context classification failed: \(error.localizedDescription)", level: .error, category: "LangscapeApp.Context")
        }
    }
#endif
}
#endif
