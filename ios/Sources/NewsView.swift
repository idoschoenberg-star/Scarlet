import SwiftUI

// MARK: - News (Apple-News-style "Today" surface)
//
// Ido 2026-08-14: "a beautiful layout of the current news… multimedia…
// in the format of Apple News… countries and topics of interest… breaking
// news and headline news always available at the top."
//
// Server truth: app-api op=news_feed (ranked, clustered, media-rich stories
// weighted by his news_prefs) + a `breaking` block detected across outlets.
// Refresh: pull-to-refresh anytime, plus a 5-minute auto-refresh while the
// tab is visible — matching the server's ranked-cache freshness, so faster
// polling would only re-read the same cache and waste battery.

struct NewsStoryItem: Identifiable {
    let id: String
    let title: String
    let summary: String
    let lane: String
    let sources: [String]
    let coverage: Int
    let link: String
    let image: String?
    let hasVideo: Bool
    let ageMin: Int?
}

struct NewsBreakingItem: Identifiable {
    let id: String
    let title: String
    let sources: [String]
    let link: String
    let ageMin: Int?
}

struct NewsSourcePref: Identifiable {
    let id: String       // source name
    let lane: String
    var enabled: Bool
    let weight: Double
}

struct NewsView: View {
    @State private var stories: [NewsStoryItem] = []
    @State private var breaking: [NewsBreakingItem] = []
    @State private var prefs: [NewsSourcePref] = []
    @State private var topics: [String] = []
    @State private var fetchedAt: Date? = nil
    @State private var loading = false
    @State private var error: String? = nil
    @State private var showFilters = false
    @Environment(\.openURL) private var openURL

    private static let laneOrder = ["israel", "world", "us", "business", "tech"]
    private static let laneTitles: [String: String] = [
        "israel": "ישראל", "world": "World", "us": "United States",
        "business": "Business", "tech": "Technology",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !breaking.isEmpty { breakingBlock }
                    if let hero = stories.first { HeroCard(story: hero) { open(hero.link) } }
                    if stories.count > 1 { topStoriesBlock }
                    laneBlocks
                    if let f = fetchedAt {
                        Text("Updated \(f.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("News")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("News interests")
                }
            }
            .sheet(isPresented: $showFilters, onDismiss: { Task { await load() } }) {
                NewsFiltersSheet(prefs: $prefs, topics: $topics)
            }
            .overlay {
                if loading && stories.isEmpty && breaking.isEmpty {
                    ProgressView("Loading the news…")
                } else if let e = error, stories.isEmpty {
                    ContentUnavailableView("News unavailable", systemImage: "newspaper",
                                           description: Text(e))
                }
            }
            .refreshable { await load() }
            // 5-minute auto-refresh while visible (the .task cancels itself
            // when the view leaves the screen, so no background polling).
            .task {
                await load()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000_000)
                    if !Task.isCancelled { await load() }
                }
            }
        }
    }

    // MARK: Sections

    private var breakingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("BREAKING").font(.caption.weight(.heavy)).foregroundStyle(.red)
            }
            ForEach(breaking) { b in
                Button { open(b.link) } label: {
                    VStack(alignment: b.title.readingHAlignment, spacing: 4) {
                        Text(b.title)
                            .font(.headline)
                            .multilineTextAlignment(b.title.readingAlignment)
                            .frame(maxWidth: .infinity, alignment: b.title.readingFrameAlignment)
                        Text(metaLine(sources: b.sources, ageMin: b.ageMin))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: b.title.readingFrameAlignment)
                    }
                    // NO layoutDirection flip here: the reading* helpers
                    // already return the visual edge for an LTR container;
                    // flipping the environment as well re-inverts .trailing
                    // and lands Hebrew back on the LEFT (Ido 2026-08-14).
                }
                .buttonStyle(.plain)
                if b.id != breaking.last?.id { Divider() }
            }
        }
        .padding(14)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.red.opacity(0.35), lineWidth: 1))
    }

    private var topStoriesBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Stories").font(.title3.bold())
            ForEach(stories.dropFirst().prefix(6)) { s in
                StoryRow(story: s) { open(s.link) }
                Divider()
            }
        }
    }

    private var laneBlocks: some View {
        ForEach(Self.laneOrder, id: \.self) { lane in
            let rest = stories.dropFirst(7).filter { $0.lane == lane }
            if !rest.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Self.laneTitles[lane] ?? lane.capitalized).font(.title3.bold())
                    ForEach(rest.prefix(8)) { s in
                        StoryRow(story: s) { open(s.link) }
                        Divider()
                    }
                }
            }
        }
    }

    private func open(_ link: String) {
        guard let u = URL(string: link) else { return }
        openURL(u)
    }

    // MARK: Data

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let feedReq = Self.getWithRetry("op=news_feed")
            async let prefsReq = Self.getWithRetry("op=news_prefs")
            let (feed, prefRow) = try await (feedReq, prefsReq)
            var seen = Set<String>()
            stories = ((feed["stories"] as? [[String: Any]]) ?? []).compactMap { m in
                guard let title = m["title"] as? String, !title.isEmpty else { return nil }
                let link = (m["link"] as? String) ?? ""
                let id = link.isEmpty ? title : link
                guard !seen.contains(id) else { return nil }
                seen.insert(id)
                return NewsStoryItem(
                    id: id, title: title,
                    summary: (m["summary"] as? String) ?? "",
                    lane: (m["lane"] as? String) ?? "world",
                    sources: (m["sources"] as? [String]) ?? [],
                    coverage: (m["coverage"] as? Int) ?? 1,
                    link: link,
                    image: m["image"] as? String,
                    hasVideo: (m["has_video"] as? Bool) ?? false,
                    ageMin: m["age_min"] as? Int)
            }
            breaking = ((feed["breaking"] as? [[String: Any]]) ?? []).compactMap { m in
                guard let title = m["title"] as? String, !title.isEmpty else { return nil }
                return NewsBreakingItem(
                    id: (m["key"] as? String) ?? title,
                    title: title,
                    sources: (m["sources"] as? [String]) ?? [],
                    link: (m["link"] as? String) ?? "",
                    ageMin: m["age_min"] as? Int)
            }
            let prefRowData = (prefRow["prefs"] as? [String: Any]) ?? prefRow
            prefs = ((prefRowData["sources"] as? [[String: Any]]) ?? []).compactMap { m in
                guard let name = m["source"] as? String else { return nil }
                return NewsSourcePref(
                    id: name,
                    lane: (m["lane"] as? String) ?? "world",
                    enabled: (m["enabled"] as? Bool) ?? true,
                    weight: (m["weight"] as? Double) ?? 0.5)
            }
            topics = (prefRowData["topics"] as? [String]) ?? []
            fetchedAt = Date()
            error = nil
        } catch {
            self.error = "Couldn't reach the news service. Pull to retry."
        }
    }

    // MARK: Plumbing (mirrors InboxView/ChatsView/MusicView exactly)

    static func request(_ query: String, method: String,
                        body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?\(query)") else {
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

    static func getWithRetry(_ query: String) async throws -> [String: Any] {
        var lastError: Error = URLError(.unknown)
        for attempt in 1...2 {
            do {
                let data = try await request(query, method: "GET")
                return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } catch {
                lastError = error
                if attempt == 1 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            }
        }
        throw lastError
    }
}

// MARK: - Cards

private func metaLine(sources: [String], ageMin: Int?) -> String {
    var bits: [String] = []
    if !sources.isEmpty { bits.append(sources.prefix(3).joined(separator: " · ")) }
    if let a = ageMin {
        bits.append(a < 60 ? "\(a)m" : "\(a / 60)h")
    }
    return bits.joined(separator: "  ·  ")
}

/// Full-bleed hero: big image, gradient scrim, headline on top — the Apple
/// News "Today" opener.
private struct HeroCard: View {
    let story: NewsStoryItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                NewsImage(url: story.image, height: 240)
                LinearGradient(colors: [.clear, .black.opacity(0.85)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: story.title.readingHAlignment, spacing: 6) {
                    if story.hasVideo {
                        Label("Video", systemImage: "play.fill")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Text(story.title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(story.title.readingAlignment)
                        .frame(maxWidth: .infinity, alignment: story.title.readingFrameAlignment)
                    Text(metaLine(sources: story.sources, ageMin: story.ageMin))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: story.title.readingFrameAlignment)
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

/// Standard story row: text at the reading edge, 92pt thumbnail opposite,
/// video badge when a clip rides along.
private struct StoryRow: View {
    let story: NewsStoryItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: story.title.readingHAlignment, spacing: 5) {
                    Text(story.title)
                        .font(.headline)
                        .lineLimit(3)
                        .multilineTextAlignment(story.title.readingAlignment)
                        .frame(maxWidth: .infinity, alignment: story.title.readingFrameAlignment)
                    Text(metaLine(sources: story.sources, ageMin: story.ageMin))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: story.title.readingFrameAlignment)
                }
                if story.image != nil || story.hasVideo {
                    ZStack(alignment: .center) {
                        NewsImage(url: story.image, height: 92)
                            .frame(width: 92, height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        if story.hasVideo {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Story art with an honest placeholder under the async load — never a blank
/// hole, never a spinner per cell (house MusicArt pattern).
private struct NewsImage: View {
    let url: String?
    let height: CGFloat

    var body: some View {
        GeometryReader { _ in
            if let u = url.flatMap(URL.init(string:)) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "newspaper").font(.title).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Filters (countries/outlets + topics of interest)

private struct NewsFiltersSheet: View {
    @Binding var prefs: [NewsSourcePref]
    @Binding var topics: [String]
    @State private var newTopic = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private static let laneOrder = ["israel", "world", "us", "business", "tech"]
    private static let laneTitles: [String: String] = [
        "israel": "ישראל — Israel", "world": "World", "us": "United States",
        "business": "Business & Economy", "tech": "Technology",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Topics of interest") {
                    ForEach(topics, id: \.self) { t in
                        HStack {
                            Text(t)
                            Spacer()
                            Button {
                                topics.removeAll { $0 == t }
                            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("Add a topic (e.g. AI, hostages, Fed)", text: $newTopic)
                            .onSubmit(addTopic)
                        Button("Add", action: addTopic).disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                ForEach(Self.laneOrder, id: \.self) { lane in
                    let idxs = prefs.indices.filter { prefs[$0].lane == lane }
                    if !idxs.isEmpty {
                        Section(Self.laneTitles[lane] ?? lane.capitalized) {
                            ForEach(idxs, id: \.self) { i in
                                Toggle(prefs[i].id, isOn: $prefs[i].enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("My News")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Saving…" : "Done") { Task { await save() } }
                        .disabled(saving)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func addTopic() {
        let t = newTopic.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !topics.contains(t) else { return }
        topics.append(t)
        newTopic = ""
    }

    @MainActor
    private func save() async {
        saving = true
        defer { saving = false }
        let sources = prefs.map { p in
            ["source": p.id, "lane": p.lane, "enabled": p.enabled, "weight": p.weight] as [String: Any]
        }
        _ = try? await NewsView.request("op=news_prefs", method: "POST",
                                        body: ["sources": sources, "topics": topics])
        dismiss()
    }
}
