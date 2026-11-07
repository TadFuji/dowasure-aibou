import os
import SwiftUI
import UserNotifications

/// Daily evening notification that invites the user to talk about the day (F5).
enum EveningReminder {
    static let identifier = "evening-talk"
    static let enabledKey = "reminderEnabled"
    static let hourKey = "reminderHour"
    static let minuteKey = "reminderMinute"

    /// Asks permission (first time only) and schedules the daily notification. Returns false if not allowed.
    static func schedule(hour: Int, minute: Int) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Logger(subsystem: "io.github.tadfuji.dowasure", category: "reminder").error("authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard granted else { return false }
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = "ど忘れ相棒"
        content.body = "忘れたくないことはありますか？話しておきましょう。"
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            return true
        } catch {
            return false
        }
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

/// Lets a tapped notification or Siri open a screen.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    var openTalk = false
    var openAsk = false
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Show the banner even when the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // The evening reminder is the app's only notification.
        await MainActor.run { AppRouter.shared.openTalk = true }
    }
}
