import Foundation

/// Per-model staleness gate: `load()` calls that arrive while the data is
/// still fresh return instantly instead of refetching. Pull-to-refresh and
/// explicit user refreshes pass `force: true` via the owning model.
@MainActor
final class Freshness {
    private var last = Date.distantPast
    private let ttl: TimeInterval
    init(ttl: TimeInterval) { self.ttl = ttl }
    /// True if a fetch should proceed (stale or forced); marks the clock when it does.
    func shouldFetch(force: Bool = false) -> Bool {
        guard force || Date().timeIntervalSince(last) >= ttl else { return false }
        return true
    }
    func markFetched() { last = Date() }
    func invalidate() { last = .distantPast }
}
