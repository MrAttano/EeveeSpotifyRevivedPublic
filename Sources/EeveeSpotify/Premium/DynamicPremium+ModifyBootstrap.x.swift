import Orion

private func showHavePremiumPopUp() {
    PopUpHelper.showPopUp(
        delayed: true,
        message: "have_premium_popup".localized,
        buttonText: "OK".uiKitLocalized
    )
}

class SpotifySessionDelegateBootstrapHook: ClassHook<NSObject>, SpotifySessionDelegate {
    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "SPTCoreURLSessionDataDelegate"
        default: return "SPTDataLoaderService"
        }
    }
    
    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: HTTPURLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
    }
    
    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard 
            let request = task.currentRequest,
            let url = request.url
        else {
            return
        }
        
        if url.isBootstrap {
            writeDebugLog("Bootstrap didReceiveData: \(url.absoluteString) (+\(data.count) bytes)")
            URLSessionHelper.shared.setOrAppend(data, for: url)
            return
        }

        orig.URLSession(session, dataTask: task, didReceiveData: data)
    }
    
    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        guard
            let request = task.currentRequest,
            let url = request.url
        else {
            return
        }
        
        if error == nil && url.isBootstrap {
            let buffer = URLSessionHelper.shared.obtainData(for: url)!
            writeDebugLog("Bootstrap buffer size: \(buffer.count) bytes")
            
            do {
                var bootstrapMessage = try BootstrapMessage(serializedBytes: buffer)
                
                if UserDefaults.patchType == .notSet {
                    if bootstrapMessage.attributes["type"]?.stringValue == "premium" {
                        UserDefaults.patchType = .disabled
                        writeDebugLog("Bootstrap first-time: account type=premium")
                        showHavePremiumPopUp()
                    }
                    else {
                        UserDefaults.patchType = .requests
                        let accountType = bootstrapMessage.attributes["type"]?.stringValue ?? "unknown"
                        writeDebugLog("Bootstrap first-time: account type=\(accountType)")
                        writeDebugLog("Bootstrap: patchType set to .requests")
                        activatePremiumPatchingGroup()
                    }
                    
                }
                
                if UserDefaults.patchType == .requests {
                    writeDebugLog("Bootstrap: modifying response to premium")
                    modifyRemoteConfiguration(&bootstrapMessage.ucsResponse)
                    
                    orig.URLSession(
                        session,
                        dataTask: task,
                        didReceiveData: try bootstrapMessage.serializedBytes()
                    )
                    writeDebugLog("Bootstrap: premium response sent successfully")
                }
                else {
                    orig.URLSession(session, dataTask: task, didReceiveData: buffer)
                }
                
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            catch {
            }
        }
        
        orig.URLSession(session, task: task, didCompleteWithError: error)
    }
}
