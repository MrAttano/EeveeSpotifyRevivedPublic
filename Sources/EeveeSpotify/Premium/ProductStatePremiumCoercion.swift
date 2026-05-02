import Foundation

/// When bootstrap/`v1/customize` are missed (e.g. second auth lifecycle on 9.1.34+), Spotify still pushes
/// product state via `[SPTAuthSessionImplementation productStateUpdated:]`. Rewrite obvious free-tier maps.
func eeveePremiumCoercedProductStateIfNeeded(for state: AnyObject) -> (AnyObject, Bool) {
    guard UserDefaults.patchType.isPatching else { return (state, false) }
    guard let dict = state as NSDictionary else { return (state, false) }
    guard eeveeProductStateAppearsFreeTier(dict) else { return (state, false) }

    let mutable = NSMutableDictionary(dictionary: dict as NSDictionary)
    eeveeApplyPremiumProductStateKeys(to: mutable)
    eeveeStripFreeTierLeakKeys(from: mutable)
    writeDebugLog("[AUTH] Coerced free-tier productState to premium-compatible map")
    return (mutable as AnyObject, true)
}

private func eeveeNormKey(_ dict: NSDictionary, _ key: String) -> String {
    guard let v = dict[key] else { return "" }
    return String(describing: v).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func eeveeProductStateAppearsFreeTier(_ dict: NSDictionary) -> Bool {
    let t = eeveeNormKey(dict, "type")
    let catalogue = eeveeNormKey(dict, "catalogue")
    let fp = eeveeNormKey(dict, "financial-product")
    return t == "free" || catalogue == "free" || fp.contains("pr:free")
}

private func eeveeApplyPremiumProductStateKeys(to m: NSMutableDictionary) {
    let oneYearFromNow = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(abbreviation: "UTC")
    let end = formatter.string(from: oneYearFromNow)

    let z = NSNumber(value: 0), o = NSNumber(value: 1)

    m["catalogue"] = "premium"
    m["type"] = "premium"
    m["name"] = "Spotify Premium"
    m["financial-product"] = "pr:premium,tc:0"

    m["ads"] = z
    m["ab-ad-player-targeting"] = z
    m["allow-advertising-id-transmission"] = z
    m["restrict-advertising-id-transmission"] = o
    m["can_use_superbird"] = o
    m["is-eligible-premium-unboxing"] = o

    m["nft-disabled"] = "1"
    m["offline"] = o
    m["on-demand"] = o

    m["player-license"] = "premium"
    m["player-license-v2"] = "premium"

    m["payments-initial-campaign"] = "default"
    m["product-expiry"] = end
    m["subscription-enddate"] = end
    m["shuffle-eligible"] = o

    m["social-session"] = o
    m["social-session-free-tier"] = z
    m["streaming-rules"] = ""

    m["unrestricted"] = o
}

private func eeveeStripFreeTierLeakKeys(from m: NSMutableDictionary) {
    [
        "on-demand-trial", "on-demand-trial-in-progress", "smart-shuffle",
        "at-signal", "feature-set-id-masked", "strider-key",
        "payment-state", "last-premium-activation-date",
    ].forEach { m.removeObject(forKey: $0) }
}
