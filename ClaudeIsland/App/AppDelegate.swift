import AppKit
import SwiftUI
import UserNotifications

@MainActor class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?

    static var shared: AppDelegate?

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
        super.init()
        AppDelegate.shared = self
        UserDefaults.standard.register(defaults: ["usageWarningThreshold": 90])

        // Apply the user's Anthropic API Proxy setting to the process
        // environment as early as possible, BEFORE any plugin is loaded
        // or any subprocess is spawned. All Foundation.Process children
        // (stats' claude CLI, future plugins' shell-outs) will inherit
        // HTTPS_PROXY / HTTP_PROXY / ALL_PROXY without per-plugin opt-in.
        AppSettings.applyProxyToProcessEnvironment()

        // Re-apply whenever any UserDefaults value changes — cheap, idempotent.
        // The notification fires on every defaults write (including unrelated
        // keys), but applyProxyToProcessEnvironment() is a small setenv loop
        // so the redundant calls are harmless.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            AppSettings.applyProxyToProcessEnvironment()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        if !HookInstaller.userDisabled {
            HookInstaller.installIfNeeded()
        }
        // Keep hooks alive across settings.json rewrites (ccswitch etc. —
        // issues #66/#93). No-ops while the user has hooks switched off.
        ClaudeSettingsWatcher.shared.start()
        CodexFeatureGate.shared.onLaunch()
        logHookHealth()

        // Request notification permission — .accessory policy blocks the system dialog,
        // so temporarily switch to .regular when permission is not yet determined.
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus == .notDetermined {
                    NSApplication.shared.setActivationPolicy(.regular)
                    center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                        DispatchQueue.main.async {
                            NSApplication.shared.setActivationPolicy(.accessory)
                        }
                    }
                } else {
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
            }
        }

        windowManager = WindowManager()
        _ = windowManager?.setupNotchWindow()

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        // Initialize Sparkle auto-updater
        _ = UpdaterManager.shared

        // Load native plugins from ~/.config/codeisland/plugins/
        NativePluginManager.shared.loadAll()
        ThemeRegistry.shared.loadAll()

        // Initialize CodeLight sync (connects to server if configured)
        _ = SyncManager.shared

        // Stats are now handled by the external stats plugin.
        // AnalyticsCollector.shared.start() is called by the plugin's activate().

        // Ad-hoc 签名升级后 TCC 权限失效检测：已配对 CodeLight 的用户才会收到通知，
        // 只在权限"从有变没"时发通知，避免反复打扰。
        PermissionAlertNotifier.installAndCheck()
    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenObserver = nil
    }

    // Allow notifications to show even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// 处理通知点击（含按钮）。权限失效通知走 PermissionAlertNotifier.handleResponse。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let categoryId = response.notification.request.content.categoryIdentifier
        if categoryId == PermissionAlertNotifier.notificationCategory {
            PermissionAlertNotifier.handleResponse(actionIdentifier: response.actionIdentifier)
        }
        completionHandler()
    }

    private func logHookHealth() {
        let reports = [HookHealthCheck.checkClaude(), HookHealthCheck.checkCodex()]
        for report in reports where !report.isHealthy {
            for issue in report.errors {
                NSLog("[CodeIsland] Hook health (\(report.agent)): \(issue)")
            }
        }
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.codeisland.app"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}
