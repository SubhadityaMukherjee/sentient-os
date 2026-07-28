//
//  SidekickNotificationDelegate.swift
//  Sentient OS macOS
//
//  Bridges a Sidekick completion-notification TAP into SwiftUI: UNUserNotificationCenterDelegate has
//  no access to the SwiftUI environment, so on tap it posts .openSidekickHistory, which RootView
//  observes and turns into `openWindow(id:)`. Owned by AppState for the app's lifetime (set as the
//  center's delegate in AppState.init). Also banners notifications while the app is frontmost — a
//  Sidekick finish is worth flagging even when the user is looking at Sentient.
//

import Foundation
import UserNotifications

extension Notification.Name {
    static let openSidekickHistory = Notification.Name("SentientOpenSidekickHistory")
}

final class SidekickNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        NotificationCenter.default.post(name: .openSidekickHistory, object: nil)
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
