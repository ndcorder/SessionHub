import Foundation
import SwiftUI

@MainActor
@Observable
final class AppPreferences {
    enum SortOrder: String, CaseIterable, Identifiable {
        case project = "Project name", recent = "Recently used", active = "Active first"
        var id: String { rawValue }
    }
    enum Appearance: String, CaseIterable, Identifiable {
        case system = "System", light = "Light", dark = "Dark"
        var id: String { rawValue }
        var colorScheme: ColorScheme? { self == .system ? nil : (self == .dark ? .dark : .light) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var pollingChanged: (() -> Void)?
    @ObservationIgnored var shortcutChanged: (() -> Void)?
    var favorites: Set<String> { didSet { defaults.set(favorites.sorted(), forKey: "favorites") } }
    var collapsed: Set<String> { didSet { defaults.set(collapsed.sorted(), forKey: "collapsed") } }
    var sortOrder: SortOrder { didSet { defaults.set(sortOrder.rawValue, forKey: "sortOrder") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var showDetails: Bool { didSet { defaults.set(showDetails, forKey: "showDetails") } }
    var refreshInterval: Double { didSet {
        defaults.set(refreshInterval, forKey: "refreshInterval")
        pollingChanged?()
    } }
    var shortcutEnabled: Bool { didSet {
        defaults.set(shortcutEnabled, forKey: "shortcutEnabled")
        shortcutChanged?()
    } }
    var showSessionCount: Bool { didSet { defaults.set(showSessionCount, forKey: "showSessionCount") } }
    private(set) var recent: [String: Double]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = Set(defaults.stringArray(forKey: "favorites") ?? [])
        collapsed = Set(defaults.stringArray(forKey: "collapsed") ?? [])
        sortOrder = SortOrder(rawValue: defaults.string(forKey: "sortOrder") ?? "") ?? .project
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        showDetails = defaults.object(forKey: "showDetails") as? Bool ?? true
        let interval = defaults.double(forKey: "refreshInterval")
        refreshInterval = [1.0, 3.0, 5.0, 10.0].contains(interval) ? interval : 3
        shortcutEnabled = defaults.object(forKey: "shortcutEnabled") as? Bool ?? true
        showSessionCount = defaults.object(forKey: "showSessionCount") as? Bool ?? false
        recent = defaults.dictionary(forKey: "recent") as? [String: Double] ?? [:]
    }

    func toggleFavorite(_ profile: String) {
        if !favorites.insert(profile).inserted { favorites.remove(profile) }
    }
    func toggleCollapsed(_ profile: String) {
        if !collapsed.insert(profile).inserted { collapsed.remove(profile) }
    }
    func recordVisit(_ sessionId: String, at date: Date = Date()) {
        recent[sessionId] = date.timeIntervalSince1970
        recent = Dictionary(uniqueKeysWithValues: recent.sorted { $0.value > $1.value }.prefix(100).map { ($0.key, $0.value) })
        defaults.set(recent, forKey: "recent")
    }
    func ordered(_ groups: [ProjectGroup]) -> [ProjectGroup] {
        groups.sorted { lhs, rhs in
            if favorites.contains(lhs.profileName) != favorites.contains(rhs.profileName) {
                return favorites.contains(lhs.profileName)
            }
            if sortOrder == .active, lhs.hasActiveSession != rhs.hasActiveSession { return lhs.hasActiveSession }
            if sortOrder == .recent {
                let left = lhs.sessions.map { recent[$0.id, default: 0] }.max() ?? 0
                let right = rhs.sessions.map { recent[$0.id, default: 0] }.max() ?? 0
                if left != right { return left > right }
            }
            return lhs.profileName.localizedStandardCompare(rhs.profileName) == .orderedAscending
        }
    }
}
