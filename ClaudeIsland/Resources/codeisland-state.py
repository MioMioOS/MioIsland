#!/usr/bin/env python3
"""
Code Island Hook
- Sends session state to CodeIsland.app via Unix socket
- For PermissionRequest: waits for user decision from the app
"""
import json
import os
import socket
import sys

SOCKET_PATH = "/tmp/codeisland.sock"
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    import subprocess

    # Get parent PID (Claude process)
    ppid = os.getppid()

    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            # ps returns just "ttys001", we need "/dev/ttys001"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def detect_terminal_app():
    """Detect terminal from environment variables — more reliable than process tree on macOS."""
    env = os.environ
    # Check multiplexers first (innermost layer)
    if env.get("ZELLIJ") is not None:   # ZELLIJ key present (value may be "0")
        return "Zellij"
    if env.get("TMUX"):
        return "tmux"
    # Then outer terminal emulator
    if env.get("GHOSTTY_RESOURCES_DIR") or env.get("TERM_PROGRAM") == "ghostty":
        return "Ghostty"
    if env.get("ITERM_SESSION_ID") or env.get("LC_TERMINAL") == "iTerm2":
        return "iTerm2"
    term = env.get("TERM_PROGRAM", "").lower()
    if term == "apple_terminal":
        return "Terminal"
    if "warp" in term:
        return "Warp"
    if "wezterm" in term:
        return "WezTerm"
    if "vscode" in term:
        return "VS Code"
    if env.get("CMUX_SOCKET_PATH"):
        return "cmux"
    return None


def send_event(state):
    """Send event to app, return response if any"""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())

        # For permission requests, wait for response
        if state.get("status") == "waiting_for_approval":
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()

        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


def _is_parent_codex():
    """Check if the parent process is the Codex CLI (not Claude Code)."""
    import subprocess
    try:
        result = subprocess.run(
            ["ps", "-p", str(os.getppid()), "-o", "comm="],
            capture_output=True, text=True, timeout=2
        )
        return "codex" in result.stdout.strip().lower()
    except Exception:
        return False


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")

    # Filter out probe/telemetry sessions from third-party tools (e.g. CodexBar)
    PROBE_MARKERS = ["ClaudeProbe", "CodexBar"]
    if any(marker in cwd for marker in PROBE_MARKERS):
        sys.exit(0)
    tool_input = data.get("tool_input", {})

    # Detect Codex. Payload fields like "model"/"permission_mode" exist on
    # both CLIs, so:
    #   1) transcript_path under ~/.codex/ is definitive — and keeps working
    #      when Codex spawns hooks through a shell wrapper, where the
    #      parent-process check sees "sh" instead of "codex" (issue #84);
    #   2) otherwise fall back to the parent process name.
    transcript_path = data.get("transcript_path", "") or ""
    is_codex = "/.codex/" in transcript_path or _is_parent_codex()

    # Get process info
    claude_pid = os.getppid()
    tty = get_tty()

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
    }

    # Capture cmux identity from our own environment.
    # The hook script is a direct child of claude, which inherited these env
    # vars from the cmux shell. We're the only reliable way to read them —
    # `ps -E` on macOS hides env vars of hardened-runtime processes even to the
    # same user, so CodeIsland can't fetch them after the fact.
    cmux_workspace_id = os.environ.get("CMUX_WORKSPACE_ID")
    cmux_surface_id = os.environ.get("CMUX_SURFACE_ID")
    if cmux_workspace_id:
        state["cmux_workspace_id"] = cmux_workspace_id
    if cmux_surface_id:
        state["cmux_surface_id"] = cmux_surface_id

    # For non-Codex sessions, send env-detected terminal as a hint for Swift fallback
    if not is_codex:
        terminal_hint = detect_terminal_app()
        if terminal_hint:
            state["terminal_app"] = terminal_hint

    # For Codex sessions, pass source marker and transcript path
    if is_codex:
        state["source"] = "codex"
        if transcript_path:
            state["transcript_path"] = transcript_path

    # Map events to status
    if event == "UserPromptSubmit":
        # User just sent a message - Claude is now processing
        state["status"] = "processing"

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionRequest":
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # tool_use_id lookup handled by Swift-side cache from PreToolUse

        # AskUserQuestion: don't block — let Claude Code show its own
        # permission prompt. The question UI is handled by PreToolUse.
        if data.get("tool_name") == "AskUserQuestion":
            sys.exit(0)

        # Other tools: send to app and wait for decision
        state["status"] = "waiting_for_approval"
        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                # Output JSON to approve
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                # Output JSON to deny
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via CodeIsland",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "SubagentStop":
        # SubagentStop fires when a subagent completes - usually means back to waiting
        state["status"] = "waiting_for_input"

    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"

    elif event == "PreCompact":
        # Context is being compacted (manual or auto)
        state["status"] = "compacting"

    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    send_event(state)


if __name__ == "__main__":
    main()
