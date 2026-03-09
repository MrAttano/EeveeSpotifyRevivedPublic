import Foundation
import Orion

// Global variable for access token
public var spotifyAccessToken: String?

// Global counters for debugging 9.1.6
private var totalRequests = 0
private var lyricsRequests = 0
private var lastPopupTime: Date?
private var capturedURLs: [String] = []
private var isCapturingURLs = false

// --- Full URL logging for logout diagnosis ---
private var allRequestLog: [(Date, String, Int)] = []  // (time, path, statusCode)
private let logStartTime = Date()

// Helper function to start capturing from other files
func DataLoaderServiceHooks_startCapturing() {
    isCapturingURLs = true
    capturedURLs.removeAll()
}

class SPTDataLoaderServiceHook: ClassHook<NSObject>, SpotifySessionDelegate {
    static let targetName = "SPTDataLoaderService"

    // orion:new
    static var cachedCustomizeData: Data?

    // orion:new
    static var handledCustomizeTasks = Set<Int>()

    // orion:new
    func shouldBlock(_ url: URL) -> Bool {
        return url.isDeleteToken || url.isAccountValidate || url.isOndemandSelector
            || url.isTrialsFacade || url.isPremiumMarketing || url.isPendragonFetchMessageList
            || url.isSessionInvalidation || url.isPushkaTokens
    }

    // orion:new
    func shouldModify(_ url: URL) -> Bool {
        let shouldPatchPremium = BasePremiumPatchingGroup.isActive
        let shouldReplaceLyrics = BaseLyricsGroup.isActive
        
        let isLyricsURL = url.isLyrics
        if isLyricsURL {
        }
        
        return (shouldReplaceLyrics && isLyricsURL)
            || (shouldPatchPremium && (url.isCustomize || url.isPremiumPlanRow || url.isPremiumBadge || url.isPlanOverview))
    }
    
    // orion:new
    func respondWithCustomData(_ data: Data, task: URLSessionDataTask, session: URLSession) {
        orig.URLSession(session, dataTask: task, didReceiveData: data)
    }

    // orion:new
    func handleBlockedEndpoint(_ url: URL, task: URLSessionDataTask, session: URLSession) {
        if url.isDeleteToken {
            writeDebugLog("🚫 DeleteToken BLOCKED — returning fake success")
            respondWithCustomData(Data(), task: task, session: session)
        } else if url.isAccountValidate {
            writeDebugLog("🚫 AccountValidate BLOCKED — returning cached status")
            let response = "{\"status\":1,\"country\":\"US\",\"is_country_launched\":true}".data(using: .utf8)!
            respondWithCustomData(response, task: task, session: session)
        } else if url.isOndemandSelector {
            writeDebugLog("🚫 OndemandSelector: replaced with empty proto")
            respondWithCustomData(Data(), task: task, session: session)
        } else if url.isTrialsFacade {
            writeDebugLog("🚫 TrialsFacade: replaced with NOT_ELIGIBLE")
            let response = "{\"result\":\"NOT_ELIGIBLE\"}".data(using: .utf8)!
            respondWithCustomData(response, task: task, session: session)
        } else if url.isPremiumMarketing {
            writeDebugLog("🚫 PremiumMarketing: replaced with {}")
            respondWithCustomData("{}".data(using: .utf8)!, task: task, session: session)
        } else if url.isPendragonFetchMessageList {
            writeDebugLog("🚫 Pendragon FetchMessageList: blocked — sending empty response")
            respondWithCustomData(Data(), task: task, session: session)
        } else if url.isPushkaTokens {
            writeDebugLog("🚫 PushkaTokens BLOCKED: \(url.path)")
            respondWithCustomData(Data(), task: task, session: session)
        } else if url.isSessionInvalidation {
            writeDebugLog("🚫 SessionInvalidation BLOCKED: \(url.path)")
            respondWithCustomData(Data(), task: task, session: session)
        }
        orig.URLSession(session, task: task, didCompleteWithError: nil)
    }
    
    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        // Capture authorization token from any request
        if let request = task.currentRequest,
           let headers = request.allHTTPHeaderFields,
           let auth = headers["Authorization"] ?? headers["authorization"],
           auth.hasPrefix("Bearer ") {
            spotifyAccessToken = String(auth.dropFirst(7))
        }

        // Log HTTP errors that could trigger session invalidation
        if let httpResponse = task.response as? HTTPURLResponse,
           let url = task.currentRequest?.url {
            let status = httpResponse.statusCode
            // Log ALL requests with their status codes for logout diagnosis
            let path = url.path
            let elapsed = Int(Date().timeIntervalSince(logStartTime))
            if status >= 400 {
                writeDebugLog("🌐 [\(elapsed)s] HTTP \(status) \(url.host ?? "")\(path)")
            } else {
                // Log all requests but with compact format to avoid log bloat
                writeDebugLog("🌐 [\(elapsed)s] \(status) \(path)")
            }
            if status == 401 || status == 403 {
                writeDebugLog("⚠️ HTTP \(status) on \(path) — potential session trigger")
            }
        } else if let url = task.currentRequest?.url {
            // No HTTP response (possibly failed)
            let path = url.path
            let elapsed = Int(Date().timeIntervalSince(logStartTime))
            if let error = error {
                writeDebugLog("🌐 [\(elapsed)s] FAIL \(path) — \(error.localizedDescription)")
            } else {
                writeDebugLog("🌐 [\(elapsed)s] ??? \(path)")
            }
        }

        // Log request headers FIRST for ALL requests to lyrics endpoints
        if let url = task.currentRequest?.url, url.absoluteString.contains("lyrics") {
            if let request = task.currentRequest {
                if let headers = request.allHTTPHeaderFields {
                    for (key, value) in headers {
                        if key.lowercased().contains("auth") || key.lowercased().contains("token") || 
                           key.lowercased() == "user-agent" || key.lowercased() == "client-token" ||
                           key.lowercased() == "spotify-app-version" {
                        }
                    }
                } else {
                }
            } else {
            }
        }
        
        guard let url = task.currentRequest?.url else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }
        
        // Capture ALL URLs when debugging
        if isCapturingURLs && capturedURLs.count < 50 {
            capturedURLs.append(url.absoluteString)
            
            // After 15 requests, show popup with summary
            if capturedURLs.count == 15 {
                isCapturingURLs = false
                DispatchQueue.main.async {
                    let hasLyrics = capturedURLs.contains { $0.lowercased().contains("lyric") }
                    let hasColor = capturedURLs.contains { $0.contains("color") }
                    let hasSuno = capturedURLs.contains { $0.contains("suno") }
                    let hasApi = capturedURLs.contains { $0.contains("api.spotify") || $0.contains("spclient") }
                    
                    let message = """
                    Captured 15 requests:
                    
                    'lyric': \(hasLyrics ? "YES ✅" : "NO ❌")
                    'color': \(hasColor ? "YES" : "NO")
                    'suno': \(hasSuno ? "YES" : "NO")
                    Spotify API: \(hasApi ? "YES" : "NO")
                    
                    \(hasLyrics ? "Found lyrics URLs!" : "NO lyrics URLs.\n9.1.6 uses pre-loaded lyrics data.")
                    
                    All URLs logged to console.
                    """
                    
                    PopUpHelper.showPopUp(message: message, buttonText: "OK")
                }
            }
        }
        
        // C
        
        // Count all requests for debugging
        totalRequests += 1
        
        // Debug: Log all URLs that contain "lyric" (case insensitive)
        let urlString = url.absoluteString.lowercased()
        if urlString.contains("lyric") {
            lyricsRequests += 1
            
            // Show popup for first lyrics request
            if lyricsRequests == 1, let lastTime = lastPopupTime, Date().timeIntervalSince(lastTime) > 10 || lastPopupTime == nil {
                lastPopupTime = Date()
                DispatchQueue.main.async {
                    PopUpHelper.showPopUp(
                        message: "🎵 FOUND LYRICS REQUEST!\n\nURL: \(url.absoluteString)\n\n9.1.6 DOES make network requests for lyrics!",
                        buttonText: "OK"
                    )
                }
            }
        }
        
        // Also check for color-lyrics specifically
        if url.path.contains("color-lyrics") || url.path.contains("lyrics") {
        }
        
        // Handle blocked endpoints (session protection)
        if shouldBlock(url) {
            handleBlockedEndpoint(url, task: task, session: session)
            return
        }

        // Handle customize 304 that was already served in didReceiveResponse
        if SPTDataLoaderServiceHook.handledCustomizeTasks.remove(task.taskIdentifier) != nil {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        guard error == nil, shouldModify(url) else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }
        
        
        // Log headers RIGHT HERE where we know code executes
        if url.isLyrics, let request = task.currentRequest {
            if let headers = request.allHTTPHeaderFields {
                for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                    let truncated = value.count > 80 ? "\(value.prefix(80))..." : value
                }
            }
        }
        
        guard let buffer = URLSessionHelper.shared.obtainData(for: url) else {
            // Customize 304 fallback: serve cached modified data when no buffer available
            if url.isCustomize, let cached = SPTDataLoaderServiceHook.cachedCustomizeData {
                writeDebugLog("Customize: using cached modified response (no buffer)")
                respondWithCustomData(cached, task: task, session: session)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            }
            return
        }
        
        
        do {
            if url.isLyrics {
                
                let originalLyrics = try? Lyrics(serializedBytes: buffer)
                
                // Try to fetch custom lyrics with a timeout
                let semaphore = DispatchSemaphore(value: 0)
                var customLyricsData: Data?
                var customLyricsError: Error?
                
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        customLyricsData = try getLyricsDataForCurrentTrack(
                            url.path,
                            originalLyrics: originalLyrics
                        )
                    } catch {
                        customLyricsError = error
                    }
                    semaphore.signal()
                }
                
                // Wait up to 5 seconds for custom lyrics (cached LRCLIB responses are instant)
                let timeout = DispatchTime.now() + .milliseconds(5000)
                let result = semaphore.wait(timeout: timeout)
                
                if result == .success, let data = customLyricsData {
                    respondWithCustomData(data, task: task, session: session)
                    
                    // Show popup indicating custom lyrics source - DISABLED FOR PRODUCTION
                    // DispatchQueue.main.async {
                    //     PopUpHelper.showPopUp(
                    //         message: "🎵 Using \(UserDefaults.lyricsSource.description) lyrics",
                    //         buttonText: "OK"
                    //     )
                    // }
                    
                    // Complete the request
                    orig.URLSession(session, task: task, didCompleteWithError: nil)
                } else {
                    if result == .timedOut {
                    } else {
                    }
                    respondWithCustomData(buffer, task: task, session: session)
                    
                    // Show popup indicating fallback to original - DISABLED FOR PRODUCTION
                    // DispatchQueue.main.async {
                    //     PopUpHelper.showPopUp(
                    //         message: result == .timedOut ? "⏱️ Using Spotify Original (timeout)" : "🎵 Using Spotify Original",
                    //         buttonText: "OK"
                    //     )
                    // }
                    
                    // Complete the request
                    orig.URLSession(session, task: task, didCompleteWithError: nil)
                }
                return
            }
            
            if url.isPremiumPlanRow {
                respondWithCustomData(
                    try getPremiumPlanRowData(
                        originalPremiumPlanRow: try PremiumPlanRow(serializedBytes: buffer)
                    ),
                    task: task,
                    session: session
                )
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            
            if url.isPremiumBadge {
                respondWithCustomData(try getPremiumPlanBadge(), task: task, session: session)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            
            if url.isCustomize {
                var customizeMessage = try CustomizeMessage(serializedBytes: buffer)
                modifyRemoteConfiguration(&customizeMessage.response)
                let modifiedData = try customizeMessage.serializedData()
                SPTDataLoaderServiceHook.cachedCustomizeData = modifiedData
                writeDebugLog("Customize: modified and delivered successfully")
                respondWithCustomData(modifiedData, task: task, session: session)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            
            if url.isPlanOverview {
                respondWithCustomData(try getPlanOverviewData(), task: task, session: session)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
        }
        catch {
            orig.URLSession(session, task: task, didCompleteWithError: error)
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: HTTPURLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // Log 401/403 responses that could trigger session invalidation
        if response.statusCode == 401 || response.statusCode == 403 {
            let urlPath = task.currentRequest?.url?.path ?? "unknown"
            writeDebugLog("⚠️ HTTP \(response.statusCode) response on: \(urlPath)")
        }

        // Handle customize 304 — prevent free-account data leaking from URLSession cache
        if let url = task.currentRequest?.url, url.isCustomize, response.statusCode == 304 {
            if let cached = SPTDataLoaderServiceHook.cachedCustomizeData {
                writeDebugLog("Customize: 304 intercepted, serving cached modified response")
                let fakeResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:])!
                orig.URLSession(session, dataTask: task, didReceiveResponse: fakeResponse, completionHandler: handler)
                respondWithCustomData(cached, task: task, session: session)
                SPTDataLoaderServiceHook.handledCustomizeTasks.insert(task.taskIdentifier)
                return
            }
        }

        guard
            let url = task.currentRequest?.url,
            url.isLyrics,
            response.statusCode != 200
        else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        do {
            let data = try getLyricsDataForCurrentTrack(url.path)
            let okResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:])!
            
            orig.URLSession(session, dataTask: task, didReceiveResponse: okResponse, completionHandler: handler)
            respondWithCustomData(data, task: task, session: session)
        } catch {
            orig.URLSession(session, task: task, didCompleteWithError: error)
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard let url = task.currentRequest?.url else {
            return
        }

        // Suppress data for blocked endpoints (prevent original data from reaching handler)
        if shouldBlock(url) {
            return
        }

        if shouldModify(url) {
            URLSessionHelper.shared.setOrAppend(data, for: url)
            return
        }

        orig.URLSession(session, dataTask: task, didReceiveData: data)
    }
}
