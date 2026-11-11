import Foundation
import Security

public struct HTTPResult {
    public let status: Int
    public let value: Any?
    public var json: JSON { object(value) }
    public init(_ status: Int, _ value: Any? = nil) { self.status = status; self.value = value }
}
public typealias LocalAPI = (_ method: String, _ route: String, _ body: JSON?, _ lockfile: URL) -> HTTPResult

private final class LoopbackDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.host == "127.0.0.1", request.url?.scheme == "https", request.url?.port == task.originalRequest?.url?.port else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

public final class HTTPClient {
    private let remote = URLSession(configuration: .ephemeral)
    private let loopback: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        loopback = URLSession(configuration: configuration, delegate: LoopbackDelegate(), delegateQueue: nil)
    }
    private func request(_ request: URLRequest, session: URLSession) throws -> HTTPResult {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ResultBox<HTTPResult>()
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { result.store(.failure(error)); return }
            let value = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            result.store(.success(HTTPResult((response as? HTTPURLResponse)?.statusCode ?? 0, value)))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + request.timeoutInterval + 2) == .timedOut {
            task.cancel()
            throw LauncherError("The Riot request timed out.")
        }
        return try result.get()
    }
    public func json(_ url: URL) throws -> JSON {
        try require(url.scheme == "https", "The Riot service URL is invalid.")
        var query = URLRequest(url: url, timeoutInterval: 15)
        query.setValue("TFT-Live-Launcher/1.1", forHTTPHeaderField: "User-Agent")
        let response = try request(query, session: remote)
        try require(response.status == 200, "The Riot service returned HTTP \(response.status).")
        return response.json
    }
    public func local(_ method: String, _ route: String, _ body: JSON?, _ lockfile: URL) -> HTTPResult {
        do {
            let fields = try readText(lockfile).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ":")
            guard fields.count >= 5, let port = Int(fields[2]), (1...65535).contains(port), fields[4] == "https",
                  route.hasPrefix("/"), let url = URL(string: "https://127.0.0.1:\(port)" + route) else { return HTTPResult(0) }
            var query = URLRequest(url: url, timeoutInterval: 5)
            query.httpMethod = method
            query.setValue("Basic " + Data(("riot:" + fields[3]).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            if let body { query.httpBody = try jsonData(body); query.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            return try request(query, session: loopback)
        } catch { return HTTPResult(0) }
    }
}

public struct Release: Equatable {
    public let manifest: String
    public let version: String
}
public func publishedRelease(platform: String, channel: String, fetch: (URL) throws -> JSON) throws -> Release {
    try require(matches(channel, "live-[A-Z0-9]+"), "The requested TFT channel is invalid.")
    let url = URL(string: "https://sieve.services.riotcdn.net/api/v1/products/teamfighttactics/version-sets/" + channel
                  + "?q%5Bartifact_type_id%5D=client&q%5Bplatform%5D=" + platform + "&q%5Bpublished%5D=true")!
    let releases = objects(try fetch(url)["releases"])
    try require(releases.count == 1, "The live channel does not identify a unique release.")
    let release = releases[0]
    let labels = object(object(release["release"])["labels"])
    let versions = object(labels["riot:artifact_version_id"])["values"] as? [String] ?? []
    try require(object(labels["riot:platform"])["values"] as? [String] == [platform]
                && object(labels["riot:artifact_type_id"])["values"] as? [String] == ["client"], "The published release does not match the requested client.")
    try require(versions.count == 1 && !versions[0].isEmpty && text(object(release["compat_version"])["id"]) == versions[0],
                "The published release and its compatibility version do not match.")
    let download = object(release["download"])
    let manifest = text(download["url"])
    try require(matches(manifest, "https://teamfighttactics\\.secure\\.dyn\\.riotcdn\\.net/channels/public/releases/[A-Fa-f0-9]{16}\\.manifest"), "The TFT manifest is not from the expected official channel.")
    try require(download["scd_required"] as? Bool != true, "The TFT manifest requires private access.")
    return Release(manifest: manifest, version: versions[0])
}
