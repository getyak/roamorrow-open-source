import Foundation

/// Account identity and refresh generation are checked across every request. No redirects or credential forwarding.
@MainActor final class TravelGatewayClient {
    struct Failure: Error { var code: String }
    private let account: EmailAccountService
    private let baseURL: URL?
    private let transport: URLSession
    init(account: EmailAccountService = .shared, baseURL: URL? = Secrets.resolvedHarnessBaseURL(), transport: URLSession = AccountHTTP.transport()) {
        self.account = account; self.baseURL = baseURL.flatMap { TravelerHarnessClient.validatedOrigin($0.absoluteString) }; self.transport = transport
    }
    func call(_ path: String, method: String = "GET", body: TravelJSON? = nil, publicSource: Bool = false) async throws -> TravelJSON {
        guard let baseURL else { throw Failure(code: "provider_unavailable") }
        guard !publicSource || path == "public-source" && method == "POST" else { throw Failure(code: "permission_required") }
        let expected = account.identity
        let token: String?
        if publicSource { token = nil }
        else {
            guard expected != nil else { throw Failure(code: "permission_required") }
            token = try await account.accessToken()
            guard account.identity == expected else { throw Failure(code: "scope_changed") }
        }
        let generation = account.generation
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/travel").appendingPathComponent(path), timeoutInterval: 20)
        request.httpMethod = method; request.httpBody = try body.map { try JSONEncoder().encode($0) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard account.identity == expected, account.generation == generation else { throw Failure(code: "scope_changed") }
        guard data.count <= 512_000, let http = response as? HTTPURLResponse else { throw Failure(code: "invalid_response") }
        let result = try? JSONDecoder().decode(TravelJSON.self, from: data)
        guard (200..<300).contains(http.statusCode), let result else {
            let code = result?["error"]["code"].string ?? ""
            throw Failure(code: ["permission_required", "version_conflict", "proposal_expired", "digest_mismatch", "idempotency_conflict", "operation_uncertain", "capability_unsupported", "not_found"].contains(code) ? code : "provider_unavailable")
        }
        return result
    }
}
