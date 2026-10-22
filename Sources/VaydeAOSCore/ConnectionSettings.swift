import Foundation

public struct ConnectionSettings: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String

    public static let local = ConnectionSettings(
        baseURL: "http://127.0.0.1:11434/v1",
        model: "qwen3.5:9b"
    )

    public init(baseURL: String, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    public func validated() throws -> ConnectionSettings {
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !selectedModel.isEmpty,
              !selectedModel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ConnectionSettingsError.missingModel
        }

        guard !endpoint.isEmpty,
              !endpoint.contains("\\"),
              !endpoint.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }),
              var components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let originalHost = components.host,
              !originalHost.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.url != nil else {
            throw ConnectionSettingsError.invalidURL
        }

        let host = originalHost.lowercased()
        guard host != ".", host != "..",
              !host.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ConnectionSettingsError.invalidURL
        }

        if scheme == "http" && !Self.isLoopback(host) {
            throw ConnectionSettingsError.insecureURL
        }

        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }

        guard let normalizedURL = components.url?.absoluteString else {
            throw ConnectionSettingsError.invalidURL
        }
        return ConnectionSettings(baseURL: normalizedURL, model: selectedModel)
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" {
            return true
        }

        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.first == "127" else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy({ $0.isASCII && $0.isNumber })
                && Int(part).map({ (0...255).contains($0) }) == true
        }
    }
}

public enum ConnectionSettingsError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case insecureURL
    case missingModel

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid API base URL without credentials, a query, or a fragment."
        case .insecureURL:
            return "Remote APIs require HTTPS. HTTP is allowed only for a loopback address."
        case .missingModel:
            return "Enter a model name without control characters."
        }
    }
}
