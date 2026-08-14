#!/usr/bin/env swift
//
//  test-zombie-reconnect-policy.swift
//  Mirror test for issue #95-2: ServerConnection's zombie-socket detection.
//  Pins the intended semantics of the consecutive-ack-timeout counter +
//  forced-reconnect cooldown (threshold 3, cooldown 60s, reset on success /
//  connect / disconnect). Mirrors the logic in ServerConnection.swift —
//  keep the two in sync if the policy changes. Run: swift <thisfile>
//

import Foundation

// --- mirror of the production policy ------------------------------------

final class ZombiePolicy {
    var consecutiveAckTimeouts = 0
    var lastForcedReconnectAt: Date?
    var isConnected = true
    var reconnects = 0
    static let threshold = 3
    static let cooldown: TimeInterval = 60

    var now = Date(timeIntervalSince1970: 1_000_000)

    func recordAckResult(timedOut: Bool) {
        guard timedOut else { consecutiveAckTimeouts = 0; return }
        consecutiveAckTimeouts += 1
        if consecutiveAckTimeouts >= Self.threshold { forceReconnectIfStale() }
    }

    func forceReconnectIfStale() {
        guard isConnected else { return }
        if let last = lastForcedReconnectAt, now.timeIntervalSince(last) < Self.cooldown { return }
        lastForcedReconnectAt = now
        consecutiveAckTimeouts = 0
        reconnects += 1
    }
}

// --- assertions ----------------------------------------------------------

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print(cond ? "  ✓ \(label)" : "  ✗ FAIL: \(label)")
    if !cond { failures += 1 }
}

// 1. Two timeouts then a success never reconnects (slow server ≠ zombie).
var p = ZombiePolicy()
p.recordAckResult(timedOut: true); p.recordAckResult(timedOut: true); p.recordAckResult(timedOut: false)
p.recordAckResult(timedOut: true); p.recordAckResult(timedOut: true); p.recordAckResult(timedOut: false)
check(p.reconnects == 0, "interleaved successes keep resetting the run — no reconnect")

// 2. Three consecutive timeouts force exactly one reconnect and reset the run.
p = ZombiePolicy()
for _ in 0..<3 { p.recordAckResult(timedOut: true) }
check(p.reconnects == 1 && p.consecutiveAckTimeouts == 0, "3 consecutive timeouts → 1 forced reconnect, counter reset")

// 3. A continued timeout storm within the cooldown does NOT reconnect again.
for _ in 0..<10 { p.recordAckResult(timedOut: true) }
check(p.reconnects == 1, "storm inside 60s cooldown → still only 1 reconnect (no thrash)")

// 4. After the cooldown elapses, a fresh run of timeouts may reconnect again.
p.now = p.now.addingTimeInterval(61)
for _ in 0..<3 { p.recordAckResult(timedOut: true) }
check(p.reconnects == 2, "past cooldown, a new timeout run reconnects again")

// 5. When Socket.IO already knows we're disconnected, its own reconnection
//    owns recovery — the zombie path must stand down.
p = ZombiePolicy()
p.isConnected = false
for _ in 0..<5 { p.recordAckResult(timedOut: true) }
check(p.reconnects == 0, "not .connected → zombie path defers to library reconnection")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
