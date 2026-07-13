//
//  SubscriptionState.swift
//  ClaudeIsland
//
//  Server-truth subscription state. Mirrors what iPhone reads from
//  GET /v1/subscription/status, so the Mac and iPhone show the same
//  number for the same trial. Replaces the legacy "lastRedemption"
//  pattern as the source of truth for the Pair Phone banner — but
//  RedemptionRecord stays around as a "just-now" local cache so the
//  banner shows instantly after a redeem, even before the server
//  socket roundtrip lands.
//
//  Two ingestion paths:
//    1. GET /v1/subscription/status response (initial fetch on connect)
//    2. socket "subscription-updated" event payload (server-pushed
//       updates from IAP renewal, admin grant, redeem-code completion)
//
//  Both paths produce the same SubscriptionState. Server contract pins
//  the field names (status, expiresAt, daysLeft, source).
//

import Foundation

struct SubscriptionState: Codable, Equatable {
    enum Status: String, Codable {
        case trial      // time-limited, expiresAt is meaningful
        case active     // permanent (lifetime IAP) or rolling subscription
        case expired    // past expiry, no access
        case none       // never had / cancelled / pre-F4 short-circuit
    }

    let status: Status
    /// Absolute expiry time. nil for `.active` (lifetime) and `.none`.
    let expiresAt: Date?
    /// Server-computed days left. Prefer this over local math when
    /// available — server clock is the truth, avoids ceil/floor drift
    /// between Mac and iPhone showing the same trial.
    let daysLeft: Int?
    /// "redeem_code" | "iap" | "free_trial" | nil. Optional, only the
    /// socket event includes this field; GET /status omits it.
    let source: String?

    /// True when this state grants access (banner-relevant). The Pair
    /// Phone surface uses this as the gate: if not active, no banner.
    var isActive: Bool {
        switch status {
        case .trial:
            // Trial requires a future expiry. Server may forget to set
            // it, in which case we err on showing the banner — better
            // to leak one frame than hide a paid-up user.
            return expiresAt.map { $0 > Date() } ?? true
        case .active:
            return true
        case .expired, .none:
            return false
        }
    }

    /// Number to display in the banner. Server-computed daysLeft wins;
    /// local compute kicks in only when server omits it (e.g., the
    /// post-redeem path constructs SubscriptionState from a
    /// RedemptionRecord that has expiresAt but no daysLeft pre-set).
    var daysLeftDisplay: Int {
        if let d = daysLeft { return d }
        guard let exp = expiresAt else { return 0 }
        let secs = exp.timeIntervalSince(Date())
        guard secs > 0 else { return 0 }
        return max(1, Int(ceil(secs / 86400)))
    }

    /// Short locale-aware expiry date — "5月15日" / "May 15". Used in the
    /// status banner alongside the days-left number. Empty string when
    /// expiresAt is nil (lifetime / none / expired-with-no-record).
    var formattedExpiry: String {
        guard let exp = expiresAt else { return "" }
        let f = DateFormatter()
        f.locale = L10n.isChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        f.setLocalizedDateFormatFromTemplate("Md")
        return f.string(from: exp)
    }
}

// MARK: - JSON ingestion (server payloads)

extension SubscriptionState {
    /// Build from either:
    ///   - GET /v1/subscription/status response body (uses `reason`)
    ///   - socket "subscription-updated" event payload (uses `source`)
    /// Two ingest paths use different field names for the same concept,
    /// per server doc section 2.5. We normalise to a single `source`
    /// value so downstream code (and any "继承自 iPhone" UI hint) only
    /// has one truth field to consult.
    init?(serverPayload dict: [String: Any]) {
        guard let raw = dict["status"] as? String,
              let parsed = Status(rawValue: raw) else {
            return nil
        }
        self.status = parsed
        if let str = dict["expiresAt"] as? String,
           let date = SubscriptionState.parseISO8601(str) {
            self.expiresAt = date
        } else {
            self.expiresAt = nil
        }
        // Server uses Int. Be tolerant of doubles in case some
        // serialization layer in the chain converted, e.g. JS clients.
        if let i = dict["daysLeft"] as? Int {
            self.daysLeft = i
        } else if let d = dict["daysLeft"] as? Double {
            self.daysLeft = Int(d)
        } else {
            self.daysLeft = nil
        }
        // Prefer socket's `source` field. When fetching GET /status, the
        // server gives `reason` instead — translate so this Mac always
        // knows whether the trial came from Mac-self redeem or was
        // inherited from a linked iPhone, regardless of ingest path.
        if let socketSource = dict["source"] as? String {
            self.source = socketSource
        } else if let reason = dict["reason"] as? String {
            self.source = SubscriptionState.mapReasonToSource(reason)
        } else {
            self.source = nil
        }
    }

    /// GET /v1/subscription/status `reason` → unified `source` semantic.
    /// Server values per doc 2.5 (+ ISS-06 server fix, 2026-07):
    ///   `mac_redeemed`               → this Mac activated a code itself
    ///   `inherited_from_phone`       → trial belongs to a linked iPhone
    ///   `inherited_from_phone_paid`  → linked iPhone owns the lifetime IAP
    ///   `mac_device`                 → status:'none' short-circuit
    /// Prefix-match the inherited family so future server variants
    /// (e.g. `_paid`) keep tagging correctly. Anything else maps to nil —
    /// caller treats unknown source as "no special tag" rather than guessing.
    private static func mapReasonToSource(_ reason: String) -> String? {
        if reason.hasPrefix("inherited_from_phone") { return "inherited" }
        switch reason {
        case "mac_redeemed": return "redeem_code"
        case "mac_device":   return nil
        default:             return nil
        }
    }

    /// Construct from a RedemptionRecord — used right after a
    /// successful redeem so the banner shows the new trial without
    /// waiting for the server's socket push or a refetch round-trip.
    init(fromRedemption record: RedemptionRecord) {
        self.status = .trial
        self.expiresAt = record.expiresAt
        // Compute locally — by construction we don't have a
        // server-provided number yet. Once the socket event arrives
        // the next moment, this gets overwritten with the server
        // number, which is fine: same trial, same expiresAt, same N.
        let secs = record.expiresAt.timeIntervalSince(Date())
        self.daysLeft = secs > 0 ? max(1, Int(ceil(secs / 86400))) : 0
        self.source = "redeem_code"
    }

    /// Try ISO8601 with fractional seconds first (server emits
    /// "2026-05-08T03:00:00.514Z" — `.withFractionalSeconds` accepts
    /// *any* milliseconds value, not just `.000`), fall back to plain
    /// for forward-compat if the server ever drops the fractional part.
    private static func parseISO8601(_ raw: String) -> Date? {
        if let d = iso8601Fractional.date(from: raw) { return d }
        return iso8601Plain.date(from: raw)
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
