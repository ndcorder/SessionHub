import Foundation
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: LoginItemController.Status { get }
    func setEnabled(_ enabled: Bool) async throws
    func openSettings()
}

@MainActor
struct SystemLoginItemService: LoginItemService {
    var status: LoginItemController.Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .disabled
        }
    }
    func setEnabled(_ enabled: Bool) async throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
@Observable
final class LoginItemController {
    enum Status { case enabled, disabled, requiresApproval, notFound }
    private(set) var status: Status
    private(set) var isBusy = false
    private(set) var error: String?
    @ObservationIgnored private let service: LoginItemService

    init(service: LoginItemService? = nil) {
        let service = service ?? SystemLoginItemService()
        self.service = service
        status = service.status
    }
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    func refresh() { status = service.status }
    func setEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false; refresh() }
        do { try await service.setEnabled(enabled) }
        catch { self.error = "Could not change launch at login: \(error.localizedDescription)" }
    }
    func openSettings() { service.openSettings() }
}
