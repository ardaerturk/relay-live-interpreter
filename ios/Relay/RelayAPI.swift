import Foundation
import Security

struct RelayError: LocalizedError {
    let message: String
    let status: Int
    init(_ message: String, status: Int = 0) { self.message = message; self.status = status }
    var errorDescription: String? { message }
}

struct Device: Codable {
    let origin: URL
    let cookie: String
}

enum KeyStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "RelayInterpreter.Device",
         kSecAttrAccount as String: "current"]
    }
    static func load() -> Device? {
        var q = query; q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Device.self, from: data)
    }
    static func save(_ device: Device) throws {
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(device),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw RelayError("iOS could not save your device access.") }
    }
    static func forget() { SecItemDelete(query as CFDictionary) }
}

struct Transcript: Codable, Identifiable {
    let id: String
    let startedAt: Int64
    let seconds: Int
    let target: String
    var text: String?
    var date: Date { Date(timeIntervalSince1970: Double(startedAt) / 1000) }
    var language: String { target == "de" ? "German" : "English" }
}
struct HistoryPage: Decodable { var items: [Transcript]; let next: String? }

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum RelayAPI {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false; cfg.httpCookieStorage = nil; cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData; cfg.timeoutIntervalForRequest = 32
        return URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func parseInvite(_ input: String) throws -> (URL, String) {
        guard var c = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty, c.user == nil,
              c.password == nil, c.path.isEmpty || c.path == "/", c.query == nil,
              let fragment = c.percentEncodedFragment else { throw RelayError("Paste the full HTTPS invite link.") }
        var f = URLComponents(); f.percentEncodedQuery = fragment
        guard let token = f.queryItems?.first(where: { $0.name == "invite" })?.value,
              token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw RelayError("This link is missing a valid invitation.")
        }
        c.scheme = "https"; c.host = host.lowercased(); c.path = ""; c.fragment = nil
        if c.port == 443 { c.port = nil }
        guard let url = c.url else { throw RelayError("Invalid invite address.") }
        return (url, token)
    }

    private static func send(_ origin: URL, _ path: String, _ method: String, cookie: String? = nil,
                             body: Data? = nil, query: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents(url: origin.appendingPathComponent("api").appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!); req.httpMethod = method
        req.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        if let cookie { req.setValue("__Host-relay=" + cookie, forHTTPHeaderField: "Cookie") }
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = body }
        let (data, raw) = try await session.data(for: req)
        guard let res = raw as? HTTPURLResponse else { throw RelayError("Could not reach Relay.") }
        guard (200..<300).contains(res.statusCode) else {
            let text = (try? JSONDecoder().decode([String:String].self, from: data))?["error"]
            throw RelayError(text ?? "Relay returned HTTP \(res.statusCode).", status: res.statusCode)
        }
        return (data, res)
    }
    static func redeem(_ input: String) async throws -> Device {
        let (origin, token) = try parseInvite(input)
        let (_, res) = try await send(origin, "access", "POST", body: JSONEncoder().encode(["invite":token]))
        guard let header = res.value(forHTTPHeaderField: "Set-Cookie"),
              let cookie = HTTPCookie.cookies(withResponseHeaderFields:["Set-Cookie":header], for:origin)
                .first(where: { $0.name == "__Host-relay" && $0.isSecure }),
              cookie.value.range(of:"^[0-9a-f]{64}\\.[A-Za-z0-9_-]{43}$", options:.regularExpression) != nil
        else { throw RelayError("The server did not issue device access.") }
        return Device(origin:origin, cookie:cookie.value)
    }
    static func connect(_ d: Device, target: String, sdp: String) async throws -> String {
        let (data, _) = try await send(d.origin, "connect", "POST", cookie:d.cookie,
                                       body:JSONEncoder().encode(["target":target,"sdp":sdp]))
        guard let answer = try JSONDecoder().decode([String:String].self, from:data)["sdp"],
              answer.hasPrefix("v=0") else { throw RelayError("The interpreter returned no audio connection.") }
        return answer
    }
    static func save(_ d: Device, _ item: Transcript) async throws {
        _ = try await send(d.origin,"history","POST",cookie:d.cookie,body:JSONEncoder().encode(item))
    }
    static func history(_ d: Device, after: String?) async throws -> HistoryPage {
        let (data, _) = try await send(d.origin,"history","GET",cookie:d.cookie,query:after.map { [URLQueryItem(name:"after",value:$0)] } ?? [])
        return try JSONDecoder().decode(HistoryPage.self,from:data)
    }
    static func read(_ d: Device, _ id: String) async throws -> Transcript {
        let (data, _) = try await send(d.origin,"history","GET",cookie:d.cookie,query:[URLQueryItem(name:"id",value:id)])
        return try JSONDecoder().decode(Transcript.self,from:data)
    }
    static func delete(_ d: Device, _ id: String) async throws {
        _ = try await send(d.origin,"history","DELETE",cookie:d.cookie,query:[URLQueryItem(name:"id",value:id)])
    }
}
