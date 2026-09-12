import XCTest
@testable import SessionHub

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status = LoginItemController.Status.disabled
    var reject = false
    var requiresApproval = false
    func setEnabled(_ enabled: Bool) async throws {
        if reject { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Rejected by system"]) }
        status = enabled ? (requiresApproval ? .requiresApproval : .enabled) : .disabled
    }
    func openSettings() {}
}

final class LoginItemTests: XCTestCase {
    @MainActor
    func testLoginItemTracksSystemSuccessApprovalAndFailure() async {
        let service = FakeLoginItemService()
        let model = LoginItemController(service: service)
        await model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        service.reject = true
        await model.setEnabled(false)
        XCTAssertTrue(model.isEnabled, "A rejected unregister must not misrepresent system state")
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.isBusy)
        service.reject = false
        await model.setEnabled(false)
        XCTAssertFalse(model.isEnabled)
        service.requiresApproval = true
        await model.setEnabled(true)
        XCTAssertEqual(model.status, .requiresApproval)
        XCTAssertTrue(model.isEnabled)
        service.status = .disabled // External system-settings change.
        model.refresh()
        XCTAssertFalse(model.isEnabled)
    }
}
