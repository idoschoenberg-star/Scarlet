import SwiftUI
import Charts

/// The "Amwell" tab — Ido's corporate-intel brief on American Well Corp
/// (NYSE: AMWL). It opens with an Apple-Stocks-fidelity quote + chart for the
/// ticker, then a running feed of fresh intelligence: company press releases,
/// competitive coverage (Teladoc and the rest), client news (DHA, Elevance,
/// Highmark…), and analyst ratings.
///
/// Data comes from two token-authed edge-function ops on `app-api`:
///   • `op=amwl_quote`  — the live quote + 1D/1Y close series.
///   • `op=amwl_intel`  — the four intel feeds.
/// Both are optional-safe end to end: any field may be null and any section may
/// be empty, and the page degrades to skeletons / a "pull to refresh" line
/// rather than ever crashing or breaking layout. This view deliberately does
/// NOT read the Conversation @EnvironmentObject, so it needs no re-injection.

// MARK: - Palette

private enum AmwellStyle {
    /// Amwell brand blue for chrome/accents; gains green / losses red for the
    /// quote — matched to Apple Stocks' feel on a dark ground.
    static let brand = Color(red: 0.29, green: 0.55, blue: 0.96)
    static let up = Color(red: 0.30, green: 0.85, blue: 0.46)
    static let down = Color(red: 1.0, green: 0.35, blue: 0.38)
    static let surface = Color.white.opacity(0.06)
    static let surfaceHi = Color.white.opacity(0.09)
    static let hair = Color.white.opacity(0.08)
    static let label = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.38)
}

// MARK: - Model

@MainActor
final class AmwellModel: ObservableObject {

    /// One point on the price series. `t` is epoch-millis (backend sends ms).
    struct ChartPoint: Identifiable {
        let id = UUID()
        let date: Date
        let close: Double
    }

    /// The live quote. Every numeric field is optional — the backend may hand
    /// back nulls (pre-market, a data-provider gap) and the UI shows "—".
    struct Quote {
        var symbol = "AMWL"
        var name = "American Well Corp"
        var currency = "USD"
        var price: Double?
        var change: Double?
        var changePct: Double?
        var prevClose: Double?
        var open: Double?
        var dayLow: Double?
        var dayHigh: Double?
        var week52Low: Double?
        var week52High: Double?
        var marketCap: Double?
        var asOf: String = ""
        var source: String = ""
        var chart1d: [ChartPoint] = []
        var chart1y: [ChartPoint] = []

        /// Direction sign for coloring: prefer explicit change, fall back to
        /// price-vs-prevClose so a missing `change` still colors correctly.
        var isUp: Bool {
            if let c = change { return c >= 0 }
            if let p = price, let pc = prevClose { return p >= pc }
            return true
        }
    }

    /// One intel card, shared shape across all four feeds.
    struct IntelItem: Identifiable {
        let id = UUID()
        let title: String
        let source: String
        let link: String
        let published: String?
        let snippet: String
    }

    struct Intel {
        var press: [IntelItem] = []
        var competitors: [IntelItem] = []
        var clients: [IntelItem] = []
        var analyst: [IntelItem] = []
        var updatedAt: String = ""
    }

    enum Load { case idle, loading, ready, failed }

    @Published var quote: Quote?
    @Published var intel: Intel?
    @Published var quoteState: Load = .idle
    @Published var intelState: Load = .idle

    /// First paint shows skeletons; a later refresh keeps the last-good data on
    /// screen so a transient failure never blanks the page.
    var hasAnyData: Bool { quote != nil || intel != nil }

    func load() async {
        if quoteState != .ready { quoteState = .loading }
        if intelState != .ready { intelState = .loading }
        // Fetch both concurrently; a failure in one must not sink the other.
        async let q: Void = loadQuote()
        async let i: Void = loadIntel()
        _ = await (q, i)
    }

    private func loadQuote() async {
        do {
            let data = try await Self.request("op=amwl_quote")
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            quote = Self.parseQuote(obj)
            quoteState = .ready
        } catch {
            // Keep any prior quote on screen; only flip to failed on cold start.
            quoteState = (quote == nil) ? .failed : .ready
        }
    }

    private func loadIntel() async {
        do {
            let data = try await Self.request("op=amwl_intel")
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            intel = Self.parseIntel(obj)
            intelState = .ready
        } catch {
            intelState = (intel == nil) ? .failed : .ready
        }
    }

    // MARK: parsing (every field optional-safe)

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        return ""
    }

    private static func parsePoints(_ raw: Any?) -> [ChartPoint] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { row in
            guard let t = num(row["t"]), let c = num(row["c"]) else { return nil }
            // Guard against absurd timestamps; ms since epoch expected.
            let seconds = t > 1_000_000_000_000 ? t / 1000 : t
            return ChartPoint(date: Date(timeIntervalSince1970: seconds), close: c)
        }
    }

    private static func parseQuote(_ o: [String: Any]) -> Quote {
        var q = Quote()
        if !str(o["symbol"]).isEmpty { q.symbol = str(o["symbol"]) }
        if !str(o["name"]).isEmpty { q.name = str(o["name"]) }
        if !str(o["currency"]).isEmpty { q.currency = str(o["currency"]) }
        q.price = num(o["price"])
        q.change = num(o["change"])
        q.changePct = num(o["changePct"])
        q.prevClose = num(o["prevClose"])
        q.open = num(o["open"])
        q.dayLow = num(o["dayLow"])
        q.dayHigh = num(o["dayHigh"])
        q.week52Low = num(o["week52Low"])
        q.week52High = num(o["week52High"])
        q.marketCap = num(o["marketCap"])
        q.asOf = str(o["asOf"])
        q.source = str(o["source"])
        q.chart1d = parsePoints(o["chart1d"])
        q.chart1y = parsePoints(o["chart1y"])
        return q
    }

    private static func parseItems(_ raw: Any?) -> [IntelItem] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.map { row in
            IntelItem(
                title: str(row["title"]),
                source: str(row["source"]),
                link: str(row["link"]),
                published: (row["published"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                snippet: str(row["snippet"])
            )
        }
    }

    private static func parseIntel(_ o: [String: Any]) -> Intel {
        var i = Intel()
        i.press = parseItems(o["press"])
        i.competitors = parseItems(o["competitors"])
        i.clients = parseItems(o["clients"])
        i.analyst = parseItems(o["analyst"])
        i.updatedAt = str(o["updated_at"])
        return i
    }

    // MARK: plumbing (same shape as DraftModel: apiBase + x-scarlet-token)

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

// MARK: - Formatting helpers

private enum AmwellFmt {
    static func price(_ v: Double?, currency: Bool = false) -> String {
        guard let v else { return "—" }
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.minimumFractionDigits = 2
        n.maximumFractionDigits = 2
        let s = n.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)
        return currency ? "$" + s : s
    }

    /// Signed change, e.g. "+0.42" / "-1.10".
    static func signed(_ v: Double?) -> String {
        guard let v else { return "—" }
        let s = String(format: "%.2f", abs(v))
        return (v >= 0 ? "+" : "−") + s
    }

    static func signedPct(_ v: Double?) -> String {
        guard let v else { return "—" }
        let s = String(format: "%.2f", abs(v))
        return (v >= 0 ? "+" : "−") + s + "%"
    }

    /// Market cap → $B / $M with a T ceiling. AMWL sits in the sub-$1B range,
    /// but keep the full ladder so a big number never mis-renders.
    static func cap(_ v: Double?) -> String {
        guard let v, v > 0 else { return "—" }
        let abs = Swift.abs(v)
        switch abs {
        case 1_000_000_000_000...:
            return String(format: "$%.2fT", v / 1_000_000_000_000)
        case 1_000_000_000...:
            return String(format: "$%.2fB", v / 1_000_000_000)
        case 1_000_000...:
            return String(format: "$%.1fM", v / 1_000_000)
        default:
            return String(format: "$%.0f", v)
        }
    }

    private static let iso = ISO8601DateFormatter()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Relative date for an intel card ("3h ago"). Falls back to the raw string
    /// if it can't be parsed, and to "" if there's nothing.
    static func relative(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        let d = iso.date(from: s)
            ?? isoNoFrac.date(from: s)
            ?? fallbackDate(s)
        guard let d else { return s }
        return rel.localizedString(for: d, relativeTo: Date())
    }

    private static func fallbackDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "EEE, dd MMM yyyy HH:mm:ss Z"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// "As of" line — pass the backend string through if it isn't a parseable
    /// timestamp; otherwise render a short local time.
    static func asOf(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        let d = iso.date(from: s) ?? isoNoFrac.date(from: s) ?? fallbackDate(s)
        guard let d else { return s }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - View

struct AmwellView: View {
    @StateObject private var model = AmwellModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    chartSection
                    statsSection
                    intelSections
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .frame(maxWidth: 760, alignment: .leading)   // iPad/Mac: keep it readable
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(ScarletBackground().ignoresSafeArea())
            .navigationTitle("Amwell")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            .task {
                if model.quoteState == .idle { await model.load() }
            }
        }
    }

    // MARK: header

    private var header: some View {
        let q = model.quote
        let up = q?.isUp ?? true
        let tint = up ? AmwellStyle.up : AmwellStyle.down
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(q?.symbol ?? "AMWL")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("NYSE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AmwellStyle.faint)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(AmwellStyle.surface))
                Spacer(minLength: 0)
            }
            Text("Amwell — \(q?.name ?? "American Well Corp")")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AmwellStyle.label)

            if model.quoteState == .loading && q == nil {
                skeletonLine(width: 180, height: 40).padding(.top, 6)
                skeletonLine(width: 120, height: 18)
            } else if model.quoteState == .failed && q == nil {
                Text("Couldn't load the quote. Pull to refresh.")
                    .font(.system(size: 14))
                    .foregroundStyle(AmwellStyle.faint)
                    .padding(.top, 8)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(AmwellFmt.price(q?.price))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AmwellFmt.signed(q?.change))
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                        Text(AmwellFmt.signedPct(q?.changePct))
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(tint)
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)

                if let asOf = q?.asOf, !asOf.isEmpty {
                    Text("As of \(AmwellFmt.asOf(asOf))")
                        .font(.system(size: 12))
                        .foregroundStyle(AmwellStyle.faint)
                }
            }
        }
    }

    // MARK: chart

    @State private var range: ChartRange = .day
    enum ChartRange: String, CaseIterable, Identifiable {
        case day = "1D", year = "1Y"
        var id: String { rawValue }
    }

    private var chartSection: some View {
        let q = model.quote
        let up = q?.isUp ?? true
        let tint = up ? AmwellStyle.up : AmwellStyle.down
        let points = (range == .day ? q?.chart1d : q?.chart1y) ?? []
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(ChartRange.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            Group {
                if points.count >= 2 {
                    priceChart(points, tint: tint)
                } else if model.quoteState == .loading && q == nil {
                    skeletonBlock(height: 200)
                } else {
                    chartPlaceholder
                }
            }
            .frame(height: 210)
        }
    }

    private func priceChart(_ points: [AmwellModel.ChartPoint], tint: Color) -> some View {
        let closes = points.map(\.close)
        let lo = closes.min() ?? 0
        let hi = closes.max() ?? 1
        let pad = max((hi - lo) * 0.08, hi == lo ? max(hi * 0.01, 0.5) : 0.0)
        let domain = (lo - pad)...(hi + pad)
        return Chart {
            ForEach(points) { p in
                AreaMark(
                    x: .value("t", p.date),
                    yStart: .value("floor", lo - pad),
                    yEnd: .value("close", p.close)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("t", p.date),
                    y: .value("close", p.close)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
            if let prev = q?.prevClose, range == .day {
                RuleMark(y: .value("prev", prev))
                    .foregroundStyle(AmwellStyle.faint)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.background(Color.clear) }
    }

    private var q: AmwellModel.Quote? { model.quote }

    private var chartPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(AmwellStyle.surface)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(AmwellStyle.faint)
                    Text(model.quoteState == .failed
                         ? "Chart unavailable — pull to refresh"
                         : "No price history for this range")
                        .font(.system(size: 13))
                        .foregroundStyle(AmwellStyle.faint)
                }
            )
    }

    // MARK: stats

    /// One statistic (label + formatted value); a named struct instead of a
    /// tuple so the SwiftUI type-checker doesn't choke on tuples-of-tuples.
    private struct AmwellStat: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }
    private struct AmwellStatRow: Identifiable {
        let id = UUID()
        let left: AmwellStat
        let right: AmwellStat?
    }

    /// Precomputed OUTSIDE the ViewBuilder (explicitly typed) — the inline
    /// stride/map/tuple version blew past the compiler's type-check budget.
    private var statRows: [AmwellStatRow] {
        let q = model.quote
        let stats: [AmwellStat] = [
            AmwellStat(label: "Open", value: AmwellFmt.price(q?.open)),
            AmwellStat(label: "Prev Close", value: AmwellFmt.price(q?.prevClose)),
            AmwellStat(label: "High", value: AmwellFmt.price(q?.dayHigh)),
            AmwellStat(label: "Low", value: AmwellFmt.price(q?.dayLow)),
            AmwellStat(label: "52W High", value: AmwellFmt.price(q?.week52High)),
            AmwellStat(label: "52W Low", value: AmwellFmt.price(q?.week52Low)),
            AmwellStat(label: "Mkt Cap", value: AmwellFmt.cap(q?.marketCap)),
            AmwellStat(label: "Currency", value: q?.currency ?? "USD"),
        ]
        var rows: [AmwellStatRow] = []
        var i = 0
        while i < stats.count {
            rows.append(AmwellStatRow(left: stats[i],
                                      right: i + 1 < stats.count ? stats[i + 1] : nil))
            i += 2
        }
        return rows
    }

    private var statsSection: some View {
        let rows = statRows
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, pair in
                HStack(spacing: 0) {
                    statCell(pair.left.label, pair.left.value)
                    Rectangle().fill(AmwellStyle.hair).frame(width: 1, height: 34)
                    if let right = pair.right {
                        statCell(right.label, right.value)
                    } else {
                        Spacer()
                    }
                }
                if idx < rows.count - 1 {
                    Rectangle().fill(AmwellStyle.hair).frame(height: 1)
                }
            }
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 16).fill(AmwellStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AmwellStyle.hair, lineWidth: 1))
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AmwellStyle.label)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: intel

    private var intelSections: some View {
        VStack(alignment: .leading, spacing: 26) {
            intelGroup("Press & Company",
                       systemImage: "megaphone.fill",
                       items: model.intel?.press ?? [])
            intelGroup("Competitors — Teladoc & others",
                       systemImage: "arrow.triangle.2.circlepath",
                       items: model.intel?.competitors ?? [])
            intelGroup("Clients — DHA, Elevance, Highmark…",
                       systemImage: "building.2.fill",
                       items: model.intel?.clients ?? [])
            intelGroup("Analyst & Ratings",
                       systemImage: "star.fill",
                       items: model.intel?.analyst ?? [])

            if let updated = model.intel?.updatedAt, !updated.isEmpty {
                Text("Intel updated \(AmwellFmt.relative(updated))")
                    .font(.system(size: 11))
                    .foregroundStyle(AmwellStyle.faint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func intelGroup(_ title: String, systemImage: String,
                            items: [AmwellModel.IntelItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AmwellStyle.brand)
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }

            if items.isEmpty {
                emptyOrLoadingRow
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        IntelCard(item: item)
                    }
                }
            }
        }
    }

    private var emptyOrLoadingRow: some View {
        Group {
            switch model.intelState {
            case .loading where model.intel == nil:
                VStack(spacing: 10) {
                    skeletonBlock(height: 74)
                    skeletonBlock(height: 74)
                }
            case .failed where model.intel == nil:
                Text("Couldn't load — pull to refresh.")
                    .font(.system(size: 13))
                    .foregroundStyle(AmwellStyle.faint)
            default:
                Text("Nothing new here yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(AmwellStyle.faint)
            }
        }
    }

    // MARK: skeletons

    private func skeletonLine(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(AmwellStyle.surfaceHi)
            .frame(width: width, height: height)
            .redacted(reason: .placeholder)
    }

    private func skeletonBlock(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(AmwellStyle.surface)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

// MARK: - Intel card

/// One tappable intel row. Opens `link` in the system browser via the
/// SwiftUI-native openURL (Catalyst-safe, no sheet — honors the one-sheet
/// Mac-Catalyst rule). A missing/malformed link degrades to a non-tappable card.
private struct IntelCard: View {
    let item: AmwellModel.IntelItem
    @Environment(\.openURL) private var openURL

    private var url: URL? {
        let trimmed = item.link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    var body: some View {
        Button {
            if let url { openURL(url) }
        } label: {
            card
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title.isEmpty ? "(untitled)" : item.title)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !item.snippet.isEmpty {
                Text(item.snippet)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if !item.source.isEmpty {
                    Text(item.source)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AmwellStyle.brand)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(AmwellStyle.brand.opacity(0.14)))
                }
                let rel = AmwellFmt.relative(item.published)
                if !rel.isEmpty {
                    Text(rel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AmwellStyle.faint)
                }
                Spacer(minLength: 0)
                if url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AmwellStyle.faint)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(AmwellStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AmwellStyle.hair, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}
