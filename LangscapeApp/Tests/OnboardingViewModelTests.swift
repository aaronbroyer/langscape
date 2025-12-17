import XCTest
@testable import Langscape
import Utilities

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "com.langscape.tests.onboarding")
        defaults.removePersistentDomain(forName: "com.langscape.tests.onboarding")
        settings = AppSettings(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "com.langscape.tests.onboarding")
        defaults = nil
        settings = nil
        super.tearDown()
    }

    func testAdvanceFromSplashMovesToHero() {
        let viewModel = OnboardingViewModel(settings: settings)
        viewModel.advanceFromSplash()
        XCTAssertEqual(viewModel.step, .hero)
    }

    func testGetStartedFromHeroMovesToLanguageSelection() {
        let viewModel = OnboardingViewModel(settings: settings)
        viewModel.advanceFromSplash()
        viewModel.getStartedFromHero()
        XCTAssertEqual(viewModel.step, .languageSelection)
    }

    func testContinueFromLanguageSelectionPersistsPreference() {
        let viewModel = OnboardingViewModel(settings: settings)
        viewModel.advanceFromSplash()
        viewModel.getStartedFromHero()
        viewModel.setTargetLanguage(.english)
        viewModel.continueFromLanguageSelection()
        XCTAssertEqual(settings.selectedLanguage, .spanishToEnglish)
        XCTAssertEqual(viewModel.step, .cameraPermission)
    }

    func testSkipLanguageSelectionDoesNotPersistChanges() {
        let viewModel = OnboardingViewModel(settings: settings)
        viewModel.advanceFromSplash()
        viewModel.getStartedFromHero()
        viewModel.setTargetLanguage(.english)
        viewModel.skipLanguageSelection()
        XCTAssertEqual(settings.selectedLanguage, .englishToSpanish)
        XCTAssertEqual(viewModel.step, .cameraPermission)
    }

    func testCompleteOnboardingSetsFlag() {
        let viewModel = OnboardingViewModel(settings: settings)
        viewModel.completeOnboarding()
        XCTAssertTrue(settings.hasCompletedOnboarding)
    }
}
