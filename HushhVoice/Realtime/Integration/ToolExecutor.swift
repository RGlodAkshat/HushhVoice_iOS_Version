import Foundation

protocol ToolExecutor {
    func execute(name: String, argsJSON: String) async throws -> String
}

struct StubToolExecutor: ToolExecutor {
    func execute(name: String, argsJSON: String) async throws -> String {
        // Stub output for now. Replace with real backend tool execution.
        return "{\"ok\":true,\"tool\":\(jsonString(name)),\"args\":\(argsJSON)}"
    }

    private func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

