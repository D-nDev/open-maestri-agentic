import XCTest
@testable import open_maestri

final class SkillInjectorTests: XCTestCase {
    let injector = SkillInjector.shared

    // MARK: - SkillInjector simplified version (CLI binary has been injected via PATH, shell function is no longer generated)

    func testInjectorIsSingleton() {
        XCTAssertTrue(SkillInjector.shared === injector, "Should be a singleton")
    }

    func testInjectorExists() {
        // SkillInjector now only outputs a confirmation message and does not generate a shell function
        // inject(to:host:) method signature remains backwards compatible
        XCTAssertNotNil(injector)
    }
}
