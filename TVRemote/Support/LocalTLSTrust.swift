import Foundation

/// Accepts a TV's self-signed certificate for a local-network connection.
///
/// `NSAllowsLocalNetworking` in Info.plist lets the local socket through App
/// Transport Security. URLSession still asks the delegate before it will use
/// a certificate the system does not trust. WebSocket handshakes deliver that
/// ask to the task delegate, so both entry points have to accept it.
enum LocalNetworkTrust {
    static func handle(
        _ challenge: URLAuthenticationChallenge,
        expectedHost: String,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              accepts(challenge.protectionSpace.host, expectedHost: expectedHost) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    static func accepts(_ presentedHost: String, expectedHost: String) -> Bool {
        let presented = presentedHost.lowercased()
        let expected = expectedHost.lowercased()
        if presented == expected { return true }
        return isLocal(presented) && isLocal(expected)
    }

    static func isLocal(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if name == "localhost" || name.hasSuffix(".local") { return true }
        if name.contains(":") {
            return name == "::1" || name.hasPrefix("fe80:") || name.hasPrefix("fd")
        }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }
}

/// Accepts the TV's self-signed certificate only for the host we dialed.
final class LocalTLSTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    var host: String

    init(host: String) {
        self.host = host
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        LocalNetworkTrust.handle(challenge, expectedHost: host, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        LocalNetworkTrust.handle(challenge, expectedHost: host, completionHandler: completionHandler)
    }
}
