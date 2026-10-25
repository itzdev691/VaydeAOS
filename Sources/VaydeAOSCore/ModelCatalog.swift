import Combine
import Foundation

public struct ModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// Nil means unreported; an empty list means no explicit effort is supported.
    public let reasoningEfforts: [ConnectionSettings.ReasoningEffort]?
    public let defaultEffort: ConnectionSettings.ReasoningEffort?
    public let isDefault: Bool

    public init(id: String, name: String? = nil,
                reasoningEfforts: [ConnectionSettings.ReasoningEffort]? = nil,
                defaultEffort: ConnectionSettings.ReasoningEffort? = nil, isDefault: Bool = false) {
        self.id = id; self.name = name ?? id; self.reasoningEfforts = reasoningEfforts
        self.defaultEffort = defaultEffort; self.isDefault = isDefault
    }
}

/// One policy drives the composer, settings, sidebar, and runtime preflight.
public struct ModelSelection: Sendable {
    public let settings: ConnectionSettings
    public let models: [ModelOption]?
    public let catalogError: String?

    public init(settings: ConnectionSettings, models: [ModelOption]?, catalogError: String? = nil) {
        self.settings = settings; self.models = models; self.catalogError = catalogError
    }
    public var selectedID: String {
        settings.provider == .chatGPT ? settings.selectedChatGPTModel : settings.model
    }
    public var resolvedModel: ModelOption? {
        if settings.provider == .chatGPT && selectedID.isEmpty {
            return models?.first(where: \.isDefault) ?? models?.first
        }
        return models?.first { $0.id == selectedID }
    }
    public var displayName: String {
        if settings.provider == .chatGPT && selectedID.isEmpty {
            return resolvedModel.map { "\($0.name) (account default)" } ?? "Account default (unresolved)"
        }
        return resolvedModel?.name ?? settings.activeModel
    }
    public var availableEfforts: [ConnectionSettings.ReasoningEffort] {
        let supported = resolvedModel?.reasoningEfforts ?? []
        let known = ConnectionSettings.ReasoningEffort.allCases.filter {
            $0 != .automatic && supported.contains($0)
        }
        var result: [ConnectionSettings.ReasoningEffort] = [.automatic] + known
        for effort in supported where !result.contains(effort) { result.append(effort) }
        return result
    }
    public var modelIssue: String? {
        guard models != nil, resolvedModel == nil else { return nil }
        return selectedID.isEmpty ? "The model catalog is empty. Refresh models before sending."
            : "\(selectedID) is not in this connection's model catalog. Refresh or select another model."
    }
    public var issue: String? {
        if let modelIssue { return modelIssue }
        if settings.reasoningEffort != .automatic, let efforts = resolvedModel?.reasoningEfforts,
           !efforts.contains(settings.reasoningEffort) {
            return "\(settings.reasoningEffort.label) reasoning is unsupported by \(resolvedModel?.name ?? selectedID). Choose a supported level or Auto."
        }
        return nil
    }
    public var hint: String {
        if let catalogError { return catalogError + " Refresh models; manual API identifiers remain available when discovery is unsupported." }
        if models == nil { return "Refresh models to verify availability and reasoning support." }
        guard let model = resolvedModel else { return "Select a model from this connection's catalog." }
        guard let efforts = model.reasoningEfforts else {
            return "Reasoning support is unreported. Auto leaves the provider default unchanged; saved explicit levels are unverified."
        }
        if efforts.isEmpty { return "This model reports no configurable reasoning levels. Use Auto." }
        return model.defaultEffort.map { "Auto uses the reported default: \($0.label)." }
            ?? "Auto uses the model default. Only reported reasoning levels are offered."
    }
}

public struct ModelSelectionError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public protocol ModelCatalogServing: Sendable {
    func models(settings: ConnectionSettings, apiKey: String?) async throws -> [ModelOption]
}

/// GET /models is shared by compatible APIs and Ollama; no inference request is made.
public struct ModelCatalogClient: ModelCatalogServing {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func models(settings: ConnectionSettings, apiKey: String?) async throws -> [ModelOption] {
        var connection = settings
        connection.provider = .compatibleAPI
        connection.model = "discovery"
        connection = try connection.validated()
        var components = URLComponents(string: connection.baseURL + "/models")!
        var result: [ModelOption] = []
        var seen: Set<String> = []
        var cursors: Set<String> = []
        for _ in 0..<20 {
            try Task.checkCancellation()
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                guard !key.unicodeScalars.contains(where: {
                    CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                }) else { throw ChatClientError.invalidAPIKey }
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.data(for: request, delegate: PrivateRequestDelegate()) }
            catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw ModelSelectionError("Model discovery could not reach the API. Check the endpoint and connection.")
            }
            guard let http = response as? HTTPURLResponse else { throw ChatClientError.malformedResponse }
            guard (200...299).contains(http.statusCode) else {
                // Do not display provider bodies, which may echo keys or request details.
                throw ModelSelectionError("Model discovery returned HTTP \(http.statusCode). Check the endpoint and credentials.")
            }
            guard data.count <= 4 * 1024 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["data"] as? [[String: Any]] else { throw ChatClientError.malformedResponse }
            for row in rows {
                guard let id = row["id"] as? String, !id.isEmpty,
                      !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw ChatClientError.malformedResponse
                }
                guard seen.insert(id).inserted else { continue }
                // Optional compatible-server extensions; absent metadata remains unknown.
                let efforts = (row["supported_reasoning_efforts"] as? [String])?.compactMap {
                    ConnectionSettings.ReasoningEffort(rawValue: $0)
                }
                let defaultEffort = (row["default_reasoning_effort"] as? String).flatMap {
                    ConnectionSettings.ReasoningEffort(rawValue: $0)
                }
                result.append(ModelOption(id: id, name: row["display_name"] as? String,
                    reasoningEfforts: efforts, defaultEffort: defaultEffort))
            }
            guard object["has_more"] as? Bool == true else { return result }
            guard let cursor = (object["last_id"] as? String) ?? (rows.last?["id"] as? String),
                  cursors.insert(cursor).inserted else { throw ChatClientError.malformedResponse }
            components.queryItems = [URLQueryItem(name: "after", value: cursor)]
        }
        throw ModelSelectionError("The model catalog exceeded the discovery limit. Narrow the provider catalog and refresh.")
    }
}

@MainActor
public final class APIModelCatalog: ObservableObject {
    public struct State: Sendable {
        public var models: [ModelOption]?
        public var error: String?
        public var isLoading = false
    }
    @Published private var states: [String: State] = [:]
    private var tokens: [String: UUID] = [:]
    private let client: any ModelCatalogServing
    public init(client: any ModelCatalogServing = ModelCatalogClient()) { self.client = client }

    private func key(_ settings: ConnectionSettings) -> String {
        (try? ConnectionSettings(baseURL: settings.baseURL, model: "discovery").validated().baseURL) ?? settings.baseURL
    }
    public func state(for settings: ConnectionSettings) -> State { states[key(settings)] ?? State() }
    public func invalidate(_ settings: ConnectionSettings) {
        let endpoint = key(settings)
        tokens[endpoint] = UUID()
        states.removeValue(forKey: endpoint)
    }
    public func reportError(_ message: String, for settings: ConnectionSettings) {
        let endpoint = key(settings)
        tokens[endpoint] = UUID()
        states[endpoint] = State(error: message)
    }
    public func refresh(settings: ConnectionSettings, apiKey: String?, force: Bool = false) async {
        let endpoint = key(settings)
        let previous = state(for: settings)
        guard !previous.isLoading, force || (previous.models == nil && previous.error == nil) else { return }
        let token = UUID(); tokens[endpoint] = token
        states[endpoint] = State(models: previous.models, isLoading: true)
        do {
            let models = try await client.models(settings: settings, apiKey: apiKey)
            try Task.checkCancellation()
            guard tokens[endpoint] == token else { return }
            states[endpoint] = State(models: models)
        } catch {
            guard tokens[endpoint] == token else { return }
            states[endpoint] = State(models: previous.models,
                error: error is CancellationError ? nil : error.localizedDescription)
        }
    }
}
