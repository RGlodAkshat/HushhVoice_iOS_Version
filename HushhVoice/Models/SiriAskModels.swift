import Foundation

// Decoding models for the /siri/ask API response.
struct SiriAskResponse: Decodable {
    let ok: Bool
    let data: SiriAskData?
    let error: SiriAskError?
}

struct SiriAskData: Decodable {
    let speech: String?
    let display: String?
    let open_url: String?
}

struct SiriAskError: Decodable {
    let message: String?
}
