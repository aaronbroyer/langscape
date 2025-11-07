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

    func testAdvanceFromSplashMovesToSlides() {
        let viewModel = OnboardingViewModel(settings: settings)
        viewModel.advanceFromSplash()
        XCTAssertEqual(viewModel.step, .slides)
    }

    func testShowLanguageSelectionAfterSlides() {
        let viewModel = OnboardingViewModel(settings: settings)
        viewModel.advanceFromSplash()
        viewModel.showLanguageSelection()
        XCTAssertEqual(viewModel.step, .languageSelection)
    }

    func testSelectLanguagePersistsPreference() {
        let viewModel = OnboardingViewModel(settings: settings)
        viewModel.advanceFromSplash()
        viewModel.showLanguageSelection()
        viewModel.selectLanguage(.spanishToEnglish)
        XCTAssertEqual(settings.selectedLanguage, .spanishToEnglish)
        XCTAssertEqual(viewModel.step, .cameraPermission)
    }

    func testCompleteOnboardingSetsFlag() {
        let viewModel = OnboardingViewModel(settings: settings)
        viewModel.completeOnboarding()
        XCTAssertTrue(settings.hasCompletedOnboarding)
    }
}
