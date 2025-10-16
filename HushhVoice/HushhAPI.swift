import Foundation

enum HushhAPI {
    // Point this at your deployed API
    static let base = URL(string: "https://hushhvoice-1.onrender.com")!
    static let appJWT = "Bearer dev-demo-app-jwt" // TODO: replace with a real, signed app token

    /// Send a prompt to the single route. Backend returns Siri-friendly fields.
    static func ask(prompt: String, googleToken: String?) async throws -> SiriAskData {
        var req = URLRequest(url: base.appendingPathComponent("/siri/ask"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Optional identity header (if you want threading/analytics by email)
        req.setValue("founder@hushh.ai", forHTTPHeaderField: "X-User-Email")

        var tokens: [String: Any] = ["app_jwt": appJWT]
        if let googleToken { tokens["google_access_token"] = googleToken }

        let body: [String: Any] = ["prompt": prompt, "tokens": tokens]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if !(200..<300).contains(http.statusCode) {
            let decoded = try? JSONDecoder().decode(SiriAskResponse.self, from: data)
            let msg = decoded?.error?.message ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "HushhAPI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let result = try JSONDecoder().decode(SiriAskResponse.self, from: data)
        guard let data = result.data else {
            throw NSError(domain: "HushhAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        return data
    }
}



