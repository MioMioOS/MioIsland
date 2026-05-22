# MioIsland Agent Tab Phase 2 State Design (#90)

Status: design / interaction spec for continuous UI lane.
Scope: MioIsland Settings → Agent tab status, controls, drain/log states, and copy for Phase 2 prep.
Non-goals: implement IPC, change launchctl behavior, or design Workroom binding execution flows.

## 1. Purpose

The Agent tab should make local `mio-agent` lifecycle state understandable without pretending Phase 2 IPC is already finished. The user needs to know whether the binary is installed, whether launchd has the job loaded, whether the process is running, whether the health endpoint is reachable, whether Stop is drain-safe, and where to inspect logs.

This spec builds on the #70/#74 skeleton: install/start/stop already exist; Phase 2 should improve status clarity, loaded/running distinction, drain copy, and log affordances.

## 2. Core Principle

Separate **registration**, **process**, and **health**. A loaded LaunchAgent is not the same as a running process; a running process is not the same as a healthy agent.

Do not collapse these into one ambiguous label.

## 3. Status Model

| State | Definition | Primary label | Dot | User meaning |
|---|---|---|---|---|
| `not_installed` | `~/.mio/bin/mio-agent` missing | `Not installed` | neutral gray | Install first. |
| `installed_unloaded` | binary exists, launchd job not loaded | `Installed · stopped` | amber | Start will bootstrap the job. |
| `loaded_stopped` | job loaded, process not running | `Loaded · not running` | amber | Start will kickstart the job. |
| `starting` | install/start command in progress | `Starting...` | blue spinner | Wait; controls disabled. |
| `running_healthy` | process running + health endpoint 200 | `Running` | green | Normal. |
| `running_unhealthy` | process running but health endpoint timeout/error | `Running · health check failed` | red | Check logs; restart may help. |
| `draining` | Stop requested, IPC drain in progress | `Stopping safely...` | blue spinner | Phase 2 only; waiting for in-flight actions. |
| `stopping` | bootout in progress after drain/no-op | `Stopping...` | blue spinner | Controls disabled. |
| `error` | install/start/stop command failed | `Action failed` | red | Show controlled diagnostic and Logs link. |
| `unknown` | probe failed or data stale | `Status unknown` | gray | Refresh. |

Phase 1/now may not distinguish every state in code yet. The UI should still be designed around this model so later probes can fill it in without redesign.

## 4. Layout

Keep the existing Settings tab structure but make the hierarchy more diagnostic:

```text
Mio Agent
Local background daemon for runtime actions and status reporting.

[Overall status card]
  Running / Not installed / Health failed
  Last checked 14:32 · Refresh

[Lifecycle details]
  Binary        installed / missing
  LaunchAgent   loaded / unloaded
  Process       running / stopped
  Health        127.0.0.1:7878 reachable / unavailable
  Socket        ~/.mio/agent.sock available / pending Phase 2

[Controls]
  Install / Start / Restart / Stop
  helper text or last action message

[Logs]
  Open log file · Copy last 100 lines
  latest redacted preview, if cheap

[Unavailable / Phase 2 capabilities]
  Workroom binding · Action execution · Log streaming · Auto-upgrade
```

## 5. Status Card Copy

### Not Installed

```text
Not installed
Install the bundled mio-agent before starting local action execution.
```

Primary action: `Install`.
Secondary: none.

### Installed / Stopped

```text
Installed · stopped
The LaunchAgent is not running. Start it to prepare local action execution.
```

Primary action: `Start`.

### Running Healthy

```text
Running
mio-agent is available on this Mac.
```

Primary action: `Stop`.
Secondary: `Restart` only when Phase 2 or #74 loaded handling is stable.

### Running Unhealthy

```text
Running · health check failed
The process exists, but the local health endpoint did not respond.
```

Primary action: `Restart`.
Secondary: `Open logs`.

### Draining

```text
Stopping safely...
Waiting for in-flight actions to reach a safe stopping point.
```

Use only after real IPC drain exists. Until then, do not show this state.

### Phase 1 Stop Copy

Current no-op drain / bootout stop should use honest copy:

```text
Stopping...
The agent will be unloaded from launchd. Drain-safe stop is coming in Phase 2.
```

Do not say:

```text
Safe stop complete
All actions drained
No work in flight
```

## 6. Controls

| Control | Visible when | Enabled when | Copy / effect |
|---|---|---|---|
| `Install` | not installed | not busy | Copies bundled binary, writes plist, bootstrap. |
| `Start` | installed + not running | not busy | Bootstrap-first, fallback kickstart. |
| `Restart` | running/unhealthy or loaded | not busy | Future: kickstart loaded job. Optional for Phase 2. |
| `Stop` | running or loaded | not busy | Drain request if available, then bootout. |
| `Refresh` | always | not busy | Re-probe status. |
| `Open logs` | binary installed or log file exists | always | Reveal or open `~/.mio/agent.log`. |

### Button Hierarchy

- Primary action uses accent fill (`Install`, `Start`, `Restart` when unhealthy).
- `Stop` uses outline/destructive-tint, not full red fill unless an action is dangerous.
- `Open logs` is secondary text/icon button.
- Disabled buttons must keep readable text; use muted background rather than opacity below 0.5.

## 7. Lifecycle Detail Rows

Rows should be compact and scannable:

```text
[icon] Binary        ~/.mio/bin/mio-agent                 Installed
[icon] LaunchAgent   io.miomioos.mio-agent                Loaded
[icon] Process       pgrep mio-agent                      Running
[icon] Health        127.0.0.1:7878                       OK
[icon] Socket        ~/.mio/agent.sock                    Pending Phase 2
```

Use pill labels:

- `Installed` / `Missing`
- `Loaded` / `Unloaded`
- `Running` / `Stopped`
- `OK` / `Failed`
- `Pending` for Phase 2-only rows

Do not bury the path in a paragraph; use middle truncation for long paths.

## 8. Logs Surface

Phase 2 should add a logs card, even before live streaming:

```text
Logs
Use logs for install/start/stop diagnostics. Sensitive values are not expected here; report any token/path leak.

[Open log file] [Copy last 100 lines]
```

If a preview is shown:

- max 8 lines;
- monospace 10-11 pt;
- redacted before display if token/path patterns are known;
- never auto-upload logs.

Empty state:

```text
No agent log yet. Start the agent to create ~/.mio/agent.log.
```

Error state:

```text
Could not read log file. Check file permissions or open it in Finder.
```

## 9. Drain-Safe Stop States

Future IPC drain sequence:

1. User taps `Stop`.
2. If IPC unavailable, show Phase 1 stop confirmation/copy and proceed to bootout only if user confirms or current design allows direct stop.
3. If IPC available, enter `draining`.
4. Drain request sent to `~/.mio/agent.sock` with 8s deadline.
5. UI shows one of:
   - `No in-flight actions. Stopping...`
   - `Waiting for 1 in-flight action...`
   - `Drain deadline reached. Stopping agent; check action status in CodeLight.`
6. Bootout runs.
7. Refresh status.

Important copy rule: if drain deadline is reached, the UI must not imply all work completed safely. It should point users to CodeLight action status.

## 10. Error Copy

Keep user-facing errors controlled and actionable:

| Situation | Copy |
|---|---|
| bundled binary missing | `mio-agent was not found in the app bundle.` |
| bootstrap fails | `Could not register LaunchAgent. Check Logs for launchctl output.` |
| kickstart fails | `Could not start the loaded job. Check Logs.` |
| bootout fails | `Could not unload LaunchAgent. Refresh status or check Logs.` |
| process still running after stop | `Process still running after stop request.` |
| health failed | `Process is running, but health check failed.` |

Avoid raw shell output as primary copy. Raw exit codes may appear in a small diagnostic line, for example:

```text
launchctl bootstrap exited 5
```

Do not show secrets, tokens, or full environment dumps.

## 11. Visual Language

MioIsland Settings already uses quiet utility UI. Keep it dense and operational:

- cards: existing `SettingsCard` / `SettingsListCard` style;
- typography: small but high contrast;
- status dots: green/amber/red/gray/blue spinner;
- no mascot/illustration here;
- avoid celebratory success art; this is an operator control panel;
- use icons only to improve scanning, not decoration.

## 12. Implementation Handoff

Suggested view model fields:

```swift
struct AgentLifecycleSnapshot {
    var binaryExists: Bool
    var launchAgentLoaded: Bool?
    var processRunning: Bool
    var healthReachable: Bool
    var socketExists: Bool?
    var isBusy: Bool
    var phase: AgentLifecyclePhase
    var lastCheckedAt: Date?
    var lastActionMessage: String?
    var lastDiagnostic: String?
}
```

Suggested phase enum:

```swift
enum AgentLifecyclePhase {
    case checking
    case notInstalled
    case installedUnloaded
    case loadedStopped
    case starting
    case runningHealthy
    case runningUnhealthy
    case draining
    case stopping
    case error
    case unknown
}
```

Suggested component split:

- `AgentOverallStatusCard`
- `AgentLifecycleRows`
- `AgentControlButtons`
- `AgentLogsCard`
- `AgentPhase2CapabilitiesCard`

## 13. Screenshot Checklist

Before Phase 2 UI passes review, capture:

1. Not installed: install CTA and no Start/Stop confusion.
2. Installed stopped: Start primary, lifecycle rows show binary installed + unloaded/stopped.
3. Running healthy: green status, Stop visible, health OK.
4. Running unhealthy: red/amber status, Restart/Open logs emphasized.
5. Stopping Phase 1: no drain-safe promise.
6. Draining Phase 2 mock: waiting copy and deadline copy.
7. Logs card empty and with preview.
8. Long path truncation in binary/log rows.

## 14. Acceptance Criteria

- UI distinguishes installed, loaded, running, and healthy.
- Stop copy does not imply drain-safe behavior until IPC exists.
- Error states tell the user where to look next without dumping raw logs.
- Logs affordance is visible enough for diagnostics but does not auto-upload or expose secrets.
- Buttons remain readable when disabled.
- Phase 2-only capabilities are labeled as pending, not silently broken.
