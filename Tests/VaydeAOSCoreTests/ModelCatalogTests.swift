import Foundation
import Testing
@testable import VaydeAOSCore

struct ModelSelectionTests {
    @Test func accountDefaultUsesTheSameResolutionAndCapabilitiesAsRuntime() throws {
        let options = [ModelOption(id: "first"), ModelOption(id: "default", name: "Default model",
            reasoningEfforts: [.low, .high], defaultEffort: .high, isDefault: true)]
        let settings = ConnectionSettings(baseURL: "", model: "", provider: .chatGPT)
        let selection = ModelSelection(settings: settings, models: options)
        #expect(selection.resolvedModel?.id == "default")
        #expect(selection.displayName == "Default model (account default)")
        #expect(selection.availableEfforts == [.automatic, .low, .high])
        #expect(selection.hint.contains("High"))
        #expect(ModelSelection(settings: settings, models: Array(options.prefix(1))).resolvedModel?.id == "first")
        #expect(ModelSelection(settings: settings, models: nil).displayName == "Account default (unresolved)")
    }

    @Test func unsupportedSavedEffortAndMissingModelsAreFlaggedWithoutSubstitution() {
        var settings = ConnectionSettings.local
        settings.model = "limited"; settings.reasoningEffort = .max
        let options = [ModelOption(id: "limited", reasoningEfforts: [.low, .high])]
        let selection = ModelSelection(settings: settings, models: options)
        #expect(selection.issue?.contains("unsupported") == true)
        #expect(selection.settings.reasoningEffort == .max)
        settings.model = "missing"
        #expect(ModelSelection(settings: settings, models: options).modelIssue?.contains("missing") == true)
        #expect(ModelSelection(settings: settings, models: nil).modelIssue == nil)
        #expect(ModelSelection(settings: settings, models: []).modelIssue != nil)
    }

    @Test func unknownCapabilitiesRemainDistinctFromNoReasoningSupport() {
        var settings = ConnectionSettings.local; settings.reasoningEffort = .high
        let unknown = ModelSelection(settings: settings, models: [ModelOption(id: settings.model)])
        #expect(unknown.availableEfforts == [.automatic])
        #expect(unknown.issue == nil)
        #expect(unknown.hint.contains("unverified"))
        let unsupported = ModelSelection(settings: settings, models: [ModelOption(id: settings.model, reasoningEfforts: [])])
        #expect(unsupported.availableEfforts == [.automatic])
        #expect(unsupported.issue != nil)
        #expect(unsupported.hint.contains("no configurable"))
    }

    @Test func providerDefinedReasoningLevelsRoundTripAndAreOfferedOnlyWhenAdvertised() throws {
        let custom = try #require(ConnectionSettings.ReasoningEffort(rawValue: "adaptive"))
        var settings = ConnectionSettings.local; settings.reasoningEffort = custom
        let restored = try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.reasoningEffort == custom)
        let selection = ModelSelection(settings: settings,
            models: [ModelOption(id: settings.model, reasoningEfforts: [.high, custom, .high, .ultra])])
        #expect(selection.availableEfforts == [.automatic, .high, .ultra, custom])
        #expect(selection.issue == nil)
        #expect(ConnectionSettings.ReasoningEffort(rawValue: "injected\nvalue") == nil)
    }
}

@MainActor
@Suite("Model selection and discovery")
final class ModelCatalogTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test func composerChangesPersistPerChatAndKnownInvalidSettingsCannotSend() async throws {
        let catalog = APIModelCatalog(client: FixedModelCatalog())
        let client = ModelChatClient()
        let session = ChatSession(client: client, store: LocalStore(directory: directory),
                                  credentials: CatalogCredentials(), apiModels: catalog)
        await session.refreshModels()
        session.draft = "Keep this prompt"
        #expect(!session.canSend) // The saved local model is absent from this test catalog.
        try session.selectModel("reasoner")
        try session.setReasoningEffort(.high)
        let first = session.selectedChatID
        session.newChat()
        try session.selectModel("plain")
        #expect(session.settings.reasoningEffort == .high)
        #expect(session.modelSelection.issue != nil)
        session.draft = "Second prompt"; session.send()
        #expect(await client.requests.isEmpty)
        #expect(session.draft == "Second prompt")
        #expect(throws: ModelSelectionError.self) { try session.setReasoningEffort(.low) }
        try session.setReasoningEffort(.automatic)
        #expect(session.canSend)
        session.send(); await session.sendTask?.value
        #expect(await client.requests == ["plain"])
        session.selectChat(first)
        #expect(session.settings.model == "reasoner")
        #expect(session.settings.reasoningEffort == .high)
        #expect(session.draft == "Keep this prompt")
        #expect(session.canSend)
        let restored = ChatSession(store: LocalStore(directory: directory), credentials: CatalogCredentials())
        #expect(restored.settings.model == "reasoner")
        #expect(restored.settings.reasoningEffort == .high)
    }

    @Test func lateDiscoveryCannotReplaceANewerCredentialScopeOrEndpoint() async throws {
        let client = DeferredModelCatalog()
        let catalog = APIModelCatalog(client: client)
        let settings = ConnectionSettings.local
        let old = Task { await catalog.refresh(settings: settings, apiKey: "old") }
        try await waitForRequests(1, client: client)
        catalog.invalidate(settings)
        let fresh = Task { await catalog.refresh(settings: settings, apiKey: "new") }
        try await waitForRequests(2, client: client)
        await client.finish(1, models: [ModelOption(id: "new-model")]); await fresh.value
        await client.finish(0, models: [ModelOption(id: "old-model")]); await old.value
        #expect(catalog.state(for: settings).models?.map(\.id) == ["new-model"])
        let other = ConnectionSettings(baseURL: "https://other.example/v1", model: "other")
        #expect(catalog.state(for: other).models == nil)
        #expect(!catalog.state(for: settings).isLoading)
    }

    @Test func discoveryFailureRetainsManualSelectionAndCanBeRetried() async throws {
        let catalog = APIModelCatalog(client: FailingModelCatalog())
        let session = ChatSession(store: LocalStore(directory: directory), credentials: CatalogCredentials(), apiModels: catalog)
        let original = session.settings
        await session.refreshModels()
        #expect(session.settings == original)
        #expect(session.modelSelection.models == nil)
        #expect(session.modelSelection.hint.contains("discovery"))
        session.draft = "Manual model request"
        #expect(session.canSend)
        try session.selectModel("manual-model")
        #expect(session.settings.model == "manual-model")
        #expect(session.modelSelection.availableEfforts == [.automatic])
    }

    private func waitForRequests(_ count: Int, client: DeferredModelCatalog) async throws {
        let deadline = Date().addingTimeInterval(3)
        while await client.count < count {
            guard Date() < deadline else { throw ModelSelectionError("Timed out waiting for discovery") }
            await Task.yield()
        }
    }
}

private struct FixedModelCatalog: ModelCatalogServing {
    func models(settings: ConnectionSettings, apiKey: String?) async throws -> [ModelOption] {
        [ModelOption(id: "reasoner", reasoningEfforts: [.low, .high]), ModelOption(id: "plain", reasoningEfforts: [])]
    }
}
private struct FailingModelCatalog: ModelCatalogServing {
    func models(settings: ConnectionSettings, apiKey: String?) async throws -> [ModelOption] {
        throw ModelSelectionError("Model discovery unavailable")
    }
}
private actor DeferredModelCatalog: ModelCatalogServing {
    private var pending: [CheckedContinuation<[ModelOption], Never>] = []
    var count: Int { pending.count }
    func models(settings: ConnectionSettings, apiKey: String?) async throws -> [ModelOption] {
        await withCheckedContinuation { pending.append($0) }
    }
    func finish(_ index: Int, models: [ModelOption]) { pending[index].resume(returning: models) }
}
private actor ModelChatClient: ChatServing {
    var requests: [String] = []
    func reply(to messages: [ChatMessage], settings: ConnectionSettings, apiKey: String?) async throws -> String {
        requests.append(settings.model); return "Reply"
    }
}
private struct CatalogCredentials: CredentialStoring {
    func load(for endpoint: String) throws -> String? { nil }
    func save(_ key: String, for endpoint: String) throws { }
}
