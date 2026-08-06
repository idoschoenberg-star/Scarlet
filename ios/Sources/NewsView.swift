import Foundation
import SwiftUI

// =============================================================================
// MARK: - News — Scarlet's flagship reading room
// =============================================================================
//
// One publishing house, many sources. Every story — Reuters, Haaretz, Ynet,
// the Times, a niche blog — is poured into the SAME house style: the same type
// scale, the same near-black canvas, the same card shapes, the same scarlet
// accent used sparingly. The reader should never feel a seam between sources;
// it should feel like a single, beautifully art-directed daily.
//
// Modeled on Apple News "Today": a full-bleed LEAD STORY at the top, then a
// ranked mix of feature cards and compact rows, grouped loosely by priority.
//
// Hebrew and English live side by side. Direction is decided PER TEXT (never
// window-wide) via `String.isRTLDominant` — a Hebrew headline reads
// right-to-left and hugs the right edge; an English one reads left-to-right and
// hugs the left — in the very same feed. (Same discipline as DraftView.)
//
// Detail is a PUSH (NavigationLink), never a sheet — Mac Catalyst allows only
// one sheet presentation per view, and there is always a clear way OUT to the
// origin ("Open in <source>" + Share).
//
// Self-contained: it reads no @EnvironmentObject (no convo), so it drops into
// the tab bar without any re-injection ceremony.

// =============================================================================
// MARK: - The house style (one design system, applied uniformly)
// =============================================================================

/// The single source of truth for how News looks. Every source is rendered
/// through THESE tokens, so the feed reads as one magazine, not a pile of RSS.
enum NewsStyle {

    // -- Palette: a clean, near-black gallery so photography sings, with the
    //    Scarlet rose used only as an accent (kickers, the lead badge, actions).
    static let canvasTop    = Color(red: 0.075, green: 0.065, blue: 0.075)
    static let canvasBottom = Color(red: 0.030, green: 0.028, blue: 0.035)
    /// Elevated card surface — a hair lighter than the canvas, warm-neutral.
    static let card         = Color(red: 0.108, green: 0.104, blue: 0.118)
    /// Letterbox fill behind images while they load (never a broken box).
    static let imageFill    = Color(red: 0.145, green: 0.140, blue: 0.155)

    static let ink          = Color(red: 0.965, green: 0.945, blue: 0.945)   // primary text
    static let inkSecondary = Color(red: 0.640, green: 0.628, blue: 0.660)   // meta / time
    static let inkTertiary  = Color(red: 0.480, green: 0.470, blue: 0.505)   // faint labels

    static let accent       = Color(red: 1.00, green: 0.35, blue: 0.42)      // Scarlet rose
    static let accentSoft    = Color(red: 1.00, green: 0.52, blue: 0.57)

    static let hairline     = Color.white.opacity(0.08)

    // -- Geometry: consistent radii and rhythm across every card.
    static let heroRadius: CGFloat = 24
    static let cardRadius: CGFloat = 20
    static let pageHPadding: CGFloat = 18
    static let cardGap: CGFloat = 18
    static let sectionGap: CGFloat = 26

    // -- Type scale: READABLE, and DIRECTION-AWARE (the crux of the Hebrew fix).
    //
    //    English reads in an editorial serif (New York) — that's the magazine
    //    voice. Hebrew must NOT: the system serif face carries NO Hebrew glyphs,
    //    so Hebrew fell back to a mismatched face and rendered thin, cramped and
    //    hard to read — the #1 legibility bug Ido reported. Hebrew now renders in
    //    the system SANS (SF Hebrew is excellent), a hair LARGER and a shade
    //    HEAVIER so it holds its weight beside the Latin serif, with a touch more
    //    line spacing (Hebrew reads better with air). One ramp, resolved per
    //    string by its own direction.
    //
    //    display  → the lead / detail headline
    //    title    → feature-card headlines
    //    rowTitle → compact-row headlines
    //    body     → summaries / detail body
    enum Role { case display(CGFloat), title, rowTitle, body }

    static func font(_ role: Role, rtl: Bool) -> Font {
        switch role {
        case .display(let s):
            return rtl ? .system(size: s + 2, weight: .heavy)
                       : .system(size: s,     weight: .bold,     design: .serif)
        case .title:
            return rtl ? .system(size: 23,   weight: .bold)
                       : .system(size: 22,   weight: .semibold, design: .serif)
        case .rowTitle:
            return rtl ? .system(size: 19.5, weight: .semibold)
                       : .system(size: 18,   weight: .semibold, design: .serif)
        case .body:
            return rtl ? .system(size: 17.5, weight: .regular)
                       : .system(size: 16.5, weight: .regular)
        }
    }

    /// Line spacing per role; Hebrew gets a little more air so tall glyphs and
    /// nikud don't crowd the line above.
    static func lineSpacing(_ role: Role, rtl: Bool) -> CGFloat {
        let base: CGFloat
        switch role {
        case .display:  base = 5
        case .title:    base = 3.5
        case .rowTitle: base = 3
        case .body:     base = 5
        }
        return rtl ? base + 1.5 : base
    }

    // -- Chrome / state-screen fonts (short English UI labels).
    static let title    = Font.system(size: 22, weight: .semibold, design: .serif)
    static let body     = Font.system(size: 16.5, weight: .regular)
    static let kicker   = Font.system(size: 12.5, weight: .bold)
    static let meta     = Font.system(size: 13.5, weight: .regular)
}

/// Card surface + hairline, applied identically to every card so all sources
/// share one silhouette.
private extension View {
    func newsCardSurface(radius: CGFloat = NewsStyle.cardRadius) -> some View {
        self
            .background(NewsStyle.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(NewsStyle.hairline, lineWidth: 1))
    }
}

// =============================================================================
// MARK: - Formatting helpers
// =============================================================================

enum NewsFormat {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// A few common non-ISO shapes seen from feeds (RFC-822-ish, date-only).
    private static let fallbacks: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"].map { fmt in
            let d = DateFormatter()
            d.locale = Locale(identifier: "en_US_POSIX")
            d.dateFormat = fmt
            return d
        }
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = iso.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        for f in fallbacks { if let d = f.date(from: s) { return d } }
        return nil
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated   // "3h ago", "2d ago" — compact but clear
        return f
    }()

    /// "3h ago" / "just now" — nil when there's no usable timestamp.
    static func relativeTime(_ s: String?) -> String? {
        guard let d = parse(s) else { return nil }
        if Date().timeIntervalSince(d) < 60 { return "just now" }
        return relative.localizedString(for: d, relativeTo: Date())
    }

    /// "TUESDAY · AUG 6" masthead date from the feed's fetch time (or now).
    static func masthead(_ fetchedAt: String) -> String {
        let d = parse(fetchedAt) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "EEEE '·' MMM d"
        return f.string(from: d).uppercased()
    }
}

// =============================================================================
// MARK: - Model
// =============================================================================

struct NewsMedia {
    let type: String   // "image" | "video"
    let url: String
    let source: String
    var isVideo: Bool { type.lowercased() == "video" }
}

struct NewsSourceLink: Identifiable {
    let source: String
    let link: String
    var id: String { source + "|" + link }
}

/// One story, normalized. The feed arrives already ranked (best first); we keep
/// that order and only group loosely by position.
struct NewsStory: Identifiable {
    let id: String
    let title: String
    let summary: String?
    let sources: [String]
    let published: String?
    let link: String
    let links: [NewsSourceLink]
    let image: String?
    let media: [NewsMedia]
    let priority: Double
    let lane: String?
    let lang: String?

    /// The one name we badge the story with — first listed source, then the
    /// first link's source, then the article host as a last resort.
    var primarySource: String {
        if let s = sources.first(where: { !$0.isEmpty }) { return s }
        if let s = links.first?.source, !s.isEmpty { return s }
        if let h = URL(string: link)?.host { return h.replacingOccurrences(of: "www.", with: "") }
        return "News"
    }

    var imageURL: URL? {
        if let image, let u = URL(string: image), image.hasPrefix("http") { return u }
        // Fall back to the first image in `media` if the top-level image is absent.
        if let m = media.first(where: { !$0.isVideo && $0.url.hasPrefix("http") }),
           let u = URL(string: m.url) { return u }
        return nil
    }

    var articleURL: URL? {
        guard link.hasPrefix("http"), let u = URL(string: link) else { return nil }
        return u
    }

    var hasVideo: Bool { media.contains { $0.isVideo } }

    /// Extra source links beyond the primary — "also reported by".
    var alternateLinks: [NewsSourceLink] {
        links.filter { $0.link != link && !$0.link.isEmpty }
    }

    var relativeTime: String? { NewsFormat.relativeTime(published) }
}

@MainActor
final class NewsModel: ObservableObject {

    enum Phase { case loading, loaded, empty, error }

    @Published var stories: [NewsStory] = []
    @Published var sourcesOK: [String] = []
    @Published var fetchedAt: String = ""
    @Published var phase: Phase = .loading
    @Published var errorText = ""

    /// Fetch (or re-fetch) the ranked feed. Safe to call repeatedly — a failed
    /// refresh keeps whatever's already on screen rather than blanking it.
    func load() async {
        if stories.isEmpty { phase = .loading }
        errorText = ""
        do {
            let data = try await Self.request("op=news_feed")
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let raw = (obj?["stories"] as? [[String: Any]]) ?? []
            let parsed = raw.enumerated().compactMap { Self.story(from: $0.element, index: $0.offset) }
            stories = parsed
            sourcesOK = (obj?["sources_ok"] as? [String]) ?? []
            fetchedAt = (obj?["fetched_at"] as? String) ?? fetchedAt
            phase = parsed.isEmpty ? .empty : .loaded
        } catch {
            if stories.isEmpty {
                phase = .error
                errorText = "Couldn't reach the newsroom — pull to try again."
            }
            // A failed refresh with stories already up: keep them, stay silent.
        }
    }

    /// Normalize one JSON story into `NewsStory`, defensively (any field may be
    /// missing; priority may arrive as Int or Double; titles may be Hebrew).
    private static func story(from d: [String: Any], index: Int) -> NewsStory? {
        let title = (d["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        let link = (d["link"] as? String) ?? ""

        let sources = (d["sources"] as? [String])?.filter { !$0.isEmpty } ?? []

        let links: [NewsSourceLink] = ((d["links"] as? [[String: Any]]) ?? []).compactMap { l in
            let src = (l["source"] as? String) ?? ""
            let lnk = (l["link"] as? String) ?? ""
            guard !lnk.isEmpty || !src.isEmpty else { return nil }
            return NewsSourceLink(source: src, link: lnk)
        }

        let media: [NewsMedia] = ((d["media"] as? [[String: Any]]) ?? []).compactMap { m in
            let url = (m["url"] as? String) ?? ""
            guard !url.isEmpty else { return nil }
            return NewsMedia(type: (m["type"] as? String) ?? "image",
                             url: url,
                             source: (m["source"] as? String) ?? "")
        }

        let priority: Double = {
            if let p = d["priority"] as? Double { return p }
            if let p = d["priority"] as? Int { return Double(p) }
            if let p = d["priority"] as? NSNumber { return p.doubleValue }
            return 0
        }()

        let summary = (d["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return NewsStory(
            id: "\(index)|\(link.isEmpty ? title : link)",
            title: title,
            summary: (summary?.isEmpty == true) ? nil : summary,
            sources: sources,
            published: d["published"] as? String,
            link: link,
            links: links,
            image: d["image"] as? String,
            media: media,
            priority: priority,
            lane: d["lane"] as? String,
            lang: d["lang"] as? String
        )
    }

    // Same plumbing shape as DraftView.request: apiBase + x-scarlet-token + 200 check.
    private static func request(_ query: String) async throws -> Data {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?v=2&\(query)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// =============================================================================
// MARK: - Bidi-aware text (Hebrew RTL, English LTR — per string, in one feed)
// =============================================================================

/// One text run in ITS OWN direction — the exact discipline DraftView uses.
/// Hebrew hugs the trailing edge and reads right-to-left; English hugs the
/// leading edge and reads left-to-right. Intra-run mixing (an English name in a
/// Hebrew headline) is handled by SwiftUI's own bidi.
struct NewsText: View {
    let text: String
    var role: NewsStyle.Role
    var color: Color = NewsStyle.ink
    var lineLimit: Int? = nil
    /// Force a light color when the text sits over an image scrim.
    var overImage: Bool = false

    var body: some View {
        let rtl = text.isRTLDominant
        Text(text)
            .font(NewsStyle.font(role, rtl: rtl))
            .foregroundStyle(color)
            .lineSpacing(NewsStyle.lineSpacing(role, rtl: rtl))
            .lineLimit(lineLimit)
            // Reading-START alignment: `.leading` resolves against the text's OWN
            // layout direction (set just below) — LEFT for English, RIGHT for
            // Hebrew — so every string hugs the edge it reads from. The old code
            // forced `.trailing` AND `.rightToLeft`, which cancel to `.leading`
            // and shoved Hebrew to the LEFT. This was the core RTL bug.
            .multilineTextAlignment(.leading)
            // Never let a parent (grid row, HStack) vertically compress or clip
            // the wrapped lines — the block always takes the height it needs.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .shadow(color: overImage ? .black.opacity(0.38) : .clear,
                    radius: overImage ? 8 : 0, x: 0, y: 1)
    }
}

// =============================================================================
// MARK: - Image (graceful, letterboxed, never a broken box)
// =============================================================================

/// Fills its frame with the image (scaled to fill, clipped). While loading or on
/// failure it shows a calm letterbox with a faint mark — never a torn box. The
/// caller sets the frame height and clips; heights are capped so scrolling stays
/// buttery.
struct NewsImage: View {
    let url: URL?

    var body: some View {
        ZStack {
            NewsStyle.imageFill
            if let url {
                AsyncImage(url: url,
                           transaction: Transaction(animation: .easeInOut(duration: 0.35))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    case .empty:
                        placeholder(spinning: true)
                    case .failure:
                        placeholder(spinning: false)
                    @unknown default:
                        placeholder(spinning: false)
                    }
                }
            } else {
                placeholder(spinning: false)
            }
        }
        .clipped()
        .contentShape(Rectangle())
    }

    private func placeholder(spinning: Bool) -> some View {
        ZStack {
            LinearGradient(colors: [NewsStyle.imageFill,
                                    NewsStyle.imageFill.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
            if spinning {
                ProgressView().tint(NewsStyle.inkTertiary)
            } else {
                Image(systemName: "newspaper")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(NewsStyle.inkTertiary.opacity(0.55))
            }
        }
    }
}

/// Small circular play affordance for video stories.
struct NewsPlayBadge: View {
    var size: CGFloat = 46
    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().stroke(.white.opacity(0.35), lineWidth: 1)
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: size * 0.03)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }
}

// =============================================================================
// MARK: - Kicker (source + time), the shared editorial byline
// =============================================================================

/// The one byline used on every non-hero card: SOURCE in scarlet caps, a dot,
/// then the relative time. Same on Reuters and on a blog — one house voice.
struct NewsKicker: View {
    let source: String
    let time: String?
    var body: some View {
        HStack(spacing: 7) {
            Text(source.uppercased())
                .font(NewsStyle.kicker)
                .tracking(0.8)
                .foregroundStyle(NewsStyle.accent)
                .lineLimit(1)
            if let time {
                Text("·").foregroundStyle(NewsStyle.inkTertiary)
                Text(time)
                    .font(NewsStyle.meta)
                    .foregroundStyle(NewsStyle.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// =============================================================================
// MARK: - The lead story (the ONLY text-over-image, done cleanly)
// =============================================================================

struct NewsHeroCard: View {
    let story: NewsStory
    @Environment(\.horizontalSizeClass) private var hSize

    private var height: CGFloat { hSize == .regular ? 460 : 360 }
    private var rtl: Bool { story.title.isRTLDominant }

    var body: some View {
        ZStack(alignment: rtl ? .bottomTrailing : .bottomLeading) {
            // Image — or, when there's none, a rich scarlet gradient so the lead
            // still looks deliberately art-directed rather than empty.
            Group {
                if story.imageURL != nil {
                    NewsImage(url: story.imageURL)
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.62, green: 0.10, blue: 0.22),
                                 Color(red: 0.30, green: 0.05, blue: 0.13)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()

            // Legibility scrim — the clean gradient that lets text sit safely
            // over photography. This is the ONLY place text overlaps an image.
            LinearGradient(
                colors: [.clear, .black.opacity(0.10), .black.opacity(0.86)],
                startPoint: .top, endPoint: .bottom)
                .frame(height: height)

            // Headline block, pinned to the bottom reading edge. The block runs
            // in the headline's own direction, so for a Hebrew lead the badge and
            // time hug the right edge too — the whole card reads as one language.
            VStack(alignment: .leading, spacing: 10) {
                leadBadge
                NewsText(text: story.title,
                         role: .display(hSize == .regular ? 34 : 29),
                         color: .white,
                         lineLimit: 4,
                         overImage: true)
                if let time = story.relativeTime {
                    Text(time)
                        .font(NewsStyle.meta)
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                }
            }
            .padding(22)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)

            if story.hasVideo {
                NewsPlayBadge(size: 62)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: NewsStyle.heroRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NewsStyle.heroRadius, style: .continuous)
            .stroke(.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 22, y: 12)
    }

    private var leadBadge: some View {
        HStack(spacing: 8) {
            Text("LEAD STORY")
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(NewsStyle.accent, in: Capsule())
            Text(story.primarySource.uppercased())
                .font(NewsStyle.kicker)
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
        }
    }
}

// =============================================================================
// MARK: - Feature card (image on top) — the workhorse of the feed
// =============================================================================

struct NewsFeatureCard: View {
    let story: NewsStory
    @Environment(\.horizontalSizeClass) private var hSize

    private var imageHeight: CGFloat { hSize == .regular ? 200 : 208 }
    /// The card's chrome follows the HEADLINE's direction, so a Hebrew story's
    /// byline and text hug the right edge as one block.
    private var rtl: Bool { story.title.isRTLDominant }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if story.imageURL != nil {
                ZStack(alignment: .bottomTrailing) {
                    NewsImage(url: story.imageURL)
                        .frame(height: imageHeight)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    if story.hasVideo {
                        NewsPlayBadge(size: 44).padding(12)
                    }
                }
            }
            // Text block laid out in the headline's direction. `.leading` here is
            // reading-start, so under the RTL environment it hugs the right — and
            // the kicker's trailing spacer pushes SOURCE·TIME to the right too.
            VStack(alignment: .leading, spacing: 9) {
                NewsKicker(source: story.primarySource, time: story.relativeTime)
                NewsText(text: story.title, role: .title,
                         color: NewsStyle.ink, lineLimit: 3)
                if let summary = story.summary {
                    NewsText(text: summary, role: .body,
                             color: NewsStyle.inkSecondary, lineLimit: 3)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .newsCardSurface()
    }
}

// =============================================================================
// MARK: - Compact row (leading text, trailing thumbnail) — the long tail
// =============================================================================

struct NewsCompactRow: View {
    let story: NewsStory

    /// Row direction follows the headline. For a Hebrew story the whole row
    /// mirrors — text on the right, thumbnail on the LEFT — the way an Israeli
    /// news app lays it out, instead of a right-aligned headline crammed against
    /// a left-pinned thumbnail.
    private var rtl: Bool { story.title.isRTLDominant }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                NewsKicker(source: story.primarySource, time: story.relativeTime)
                NewsText(text: story.title, role: .rowTitle,
                         color: NewsStyle.ink, lineLimit: 4)
                Spacer(minLength: 0)
            }
            if story.imageURL != nil {
                ZStack(alignment: .bottomTrailing) {
                    NewsImage(url: story.imageURL)
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if story.hasVideo {
                        NewsPlayBadge(size: 28).padding(6)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .newsCardSurface(radius: 18)
    }
}

// =============================================================================
// MARK: - Section header (the magazine's quiet dividers)
// =============================================================================

struct NewsSectionHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(NewsStyle.accent)
                .frame(width: 22, height: 3)
                .clipShape(Capsule())
            Text(title.uppercased())
                .font(.system(size: 13, weight: .heavy))
                .tracking(1.8)
                .foregroundStyle(NewsStyle.ink)
            Spacer()
        }
    }
}

// =============================================================================
// MARK: - NewsView — the reading room
// =============================================================================

struct NewsView: View {
    @StateObject private var model = NewsModel()
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var refreshSpin = false

    private var columns: [GridItem] {
        let count = hSize == .regular ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: NewsStyle.cardGap, alignment: .top),
                     count: count)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [NewsStyle.canvasTop, NewsStyle.canvasBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    feed
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(NewsStyle.accent)
        .task {
            if model.stories.isEmpty { await model.load() }
        }
    }

    // MARK: top bar

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("News")
                        .font(.system(size: 30, weight: .heavy, design: .serif))
                        .foregroundStyle(NewsStyle.ink)
                    Text(mastheadLine)
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(NewsStyle.inkTertiary)
                        .lineLimit(1)
                }
                Spacer()
                filterMenu
                refreshButton
            }
            .padding(.horizontal, NewsStyle.pageHPadding)
            .padding(.top, 8)
            .padding(.bottom, 2)
            Rectangle().fill(NewsStyle.hairline).frame(height: 1)
        }
    }

    private var mastheadLine: String {
        var s = NewsFormat.masthead(model.fetchedAt)
        let n = model.sourcesOK.count
        if n > 0 { s += "  ·  \(n) SOURCE\(n == 1 ? "" : "S")" }
        return s
    }

    private var refreshButton: some View {
        Button {
            Task {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    refreshSpin = true
                }
                await model.load()
                withAnimation(.default) { refreshSpin = false }
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NewsStyle.accent)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.06), in: Circle())
                .overlay(Circle().stroke(NewsStyle.hairline, lineWidth: 1))
                .rotationEffect(.degrees(refreshSpin ? 360 : 0))
        }
        .buttonStyle(.plain)
    }

    /// Filter / priorities — a stub for now (source priorities are managed
    /// elsewhere). A Menu, not a sheet, so it plays nicely with Mac Catalyst's
    /// one-sheet rule and never dead-ends.
    private var filterMenu: some View {
        Menu {
            Section("Source priorities") {
                Label("Managed in Settings — coming here soon", systemImage: "slider.horizontal.3")
            }
            Button {
                Task { await model.load() }
            } label: {
                Label("Refresh feed", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NewsStyle.ink)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.06), in: Circle())
                .overlay(Circle().stroke(NewsStyle.hairline, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: feed

    @ViewBuilder
    private var feed: some View {
        ScrollView {
            switch model.phase {
            case .loading where model.stories.isEmpty:
                loadingState
            case .error where model.stories.isEmpty:
                errorState
            case .empty:
                emptyState
            default:
                feedContent
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.load() }
    }

    /// The magazine, laid out: the LEAD, then feature cards ("Top Stories"),
    /// then the compact long tail ("More to Read"). Grouping is loose and driven
    /// purely by the server's ranking — the reader feels curation, not plumbing.
    private var feedContent: some View {
        // stories[0] is the lead. The next handful become large feature cards;
        // the remainder ride as compact rows.
        let stories = model.stories
        let featureCount = min(hSize == .regular ? 6 : 4, max(0, stories.count - 1))
        let features = Array(stories.dropFirst().prefix(featureCount))
        let rest = Array(stories.dropFirst(1 + featureCount))

        return LazyVStack(alignment: .leading, spacing: NewsStyle.sectionGap) {
            if let lead = stories.first {
                NavigationLink { NewsDetailView(story: lead) } label: {
                    NewsHeroCard(story: lead)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }

            if !features.isEmpty {
                VStack(alignment: .leading, spacing: NewsStyle.cardGap) {
                    NewsSectionHeader(title: "Top Stories")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: NewsStyle.cardGap) {
                        ForEach(features) { story in
                            NavigationLink { NewsDetailView(story: story) } label: {
                                NewsFeatureCard(story: story)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !rest.isEmpty {
                VStack(alignment: .leading, spacing: NewsStyle.cardGap) {
                    NewsSectionHeader(title: "More to Read")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: NewsStyle.cardGap) {
                        ForEach(rest) { story in
                            NavigationLink { NewsDetailView(story: story) } label: {
                                NewsCompactRow(story: story)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            footerNote
        }
        .padding(.horizontal, NewsStyle.pageHPadding)
        .padding(.bottom, 40)
    }

    private var footerNote: some View {
        VStack(spacing: 4) {
            Rectangle().fill(NewsStyle.hairline).frame(width: 40, height: 1)
                .padding(.bottom, 6)
            Text("You're all caught up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NewsStyle.inkSecondary)
            if let updated = NewsFormat.relativeTime(model.fetchedAt) {
                Text("Updated \(updated)")
                    .font(.system(size: 12))
                    .foregroundStyle(NewsStyle.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    // MARK: states

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().tint(NewsStyle.accent).controlSize(.large)
            Text("Gathering today's news…")
                .font(NewsStyle.body)
                .foregroundStyle(NewsStyle.inkSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private var errorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(NewsStyle.inkSecondary)
            Text(model.errorText.isEmpty ? "Couldn't load the news." : model.errorText)
                .font(NewsStyle.body)
                .foregroundStyle(NewsStyle.inkSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await model.load() }
            } label: {
                Text("Try again")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(NewsStyle.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        .padding(.horizontal, 32)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "newspaper")
                .font(.system(size: 34))
                .foregroundStyle(NewsStyle.inkSecondary)
            Text("No stories right now")
                .font(NewsStyle.title)
                .foregroundStyle(NewsStyle.ink)
            Text("Pull to refresh in a little while.")
                .font(NewsStyle.body)
                .foregroundStyle(NewsStyle.inkSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

// =============================================================================
// MARK: - NewsDetailView (push, not a sheet) — always a way out to the source
// =============================================================================

struct NewsDetailView: View {
    let story: NewsStory
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var hSize

    private var heroHeight: CGFloat { hSize == .regular ? 420 : 300 }

    var body: some View {
        ZStack {
            LinearGradient(colors: [NewsStyle.canvasTop, NewsStyle.canvasBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                detailBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        heroImage
                        VStack(alignment: .leading, spacing: 14) {
                            // Byline + headline + standfirst read in the article's
                            // own direction (Hebrew → right, English → left); the
                            // action chrome below stays in the app's LTR frame.
                            VStack(alignment: .leading, spacing: 12) {
                                NewsKicker(source: story.primarySource, time: story.relativeTime)
                                NewsText(text: story.title,
                                         role: .display(hSize == .regular ? 34 : 29),
                                         color: NewsStyle.ink, lineLimit: nil)
                                if let summary = story.summary {
                                    NewsText(text: summary, role: .body,
                                             color: NewsStyle.ink.opacity(0.88),
                                             lineLimit: nil)
                                }
                            }
                            .environment(\.layoutDirection,
                                         story.title.isRTLDominant ? .rightToLeft : .leftToRight)
                            openButton
                            alternates
                            sourcesFootnote
                        }
                        .padding(.horizontal, NewsStyle.pageHPadding)
                    }
                    .padding(.bottom, 44)
                }
                .scrollIndicators(.hidden)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: bar (drawn — the app hides the system nav bar; Catalyst has no
    // edge-swipe-back — so we draw the way back and Share ourselves).

    private var detailBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("News").font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(NewsStyle.accent)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if let url = story.articleURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(NewsStyle.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, NewsStyle.pageHPadding)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NewsStyle.hairline).frame(height: 1)
        }
    }

    // MARK: hero

    @ViewBuilder
    private var heroImage: some View {
        if story.imageURL != nil {
            Button {
                // A video hero opens the source (where the clip actually plays).
                if story.hasVideo, let url = story.articleURL { openURL(url) }
            } label: {
                ZStack {
                    NewsImage(url: story.imageURL)
                        .frame(height: heroHeight)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    if story.hasVideo { NewsPlayBadge(size: 66) }
                }
            }
            .buttonStyle(.plain)
            .disabled(!story.hasVideo)
        }
    }

    // MARK: the way out

    private var openButton: some View {
        Group {
            if let url = story.articleURL {
                Button {
                    openURL(url)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: story.hasVideo ? "play.rectangle.fill" : "safari.fill")
                            .font(.system(size: 17, weight: .semibold))
                        Text(story.hasVideo
                             ? "Watch on \(story.primarySource)"
                             : "Open in \(story.primarySource)")
                            .font(.system(size: 16.5, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .bold))
                            .opacity(0.8)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 15)
                    .frame(maxWidth: .infinity)
                    .background(NewsStyle.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
    }

    /// "Also reported by" — every alternate source stays one tap from its origin.
    @ViewBuilder
    private var alternates: some View {
        let alts = story.alternateLinks
        if !alts.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("ALSO REPORTED BY")
                    .font(.system(size: 11.5, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(NewsStyle.inkTertiary)
                FlowChips(links: alts) { openURL($0) }
            }
            .padding(.top, 4)
        }
    }

    private var sourcesFootnote: some View {
        Group {
            if !story.sources.isEmpty {
                Text("Sources: " + story.sources.joined(separator: ", "))
                    .font(.system(size: 12.5))
                    .foregroundStyle(NewsStyle.inkTertiary)
                    .padding(.top, 6)
            }
        }
    }
}

/// A simple wrapping row of tappable source chips (no external layout deps).
struct FlowChips: View {
    let links: [NewsSourceLink]
    let onTap: (URL) -> Void

    var body: some View {
        // A LazyVGrid with adaptive item widths wraps chips cleanly on any width.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 220),
                                     spacing: 8, alignment: .leading)],
                  alignment: .leading, spacing: 8) {
            ForEach(links) { link in
                Button {
                    if let u = URL(string: link.link), link.link.hasPrefix("http") { onTap(u) }
                } label: {
                    HStack(spacing: 5) {
                        Text(link.source.isEmpty ? "Source" : link.source)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(NewsStyle.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().stroke(NewsStyle.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!link.link.hasPrefix("http"))
            }
        }
    }
}
