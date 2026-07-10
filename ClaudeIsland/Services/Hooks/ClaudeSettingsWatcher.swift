//
//  ClaudeSettingsWatcher.swift
//  ClaudeIsland
//
//  Auto-heals the Claude Code hook installation.
//
//  Provider switchers (ccswitch and friends) rewrite ~/.claude/settings.json
//  when the user changes model providers, wiping the hooks block. From that
//  moment every new Claude session is invisible to the app until it is
//  relaunched (issues #66 / #93). This watcher observes settings.json and
//  re-installs the hooks the moment they disappear — unless the user turned
//  hooks off on purpose (HookInstaller.userDisabled).
//

import Foundation

final class ClaudeSettingsWatcher: @unchecked Sendable {
    static let shared = ClaudeSettingsWatcher()

    private let queue = DispatchQueue(label: "com.codeisland.settings-watcher", qos: .utility)
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var pendingHeal: DispatchWorkItem?
    private var safetyNet: DispatchSourceTimer?

    private var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    private var settingsURL: URL {
        claudeDir.appendingPathComponent("settings.json")
    }

    private init() {}

    func start() {
        queue.async { [self] in
            armFileWatcher()
            armDirWatcher()
            armSafetyNet()
        }
    }

    // MARK: - Watchers

    /// Watch settings.json itself — catches in-place rewrites (truncate+write).
    /// Re-armed after delete/rename because the fd tracks the old inode.
    private func armFileWatcher() {
        fileSource?.cancel()
        fileSource = nil

        let fd = open(settingsURL.path, O_EVTONLY)
        guard fd >= 0 else { return } // file absent — dir watcher re-arms us

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.fileSource?.data ?? []
            self.scheduleHeal()
            if flags.contains(.delete) || flags.contains(.rename) {
                // Atomic replace — follow the new inode shortly after.
                self.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.armFileWatcher()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        fileSource = source
        source.resume()
    }

    /// Watch ~/.claude — catches settings.json being replaced or recreated
    /// (directory entry churn the file fd can't see).
    private func armDirWatcher() {
        dirSource?.cancel()
        dirSource = nil

        let fd = open(claudeDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleHeal()
            // Entry churn may have swapped settings.json's inode.
            self.armFileWatcher()
        }
        source.setCancelHandler { close(fd) }
        dirSource = source
        source.resume()
    }

    /// Low-frequency poll as a backstop for anything the vnode sources miss.
    private func armSafetyNet() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            self?.healIfNeeded()
        }
        safetyNet = timer
        timer.resume()
    }

    // MARK: - Heal

    /// Debounce: ccswitch-style tools write the file several times in a burst.
    private func scheduleHeal() {
        pendingHeal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.healIfNeeded()
        }
        pendingHeal = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func healIfNeeded() {
        guard !HookInstaller.userDisabled else { return }
        guard !HookInstaller.isInstalled() else { return }
        DebugLogger.log("Hooks", "settings.json lost codeisland hooks — auto-reinstalling")
        HookInstaller.installIfNeeded()
    }
}
