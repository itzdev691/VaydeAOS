import Foundation
import SwiftUI
import VaydeAOSCore

@MainActor
final class PublicAPIStatus: ObservableObject {
    @Published private(set) var history: [OpenAIStatusSample] = []
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var feedFailed = false
    private let client = OpenAIStatusClient()

    var snapshot: OpenAIStatusSnapshot? { history.last?.snapshot }

    func isStale(at date: Date) -> Bool {
        feedFailed || lastSuccess.map { date.timeIntervalSince($0) > 150 } ?? true
    }

    /// The view owns cancellation; hidden/background dashboards stop polling.
    func poll() async {
        while !Task.isCancelled {
            do {
                let snapshot = try await client.fetch()
                try Task.checkCancellation()
                let now = Date()
                append(OpenAIStatusSample(observedAt: now, snapshot: snapshot))
                lastSuccess = now
                feedFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                feedFailed = true
                append(OpenAIStatusSample(observedAt: Date(), snapshot: nil))
            }
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { return }
        }
    }

    private func append(_ sample: OpenAIStatusSample) {
        history.append(sample)
        history = Array(history.suffix(60))
    }
}
