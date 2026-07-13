//
//  PhoneMessageFailureNotifier.swift
//  ClaudeIsland
//
//  OPT-08: surfaces phone→Mac message failures as user-visible macOS
//  notifications. Before this, a failed injection was os.log-only — the
//  phone showed "delivered", the Mac did nothing, and the user had zero
//  clues (ISS-06 field report: a paying user spent hours chasing
//  permissions because every failure in this path was silent).
//

import Foundation
import UserNotifications

@MainActor
enum PhoneMessageFailureNotifier {

    /// Per-reason debounce so a burst of failures doesn't spam
    /// Notification Center — one notice per reason per minute is enough
    /// to make the failure visible.
    private static var lastNotified: [String: Date] = [:]
    private static let debounceInterval: TimeInterval = 60

    /// Post a user-visible notification about a failed phone message.
    /// Also mirrors the event into ~/.claude/.codeisland.log (OPT-09)
    /// so "it silently did nothing" can always be reconstructed.
    static func notify(reason: String, detail: String) {
        DebugLogger.log("PhoneMsg", "FAILED (\(reason)) — \(detail)")

        let now = Date()
        if let last = lastNotified[reason], now.timeIntervalSince(last) < debounceInterval {
            return
        }
        lastNotified[reason] = now

        let content = UNMutableNotificationContent()
        content.title = L10n.phoneMessageFailedTitle
        content.body = detail

        let request = UNNotificationRequest(
            identifier: "phone-msg-fail-\(reason)-\(Int(now.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
