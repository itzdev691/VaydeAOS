import Foundation

public struct ConnectionSettings: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable {
        case compatibleAPI
        case chatGPT
        /// Compatibility spelling for callers of the initial runtime integration.
        public static var codex: Self { .chatGPT }
        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            if value == "codex" { self = .chatGPT }
            else if let provider = Self(rawValue: value) { self = provider }
            else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown provider")) }
        }
    }
    public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
        case automatic, none, minimal, low, medium, high, xhigh, max

        public var label: String {
            switch self {
            case .automatic: return "Auto"
            case .xhigh: return "Extra high"
            default: return rawValue.capitalized
            }
        }

        /// Omit the parameter in Auto so each model keeps its own default.
        public var requestValue: String? { self == .automatic ? nil : rawValue }
    }
    public var baseURL: String
    public var model: String
    public var provider: Provider
    public var chatGPTModel: String?
    public var reasoningEffort: ReasoningEffort
    public var codexModel: String
    public var codexWorkspace: String
    public var codexAllowsWrites: Bool
    private var chatGPTConnectionVersion = 2
    public var needsChatGPTAccountReview = false
    public var activeModel: String {
        switch provider {
        case .chatGPT: return selectedChatGPTModel.isEmpty ? "ChatGPT default" : selectedChatGPTModel
        case .compatibleAPI: return model
        }
    }
    public var connectionLabel: String {
        switch provider {
        case .chatGPT: return "ChatGPT / agent runtime"
        case .compatibleAPI: return baseURL
        }
    }
    public var selectedChatGPTModel: String { chatGPTModel ?? codexModel }

    public static let local = ConnectionSettings(
        baseURL: "http://127.0.0.1:11434/v1",
        model: "qwen3.5:9b"
    )

    public init(baseURL: String, model: String, provider: Provider = .compatibleAPI, chatGPTModel: String? = nil,
                reasoningEffort: ReasoningEffort = .automatic, codexModel: String = "",
                codexWorkspace: String = "", codexAllowsWrites: Bool = false) {
        self.baseURL = baseURL
        self.model = model
        self.provider = provider
        self.chatGPTModel = chatGPTModel
        self.reasoningEffort = reasoningEffort
        self.codexModel = codexModel
        self.codexWorkspace = codexWorkspace
        self.codexAllowsWrites = codexAllowsWrites
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL, model, provider, chatGPTModel, reasoningEffort, codexModel, codexWorkspace, codexAllowsWrites, chatGPTConnectionVersion, needsChatGPTAccountReview
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        model = try values.decode(String.self, forKey: .model)
        let savedProvider = try values.decodeIfPresent(String.self, forKey: .provider)
        provider = try values.decodeIfPresent(Provider.self, forKey: .provider) ?? .compatibleAPI
        chatGPTModel = try values.decodeIfPresent(String.self, forKey: .chatGPTModel)
        reasoningEffort = try values.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort) ?? .automatic
        codexModel = try values.decodeIfPresent(String.self, forKey: .codexModel) ?? ""
        codexWorkspace = try values.decodeIfPresent(String.self, forKey: .codexWorkspace) ?? ""
        codexAllowsWrites = try values.decodeIfPresent(Bool.self, forKey: .codexAllowsWrites) ?? false
        let version = try values.decodeIfPresent(Int.self, forKey: .chatGPTConnectionVersion) ?? 1
        needsChatGPTAccountReview = try values.decodeIfPresent(Bool.self, forKey: .needsChatGPTAccountReview) ?? false
        if savedProvider == "chatGPT" && version < 2 {
            codexAllowsWrites = false
            needsChatGPTAccountReview = true
        }
        if savedProvider == "codex" {
            // The former runtime choice owned this model; the helper model may be stale.
            chatGPTModel = codexModel.isEmpty ? nil : codexModel
        }
    }

    public func validated() throws -> ConnectionSettings {
        if provider == .chatGPT {
            var result = self
            result.codexModel = selectedChatGPTModel.trimmingCharacters(in: .whitespacesAndNewlines)
            result.chatGPTModel = result.codexModel.isEmpty ? nil : result.codexModel
            if let api = try? ConnectionSettings(baseURL: baseURL, model: model).validated() {
                result.baseURL = api.baseURL; result.model = api.model
            }
            guard !result.codexModel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  (codexWorkspace.isEmpty ? !codexAllowsWrites : codexWorkspace.hasPrefix("/")),
                  !codexWorkspace.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ConnectionSettingsError.invalidWorkspace
            }
            // An unselected folder uses the app's private chat workspace.
            if codexWorkspace.isEmpty { return result }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: codexWorkspace, isDirectory: &directory), directory.boolValue else {
                throw ConnectionSettingsError.invalidWorkspace
            }
            result.codexWorkspace = URL(fileURLWithPath: codexWorkspace).resolvingSymlinksInPath().path
            return result
        }
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let planModel = chatGPTModel?.trimmingCharacters(in: .whitespacesAndNewlines)

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
        return ConnectionSettings(baseURL: normalizedURL, model: selectedModel, provider: provider,
                                  chatGPTModel: planModel, reasoningEffort: reasoningEffort,
                                  codexModel: codexModel, codexWorkspace: codexWorkspace, codexAllowsWrites: codexAllowsWrites)
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
    case invalidWorkspace

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid API base URL without credentials, a query, or a fragment."
        case .insecureURL:
            return "Remote APIs require HTTPS. HTTP is allowed only for a loopback address."
        case .missingModel:
            return "Enter a model name without control characters."
        case .invalidWorkspace:
            return "Choose an existing workspace folder and a model name without control characters."
        }
    }
}
