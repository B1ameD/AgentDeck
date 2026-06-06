import XCTest
import SwiftUI
import AppKit
@testable import AgentDeckApp

final class SettingsOptionsTests: XCTestCase {
    func testRequiredSettingsExposeMinimumOptionCounts() {
        XCTAssertEqual(AgentActivationMode.allCases.count, 3)
        XCTAssertEqual(PromptOptimizationMode.allCases.count, 3)
        XCTAssertEqual(AppTheme.allCases.count, 3)
        XCTAssertEqual(AppLanguage.allCases.count, 3)
        XCTAssertGreaterThanOrEqual(BundledCodeFont.allCases.count, 5)
        XCTAssertGreaterThanOrEqual(InterfaceFont.allCases.count, 5)
        XCTAssertGreaterThanOrEqual(AgentBehaviorRule.allCases.count, 3)
        XCTAssertGreaterThanOrEqual(SystemPromptPreset.allCases.count, 4)
        XCTAssertGreaterThanOrEqual(InstructionPreset.allCases.count, 3)
        XCTAssertGreaterThanOrEqual(KnownProjectsStore.seedProjects().count, 3)
        XCTAssertGreaterThanOrEqual(WorkspaceMode.allCases.count, 3)
    }

    func testNamedInterfaceFontsResolveOnThisMac() {
        for font in InterfaceFont.allCases {
            guard let familyName = font.familyName else { continue }
            XCTAssertNotNil(NSFont(name: familyName, size: 14), "\(font.label) should resolve instead of falling back to system")
        }
    }

    func testSettingsFallbackToExpectedDefaults() {
        XCTAssertEqual(AgentActivationMode.resolve("bogus"), .always)
        XCTAssertEqual(PromptOptimizationMode.resolve("bogus"), .useDefault)
        XCTAssertEqual(AppTheme.resolve("bogus"), .system)
        XCTAssertEqual(AppLanguage.resolve("bogus"), .auto)
        XCTAssertEqual(AppFontSize.resolve(11), .s14)
        XCTAssertEqual(InterfaceFont.resolve("bogus"), .system)
        XCTAssertEqual(AgentBehaviorRule.resolve("bogus"), .balanced)
        XCTAssertEqual(SystemPromptPreset.resolve("bogus"), .assistant)
        XCTAssertEqual(InstructionPreset.resolve("bogus"), .general)
        XCTAssertEqual(WorkspaceMode.resolve("bogus"), .development)
    }

    func testAppFontSizeOptionsAreTenThroughTwentyFourByTwo() {
        XCTAssertEqual(AppFontSize.allCases.map(\.rawValue), [10, 12, 14, 16, 18, 20, 22, 24])
        XCTAssertEqual(AppFontSize.s20.points, 20)
        XCTAssertEqual(AppFontSize.points(22), 22)
    }

    func testPromptOptimizationModeControlsComposerButtonVisibility() {
        XCTAssertTrue(PromptOptimizationMode.useDefault.showsComposerButton)
        XCTAssertTrue(PromptOptimizationMode.custom.showsComposerButton)
        XCTAssertFalse(PromptOptimizationMode.disabled.showsComposerButton)
    }

    func testInterfaceFontSeparatesDesignAndFamilyForStableModifier() {
        XCTAssertEqual(InterfaceFont.system.fontDesign, .default)
        XCTAssertEqual(InterfaceFont.rounded.fontDesign, .rounded)
        XCTAssertEqual(InterfaceFont.serif.fontDesign, .serif)
        XCTAssertNil(InterfaceFont.system.familyName)
        XCTAssertNil(InterfaceFont.rounded.familyName)
        XCTAssertNil(InterfaceFont.serif.familyName)

        XCTAssertNil(InterfaceFont.avenirNext.fontDesign)
        XCTAssertEqual(InterfaceFont.avenirNext.familyName, "Avenir Next")
        XCTAssertNil(InterfaceFont.verdana.fontDesign)
        XCTAssertEqual(InterfaceFont.verdana.familyName, "Verdana")
        XCTAssertNil(InterfaceFont.avenirNext.environmentFontDesign)
        XCTAssertEqual(InterfaceFont.rounded.environmentFontDesign, .rounded)
    }

    func testDarkThemeForcesDarkScheme() {
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
    }

    func testKnownProjectsRoundTripThroughAppStorageString() {
        let projects = [
            KnownProject(id: "a", name: "Project A", path: "/tmp/a"),
            KnownProject(id: "b", name: "Project B", path: "/tmp/b"),
            KnownProject(id: "c", name: "Project C", path: "/tmp/c")
        ]

        let raw = KnownProjectsStore.encode(projects)
        XCTAssertEqual(KnownProjectsStore.decode(raw), projects)
    }
}
