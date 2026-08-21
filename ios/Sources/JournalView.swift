import SwiftUI

// MARK: - The Journal (יומן)
//
// "Pins" was the capture device, not the product. The product is the JOURNAL:
// where Ido manages the documentation of his life and the actions that flow
// from it (docs/JOURNAL_PROGRAM.md, 2026-08-18). This screen is the Journal's
// INBOX — the review lane where staged work and derived storylines wait for
// his ruling.
//
// Two card families live here, and they are NOT the same kind of decision:
//
//   • ACTION cards (reminder, communication, meeting_notes, calendar_event,
//     research, memory) — things to DO. Accepting routes them into the
//     captures spine, so a communication becomes a staged draft he still
//     approves; nothing is ever sent from this screen.
//   • VERIFICATION cards (`journal_fact`, carrying meta.thread_slug) — a
//     storyline Scarlet DERIVED, asking whether it is real. Accept means "this
//     really is a thing in my life", amend fixes its name, reject means she
//     misheard or overheard it and it is permanently removed. These rule on
//     TRUTH, not execution, so they get their own look and their own words.
//
// Server truth: op=pins_list (already priority-first) and op=pins_review
// {id, action: accept|amend|reject, title?, body?, …}. The API names stay
// `pins_*` for app compatibility; every user-facing surface says Journal.
//
// 2026-08-21: the Journal SECTION is now the LIVE day-by-day browser
// (JournalLiveView.swift — `JournalView` lives there). This screen is the
// REVIEW LANE it pushes to from its banner: same cards, same rulings,
// unchanged behavior — one push deeper.

struct JournalCard: Identifiable, Equatable {
    let id: String
    let type: String
    let title: String
    let body: String
    let channel: String
    let recipient: String
    let dueHint: String
    let priority: Int
    let confidence: Double
    let createdAt: Date?
    /// Present only on `journal_fact` cards — the storyline being verified.
    let threadSlug: String

    /// A verification card rules on truth; everything else stages an action.
    var isVerification: Bool { type == "journal_fact" && !threadSlug.isEmpty }
}

@MainActor
final class JournalModel: ObservableObject {
    @Published private(set) var cards: [JournalCard] = []
    @Published private(set) var loading = false
    /// The card currently being decided — its buttons disable so a slow
    /// network can never double-fire a ruling.
    @Published private(set) var decidingId: String?
    @Published var error: String?
    /// What just happened, in his words — the same "say what you did"
    /// confirmation the rest of the approve loop gives.
    @Published var lastOutcome: String?

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await Self.request("op=pins_list", method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let rows = (obj["pins"] as? [[String: Any]]) ?? []
            cards = rows.compactMap(Self.parse)
            error = nil
        } catch {
            // Keep whatever is already on screen — a dropped refresh must not
            // blank a list he may be halfway through.
            self.error = cards.isEmpty
                ? "Couldn't load the Journal. Pull down to try again."
                : nil
        }
    }

    /// Send one ruling. `title`/`body` carry his edits on an amend.
    func review(_ card: JournalCard, action: String,
                title: String? = nil, body: String? = nil) async {
        guard decidingId == nil else { return }
        decidingId = card.id
        defer { decidingId = nil }
        var payload: [String: Any] = ["id": card.id, "action": action]
        if let title, !title.isEmpty { payload["title"] = title }
        if let body { payload["body"] = body }
        do {
            let data = try await Self.request("op=pins_review", method: "POST", body: payload)
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if (obj?["ok"] as? Bool) == false {
                error = "That didn't go through — try again."
                return
            }
            cards.removeAll { $0.id == card.id }
            lastOutcome = Self.outcomeText(card: card, action: action,
                                           status: obj?["status"] as? String)
            error = nil
        } catch {
            self.error = "That didn't go through — check your connection and try again."
        }
    }

    /// Honest, specific confirmation — never a generic "done". The server
    /// tells us what it actually did (`status`); we say that.
    private static func outcomeText(card: JournalCard, action: String, status: String?) -> String {
        if card.isVerification {
            switch action {
            case "reject": return "Removed — she won't bring that up again."
            case "amend": return "Renamed and confirmed as real."
            default: return "Confirmed as real."
            }
        }
        switch (action, status ?? "") {
        case ("reject", _): return "Dropped."
        case (_, "remembered"): return "Committed to memory."
        case (_, "executing"):
            return card.type == "communication"
                ? "Drafting it — it'll come to you for approval before anything is sent."
                : "On it."
        default: return action == "amend" ? "Amended and accepted." : "Accepted."
        }
    }

    private static func parse(_ r: [String: Any]) -> JournalCard? {
        guard let id = r["id"] as? String else { return nil }
        let meta = r["meta"] as? [String: Any]
        return JournalCard(
            id: id,
            type: (r["type"] as? String) ?? "other",
            title: str(r["title"]),
            body: str(r["body"]),
            channel: str(r["channel"]),
            recipient: str(r["recipient"]),
            dueHint: str(r["due_hint"]),
            priority: (r["priority"] as? NSNumber)?.intValue ?? 3,
            confidence: (r["confidence"] as? NSNumber)?.doubleValue ?? 0,
            createdAt: (r["created_at"] as? String).flatMap(parseTimestamp),
            threadSlug: str(meta?["thread_slug"]))
    }

    private static func str(_ v: Any?) -> String { (v as? String) ?? "" }

    /// Postgres hands back "2026-08-18 05:30:38.436894+00"; ISO8601 parsers
    /// reject that shape, so try both.
    private static func parseTimestamp(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let pg = DateFormatter()
        pg.locale = Locale(identifier: "en_US_POSIX")
        pg.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ssZ",
                    "yyyy-MM-dd HH:mm:ss.SSSSSS'+00'", "yyyy-MM-dd HH:mm:ss'+00'"] {
            pg.dateFormat = fmt
            if let d = pg.date(from: s) { return d }
        }
        return nil
    }

    // Same plumbing shape as InboxModel / SecretApprovalsModel.
    private static func request(_ query: String, method: String,
                                body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?v=2&\(query)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Screen (the review lane — pushed from the Live Journal's banner)

struct JournalReviewScreen: View {
    /// Owned by the Live Journal root (JournalLiveView.swift), so the banner
    /// count and this list are one source of truth.
    @ObservedObject var model: JournalModel
    @EnvironmentObject private var convo: Conversation
    /// ONE sheet on this view (Mac Catalyst allows exactly one presentation
    /// per view — stacking a second is an app-quits-on-appear crash), driven
    /// by `.sheet(item:)` so the amend editor is the only thing it presents.
    @State private var amending: JournalCard?

    /// Explicit internal init: the private @State above would make the
    /// synthesized memberwise init private to THIS file, and the Live
    /// Journal (JournalLiveView.swift) constructs this screen.
    init(model: JournalModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        content
            .background(ScarletBackground().ignoresSafeArea())
            .navigationTitle("For review")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            // Same contract every other list screen honours: while this
            // sheet is up, the root's draft backstop must not open one
            // over it (Catalyst allows a single presentation per view).
            .reportsModalPresence(amending != nil)
            .sheet(item: $amending) { card in
                JournalAmendSheet(card: card) { title, body in
                    Task { await model.review(card, action: "amend", title: title, body: body) }
                }
                .preferredColorScheme(.dark)
            }
            .onAppear { convo.setFocus(Self.focusLine(model.cards)) }
            .onChange(of: model.cards) { _, cards in
                convo.setFocus(Self.focusLine(cards))
            }
            // Popping back to the day browser: release the focus only if we
            // still own it (SignalReadView's stale-guard pattern).
            .onDisappear {
                if convo.currentFocus == Self.focusLine(model.cards) {
                    convo.setFocus("[FOCUS] Ido is back on the Journal's day browser.")
                }
            }
            .task { await model.load() }
    }

    /// ALWAYS a ScrollView, empty or not — `.refreshable` only attaches to a
    /// scrollable, so an empty-state VStack would leave him with no way to
    /// pull for a retry, which is exactly when he most wants one.
    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let outcome = model.lastOutcome {
                    outcomeBanner(outcome)
                }
                if let err = model.error {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                if model.cards.isEmpty {
                    emptyState
                } else {
                    ForEach(model.cards) { card in
                        JournalCardRow(
                            card: card,
                            deciding: model.decidingId == card.id,
                            busy: model.decidingId != nil,
                            onAccept: { Task { await model.review(card, action: "accept") } },
                            onAmend: { amending = card },
                            onReject: { Task { await model.review(card, action: "reject") } })
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    private func outcomeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .transition(.opacity)
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            model.lastOutcome = nil
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Journal · יומן")
                .font(.system(size: 17, weight: .light)).tracking(2)
            if model.loading {
                ProgressView()
            } else {
                Text("Nothing waiting for you. New entries appear here as Scarlet picks things up through the day.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    /// What Scarlet "sees" while he's on this screen, so "accept the second
    /// one" or "what's in my journal" work by voice.
    private static func focusLine(_ cards: [JournalCard]) -> String {
        guard !cards.isEmpty else {
            return "[FOCUS] Ido is on the Journal's review lane. The review inbox is empty."
        }
        let verifications = cards.filter(\.isVerification).count
        var line = "[FOCUS] Ido is on the Journal's review lane, reviewing \(cards.count) "
            + "entr\(cards.count == 1 ? "y" : "ies")"
        if verifications > 0 {
            line += " (\(verifications) of them storyline verifications)"
        }
        line += ". In order: "
        line += cards.prefix(8).enumerated()
            .map { "\($0.offset + 1). \($0.element.type) — \($0.element.title)" }
            .joined(separator: "; ")
        line += ". He can accept, amend or reject each one."
        return line
    }
}

// MARK: - One card

private struct JournalCardRow: View {
    let card: JournalCard
    let deciding: Bool
    let busy: Bool
    let onAccept: () -> Void
    let onAmend: () -> Void
    let onReject: () -> Void

    private static let verifyTint = Color(red: 0.55, green: 0.72, blue: 1.0)
    private static let rose = Color(red: 1, green: 0.35, blue: 0.42)

    private var tint: Color { card.isVerification ? Self.verifyTint : Self.rose }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !card.title.isEmpty {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(card.title.readingAlignment)
                    .frame(maxWidth: .infinity, alignment: card.title.readingFrameAlignment)
                    .environment(\.layoutDirection, card.title.layoutDir)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.body.isEmpty {
                Text(card.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(card.body.readingAlignment)
                    .frame(maxWidth: .infinity, alignment: card.body.readingFrameAlignment)
                    .environment(\.layoutDirection, card.body.layoutDir)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !detailLine.isEmpty {
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if card.isVerification {
                Text("Scarlet pieced this together from what she heard. Is it a real thing in your life? Saying no removes it for good.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if card.type == "communication" {
                Text("Accepting writes the draft — nothing is sent until you approve it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(tint.opacity(card.isVerification ? 0.45 : 0.16),
                          lineWidth: card.isVerification ? 1.5 : 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(kindLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            if let at = card.createdAt {
                Text(at, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(role: .destructive, action: onReject) {
                Text(card.isVerification ? "Not real" : "Drop").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button(action: onAmend) {
                Text(card.isVerification ? "Rename" : "Edit").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button(action: onAccept) {
                if deciding {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(card.isVerification ? "Real" : "Accept").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .disabled(busy)
        .tint(tint)
    }

    /// Channel / recipient / due, whichever the card actually carries.
    private var detailLine: String {
        var bits: [String] = []
        if !card.recipient.isEmpty {
            bits.append(card.channel.isEmpty ? card.recipient : "\(card.channel) → \(card.recipient)")
        } else if !card.channel.isEmpty {
            bits.append(card.channel)
        }
        if !card.dueHint.isEmpty { bits.append(card.dueHint) }
        return bits.joined(separator: " · ")
    }

    private var kindLabel: String {
        if card.isVerification { return "Is this real?" }
        switch card.type {
        case "reminder": return "Reminder"
        case "communication": return "Message"
        case "meeting_notes": return "Meeting notes"
        case "calendar_event": return "Calendar"
        case "research": return "Research"
        case "memory": return "Remember this"
        default: return "Entry"
        }
    }

    private var icon: String {
        if card.isVerification { return "sparkle.magnifyingglass" }
        switch card.type {
        case "reminder": return "bell.fill"
        case "communication": return "paperplane.fill"
        case "meeting_notes": return "note.text"
        case "calendar_event": return "calendar"
        case "research": return "magnifyingglass"
        case "memory": return "brain.head.profile"
        default: return "circle.dashed"
        }
    }
}

// MARK: - Amend

/// Fix the wording before accepting. On a verification card only the NAME of
/// the storyline is his to correct, so the body editor stays out of the way.
private struct JournalAmendSheet: View {
    let card: JournalCard
    let onSave: (String, String) -> Void

    @State private var title: String
    /// NOT named `body` — a @State of that name shadows `View.body`.
    @State private var details: String
    @Environment(\.dismiss) private var dismiss

    init(card: JournalCard, onSave: @escaping (String, String) -> Void) {
        self.card = card
        self.onSave = onSave
        _title = State(initialValue: card.title)
        _details = State(initialValue: card.body)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .multilineTextAlignment(title.readingAlignment)
                        .environment(\.layoutDirection, title.layoutDir)
                } header: {
                    Text(card.isVerification ? "What should this be called?" : "Title")
                }
                if !card.isVerification {
                    Section("Details") {
                        TextField("Details", text: $details, axis: .vertical)
                            .lineLimit(3...12)
                            .multilineTextAlignment(details.readingAlignment)
                            .environment(\.layoutDirection, details.layoutDir)
                    }
                }
            }
            .navigationTitle(card.isVerification ? "Rename" : "Edit entry")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(card.isVerification ? "Confirm" : "Accept") {
                        onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), details)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
