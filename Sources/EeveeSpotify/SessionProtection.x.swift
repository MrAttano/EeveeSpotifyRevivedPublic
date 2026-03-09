import Orion
import Foundation

// MARK: - Session Logout Protection
// Hooks all logout-related methods to prevent Spotify from logging out
// when it detects the account isn't actually premium.
// Also intercepts Ably WebSocket messages to block server-side revocation events.
// Additionally blocks network endpoints that trigger session invalidation.
// Extends OAuth token expiry to prevent internal reauth triggers.

struct SessionLogoutHookGroup: HookGroup { }

// MARK: - SPTAuthSessionImplementation — Core Session Hooks

class SPTAuthSessionHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutHookGroup
    static let targetName = "SPTAuthSessionImplementation"

    // orion:new
    static var allowLogout = false

    func logout() {
        if SPTAuthSessionHook.allowLogout {
            writeDebugLog("✅ Logout allowed (user-initiated)")
            orig.logout()
        } else {
            writeDebugLog("🚫 BLOCKED: SPTAuthSessionImplementation.logout")
        }
    }

    // The MAIN logout entry point — logoutWithReason: is what's actually called
    // when the session is detected as invalid/expired
    func logoutWithReason(_ reason: AnyObject) {
        if SPTAuthSessionHook.allowLogout {
            writeDebugLog("✅ logoutWithReason allowed (user-initiated): \(reason)")
            orig.logoutWithReason(reason)
        } else {
            writeDebugLog("🚫 BLOCKED: SPTAuthSessionImplementation.logoutWithReason: \(reason)")
        }
    }

    // Block the delegate notification that triggers downstream logout cascade
    func callSessionDidLogoutOnDelegateWithReason(_ reason: AnyObject) {
        if SPTAuthSessionHook.allowLogout {
            writeDebugLog("✅ callSessionDidLogoutOnDelegate allowed (user-initiated)")
            orig.callSessionDidLogoutOnDelegateWithReason(reason)
        } else {
            writeDebugLog("🚫 BLOCKED: SPTAuthSessionImplementation.callSessionDidLogoutOnDelegateWithReason: \(reason)")
        }
    }

    // Block analytics logging for logout events
    func logWillLogoutEventWithLogoutReason(_ reason: AnyObject) {
        if SPTAuthSessionHook.allowLogout {
            orig.logWillLogoutEventWithLogoutReason(reason)
        } else {
            writeDebugLog("🚫 BLOCKED: SPTAuthSessionImplementation.logWillLogoutEventWithLogoutReason")
        }
    }

    // Block session destruction — log call stack to trace what triggers it
    func destroy() {
        if SPTAuthSessionHook.allowLogout {
            writeDebugLog("✅ Session destroy allowed (user-initiated)")
            orig.destroy()
        } else {
            let elapsed = Date().timeIntervalSince(tweakInitTime)
            let stack = Thread.callStackSymbols.prefix(15).joined(separator: "\n  ")
            writeDebugLog("🚫 BLOCKED: SPTAuthSessionImplementation.destroy at \(Int(elapsed))s\n  Stack:\n  \(stack)")
        }
    }

    // Log product state updates — these may trigger "free" detection
    func productStateUpdated(_ state: AnyObject) {
        let elapsed = Date().timeIntervalSince(tweakInitTime)
        writeDebugLog("📊 productStateUpdated at \(Int(elapsed))s: \(state)")
        orig.productStateUpdated(state)
    }

    // Log tryReconnect calls — these may trigger re-auth
    func tryReconnect(_ arg1: AnyObject, toAP arg2: AnyObject) {
        let elapsed = Date().timeIntervalSince(tweakInitTime)
        writeDebugLog("🔄 tryReconnect:toAP: called at \(Int(elapsed))s")
        orig.tryReconnect(arg1, toAP: arg2)
    }
}

// MARK: - SessionServiceImpl (Connectivity_SessionImpl module)

class SessionServiceImplHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutHookGroup
    static let targetName = "_TtC24Connectivity_SessionImpl18SessionServiceImpl"

    func automatedLogoutThenLogin() {
        writeDebugLog("🚫 BLOCKED: SessionServiceImpl.automatedLogoutThenLogin")
    }

    func userInitiatedLogout() {
        // The C++ timer calls this via Swift vtable dispatch, NOT from the main thread.
        // Real user taps go through the main thread. Only allow if on main thread.
        if Thread.isMainThread {
            SPTAuthSessionHook.allowLogout = true
            writeDebugLog("⚠️ User-initiated logout from main thread - allowing")
            orig.userInitiatedLogout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                SPTAuthSessionHook.allowLogout = false
            }
        } else {
            let elapsed = Date().timeIntervalSince(tweakInitTime)
            writeDebugLog("🚫 BLOCKED: SessionServiceImpl.userInitiatedLogout from BACKGROUND thread at \(Int(elapsed))s")
        }
    }

    func sessionDidLogout(_ session: AnyObject, withReason reason: AnyObject) {
        if SPTAuthSessionHook.allowLogout {
            writeDebugLog("✅ sessionDidLogout allowed (user-initiated)")
            orig.sessionDidLogout(session, withReason: reason)
        } else {
            writeDebugLog("🚫 BLOCKED: SessionServiceImpl.sessionDidLogout:withReason: reason=\(reason)")
        }
    }
}

// MARK: - SPTAuthLegacyLoginControllerImplementation

class LegacyLoginControllerHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutHookGroup
    static let targetName = "SPTAuthLegacyLoginControllerImplementation"

    func sessionDidLogout(_ session: AnyObject, withReason reason: AnyObject) {
        if SPTAuthSessionHook.allowLogout {
            writeDebugLog("✅ Legacy sessionDidLogout allowed (user-initiated)")
            orig.sessionDidLogout(session, withReason: reason)
        } else {
            writeDebugLog("🚫 BLOCKED: LegacyLoginController.sessionDidLogout:withReason: reason=\(reason)")
        }
    }

    // Block session destruction through legacy controller
    func destroySession() {
        if SPTAuthSessionHook.allowLogout {
            writeDebugLog("✅ destroySession allowed (user-initiated)")
            orig.destroySession()
        } else {
            writeDebugLog("🚫 BLOCKED: LegacyLoginController.destroySession")
        }
    }

    // Block credential erasure
    func forgetStoredCredentials() {
        if SPTAuthSessionHook.allowLogout {
            writeDebugLog("✅ forgetStoredCredentials allowed (user-initiated)")
            orig.forgetStoredCredentials()
        } else {
            writeDebugLog("🚫 BLOCKED: LegacyLoginController.forgetStoredCredentials")
        }
    }

    // Block session invalidation through legacy controller
    func invalidate() {
        if SPTAuthSessionHook.allowLogout {
            writeDebugLog("✅ invalidate allowed (user-initiated)")
            orig.invalidate()
        } else {
            writeDebugLog("🚫 BLOCKED: LegacyLoginController.invalidate")
        }
    }
}

// MARK: - OauthAccessTokenBridge — Extend token expiry
// This private class inside Connectivity_SessionImpl controls the OAuth token's
// expiry time. By hooking expiresAt to return a far-future date, we prevent
// the internal timer from marking the token as expired.

class OauthAccessTokenBridgeHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutHookGroup
    static let targetName = "_TtC24Connectivity_SessionImplP33_831B98CC28223E431E21CD27ADD20AF222OauthAccessTokenBridge"

    // Hook the GETTER
    func expiresAt() -> Any {
        let farFuture = Date(timeIntervalSinceNow: 365 * 24 * 60 * 60)
        return farFuture
    }

    // Hook the SETTER — replace with far-future at storage time
    func setExpiresAt(_ date: Any) {
        let farFuture = Date(timeIntervalSinceNow: 365 * 24 * 60 * 60)
        let elapsed = Date().timeIntervalSince(tweakInitTime)
        writeDebugLog("🔑 OauthAccessTokenBridge.setExpiresAt called at \(Int(elapsed))s — original: \(date), replacing with far-future")
        orig.setExpiresAt(farFuture)
    }

    // Hook init to directly modify the ivar using ObjC runtime
    // This catches cases where C++ sets the ivar without going through the ObjC setter
    func `init`() -> NSObject? {
        let result = orig.`init`()
        extendExpiryIvar()
        // Also start a repeating timer to keep extending the ivar
        startExpiryExtender()
        return result
    }

    // orion:new
    func extendExpiryIvar() {
        let bridgeClass: AnyClass = type(of: target)
        if let ivar = class_getInstanceVariable(bridgeClass, "expiresAt") {
            let farFuture = Date(timeIntervalSinceNow: 365 * 24 * 60 * 60)
            object_setIvar(target, ivar, farFuture)
        }
    }

    // orion:new
    func startExpiryExtender() {
        let weak = target
        let elapsed = Date().timeIntervalSince(tweakInitTime)
        writeDebugLog("🔑 OauthAccessTokenBridge.init at \(Int(elapsed))s — starting expiry extender")
        // Extend the ivar every 60 seconds
        DispatchQueue.global(qos: .utility).async {
            while true {
                Thread.sleep(forTimeInterval: 60)
                guard let obj = weak as? NSObject else { break }
                let cls: AnyClass = type(of: obj)
                if let ivar = class_getInstanceVariable(cls, "expiresAt") {
                    let farFuture = Date(timeIntervalSinceNow: 365 * 24 * 60 * 60)
                    object_setIvar(obj, ivar, farFuture)
                }
            }
        }
    }
}



// NOTE: ColdStartupTimeKeeperImplementation is a pure Swift class (not NSObject).
// Cannot hook it with Orion — crashes with targetHasIncompatibleType.
// NOTE: executeBlockRunner on SPTAsyncNativeTimerManagerThreadImpl is too broad —
// blocking it kills ALL timers including playback advancement.

// MARK: - Ably WebSocket Transport Hooks
// Intercepts Ably real-time messages to block server-side logout/revocation events

// Blocked Ably protocol actions:
// 5=disconnect, 6=disconnected, 7=close, 8=closed, 9=error, 12=detach, 13=detached, 17=auth
private let blockedAblyActions: Set<Int> = [5, 6, 7, 8, 9, 12, 13, 17]
private var seenAblyActions = Set<Int>()

private func extractAblyAction(_ text: String) -> Int? {
    guard let range = text.range(of: "\"action\":") else { return nil }
    let afterAction = text[range.upperBound...]
    let digits = afterAction.prefix(while: { $0.isNumber })
    return Int(digits)
}

class ARTWebSocketTransportHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutHookGroup
    static let targetName = "ARTWebSocketTransport"

    func webSocket(_ ws: AnyObject, didReceiveMessage message: AnyObject) {
        if let msgString = message as? String {
            if let action = extractAblyAction(msgString) {
                if blockedAblyActions.contains(action) {
                    writeDebugLog("🚫 Ably action \(action) blocked")
                    return
                }
                // Log first occurrence of each allowed action
                if seenAblyActions.insert(action).inserted {
                    writeDebugLog("📡 Ably action \(action) seen (allowed)")
                }
            }
        }
        orig.webSocket(ws, didReceiveMessage: message)
    }

    func webSocket(_ ws: AnyObject, didFailWithError error: AnyObject) {
        writeDebugLog("🚫 Ably WebSocket failure suppressed: \(error)")
    }
}

// MARK: - Ably SRWebSocket Frame Hook

class ARTSRWebSocketHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutHookGroup
    static let targetName = "ARTSRWebSocket"

    func _handleFrameWithData(_ data: NSData, opCode code: Int) {
        if code == 1,
           let text = String(data: data as Data, encoding: .utf8) {
            if let action = extractAblyAction(text) {
                if blockedAblyActions.contains(action) {
                    writeDebugLog("🚫 Ably frame blocked (action \(action))")
                    return
                }
            }
        }
        orig._handleFrameWithData(data, opCode: code)
    }
}

// MARK: - Global URLSessionTask hook to catch auth traffic bypassing SPTDataLoaderService

class URLSessionTaskResumeHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutHookGroup
    static let targetName = "NSURLSessionTask"

    func resume() {
        if let task = target as? URLSessionTask,
           let url = task.currentRequest?.url ?? task.originalRequest?.url,
           let host = url.host?.lowercased() {

            let elapsed = Date().timeIntervalSince(tweakInitTime)
            let path = url.path

            // After initial startup (30s), block login5 re-auth requests.
            if elapsed > 30 {
                if host.contains("login5") {
                    writeDebugLog("🚫 [GLOBAL] BLOCKED login5 re-auth at \(Int(elapsed))s")
                    return
                }
                // Block Google OAuth token refresh (feeds into login5 v4)
                if host.contains("googleapis.com") && path.contains("/token") {
                    writeDebugLog("🚫 [GLOBAL] BLOCKED Google OAuth refresh at \(Int(elapsed))s")
                    return
                }
            }

            // Block outgoing DeleteToken/signup requests at network level
            if host.contains("spotify") || host.contains("spclient") {
                if path.contains("DeleteToken") {
                    writeDebugLog("🚫 [GLOBAL] BLOCKED outgoing DeleteToken request")
                    return
                }
                if path.contains("signup/public") {
                    writeDebugLog("🚫 [GLOBAL] BLOCKED outgoing AccountValidate request")
                    return
                }
                if path.contains("pses/screenconfig") {
                    writeDebugLog("🚫 [GLOBAL] BLOCKED PSES screenconfig request")
                    return
                }
                // Block bootstrap re-fetch after initial startup
                if elapsed > 30 && path.contains("bootstrap/v1/bootstrap") {
                    writeDebugLog("🚫 [GLOBAL] BLOCKED bootstrap re-fetch at \(Int(elapsed))s")
                    return
                }
                // Block apresolve after initial startup (precedes reinit)
                if elapsed > 30 && host.contains("apresolve") {
                    writeDebugLog("🚫 [GLOBAL] BLOCKED apresolve at \(Int(elapsed))s")
                    return
                }
            }

            // Log any Spotify request NOT going through spclient (which is already logged)
            if host.contains("spotify") && !host.contains("spclient") && !host.contains("spotifycdn") &&
               !url.path.hasPrefix("/image/") {
                writeDebugLog("📡 [GLOBAL] \(task.currentRequest?.httpMethod ?? "?") \(host)\(url.path)")
            }
            // Also log any auth-related request regardless of host
            let pathLower = url.path.lowercased()
            if pathLower.contains("auth") || pathLower.contains("token") || pathLower.contains("login") || pathLower.contains("session") {
                if !host.contains("spclient") {
                    writeDebugLog("📡 [AUTH] \(task.currentRequest?.httpMethod ?? "?") \(host)\(url.path)")
                }
            }
        }
        orig.resume()
    }
}


