# MioIsland Daemon Installer UX + i18n Review (#124)

Status: UX / copy / i18n review for daemon distribution follow-up.
Scope: MioIsland Settings -> Mio Agent install/update flow for downloading, verifying, staging, and replacing the `mio-agent` daemon binary.
Non-goals: choose the release-hosting mechanism, implement downloader code, or change launchd behavior.

## 1. Purpose

The daemon distribution flow should make it clear which daemon binary is installed, whether a newer package is being downloaded, whether the package was verified, and whether the currently working daemon was preserved after a failure.

The user should never have to infer whether Install replaced the fixed daemon with an older or unverified one.

## 2. UX Principles

1. **No overwrite before verification.** Download into a staging path, verify checksum, then atomically replace. If verification fails, the current daemon remains in place.
2. **Preserve working state on failure.** Offline, partial download, hash mismatch, and manifest errors must say that the current daemon was kept.
3. **Separate install/update from Start/Stop.** Downloading or replacing the binary is not the same as the daemon running. The Agent lifecycle rows should keep Binary / Config / LaunchAgent / Process / Health separate.
4. **Use actionable diagnostics.** Show controlled categories and next action; do not show raw stack traces as primary UI.
5. **No secrets in UI.** It is OK to show version, architecture, SHA256 prefix, server URL, and commit. Do not show machine token, org secrets, auth headers, credential aliases, or raw provider errors.

## 3. Suggested Information Architecture

Add one compact row to the existing Lifecycle card:

```text
Daemon package   0.1.0 (arm64) · verified SHA256   Current
```

Recommended row placement:

```text
Binary
Daemon package
Config
LaunchAgent
Process
Health
Socket
```

The row should show:

- installed version, if known;
- target version during update;
- checksum verification status;
- whether the installed binary includes required fixes such as `machine-api-v1-prefix` and `socketio-control-path`.

Keep long commit/checksum values truncated in the visible row and expose full diagnostics only through Copy diagnostic.

## 4. State Model And Copy

| State | Primary copy EN | Primary copy zh-Hans | Secondary copy EN | Secondary copy zh-Hans | Primary action |
|---|---|---|---|---|---|
| `daemon_current` | Daemon installed | 守护进程已安装 | Current package is verified and ready to start. | 当前安装包已校验，可启动。 | Start |
| `update_available` | Daemon update available | 有可用守护进程更新 | A newer verified package is available. | 有新的已验证安装包可用。 | Update |
| `manifest_loading` | Checking release manifest... | 正在检查发布清单… | Looking for the latest daemon package. | 正在查找最新守护进程安装包。 | none |
| `manifest_unavailable` | Release manifest unavailable | 发布清单不可用 | The current daemon was kept. Try again when the release server is reachable. | 已保留当前守护进程。请在发布服务器可访问后重试。 | Retry |
| `unsupported_arch` | No daemon build for this Mac | 没有适用于此 Mac 的守护进程版本 | This Mac architecture is not included in the release manifest. | 发布清单中不包含此 Mac 架构。 | Copy diagnostic |
| `download_queued` | Download ready | 下载已准备 | The daemon package can be downloaded and verified before install. | 可下载并校验守护进程安装包后再安装。 | Download |
| `downloading` | Downloading mio-agent... | 正在下载 mio-agent… | Keep this window open. The current daemon has not been changed. | 请保持此窗口打开。当前守护进程尚未更改。 | Cancel |
| `download_interrupted` | Download was interrupted | 下载中断 | The current daemon was kept. Retry will start a new download. | 已保留当前守护进程。重试将重新下载。 | Retry |
| `offline` | Cannot reach release server | 无法连接发布服务器 | The current daemon was kept. Check your network and try again. | 已保留当前守护进程。请检查网络后重试。 | Retry |
| `verifying` | Verifying download... | 正在校验下载… | Checking SHA256 before install. | 正在安装前检查 SHA256。 | none |
| `hash_mismatch` | Download could not be verified | 下载文件未通过校验 | The downloaded file was discarded and the current daemon was kept. | 已丢弃下载文件，并保留当前守护进程。 | Retry |
| `staging` | Preparing update... | 正在准备更新… | Moving the verified package into staging. | 正在将已校验安装包移入暂存区。 | none |
| `replacing` | Replacing daemon safely... | 正在安全替换守护进程… | Do not quit MioIsland. The previous binary will be kept if replacement fails. | 请不要退出 MioIsland。替换失败时会保留旧版本。 | none |
| `restart_required` | Restart agent to use the new daemon | 重启 agent 以使用新版守护进程 | The package is installed. Stop and Start the agent to load it. | 安装包已安装。请停止并重新启动 agent 以加载新版。 | Restart agent |
| `updated` | Daemon updated | 守护进程已更新 | The verified daemon package is installed. | 已安装经过校验的守护进程安装包。 | Start |
| `rollback_preserved` | Current daemon was kept | 已保留当前守护进程 | The update did not replace the working daemon. | 本次更新未替换当前可用守护进程。 | Retry |

Avoid user-facing copy such as:

- "Ignore checksum"
- "Force replace"
- "Maybe installed"
- "Unknown error"
- "Check Logs" without a visible diagnostic or copy action

## 5. Button And Control Rules

| Control | Visible when | Enabled when | Notes |
|---|---|---|---|
| `Download` / `Update` | release manifest has matching artifact | not busy | Starts download into staging only. |
| `Retry` | offline, interrupted, manifest unavailable, hash mismatch | not busy | Must start from a fresh download or fresh manifest read. |
| `Cancel` | downloading | downloader supports cancellation | Cancel must leave current daemon unchanged. |
| `Start` | daemon package installed and Config present | not replacing/downloading | Do not show Start as the primary action while package replacement is active. |
| `Stop` | daemon loaded/running | not replacing/downloading | If replacing while running is not supported, ask user to Stop before Update. |
| `Restart agent` | `restart_required` | not busy | Should run the existing Stop/Start path after package replacement. |
| `Open log file` | always | always | If installer log is missing, open `~/.mio/` rather than dead-disable. |
| `Copy diagnostic` | always | always | Copy controlled state, version, arch, checksum prefix, and last error category. |

If replacement fails, the next visible state should be `rollback_preserved`, not generic `failed`.

## 6. Error Priority

When multiple conditions exist, prioritize the one that tells the user the next action:

1. Replacing / staging in progress
2. Hash mismatch
3. Partial download / interrupted
4. Offline / release server unreachable
5. Unsupported architecture
6. Config missing
7. LaunchAgent stopped
8. Health failed

Example: if the binary is installed but the release check is offline, show `Cannot reach release server` inside the installer row while the main lifecycle card can still show `Installed · stopped`.

## 7. i18n Key Proposal

MioIsland currently uses `L10n.*` in `Localization.swift`. Add installer keys under the existing Mio Agent Settings block rather than hard-coding strings in `AgentSettingsTab.swift`.

Suggested key groups:

```swift
agentInstallerRowPackage
agentInstallerStateCurrent
agentInstallerStateUpdateAvailable
agentInstallerStateManifestLoading
agentInstallerStateManifestUnavailable
agentInstallerStateUnsupportedArch
agentInstallerStateDownloadQueued
agentInstallerStateDownloading
agentInstallerStateDownloadInterrupted
agentInstallerStateOffline
agentInstallerStateVerifying
agentInstallerStateHashMismatch
agentInstallerStateStaging
agentInstallerStateReplacing
agentInstallerStateRestartRequired
agentInstallerStateUpdated
agentInstallerStateRollbackPreserved
agentInstallerActionDownload
agentInstallerActionUpdate
agentInstallerActionRetry
agentInstallerActionCancel
agentInstallerActionRestartAgent
agentInstallerActionCopyDiagnostic
agentInstallerHintCurrentKept
agentInstallerHintChecksum
agentInstallerHintNoOverwrite
agentInstallerDiagCopied
```

Keep dynamic values in formatter helpers:

```swift
agentInstallerVersion(_ version: String, arch: String)
agentInstallerChecksum(_ prefix: String)
agentInstallerCommit(_ shortSha: String)
agentInstallerDownloadProgress(_ percent: Int)
```

## 8. Visual Review Notes

- Keep the existing Agent Settings visual language: compact diagnostic rows, pill states, restrained amber/green/red semantics, and Settings-native density.
- Use spinner only for active work (`manifest_loading`, `downloading`, `verifying`, `staging`, `replacing`).
- Hash mismatch should use error red, but the preserved-current-daemon note should be neutral/amber, not green success.
- Success should not imply the daemon is running. Use `Daemon updated`, not `Agent running`.
- Long paths and checksums should truncate in the row; Copy diagnostic carries the full value.

## 9. Acceptance Checklist

- English and Simplified Chinese copy exist for every installer state, button, and diagnostic.
- Offline, hash mismatch, partial download, and manifest unavailable all explicitly say the current daemon was kept.
- The UI never replaces a working daemon before checksum verification passes.
- The UI does not expose tokens, auth headers, machine token, credential aliases, or raw provider errors.
- Start/Stop lifecycle remains separate from package download/install state.
- Running daemon replacement either requires Stop first or uses a verified bootout/bootstrap flow.
- Copy diagnostic works even when no installer log exists.
- A new/fresh machine cannot install an old daemon missing `machine-api-v1-prefix` and `socketio-control-path` fixes.
- A failed update leaves the existing `~/.mio/bin/mio-agent` executable and launchd state recoverable.
