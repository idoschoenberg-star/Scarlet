import Foundation
import SwiftUI

/// The Preferences hub — Ido's personal customization lives IN THE APP, never a
/// code change and never "ask Claude to edit it". Three ways to tune the same
/// server-side preferences, all against `app-api` (`x-scarlet-token`):
///
///   1. A live, human-readable SUMMARY of his current priorities, generated
///      dynamically by the server (`op=prefs_summary`) — never a hard-coded list.
///   2. Change them THREE ways that all update the same prefs:
///      a. type a natural-language instruction (`op=prefs_instruct` {text}),
///      b. direct controls — reorder/toggle news sources (`op=news_prefs`),
///      c. a plain reminder that he can also just TALK to Scarlet.
///   3. Reorder what appears first (`op=section_order` {order}).
///
/// Design rules (standing): READABLE (body 17–18pt, titles 20–22, headers 22–26),
/// AGILE (paint instantly from the last cached value, refresh behind — never a
/// blank spinner as the primary state; optimistic updates), FEWER CLICKS
/// (direct controls, drag-to-reorder). Dark, elegant, consistent with the rest
/// of the app. Networking mirrors DraftView's `request` exactly.

// MARK: - Model

@MainActor
final class PreferencesModel: ObservableObject {

    /// One readable facet of the current preferences, as `prefs_summary` /
    /// `prefs_instruct` return it in `sections:[{key,label,detail}]`.
    struct PrefFacet: Identifiable {
        let id = UUID()
        let key: String
        let label: String
        let detail: String
    }

    /// One news source row, as `news_prefs` returns it in
    /// `sources:[{source,lane,enabled,weight}]`. `id` is assigned locally so a
    /// duplicate source name can never collide as a ForEach / reorder identity.
    struct NewsSource: Identifiable {
        let id = UUID()
        let source: String
        let lane: String
        var enabled: Bool
        var weight: Double
    }

    /// One home-section the app can show, as `section_order` returns each key in
    /// `order:[String]`; the friendly label + glyph are resolved locally.
    struct OrderItem: Identifiable {
        let id = UUID()
        let key: String
        var label: String
    }

    // The live, human-readable picture.
    @Published var summary = ""
    @Published var facets: [PrefFacet] = []

    // Direct controls.
    @Published var newsSources: [NewsSource] = []
    @Published var order: [OrderItem] = []

    // Whatever shape the server uses for `topics` — echoed back untouched on
    // every news save so a direct control never drops his topic preferences.
    private var topicsRaw: Any = [String]()

    // State that drives the (never-blank) UI.
    @Published var loaded = false          // true once anything (cache or net) is on screen
    @Published var applying = false        // a natural-language instruction is in flight
    @Published var note = ""               // gentle status / error line

    // MARK: cache keys — paint instantly on open, refresh behind.

    private static let kPrefs = "prefs.cache.prefs"
    private static let kNews  = "prefs.cache.news"
    private static let kOrder = "prefs.cache.order"

    init() {
        // Synchronous cache paint so the hub is readable the instant it opens —
        // no blank spinner as the primary state.
        if let d = UserDefaults.standard.data(forKey: Self.kPrefs),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            applyPrefs(obj, cache: false)
        }
        if let d = UserDefaults.standard.data(forKey: Self.kNews),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            applyNews(obj, cache: false)
        }
        if let d = UserDefaults.standard.data(forKey: Self.kOrder),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            applyOrder(obj, cache: false)
        }
        if !summary.isEmpty || !newsSources.isEmpty || !order.isEmpty { loaded = true }
    }

    // MARK: load / refresh (all three endpoints, in parallel, behind the paint)

    func refresh() async {
        async let a: Void = refreshPrefs()
        async let b: Void = refreshNews()
        async let c: Void = refreshOrder()
        _ = await (a, b, c)
        loaded = true
    }

    private func refreshPrefs() async {
        do {
            let data = try await Self.request("op=prefs_summary", method: "GET")
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                applyPrefs(obj, cache: true)
            }
        } catch {
            if summary.isEmpty {
                note = "Couldn't load your preferences just now — pull to refresh, or just tell Scarlet."
            }
        }
    }

    private func refreshNews() async {
        do {
            let data = try await Self.request("op=news_prefs", method: "GET")
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                applyNews(obj, cache: true)
            }
        } catch { /* keep the cached list on screen */ }
    }

    private func refreshOrder() async {
        do {
            let data = try await Self.request("op=section_order", method: "GET")
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                applyOrder(obj, cache: true)
            }
        } catch { /* keep the cached order on screen */ }
    }

    // MARK: (a) natural-language instruction

    /// POST a plain-English tuning ask; the server maps it to concrete pref
    /// changes (Claude-side) and returns the refreshed `{summary, sections}`,
    /// which replaces the card immediately — an optimistic, "she heard you" feel.
    func instruct(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !applying else { return }
        applying = true
        note = ""
        Task {
            defer { applying = false }
            do {
                let data = try await Self.request("op=prefs_instruct", method: "POST",
                                                  body: ["text": t])
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw URLError(.badServerResponse)
                }
                applyPrefs(obj, cache: true)
                // The instruction may have changed news weighting/topics too —
                // pull the direct-control lists back into agreement quietly.
                await refreshNews()
                note = "Done — updated below."
            } catch {
                note = "That didn't go through — try rephrasing, or just tell Scarlet out loud."
            }
        }
    }

    // MARK: (b) direct news controls

    /// Toggle a source on/off; the local list flips instantly, the save lands
    /// behind. On failure the toggle reverts and a note explains why.
    func setNewsEnabled(_ id: UUID, _ on: Bool) {
        guard let i = newsSources.firstIndex(where: { $0.id == id }) else { return }
        let previous = newsSources[i].enabled
        newsSources[i].enabled = on
        saveNews(revertEnabled: (id, previous))
    }

    /// Drag-to-reorder = priority: the top source carries the highest weight.
    /// Local order flips instantly; the save lands behind.
    func moveNews(from source: IndexSet, to destination: Int) {
        newsSources.move(fromOffsets: source, toOffset: destination)
        reweightNews()
        saveNews(revertEnabled: nil)
    }

    /// Re-derive an explicit descending weight from position so both the array
    /// ORDER and the numeric `weight` the server stores agree on priority.
    private func reweightNews() {
        let n = newsSources.count
        for i in newsSources.indices {
            newsSources[i].weight = Double(n - i)
        }
    }

    private func saveNews(revertEnabled: (UUID, Bool)?) {
        let payload = newsSources.map { s -> [String: Any] in
            ["source": s.source, "lane": s.lane, "enabled": s.enabled, "weight": s.weight]
        }
        let body: [String: Any] = ["sources": payload, "topics": topicsRaw]
        cacheNews(sources: payload)
        Task {
            do {
                _ = try await Self.request("op=news_prefs", method: "POST", body: body)
            } catch {
                if let (id, prev) = revertEnabled,
                   let i = newsSources.firstIndex(where: { $0.id == id }) {
                    newsSources[i].enabled = prev
                }
                note = "Couldn't save that news change — check your connection."
            }
        }
    }

    // MARK: (c) section order

    func moveOrder(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        saveOrder()
    }

    private func saveOrder() {
        let keys = order.map { $0.key }
        cacheOrder(keys: keys)
        Task {
            do {
                _ = try await Self.request("op=section_order", method: "POST",
                                           body: ["order": keys])
            } catch {
                note = "Couldn't save the new order — check your connection."
            }
        }
    }

    // MARK: decode + cache

    private func applyPrefs(_ obj: [String: Any], cache: Bool) {
        if let s = obj["summary"] as? String { summary = s }
        if let arr = obj["sections"] as? [[String: Any]] {
            facets = arr.compactMap { d in
                guard let key = d["key"] as? String else { return nil }
                let label = (d["label"] as? String) ?? Self.friendlyLabel(key)
                let detail = (d["detail"] as? String) ?? ""
                return PrefFacet(key: key, label: label, detail: detail)
            }
        }
        if cache, let d = try? JSONSerialization.data(withJSONObject: obj) {
            UserDefaults.standard.set(d, forKey: Self.kPrefs)
        }
    }

    private func applyNews(_ obj: [String: Any], cache: Bool) {
        if let arr = obj["sources"] as? [[String: Any]] {
            newsSources = arr.compactMap { d in
                guard let src = d["source"] as? String, !src.isEmpty else { return nil }
                let weight = (d["weight"] as? Double) ?? Double((d["weight"] as? Int) ?? 0)
                return NewsSource(source: src,
                                  lane: (d["lane"] as? String) ?? "",
                                  enabled: (d["enabled"] as? Bool) ?? true,
                                  weight: weight)
            }
        }
        if let topics = obj["topics"] { topicsRaw = topics }
        if cache, let d = try? JSONSerialization.data(withJSONObject: obj) {
            UserDefaults.standard.set(d, forKey: Self.kNews)
        }
    }

    private func applyOrder(_ obj: [String: Any], cache: Bool) {
        if let arr = obj["order"] as? [String] {
            order = arr.map { OrderItem(key: $0, label: Self.friendlyLabel($0)) }
        }
        if cache, let d = try? JSONSerialization.data(withJSONObject: obj) {
            UserDefaults.standard.set(d, forKey: Self.kOrder)
        }
    }

    private func cacheNews(sources: [[String: Any]]) {
        let obj: [String: Any] = ["sources": sources, "topics": topicsRaw]
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            UserDefaults.standard.set(d, forKey: Self.kNews)
        }
    }

    private func cacheOrder(keys: [String]) {
        if let d = try? JSONSerialization.data(withJSONObject: ["order": keys]) {
            UserDefaults.standard.set(d, forKey: Self.kOrder)
        }
    }

    // MARK: friendly labels + glyphs for section keys

    static func friendlyLabel(_ key: String) -> String {
        switch key {
        case "talk":      return "Talk"
        case "inbox":     return "Inbox"
        case "calendar":  return "Calendar"
        case "reminders": return "Reminders"
        case "notes":     return "Notes"
        case "photos":    return "Photos"
        case "news":      return "News"
        case "amwell":    return "Amwell"
        case "music":     return "Music"
        case "video":     return "Video"
        case "health":    return "Health"
        default:
            // Unknown key from the server: still render it readably.
            return key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    static func glyph(_ key: String) -> String {
        switch key {
        case "talk":      return "waveform"
        case "inbox":     return "tray.full"
        case "calendar":  return "calendar"
        case "reminders": return "checklist"
        case "notes":     return "note.text"
        case "photos":    return "photo.on.rectangle"
        case "news":      return "newspaper"
        case "amwell":    return "cross.case"
        case "music":     return "music.note"
        case "video":     return "film"
        case "health":    return "heart.fill"
        default:          return "square.grid.2x2"
        }
    }

    /// A friendly glyph for a news lane (best-effort; falls back to a dot).
    static func laneGlyph(_ lane: String) -> String {
        switch lane.lowercased() {
        case "israel", "hebrew":       return "flag"
        case "tech", "technology":     return "cpu"
        case "world", "international":  return "globe"
        case "business", "markets":    return "chart.line.uptrend.xyaxis"
        case "health", "medical":      return "cross.case"
        case "sports":                 return "sportscourt"
        default:                        return "circle.fill"
        }
    }

    // MARK: plumbing — identical shape to DraftModel.request (apiBase + token).

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

// MARK: - View

struct PreferencesView: View {
    /// True when presented as a sheet (a Done button dismisses it). False as a
    /// split-view detail column — there `dismiss()` is a no-op, so the Done
    /// button would be dead and is suppressed. Mirrors SettingsView exactly.
    var presentedAsSheet: Bool = true

    @StateObject private var m = PreferencesModel()
    @Environment(\.dismiss) private var dismiss
    @State private var instructionText = ""
    @State private var editMode: EditMode = .inactive
    @FocusState private var instructFocused: Bool

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)
    private let paper = Color(red: 0.96, green: 0.94, blue: 0.94)
    private let cardFill = Color.white.opacity(0.06)
    private let rowFill = Color.white.opacity(0.05)

    var body: some View {
        NavigationStack {
            List {
                summarySection
                instructSection
                newsSection
                orderSection
                talkHintSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
            .background(ScarletBackground().ignoresSafeArea())
            .navigationTitle("Preferences")
            .toolbar {
                if presentedAsSheet {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
                // One reorder toggle drives edit mode for BOTH drag lists (news
                // + section order) — iOS shows the drag handles when active.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode == .active ? "Finish" : "Reorder") {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    }
                    .disabled(m.newsSources.isEmpty && m.order.isEmpty)
                }
            }
            .refreshable { await m.refresh() }
            .task { await m.refresh() }
        }
    }

    // MARK: 1) live summary card

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Here's what I've got for you right now")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
                    .fixedSize(horizontal: false, vertical: true)

                if !m.summary.isEmpty {
                    // Render the summary paragraph-by-paragraph so mixed
                    // Hebrew/English each keeps its own reading direction.
                    ForEach(Array(m.summary.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        if line.trimmingCharacters(in: .whitespaces).isEmpty {
                            Color.clear.frame(height: 6)
                        } else {
                            paragraph(line, size: 18, weight: .regular, color: paper)
                        }
                    }
                } else if !m.loaded {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small).tint(scarletRose)
                        Text("Reading your preferences…")
                            .font(.system(size: 17)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Nothing tuned yet — tell me below what matters to you, and this becomes your living summary.")
                        .font(.system(size: 17)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !m.facets.isEmpty {
                    Divider().overlay(.white.opacity(0.12)).padding(.vertical, 2)
                    ForEach(m.facets) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.label)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(scarletRose)
                            if !f.detail.isEmpty {
                                paragraph(f.detail, size: 16, weight: .regular,
                                          color: paper.opacity(0.92))
                            }
                        }
                    }
                }

                if m.applying {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(scarletRose)
                        Text("Tuning your preferences…")
                            .font(.system(size: 15)).foregroundStyle(scarletRose.opacity(0.95))
                    }
                    .padding(.top, 2)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.10), lineWidth: 1))
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: 2a) natural-language instruction

    private var instructSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Tell me how to tune things — e.g. \u{201C}more Israeli tech, less sports\u{201D}",
                              text: $instructionText, axis: .vertical)
                        .font(.system(size: 17))
                        .lineLimit(1...4)
                        .padding(11)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        .focused($instructFocused)
                        .disabled(m.applying)
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend ? scarletRose : scarletRose.opacity(0.35))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                if !m.note.isEmpty {
                    Text(m.note)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listRowBackground(rowFill)
        } header: {
            sectionHeader("Tune with a sentence")
        } footer: {
            sectionFooter("Plain words work best. I map them to the controls below.")
        }
    }

    // MARK: 2b) direct news controls

    @ViewBuilder
    private var newsSection: some View {
        Section {
            if m.newsSources.isEmpty {
                Text(m.loaded ? "No news sources yet — add some by telling me above (e.g. \u{201C}follow Calcalist and TheMarker\u{201D})."
                              : "Loading your news sources…")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(rowFill)
            } else {
                ForEach(m.newsSources) { s in
                    HStack(spacing: 12) {
                        Image(systemName: PreferencesModel.laneGlyph(s.lane))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(s.enabled ? scarletRose : .secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.source)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(s.enabled ? paper : paper.opacity(0.5))
                            if !s.lane.isEmpty {
                                Text(s.lane.capitalized)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { s.enabled },
                            set: { m.setNewsEnabled(s.id, $0) }
                        ))
                        .labelsHidden()
                        .tint(scarletRose)
                    }
                    .listRowBackground(rowFill)
                }
                .onMove(perform: m.moveNews)
            }
        } header: {
            sectionHeader("News sources")
        } footer: {
            sectionFooter("Toggle a source to mute it. Tap \u{201C}Reorder\u{201D} to drag by priority — the top source counts most.")
        }
    }

    // MARK: 3) section order

    @ViewBuilder
    private var orderSection: some View {
        Section {
            if m.order.isEmpty {
                Text(m.loaded ? "Section order isn't set yet." : "Loading your layout…")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                    .listRowBackground(rowFill)
            } else {
                ForEach(m.order) { item in
                    HStack(spacing: 12) {
                        Image(systemName: PreferencesModel.glyph(item.key))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(scarletRose)
                            .frame(width: 24)
                        Text(item.label)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(paper)
                        Spacer()
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    .listRowBackground(rowFill)
                }
                .onMove(perform: m.moveOrder)
            }
        } header: {
            sectionHeader("What comes first")
        } footer: {
            sectionFooter("Arrange the sections in the order you want to see them. Tap \u{201C}Reorder\u{201D} to drag.")
        }
    }

    // MARK: 2c) talk hint

    private var talkHintSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(scarletRose)
                Text("You can also just talk to me. Say \u{201C}more Israeli tech, less sports\u{201D} or \u{201C}put News first\u{201D} anytime, and it all lands here.")
                    .font(.system(size: 16))
                    .foregroundStyle(paper.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            .listRowBackground(rowFill)
        }
    }

    // MARK: helpers

    private var canSend: Bool {
        !instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !m.applying
    }

    private func send() {
        guard canSend else { return }
        m.instruct(instructionText)
        instructionText = ""
        instructFocused = false
    }

    /// A section header at a readable size (List's default is tiny/uppercased).
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .bold))
            .textCase(nil)
            .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .textCase(nil)
            .foregroundStyle(.secondary)
    }

    /// One paragraph in ITS OWN direction — Hebrew right-aligned RTL, English
    /// left-aligned LTR — so a mixed summary stays harmonious (same rule the
    /// draft window uses).
    private func paragraph(_ text: String, size: CGFloat, weight: Font.Weight, color: Color) -> some View {
        let rtl = text.isRTLDominant
        return Text(text)
            .font(.system(size: size, weight: weight))
            .lineSpacing(4)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .multilineTextAlignment(rtl ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    }
}
