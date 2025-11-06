import Foundation
import Utilities

#if canImport(SwiftUI)
import SwiftUI
import DesignSystem
import UIComponents
import DetectionKit
import GameKitLS
import VocabStore
import LLMKit

@main
struct LangscapeAppMain: App {
    @StateObject private var viewModel = LangscapeViewModel()

    var body: some Scene {
        WindowGroup {
            LangscapeHomeView(viewModel: viewModel)
        }
    }
}

final class LangscapeViewModel: ObservableObject {
    private let logger = Logger.shared
    private let gameSession = GameSession()
    private let vocabStore = VocabularyStore()
    private let llm = LangscapeLLM()

    func performDemo() {
        Task {
            await logger.log("Demo started", level: .info, category: "App")
            gameSession.submit("Hello")
            await vocabStore.add(.init(phrase: "Hello", translation: "Hola"))
            _ = await llm.send(prompt: "Translate 'world'")
        }
    }
}

struct LangscapeHomeView: View {
    @ObservedObject var viewModel: LangscapeViewModel

    var body: some View {
        VStack(spacing: Spacing.medium.cgFloat) {
            Text("Langscape")
                .font(Typography.largeTitle.font)
                .foregroundStyle(ColorPalette.primary.swiftUIColor)

            Text("Explore immersive language experiences.")
                .font(Typography.body.font)
                .foregroundStyle(ColorPalette.secondary.swiftUIColor)

            PrimaryButton(title: "Run Demo") {
                viewModel.performDemo()
            }
        }
        .padding(Spacing.large.cgFloat)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorPalette.background.swiftUIColor)
    }
}

#Preview {
    LangscapeHomeView(viewModel: LangscapeViewModel())
}
#endif
