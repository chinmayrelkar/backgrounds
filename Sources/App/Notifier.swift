import Foundation
import UserNotifications

/// Remembers which login jobs we've seen and posts a notification when a new one shows up.
@MainActor
final class Notifier {
    private let defaults = UserDefaults.standard
    private let key = "knownJobIDs"
    private var askedPermission = false

    /// Returns ids not seen before. The very first run just records the baseline.
    func recordJobs(_ ids: [String]) -> Set<String> {
        let current = Set(ids)
        guard let stored = defaults.stringArray(forKey: key) else {
            defaults.set(Array(current), forKey: key)
            return []
        }
        let known = Set(stored)
        let fresh = current.subtracting(known)
        if !fresh.isEmpty { defaults.set(Array(known.union(current)), forKey: key) }
        return fresh
    }

    func post(title: String, body: String) {
        // UNUserNotificationCenter crashes without a bundle id (e.g. `swift run`).
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if askedPermission { send(); return }
        askedPermission = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { send() }
        }
    }
}
