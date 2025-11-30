#if canImport(SwiftUI) && canImport(ARKit)
import SwiftUI
import ARKit
import RealityKit
import DetectionKit
import GameKitLS
import UIComponents
import DesignSystem
import Utilities
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
private typealias DetectionRect = DetectionKit.NormalizedRect

struct CameraPreviewView: View {
    @ObservedObject var viewModel: DetectionVM
    @ObservedObject var gameViewModel: LabelScrambleVM
    @ObservedObject var contextManager: ContextManager

    @State private var showCompletionFlash = false
    @State private var homeCardPressed = false
    @State private var startPulse = false
#if canImport(CoreImage)
    private static let maskCache = DetectionOverlayMaskCache()
#endif

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
            .onChange(of: gameViewModel.round) { _, _ in
                requestSegmentationForCurrentRound()
            }
        }
        .overlay(alignment: .topLeading) {
            contextBadge
                .padding(.top, 24)
                .padding(.leading, 24)
        }
        .onAppear {
            viewModel.setAutomaticSegmentationEnabled(false)
        }
        .onDisappear {
            viewModel.setAutomaticSegmentationEnabled(true)
        }
    }

    @ViewBuilder
    private func overlays(in size: CGSize) -> some View {
        ZStack {
            switch gameViewModel.phase {
            case .home:
                homeOverlay
            case .scanning:
                maskOverlay(in: size)
                scanningIndicator
            case .ready:
                maskOverlay(in: size)
                startButton
            case .playing:
                maskOverlay(in: size)
                roundOverlay(in: size, interactive: true)
            case .paused:
                maskOverlay(in: size)
                roundOverlay(in: size, interactive: false)
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
                LangscapeLogo(style: .full, glyphSize: 56, brand: .context)
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
                showTargets: false,
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
            print("CameraPreviewView: State .ready - prepping segmentation")
            requestSegmentationForCurrentRound()
        case .scanning:
            print("CameraPreviewView: State .scanning - prepping segmentation")
        case .playing, .paused:
            print("CameraPreviewView: State .playing/.paused - hiding 2D overlays")
            requestSegmentationForCurrentRound()
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

    private func maskOverlay(in size: CGSize) -> AnyView {
#if canImport(CoreImage)
        guard shouldShowMaskOverlay(for: gameViewModel.phase),
              let round = gameViewModel.round,
              let cameraFrame = cameraFrameRect(in: size) else {
            return AnyView(
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            )
        }
        let pendingObjects = pendingRoundObjects(round: round, placedLabels: gameViewModel.placedLabels)
        guard !pendingObjects.isEmpty else {
            return AnyView(Color.clear.frame(width: size.width, height: size.height).allowsHitTesting(false))
        }

        let pendingIDs = Set(pendingObjects.map(\.id))
        let maskIDs = Set(viewModel.segmentationMasks.keys.filter { pendingIDs.contains($0) })
        Self.maskCache.prune(keeping: maskIDs)

        let masks: [SegmentationMaskDrawable] = pendingObjects.compactMap { object in
            guard let mask = viewModel.segmentationMasks[object.id],
                  let cgImage = Self.maskCache.image(for: object.id, mask: mask) else { return nil }
            return SegmentationMaskDrawable(id: object.id, cgImage: cgImage)
        }
        guard !masks.isEmpty else {
            return AnyView(Color.clear.frame(width: size.width, height: size.height).allowsHitTesting(false))
        }

        return AnyView(
            SegmentationOverlayLayer(
                masks: masks,
                cameraFrame: cameraFrame,
                viewSize: size
            )
        )
#else
        return AnyView(
            Color.clear
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
        )
#endif
    }

    private func shouldShowMaskOverlay(for phase: LabelScrambleVM.Phase) -> Bool {
        switch phase {
        case .ready, .playing, .paused:
            return true
        default:
            return false
        }
    }

    private func pendingRoundObjects(round: Round, placedLabels: Set<GameKitLS.Label.ID>) -> [DetectedObject] {
        let satisfiedIDs = Set(placedLabels.compactMap { round.target(for: $0) })
        return round.objects.filter { !satisfiedIDs.contains($0.id) }
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

    private func cameraFrameRect(in viewSize: CGSize) -> CGRect? {
        projectedCameraFrameRect(inputImageSize: viewModel.inputImageSize, viewSize: viewSize)
    }

    private func requestSegmentationForCurrentRound() {
        guard let round = gameViewModel.round else { return }
        let pendingObjects = pendingRoundObjects(round: round, placedLabels: gameViewModel.placedLabels)
        guard !pendingObjects.isEmpty else { return }

        let availableIDs = Set(viewModel.trackSnapshots.map(\.id))
        for object in pendingObjects where availableIDs.contains(object.id) {
            viewModel.requestSegmentation(for: object.id)
        }
    }
}

#if canImport(CoreImage)
private struct SegmentationMaskDrawable: Identifiable {
    let id: UUID
    let cgImage: CGImage
}

private struct SegmentationOverlayLayer: View {
    let masks: [SegmentationMaskDrawable]
    let cameraFrame: CGRect
    let viewSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(masks) { mask in
                glowingMask(for: mask)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .allowsHitTesting(false)
    }

    /// Creates a tinted, feathered mask so that we highlight only the segmented pixels instead of blasting solid white blobs.
    private func glowingMask(for mask: SegmentationMaskDrawable) -> some View {
        let baseMask = maskImage(for: mask)
        let glowGradient = LinearGradient(
            colors: [
                Color.white.opacity(0.95),
                ColorPalette.accent.swiftUIColor.opacity(0.9)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return glowGradient
            .blendMode(.screen)
            .mask(baseMask)
            .overlay(
                Color.white
                    .opacity(0.55)
                    .blur(radius: 14)
                    .mask(baseMask)
                    .blendMode(.screen)
            )
    }

    private func maskImage(for mask: SegmentationMaskDrawable) -> some View {
        Image(decorative: mask.cgImage, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fill)
            .frame(width: cameraFrame.width, height: cameraFrame.height)
            .position(x: cameraFrame.midX, y: cameraFrame.midY)
    }
}

private final class DetectionOverlayMaskCache {
    private let context = CIContext()
    private var cache: [UUID: CGImage] = [:]

    func image(for id: UUID, mask: CIImage) -> CGImage? {
        if let cached = cache[id] {
            return cached
        }
        guard let cgImage = context.createCGImage(mask, from: mask.extent) else { return nil }
        cache[id] = cgImage
        return cgImage
    }

    func prune(keeping ids: Set<UUID>) {
        guard !ids.isEmpty else {
            cache.removeAll()
            return
        }
        cache = cache.filter { ids.contains($0.key) }
    }
}
#endif

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
        ARSessionCoordinator(viewModel: viewModel, contextManager: contextManager)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
#if canImport(CoreImage)
        context.coordinator.updateWorldGlows(
            arView: uiView,
            phase: gameViewModel.phase,
            round: gameViewModel.round,
            placedLabels: gameViewModel.placedLabels,
            trackSnapshots: viewModel.trackSnapshots,
            segmentationMasks: viewModel.segmentationMasks,
            inputImageSize: viewModel.inputImageSize
        )
#else
        context.coordinator.clearAnchors(from: uiView)
#endif
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: ARSessionCoordinator) {
        coordinator.detach(from: uiView)
        uiView.session.pause()
    }
}

private final class ARSessionCoordinator: NSObject, ARSessionDelegate {
    private let viewModel: DetectionVM
    private let contextManager: ContextManager
    private weak var arView: ARView?
    private var lastFrameTime: TimeInterval = 0
    private let logger = Logger.shared
#if canImport(CoreImage)
    private var glowOverlays: [UUID: GlowOverlay] = [:]
    private let textureCache = MaskTextureCache()
#endif

    init(viewModel: DetectionVM, contextManager: ContextManager) {
        self.viewModel = viewModel
        self.contextManager = contextManager
    }

    func attach(to arView: ARView) {
        self.arView = arView
        arView.session.delegate = self
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        Task { await logger.log("AR session configured", level: .info, category: "LangscapeApp.Camera") }
    }

    func detach(from arView: ARView) {
#if canImport(CoreImage)
        clearAnchors(from: arView)
#endif
        arView.session.delegate = nil
        self.arView = nil
    }

    func clearAnchors(from arView: ARView) {
#if canImport(CoreImage)
        for overlay in glowOverlays.values {
            overlay.anchor.removeFromParent()
        }
        glowOverlays.removeAll()
        textureCache.removeAll()
#endif
    }

#if canImport(CoreImage)
    @MainActor
    func updateWorldGlows(
        arView: ARView,
        phase: LabelScrambleVM.Phase,
        round: Round?,
        placedLabels: Set<GameKitLS.Label.ID>,
        trackSnapshots: [DetectionTrackSnapshot],
        segmentationMasks: [UUID: CIImage],
        inputImageSize: CGSize?
    ) {
        guard shouldRenderGlows(for: phase), let round else {
            clearAnchors(from: arView)
            return
        }
        guard let inputImageSize, let frame = arView.session.currentFrame else {
            clearAnchors(from: arView)
            return
        }

        let pendingIDs = pendingObjectIDs(in: round, placedLabels: placedLabels)
        guard !pendingIDs.isEmpty else {
            clearAnchors(from: arView)
            return
        }

        let snapshotLookup = Dictionary(uniqueKeysWithValues: trackSnapshots.map { ($0.id, $0) })
        let activeOverlayIDs: Set<UUID> = Set(segmentationMasks.keys.filter { pendingIDs.contains($0) })

        if !segmentationMasks.isEmpty {
            for (maskID, mask) in segmentationMasks {
                guard pendingIDs.contains(maskID),
                      let snapshot = snapshotLookup[maskID],
                      let viewRect = projectedRect(for: snapshot.boundingBox, inputImageSize: inputImageSize, viewSize: arView.bounds.size),
                      viewRect.width > 2, viewRect.height > 2,
                      let raycastResult = raycast(at: CGPoint(x: viewRect.midX, y: viewRect.midY), in: arView),
                      isRaycastValid(raycastResult, camera: frame.camera) else { continue }

                let depth = distanceFromCamera(to: raycastResult.worldTransform.translation, camera: frame.camera)
                guard let planeSize = planeSizeInMeters(for: snapshot.boundingBox, depth: depth, inputImageSize: inputImageSize, camera: frame.camera) else { continue }

                guard let texture = textureCache.texture(for: maskID, mask: mask) else {
                    print("⚠️ Segmentation mask texture missing for \(maskID). Skipping anchor to avoid full-screen overlay.")
                    continue
                }
                placeOverlay(
                    id: maskID,
                    texture: texture,
                    size: planeSize,
                    raycastResult: raycastResult,
                    camera: frame.camera,
                    arView: arView
                )
            }
        }

        pruneInactiveOverlays(keeping: activeOverlayIDs)
        textureCache.prune(keeping: activeOverlayIDs)
    }

    private func shouldRenderGlows(for phase: LabelScrambleVM.Phase) -> Bool {
        switch phase {
        case .ready, .playing, .paused:
            return true
        default:
            return false
        }
    }

    private func pendingObjectIDs(in round: Round, placedLabels: Set<GameKitLS.Label.ID>) -> Set<DetectedObject.ID> {
        if placedLabels.isEmpty {
            return Set(round.objects.map(\.id))
        }
        let satisfied = Set(placedLabels.compactMap { round.target(for: $0) })
        return Set(round.objects.compactMap { satisfied.contains($0.id) ? nil : $0.id })
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
    private func placeOverlay(
        id: UUID,
        texture: TextureResource,
        size: SIMD2<Float>,
        raycastResult: ARRaycastResult,
        camera: ARCamera,
        arView: ARView
    ) {
        let width = max(size.x, 0.3)
        let height = max(size.y, 0.3)
        let mesh = MeshResource.generatePlane(width: width, height: height)

        var material = UnlitMaterial()
        let baseTint = UIColor.systemCyan
        material.color = .init(tint: baseTint.withAlphaComponent(0.95))
        let opacityTexture = MaterialParameters.Texture(texture)
        material.blending = .transparent(opacity: .init(texture: opacityTexture))

        let transform = Transform(matrix: raycastResult.worldTransform)
        let cameraPosition = camera.transform.translation

        if let overlay = glowOverlays[id] {
            overlay.anchor.transform = transform
            overlay.entity.model = ModelComponent(mesh: mesh, materials: [material])
            overlay.entity.look(at: cameraPosition, from: transform.translation, relativeTo: nil)
        } else {
            let anchor = AnchorEntity(world: raycastResult.worldTransform)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.look(at: cameraPosition, from: transform.translation, relativeTo: nil)
            anchor.addChild(entity)
            arView.scene.addAnchor(anchor)
            glowOverlays[id] = GlowOverlay(anchor: anchor, entity: entity)
        }
    }

    private func pruneInactiveOverlays(keeping activeIDs: Set<UUID>) {
        guard !activeIDs.isEmpty else {
            for overlay in glowOverlays.values {
                overlay.anchor.removeFromParent()
            }
            glowOverlays.removeAll()
            return
        }

        let stale = glowOverlays.keys.filter { !activeIDs.contains($0) }
        for id in stale {
            if let overlay = glowOverlays[id] {
                overlay.anchor.removeFromParent()
            }
            glowOverlays.removeValue(forKey: id)
        }
    }
#endif

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = Date().timeIntervalSince1970
        guard now - lastFrameTime >= 0.25 else { return }
        lastFrameTime = now

        guard let pixelBuffer = clonePixelBuffer(frame.capturedImage) else {
            Task { await logger.log("Camera pipeline dropped a frame because the pixel buffer could not be cloned.", level: .warning, category: "LangscapeApp.Camera") }
            return
        }
        #if canImport(ImageIO)
        let orientationRaw = CGImagePropertyOrientation.right.rawValue
        #else
        let orientationRaw: UInt32? = nil
        #endif
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let inputSize = CGSize(width: width, height: height)
        let request = DetectionRequest(pixelBuffer: pixelBuffer, imageOrientationRaw: orientationRaw)

        Task { @MainActor [contextManager] in
            if contextManager.shouldClassifyScene {
                await contextManager.classify(pixelBuffer)
            }
        }

        Task { @MainActor in
            viewModel.setInputSize(inputSize)
            viewModel.enqueue(request)
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

#if canImport(CoreImage)
private struct GlowOverlay {
    let anchor: AnchorEntity
    let entity: ModelEntity
}

@MainActor
private final class MaskTextureCache {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var cache: [UUID: TextureResource] = [:]
    private let options = TextureResource.CreateOptions(semantic: .raw)

    func texture(for id: UUID, mask: CIImage) -> TextureResource? {
        if let cached = cache[id] {
            return cached
        }
        guard let cgImage = ciContext.createCGImage(mask, from: mask.extent) else {
            return nil
        }
        guard let texture = try? TextureResource.generate(from: cgImage, options: options) else {
            return nil
        }
        cache[id] = texture
        return texture
    }

    func prune(keeping ids: Set<UUID>) {
        guard !ids.isEmpty else {
            cache.removeAll()
            return
        }
        cache = cache.filter { ids.contains($0.key) }
    }

    func removeAll() {
        cache.removeAll()
    }
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

@MainActor
final class ContextManager: ObservableObject {
    enum State: Equatable {
        case unknown
        case detecting
        case locked(String)
    }

    @Published private(set) var state: State = .unknown

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
        if case .unknown = state { return true }
        return false
    }

    var contextDisplayName: String {
        switch state {
        case .unknown:
            return "Detecting environment…"
        case .detecting:
            return "Locking environment…"
        case .locked(let value):
            return "Context: \(value.capitalized)"
        }
    }

    var isDetecting: Bool {
        if case .detecting = state { return true }
        return false
    }

    var canManuallyChange: Bool {
        if case .locked = state { return true }
        return false
    }

    func reset() {
        state = .unknown
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
