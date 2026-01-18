import Foundation

// Lightweight network client for your backend.
enum HushhAPI {
    // static let base = URL(string "https://hushhvoice-1.onrender.com")!
   static let base = URL(string: "https://7def8415dc68.ngrok-free.app")!


    static let appJWT = "Bearer dev-demo-app-jwt"
    static let streamSessionToken = "dev-stream-token"
    static let enableStreaming = true

    static var streamURL: URL? {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        if comps?.scheme == "https" {
            comps?.scheme = "wss"
        } else if comps?.scheme == "http" {
            comps?.scheme = "ws"
        }
        comps?.path = "/chat/stream"
        return comps?.url
    }

    static func ask(prompt: String, googleToken: String?) async throws -> SiriAskData {
        // Build the request for the ask endpoint.
        var req = URLRequest(url: base.appendingPathComponent("/siri/ask"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("founder@hushh.ai", forHTTPHeaderField: "X-User-Email")

        var tokens: [String: Any] = ["app_jwt": appJWT]
        if let googleToken { tokens["google_access_token"] = googleToken }

        let body: [String: Any] = [
            "prompt": prompt,
            "tokens": tokens
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Perform the network call.
        let (data, resp) = try await URLSession.shared.data(for: req)

        if let http = resp as? HTTPURLResponse {
            print("🔵 /siri/ask status: \(http.statusCode)")
        } else {
            print("🔵 /siri/ask: non-HTTP response?")
        }

        if let raw = String(data: data, encoding: .utf8) {
            print("📩 RAW /siri/ask RESPONSE:\n\(raw)\n------------------------")
        } else {
            print("📩 RAW /siri/ask RESPONSE (non-UTF8, size \(data.count) bytes)")
        }

        // Validate HTTP status before decoding.
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(SiriAskResponse.self, from: data)
            let msg = decoded?.error?.message ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "HushhAPI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }

        // Decode JSON into Swift structs.
        let result = try JSONDecoder().decode(SiriAskResponse.self, from: data)

        print("🧩 Decoded SiriAskResponse.ok = \(result.ok)")
        print("🧩 Decoded SiriAskResponse.data.display = \(result.data?.display ?? "nil")")
        print("🧩 Decoded SiriAskResponse.data.speech  = \(result.data?.speech ?? "nil")")

        guard let data = result.data else {
            throw NSError(domain: "HushhAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        return data
    }

    static func tts(text: String, voice: String? = nil) async throws -> Data {
        // Request audio data from backend TTS.
        var req = URLRequest(url: base.appendingPathComponent("/tts"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["text": text]
        if let voice, !voice.isEmpty { body["voice"] = voice }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "HushhAPI.TTS", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }

        return data
    }

    static func deleteAccount(googleToken: String?, appleUserID: String?, kaiUserID: String?) async throws {
        // Tell backend to delete the account associated with tokens/IDs.
        var req = URLRequest(url: base.appendingPathComponent("/account/delete"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [:]
        if let googleToken { payload["google_access_token"] = googleToken }
        if let appleUserID, !appleUserID.isEmpty {
            payload["apple_user_id"] = appleUserID
            payload["user_id"] = appleUserID
        }
        if let kaiUserID, !kaiUserID.isEmpty {
            payload["kai_user_id"] = kaiUserID
            if payload["user_id"] == nil {
                payload["user_id"] = kaiUserID
            }
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "HushhAPI.DeleteAccount", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
