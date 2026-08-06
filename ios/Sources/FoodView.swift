import Foundation
import SwiftUI
import UIKit

/// Food — Ido's nutrition section. He logs a meal two ways with the fewest
/// possible clicks: (a) tell Scarlet what he ate (text, or out loud), or
/// (b) snap / pick a photo of his plate. Both hit the backend `meal_log` op,
/// which returns an analyzed breakdown (calories + protein/carbs/fat/fiber).
/// The screen shows a beautiful Day / Week overview — a hero calorie ring, three
/// macro rings with grams and % of calories, today's meals, and Scarlet's
/// smartest nutrition advice — and it JUMPS: it paints instantly from a local
/// cache, refreshes behind the paint, and logs optimistically (an "analyzing…"
/// card appears the instant he sends, then fills in with the result).
///
/// Visual language deliberately matches HealthView (20pt cards, small-caps
/// headers, Circle().trim rings, the rose accent family) so Food and Health read
/// as one platform. Type comes from ScarletType tokens throughout — bigger,
/// readable — never hard-coded sizes for text.
///
/// Networking mirrors DraftView exactly: a static `request(op:body:)` that POSTs
/// to `\(AppConfig.apiBase)/app-api?v=2&op=<op>` with the `x-scarlet-token`
/// header and checks the 2xx status. No force-unwraps anywhere.
///
/// BACKEND CONTRACT (implemented in parallel by the backend integrator):
///   • op=meal_log       { text?, image_base64?, image_media_type?, when? }
///                       → { id, title, items[], totals, confidence, notes? }
///   • op=nutrition_day  { date? } → { date, meals[], totals, ratios, targets, advice }
///   • op=nutrition_week { end? }  → { days[], averages, advice }
///
/// Mac-Catalyst discipline: exactly ONE `.sheet(item:)` (photo-library picker OR
/// meal detail, via the FoodSheet enum) plus ONE `.fullScreenCover` (camera) —
/// never two `.sheet` modifiers on one view.

// MARK: - Number / date / format helpers

private enum FoodNum {
    /// Coerce a JSON number that may arrive as Double, Int, or String.
    static func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    /// A quantity that may be a string ("1 cup") or a number.
    static func qty(_ v: Any?) -> String? {
        if let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        if let d = v as? Double { return FoodFmt.int(d) }
        if let i = v as? Int { return String(i) }
        return nil
    }
}

private enum FoodDate {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()
    static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    static func parseDay(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return dayFmt.date(from: s)
    }
}

private enum FoodFmt {
    /// "1,840" — rounded, thousands-separated.
    static func int(_ d: Double) -> String { Int(d.rounded()).formatted() }
    /// "180g"
    static func grams(_ d: Double) -> String { "\(int(d))g" }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    static func time(_ d: Date) -> String { timeFmt.string(from: d) }

    static let weekdayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    static func weekday(_ d: Date) -> String { weekdayFmt.string(from: d) }

    /// "0:07" — the optimistic analyzing timer.
    static func elapsed(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Palette (the Health rose family, so Food & Health read as one system)

private enum FoodStyle {
    static let rose = Color(red: 1, green: 0.35, blue: 0.42)      // calories / accent
    static let protein = Color(red: 0.96, green: 0.42, blue: 0.75) // pink
    static let carbs = Color(red: 1, green: 0.72, blue: 0.30)      // amber
    static let fat = Color(red: 1, green: 0.62, blue: 0.38)        // peach
    static let good = Color(red: 0.55, green: 0.85, blue: 0.62)    // "kcal left" green
}

// MARK: - Wire types

/// A macro tuple, shared by meals, day totals, and week averages.
private struct FoodMacros {
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double

    static let zero = FoodMacros(calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0)

    init(calories: Double, protein: Double, carbs: Double, fat: Double, fiber: Double) {
        self.calories = calories; self.protein = protein
        self.carbs = carbs; self.fat = fat; self.fiber = fiber
    }

    init(dict: [String: Any]?) {
        let d = dict ?? [:]
        self.init(calories: FoodNum.num(d["calories"]),
                  protein: FoodNum.num(d["protein_g"]),
                  carbs: FoodNum.num(d["carbs_g"]),
                  fat: FoodNum.num(d["fat_g"]),
                  fiber: FoodNum.num(d["fiber_g"]))
    }

    func adding(_ o: FoodMacros) -> FoodMacros {
        FoodMacros(calories: calories + o.calories, protein: protein + o.protein,
                   carbs: carbs + o.carbs, fat: fat + o.fat, fiber: fiber + o.fiber)
    }
}

/// One line item inside a meal.
private struct FoodItemRow: Identifiable {
    let id = UUID()
    let name: String
    let qty: String?
    let macros: FoodMacros

    init(dict: [String: Any]) {
        name = (dict["name"] as? String) ?? "Item"
        qty = FoodNum.qty(dict["qty"])
        macros = FoodMacros(dict: dict)
    }
}

/// One logged meal.
private struct FoodMeal: Identifiable {
    let id: String
    let title: String
    let eatenAt: Date?
    let totals: FoodMacros
    let items: [FoodItemRow]
    let confidence: String
    let notes: String

    init(id: String, title: String, eatenAt: Date?, totals: FoodMacros,
         items: [FoodItemRow], confidence: String, notes: String) {
        self.id = id; self.title = title; self.eatenAt = eatenAt
        self.totals = totals; self.items = items
        self.confidence = confidence; self.notes = notes
    }

    init(dict: [String: Any]) {
        self.init(
            id: (dict["id"] as? String) ?? UUID().uuidString,
            title: (dict["title"] as? String) ?? "Meal",
            eatenAt: FoodDate.parse(dict["eaten_at"] as? String),
            totals: FoodMacros(dict: dict["totals"] as? [String: Any]),
            items: ((dict["items"] as? [[String: Any]]) ?? []).map { FoodItemRow(dict: $0) },
            confidence: (dict["confidence"] as? String) ?? "",
            notes: (dict["notes"] as? String) ?? "")
    }

    /// meal_log returns no `eaten_at`; a just-logged meal is "now" so it sorts to
    /// the top of today's list.
    static func fromLog(_ dict: [String: Any]) -> FoodMeal {
        let base = FoodMeal(dict: dict)
        return FoodMeal(id: base.id, title: base.title, eatenAt: base.eatenAt ?? Date(),
                        totals: base.totals, items: base.items,
                        confidence: base.confidence, notes: base.notes)
    }
}

/// The three macro percentages (of calories) the server computes.
private struct FoodRatios {
    let protein: Double
    let carbs: Double
    let fat: Double

    static let zero = FoodRatios(protein: 0, carbs: 0, fat: 0)

    init(protein: Double, carbs: Double, fat: Double) {
        self.protein = protein; self.carbs = carbs; self.fat = fat
    }

    init(dict: [String: Any]?) {
        let d = dict ?? [:]
        self.init(protein: FoodNum.num(d["protein_pct"]),
                  carbs: FoodNum.num(d["carbs_pct"]),
                  fat: FoodNum.num(d["fat_pct"]))
    }

    /// Recompute from macros (used for the optimistic insert before the server
    /// truth lands): protein/carbs 4 kcal/g, fat 9 kcal/g.
    static func from(_ m: FoodMacros) -> FoodRatios {
        let p = m.protein * 4, c = m.carbs * 4, f = m.fat * 9
        let t = max(p + c + f, 1)
        return FoodRatios(protein: p / t * 100, carbs: c / t * 100, fat: f / t * 100)
    }
}

/// Daily targets.
private struct FoodTargets {
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double

    static let zero = FoodTargets(calories: 0, protein: 0, carbs: 0, fat: 0)

    init(calories: Double, protein: Double, carbs: Double, fat: Double) {
        self.calories = calories; self.protein = protein
        self.carbs = carbs; self.fat = fat
    }

    init(dict: [String: Any]?) {
        let d = dict ?? [:]
        self.init(calories: FoodNum.num(d["calories"]),
                  protein: FoodNum.num(d["protein_g"]),
                  carbs: FoodNum.num(d["carbs_g"]),
                  fat: FoodNum.num(d["fat_g"]))
    }
}

private struct FoodDay {
    let date: String
    let meals: [FoodMeal]
    let totals: FoodMacros
    let ratios: FoodRatios
    let targets: FoodTargets
    let advice: String

    static let empty = FoodDay(date: "", meals: [], totals: .zero,
                               ratios: .zero, targets: .zero, advice: "")

    init(date: String, meals: [FoodMeal], totals: FoodMacros,
         ratios: FoodRatios, targets: FoodTargets, advice: String) {
        self.date = date; self.meals = meals; self.totals = totals
        self.ratios = ratios; self.targets = targets; self.advice = advice
    }

    init(dict: [String: Any]) {
        let meals = ((dict["meals"] as? [[String: Any]]) ?? [])
            .map { FoodMeal(dict: $0) }
            .sorted { ($0.eatenAt ?? .distantPast) > ($1.eatenAt ?? .distantPast) }
        self.init(date: (dict["date"] as? String) ?? "",
                  meals: meals,
                  totals: FoodMacros(dict: dict["totals"] as? [String: Any]),
                  ratios: FoodRatios(dict: dict["ratios"] as? [String: Any]),
                  targets: FoodTargets(dict: dict["targets"] as? [String: Any]),
                  advice: (dict["advice"] as? String) ?? "")
    }
}

private struct FoodWeekPoint: Identifiable {
    let dateString: String
    let date: Date?
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    var id: String { dateString }

    init(dict: [String: Any]) {
        dateString = (dict["date"] as? String) ?? UUID().uuidString
        date = FoodDate.parseDay(dict["date"] as? String)
        calories = FoodNum.num(dict["calories"])
        protein = FoodNum.num(dict["protein_g"])
        carbs = FoodNum.num(dict["carbs_g"])
        fat = FoodNum.num(dict["fat_g"])
    }
}

private struct FoodWeek {
    let days: [FoodWeekPoint]
    let averages: FoodMacros
    let advice: String

    init(dict: [String: Any]) {
        days = ((dict["days"] as? [[String: Any]]) ?? []).map { FoodWeekPoint(dict: $0) }
        averages = FoodMacros(dict: dict["averages"] as? [String: Any])
        advice = (dict["advice"] as? String) ?? ""
    }
}

/// One further-reading link under the dietitian tips (a video or an article).
private struct FoodTipLink: Identifiable {
    let id = UUID()
    let title: String
    let url: URL?
    let kind: String   // "video" | "article"
    let source: String

    var isVideo: Bool { kind == "video" }

    init(dict: [String: Any]) {
        title = (dict["title"] as? String) ?? "Read more"
        url = (dict["url"] as? String).flatMap { URL(string: $0) }
        kind = (dict["kind"] as? String) ?? "article"
        source = (dict["source"] as? String) ?? ""
    }
}

/// Scarlet's dietitian tips: personalized advice, a few focus topics, and links.
private struct FoodTips {
    let advice: String
    let focus: [String]
    let links: [FoodTipLink]

    init(advice: String, focus: [String], links: [FoodTipLink]) {
        self.advice = advice; self.focus = focus; self.links = links
    }

    init(dict: [String: Any]) {
        advice = (dict["advice"] as? String) ?? ""
        focus = ((dict["focus"] as? [Any]) ?? []).compactMap { $0 as? String }
        links = ((dict["links"] as? [[String: Any]]) ?? []).map { FoodTipLink(dict: $0) }
    }
}

/// An in-flight meal log — the optimistic "analyzing…" card.
private struct FoodPending: Identifiable {
    let id: String
    let label: String
    let isPhoto: Bool
    let startedAt: Date
}

// MARK: - Model

@MainActor
final class FoodModel: ObservableObject {
    @Published fileprivate var day: FoodDay?
    @Published fileprivate var week: FoodWeek?
    @Published fileprivate var pending: [FoodPending] = []
    @Published fileprivate var tips: FoodTips?
    @Published var dayError = ""
    @Published var weekError = ""
    @Published var logError = ""
    @Published var tipsError = ""
    @Published var tipsLoading = false
    @Published var refreshing = false
    @Published var updatedAt: Date?

    private var rawDay: [String: Any]?
    private var rawWeek: [String: Any]?

    init() { loadCache() }

    // MARK: refresh (local-first: cache already painted in init)

    func refresh() async {
        refreshing = true
        async let d: Void = refreshDay()
        async let w: Void = refreshWeek()
        // Tips load lazily (only if not yet loaded this session) — cheap here.
        async let tp: Void = refreshTips()
        _ = await (d, w, tp)
        refreshing = false
    }

    func refreshDay() async {
        guard TokenStore.token != nil else {
            if day == nil { dayError = "Locked — unlock Scarlet to see your day." }
            return
        }
        do {
            let data = try await Self.request(op: "nutrition_day", body: [:])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            rawDay = obj
            day = FoodDay(dict: obj)
            updatedAt = Date()
            dayError = ""
            saveCache()
        } catch {
            if day == nil { dayError = "Couldn't load today's nutrition — check your connection." }
        }
    }

    func refreshWeek() async {
        guard TokenStore.token != nil else {
            if week == nil { weekError = "Locked — unlock Scarlet to see your week." }
            return
        }
        do {
            let data = try await Self.request(op: "nutrition_week", body: [:])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            rawWeek = obj
            week = FoodWeek(dict: obj)
            weekError = ""
            saveCache()
        } catch {
            if week == nil { weekError = "Couldn't load your week — check your connection." }
        }
    }

    /// Scarlet-as-dietitian tips (advice + focus topics + further-reading links).
    /// Lazy: loads once per session unless `force` (the card's Refresh button).
    /// Never spins forever — always resolves to tips, an error, or empty.
    func refreshTips(force: Bool = false) async {
        guard TokenStore.token != nil else {
            if tips == nil { tipsError = "Locked — unlock Scarlet for your tips." }
            return
        }
        if tipsLoading { return }
        if tips != nil && !force { return }
        tipsLoading = true
        tipsError = ""
        defer { tipsLoading = false }
        do {
            let data = try await Self.request(op: "nutrition_tips", body: [:])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            tips = FoodTips(dict: obj)
            tipsError = ""
        } catch {
            if tips == nil { tipsError = "Couldn't load your tips — tap to try again." }
        }
    }

    // MARK: logging (optimistic — the card appears the instant he sends)

    func logText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        logError = ""
        let p = FoodPending(id: UUID().uuidString, label: t, isPhoto: false, startedAt: Date())
        withAnimation(.snappy(duration: 0.2)) { pending.insert(p, at: 0) }
        Task { await performLog(pendingID: p.id, body: ["text": t]) }
    }

    func logImage(base64: String) {
        logError = ""
        let p = FoodPending(id: UUID().uuidString, label: "Reading your plate…",
                            isPhoto: true, startedAt: Date())
        withAnimation(.snappy(duration: 0.2)) { pending.insert(p, at: 0) }
        Task {
            await performLog(pendingID: p.id,
                             body: ["image_base64": base64, "image_media_type": "image/jpeg"])
        }
    }

    private func performLog(pendingID: String, body: [String: Any]) async {
        do {
            let data = try await Self.request(op: "meal_log", body: body)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let meal = FoodMeal.fromLog(obj)
            withAnimation(.snappy(duration: 0.25)) {
                pending.removeAll { $0.id == pendingID }
                optimisticInsert(meal)
            }
            // Bring in the authoritative totals / ratios / advice behind the paint.
            await refreshDay()
            await refreshWeek()
        } catch {
            withAnimation(.snappy(duration: 0.2)) {
                pending.removeAll { $0.id == pendingID }
            }
            logError = "Scarlet couldn't analyze that — try again."
        }
    }

    /// Drop the new meal into today's list right away and re-sum totals, so the
    /// calorie ring visibly jumps before the server round-trip completes.
    private func optimisticInsert(_ meal: FoodMeal) {
        let base = day ?? FoodDay.empty
        var meals = base.meals
        meals.insert(meal, at: 0)
        let totals = meals.reduce(FoodMacros.zero) { $0.adding($1.totals) }
        day = FoodDay(date: base.date, meals: meals, totals: totals,
                      ratios: FoodRatios.from(totals), targets: base.targets,
                      advice: base.advice)
    }

    // MARK: image encode (nonisolated — no actor state touched)

    /// Downscale the plate to a longest side of ~1024px and JPEG-encode at 0.6
    /// so the base64 payload stays small, then base64.
    nonisolated static func encodePlate(_ image: UIImage) async -> String? {
        plateJPEG(image)?.base64EncodedString()
    }

    private nonisolated static func plateJPEG(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 1024
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        var source = image
        if longest > maxSide, longest > 0 {
            let ratio = maxSide / longest
            let newSize = CGSize(width: max(1, floor(pixelWidth * ratio)),
                                 height: max(1, floor(pixelHeight * ratio)))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            source = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        return source.jpegData(compressionQuality: 0.6)
    }

    // MARK: cache — Documents/food-cache.json (paints instantly on open)

    static var cacheURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("food-cache.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        if let dd = obj["day"] as? [String: Any] { rawDay = dd; day = FoodDay(dict: dd) }
        if let ww = obj["week"] as? [String: Any] { rawWeek = ww; week = FoodWeek(dict: ww) }
        updatedAt = FoodDate.parse(obj["updated"] as? String)
    }

    private func saveCache() {
        var obj: [String: Any] = [:]
        if let rawDay { obj["day"] = rawDay }
        if let rawWeek { obj["week"] = rawWeek }
        if let updatedAt { obj["updated"] = FoodDate.isoPlain.string(from: updatedAt) }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: plumbing (same shape as DraftView.request — apiBase + x-scarlet-token)

    static func request(op: String, body: [String: Any]?) async throws -> Data {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?v=2&op=\(op)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
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

// MARK: - Scope

private enum FoodScope: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    var id: String { rawValue }
}

// MARK: - View

struct FoodView: View {
    @StateObject private var model = FoodModel()
    @EnvironmentObject var convo: Conversation

    @State private var scope: FoodScope = .day
    @State private var mealText = ""
    @FocusState private var composerFocused: Bool
    @State private var showPhotoChooser = false
    @State private var showCamera = false
    @State private var activeSheet: FoodSheet?

    /// ONE `.sheet(item:)` driver (Mac Catalyst allows only one sheet per view):
    /// either the photo-library picker or a meal's detail. The camera is the ONE
    /// `.fullScreenCover` — one sheet + one cover is the Catalyst-safe pair.
    fileprivate enum FoodSheet: Identifiable {
        case photoLibrary
        case mealDetail(FoodMeal)
        var id: String {
            switch self {
            case .photoLibrary: return "photo-library"
            case .mealDetail(let m): return "meal-\(m.id)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                content
            }
            .scarletScreen()
            // Composer + Scarlet presence live at the bottom of the screen, part
            // of its layout — same pattern as Reminders (quick-add + presence).
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    composer
                    ScarletPresenceView(convo: convo)
                        .padding(.vertical, 6)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { convo.setFocus(pageFocus()) }
            .onChange(of: scope) { _, _ in convo.setFocus(pageFocus()) }
            .onChange(of: model.updatedAt) { _, _ in convo.setFocus(pageFocus()) }
            // Her ears close while Ido types into the composer.
            .onChange(of: composerFocused) { _, focused in
                if focused { convo.beginTyping() } else { convo.endTyping() }
            }
            .reportsModalPresence(activeSheet != nil || showCamera)
            .confirmationDialog("Log your plate", isPresented: $showPhotoChooser,
                                titleVisibility: .visible) {
                Button("Camera") {
                    // Simulator / camera-less Mac: fall through to the library
                    // instead of presenting a dead picker.
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCamera = true
                    } else {
                        activeSheet = .photoLibrary
                    }
                }
                Button("Photo Library") { activeSheet = .photoLibrary }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Snap or pick a photo of your meal — Scarlet estimates the calories and macros.")
            }
            .fullScreenCover(isPresented: $showCamera) {
                AttachCameraPicker { image in
                    showCamera = false
                    handlePicked(image)
                }
                .ignoresSafeArea()
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .photoLibrary:
                    AttachPhotoPicker { image in
                        activeSheet = nil
                        handlePicked(image)
                    }
                    .ignoresSafeArea()
                case .mealDetail(let meal):
                    FoodMealDetailSheet(meal: meal)
                        .preferredColorScheme(.dark)
                }
            }
        }
        // Refresh on appear (cache already painted) and on foreground return.
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    // MARK: header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Food")
                .font(.scarletHero)
                .foregroundStyle(.white)
            Spacer()
            if model.refreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.5))
            }
            if let u = model.updatedAt {
                (Text("updated ") + Text(u, style: .relative) + Text(" ago"))
                    .font(.scarletCaption)
                    .foregroundStyle(.white.opacity(0.4))
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
            }
            .disabled(model.refreshing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: content

    private var content: some View {
        ScrollView {
            VStack(spacing: 14) {
                FoodScopePicker(scope: $scope)
                if scope == .day { dayContent } else { weekContent }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .animation(.snappy(duration: 0.3), value: scope)
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.refresh() }
    }

    // MARK: DAY

    @ViewBuilder
    private var dayContent: some View {
        if let d = model.day {
            // Optimistic analyzing cards ride at the very top so the log "jumps".
            ForEach(model.pending) { p in
                FoodPendingCard(pending: p)
            }
            heroCard(d)
            if !d.advice.isEmpty {
                adviceCard(d.advice, title: "Scarlet's take")
            }
            mealsCard(d)
            tipsCard
        } else if !model.pending.isEmpty {
            ForEach(model.pending) { p in FoodPendingCard(pending: p) }
        } else if !model.dayError.isEmpty {
            retryCard(model.dayError) { Task { await model.refreshDay() } }
        } else {
            loadingCard("Loading today…")
        }
    }

    private func heroCard(_ d: FoodDay) -> some View {
        foodCard("Today", icon: "flame.fill", tint: FoodStyle.rose) {
            VStack(spacing: 18) {
                FoodCalorieRing(consumed: d.totals.calories, target: d.targets.calories)
                HStack(spacing: 0) {
                    FoodMacroRing(label: "Protein", grams: d.totals.protein,
                                  pct: d.ratios.protein, target: d.targets.protein,
                                  color: FoodStyle.protein)
                    FoodMacroRing(label: "Carbs", grams: d.totals.carbs,
                                  pct: d.ratios.carbs, target: d.targets.carbs,
                                  color: FoodStyle.carbs)
                    FoodMacroRing(label: "Fat", grams: d.totals.fat,
                                  pct: d.ratios.fat, target: d.targets.fat,
                                  color: FoodStyle.fat)
                }
                if d.totals.fiber > 0 {
                    Text("Fiber \(FoodFmt.grams(d.totals.fiber)) today")
                        .font(.scarletCaption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func mealsCard(_ d: FoodDay) -> some View {
        foodCard("Today's meals", icon: "fork.knife", tint: FoodStyle.fat) {
            if d.meals.isEmpty {
                Text("Nothing logged yet — tell Scarlet what you ate, or snap your plate below.")
                    .font(.scarletBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 10) {
                    ForEach(d.meals) { meal in
                        Button {
                            activeSheet = .mealDetail(meal)
                        } label: {
                            FoodMealCard(meal: meal)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: WEEK

    @ViewBuilder
    private var weekContent: some View {
        if let w = model.week {
            weekCard(w)
            if !w.advice.isEmpty {
                adviceCard(w.advice, title: "Weekly insight")
            }
        } else if !model.weekError.isEmpty {
            retryCard(model.weekError) { Task { await model.refreshWeek() } }
        } else {
            loadingCard("Loading your week…")
        }
    }

    private func weekCard(_ w: FoodWeek) -> some View {
        let target = model.day?.targets.calories ?? 0
        return foodCard("This week", icon: "calendar", tint: FoodStyle.rose) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(FoodFmt.int(w.averages.calories))
                        .font(.scarletHero)
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("avg kcal / day")
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                }
                FoodWeekChart(points: w.days, target: target)
                    .frame(height: 150)
                if target > 0 {
                    Text("Dashed line = \(FoodFmt.int(target)) kcal daily target")
                        .font(.scarletCaption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                HStack(spacing: 8) {
                    FoodMacroChip("Protein", w.averages.protein, FoodStyle.protein)
                    FoodMacroChip("Carbs", w.averages.carbs, FoodStyle.carbs)
                    FoodMacroChip("Fat", w.averages.fat, FoodStyle.fat)
                    Spacer(minLength: 0)
                }
                Text("Average macros per day")
                    .font(.scarletCaption)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    // MARK: advice (per-paragraph RTL/LTR, never hard-coded)

    private func adviceCard(_ text: String, title: String) -> some View {
        foodCard(title, icon: "sparkles", tint: FoodStyle.rose) {
            FoodAdviceText(text: text)
        }
    }

    // MARK: dietitian tips (advice grounded in the numbers + further reading)

    private var tipsCard: some View {
        foodCard("Dietitian tips", icon: "leaf.fill", tint: FoodStyle.good) {
            FoodTipsView(
                tips: model.tips,
                loading: model.tipsLoading,
                error: model.tipsError,
                onRefresh: { Task { await model.refreshTips(force: true) } }
            )
        }
        // Load lazily the first time the card scrolls into view.
        .onAppear { Task { await model.refreshTips() } }
    }

    // MARK: shared card shell (matches HealthView's 20pt card)

    private func foodCard<Content: View>(_ title: String, icon: String, tint: Color,
                                         @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.scarletCaptionEmph)
                    .foregroundStyle(.white.opacity(0.6))
                    .textCase(.uppercase)
                    .kerning(0.8)
            }
            body()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.06)))
    }

    private func loadingCard(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView().tint(FoodStyle.rose)
            Text(text)
                .font(.scarletDetail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private func retryCard(_ message: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.scarletBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: action)
                .buttonStyle(.bordered)
                .tint(FoodStyle.rose)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: composer (the two ways to log — text + photo — plus a voice hint)

    private var trimmedMeal: String {
        mealText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSend: Bool { !trimmedMeal.isEmpty }

    private var composer: some View {
        VStack(spacing: 6) {
            if !model.logError.isEmpty {
                Text(model.logError)
                    .font(.scarletCaption)
                    .foregroundStyle(FoodStyle.fat)
                    .frame(maxWidth: 460, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showPhotoChooser = true
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(FoodStyle.rose)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.white.opacity(0.08)))
                        .overlay(Circle().stroke(FoodStyle.rose.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Photograph your plate")

                ZStack(alignment: .leading) {
                    if mealText.isEmpty {
                        Text("What did you eat?")
                            .font(.scarletBody)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .padding(.leading, 4)
                    }
                    TextField("", text: $mealText, axis: .vertical)
                        .font(.scarletBody)
                        .foregroundStyle(.white)
                        .tint(FoodStyle.rose)
                        .lineLimit(1...3)
                        .focused($composerFocused)
                        .padding(.leading, 4)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.07)))

                // Embedded dictation: tap and speak the meal — no keyboard.
                DictationMicButton(onText: { words in
                    mealText = DictationField.merge(existing: mealText, adding: words)
                }, tint: FoodStyle.rose, size: 44)

                Button {
                    submitText()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? FoodStyle.rose : FoodStyle.rose.opacity(0.35))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            Text("Or just tell Scarlet out loud.")
                .font(.scarletCaption)
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14)
    }

    private func submitText() {
        guard canSend else { return }
        model.logText(trimmedMeal)
        mealText = ""
        composerFocused = false
    }

    /// A picked/shot plate: encode to a small JPEG off the hop, then log.
    private func handlePicked(_ image: UIImage?) {
        guard let image else { return }   // cancelled
        Task { @MainActor in
            guard let encoded = await FoodModel.encodePlate(image) else {
                model.logError = "Couldn't read that photo — try another one."
                return
            }
            model.logImage(base64: encoded)
        }
    }

    // MARK: Scarlet focus (aware of the day, and that Health sits alongside)

    private func pageFocus() -> String {
        guard let d = model.day else {
            return "[FOCUS] Ido is on his Food & Nutrition page. He can tell you what "
                + "he ate (type or say it out loud) or snap a photo of his plate, and "
                + "you log it with calories and macros. Nothing is loaded yet."
        }
        let consumed = FoodFmt.int(d.totals.calories)
        let target = d.targets.calories > 0 ? " of \(FoodFmt.int(d.targets.calories)) target" : ""
        return "[FOCUS] Ido is on his Food & Nutrition page (\(scope.rawValue) view). "
            + "Today: \(consumed) kcal\(target); protein \(FoodFmt.grams(d.totals.protein)), "
            + "carbs \(FoodFmt.grams(d.totals.carbs)), fat \(FoodFmt.grams(d.totals.fat)) "
            + "(\(Int(d.ratios.protein.rounded()))/\(Int(d.ratios.carbs.rounded()))/"
            + "\(Int(d.ratios.fat.rounded()))% by calories). \(d.meals.count) meal(s) logged. "
            + "He can log a meal by telling you what he ate or snapping his plate — analyze "
            + "it for calories and macro balance, and factor in his Health data (activity, "
            + "workouts, body) when you advise him."
    }
}

// MARK: - Scope picker (segmented capsule, matches HealthView's PeriodPicker)

private struct FoodScopePicker: View {
    @Binding var scope: FoodScope

    var body: some View {
        HStack(spacing: 4) {
            ForEach(FoodScope.allCases) { s in
                Button {
                    withAnimation(.snappy(duration: 0.3)) { scope = s }
                } label: {
                    Text(s.rawValue)
                        .font(.scarletDetailEmph)
                        .foregroundStyle(scope == s ? .white : .white.opacity(0.55))
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background {
                            if scope == s {
                                Capsule().fill(FoodStyle.rose.opacity(0.85))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.06)))
    }
}

// MARK: - Calorie ring (hero)

private struct FoodCalorieRing: View {
    let consumed: Double
    let target: Double

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(consumed / target, 1)
    }

    var body: some View {
        let remaining = target - consumed
        ZStack {
            Circle()
                .stroke(FoodStyle.rose.opacity(0.16), lineWidth: 14)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(FoodStyle.rose, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(FoodFmt.int(consumed))
                    .font(.scarletHero)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                if target > 0 {
                    Text("of \(FoodFmt.int(target)) kcal")
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                    Text(remaining >= 0 ? "\(FoodFmt.int(remaining)) left"
                                        : "\(FoodFmt.int(-remaining)) over")
                        .font(.scarletCaptionEmph)
                        .foregroundStyle(remaining >= 0 ? FoodStyle.good : FoodStyle.fat)
                } else {
                    Text("kcal today")
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(width: 200, height: 200)
    }
}

// MARK: - Macro ring (one of three under the hero)

private struct FoodMacroRing: View {
    let label: String
    let grams: Double
    let pct: Double
    let target: Double
    let color: Color

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(grams / target, 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.18), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(FoodFmt.grams(grams))
                        .font(.scarletBodyEmph)
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("\(Int(pct.rounded()))%")
                        .font(.scarletCaption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 78, height: 78)
            Text(label)
                .font(.scarletDetail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Macro chip

private struct FoodMacroChip: View {
    let label: String
    let grams: Double
    let color: Color

    init(_ label: String, _ grams: Double, _ color: Color) {
        self.label = label; self.grams = grams; self.color = color
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.scarletCaptionEmph)
                .foregroundStyle(color)
            Text(FoodFmt.grams(grams))
                .font(.scarletCaption)
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - Meal card

private struct FoodMealCard: View {
    let meal: FoodMeal

    var body: some View {
        let rtl = meal.title.isRTLDominant
        VStack(alignment: .leading, spacing: 8) {
            Text(meal.title)
                .font(.scarletTitle)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(rtl ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            HStack(spacing: 8) {
                if let t = meal.eatenAt {
                    Text(FoodFmt.time(t))
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(FoodFmt.int(meal.totals.calories)) kcal")
                    .font(.scarletBodyEmph)
                    .foregroundStyle(FoodStyle.rose)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            HStack(spacing: 6) {
                FoodMacroChip("P", meal.totals.protein, FoodStyle.protein)
                FoodMacroChip("C", meal.totals.carbs, FoodStyle.carbs)
                FoodMacroChip("F", meal.totals.fat, FoodStyle.fat)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
    }
}

// MARK: - Optimistic "analyzing…" card

private struct FoodPendingCard: View {
    let pending: FoodPending

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().tint(FoodStyle.rose)
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.isPhoto ? "Analyzing your plate…" : "Analyzing…")
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                Text(pending.label)
                    .font(.scarletDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            TimelineView(.periodic(from: pending.startedAt, by: 1)) { ctx in
                Text(FoodFmt.elapsed(ctx.date.timeIntervalSince(pending.startedAt)))
                    .font(.scarletCaption)
                    .foregroundStyle(.white.opacity(0.45))
                    .monospacedDigit()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(FoodStyle.rose.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(FoodStyle.rose.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Advice text (per-paragraph Hebrew RTL / English LTR)

private struct FoodAdviceText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Color.clear.frame(height: 4)
                } else {
                    let rtl = line.isRTLDominant
                    Text(line)
                        .font(.scarletBody)
                        .scarletReadingLineSpacing()
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(rtl ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                }
            }
        }
    }
}

// MARK: - Dietitian tips (advice + focus chips + further-reading links)

private struct FoodTipsView: View {
    let tips: FoodTips?
    let loading: Bool
    let error: String
    let onRefresh: () -> Void

    var body: some View {
        if let t = tips, !t.advice.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                FoodAdviceText(text: t.advice)
                if !t.focus.isEmpty { focusChips(t.focus) }
                if !t.links.isEmpty { linksBlock(t.links) }
                Button(action: onRefresh) {
                    Label("Refresh tips", systemImage: "arrow.clockwise")
                        .font(.scarletCaption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
        } else if loading {
            thinking
        } else if !error.isEmpty {
            Button(action: onRefresh) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text(error)
                        .multilineTextAlignment(.leading)
                }
                .font(.scarletBody)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        } else {
            // Momentary pre-load state before .onAppear kicks the fetch — never a
            // forever spinner (the parent triggers the load immediately).
            thinking
        }
    }

    private var thinking: some View {
        HStack(spacing: 12) {
            ProgressView().tint(FoodStyle.good)
            Text("Scarlet is thinking about your nutrition…")
                .font(.scarletBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func focusChips(_ focus: [String]) -> some View {
        FoodFlowChips(items: focus)
    }

    @ViewBuilder
    private func linksBlock(_ links: [FoodTipLink]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read more")
                .font(.scarletCaptionEmph)
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
                .kerning(0.8)
            ForEach(links) { link in
                Button {
                    open(link.url)
                } label: {
                    FoodTipLinkRow(link: link)
                }
                .buttonStyle(.plain)
                .disabled(link.url == nil)
            }
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        UIApplication.shared.open(url)
    }
}

/// A row of small focus-topic chips ("protein timing", "fiber", …). Only 2-4
/// short keywords, so a horizontal scroll row never clips and stays simple.
private struct FoodFlowChips: View {
    let items: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, topic in
                    Text(topic)
                        .font(.scarletCaptionEmph)
                        .foregroundStyle(FoodStyle.good)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(FoodStyle.good.opacity(0.14)))
                }
            }
            .padding(.vertical, 1)
        }
    }
}

/// One further-reading link — video (▶︎) or article (📄), tappable, source shown.
/// Video links are visually distinct (rose fill + border).
private struct FoodTipLinkRow: View {
    let link: FoodTipLink

    var body: some View {
        let rtl = link.title.isRTLDominant
        HStack(spacing: 10) {
            Image(systemName: link.isVideo ? "play.rectangle.fill" : "doc.text")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(link.isVideo ? FoodStyle.rose : FoodStyle.carbs)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title)
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(rtl ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                Text((link.isVideo ? "Video" : "Article")
                     + (link.source.isEmpty ? "" : " · \(link.source)"))
                    .font(.scarletCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(link.isVideo ? FoodStyle.rose.opacity(0.12) : .white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(link.isVideo ? FoodStyle.rose.opacity(0.30) : .white.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
    }
}

// MARK: - Week chart (self-contained SwiftUI bars + dashed target line)

private struct FoodWeekChart: View {
    let points: [FoodWeekPoint]
    /// 0 = no target line.
    let target: Double

    private var maxValue: Double {
        max(points.map(\.calories).max() ?? 0, target, 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    // Dashed daily-target line.
                    if target > 0 {
                        let ratio = min(target / maxValue, 1)
                        Path { p in
                            let y = geo.size.height * (1 - ratio)
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.white.opacity(0.35))
                    }
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(points) { p in
                            let h = geo.size.height * CGFloat(max(p.calories, 0) / maxValue)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(FoodStyle.rose.gradient)
                                .frame(height: max(h, p.calories > 0 ? 3 : 0))
                                .frame(maxWidth: .infinity, alignment: .bottom)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(points) { p in
                    Text(p.date.map { FoodFmt.weekday($0) } ?? "—")
                        .font(.scarletCaption)
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Meal detail sheet (self-contained; no @EnvironmentObject)

private struct FoodMealDetailSheet: View {
    let meal: FoodMeal
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleBlock
                    totalsBlock
                    if !meal.items.isEmpty { itemsBlock }
                    if !meal.notes.isEmpty { notesBlock }
                }
                .padding(16)
            }
            .scarletScreen()
            .navigationTitle("Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var titleBlock: some View {
        let rtl = meal.title.isRTLDominant
        return VStack(alignment: rtl ? .trailing : .leading, spacing: 4) {
            Text(meal.title)
                .font(.scarletSection)
                .foregroundStyle(.white)
                .multilineTextAlignment(rtl ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            HStack(spacing: 8) {
                if let t = meal.eatenAt {
                    Text(FoodFmt.time(t))
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                }
                if !meal.confidence.isEmpty {
                    Text("estimate: \(meal.confidence)")
                        .font(.scarletCaption)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var totalsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(FoodFmt.int(meal.totals.calories))
                    .font(.scarletHero)
                    .foregroundStyle(.white)
                Text("kcal")
                    .font(.scarletDetail)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                FoodMacroChip("Protein", meal.totals.protein, FoodStyle.protein)
                FoodMacroChip("Carbs", meal.totals.carbs, FoodStyle.carbs)
                FoodMacroChip("Fat", meal.totals.fat, FoodStyle.fat)
                Spacer(minLength: 0)
            }
            if meal.totals.fiber > 0 {
                Text("Fiber \(FoodFmt.grams(meal.totals.fiber))")
                    .font(.scarletCaption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.06)))
    }

    private var itemsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Items")
                .font(.scarletCaptionEmph)
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
                .kerning(0.8)
            ForEach(meal.items) { item in
                let name = item.qty.map { "\(item.name) · \($0)" } ?? item.name
                let rtl = name.isRTLDominant
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name)
                            .font(.scarletBody)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(rtl ? .trailing : .leading)
                            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                        Text("\(FoodFmt.int(item.macros.calories)) kcal")
                            .font(.scarletDetailEmph)
                            .foregroundStyle(FoodStyle.rose)
                    }
                    HStack(spacing: 6) {
                        FoodMacroChip("P", item.macros.protein, FoodStyle.protein)
                        FoodMacroChip("C", item.macros.carbs, FoodStyle.carbs)
                        FoodMacroChip("F", item.macros.fat, FoodStyle.fat)
                        Spacer(minLength: 0)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
            }
        }
    }

    private var notesBlock: some View {
        let rtl = meal.notes.isRTLDominant
        return VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.scarletCaptionEmph)
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
                .kerning(0.8)
            Text(meal.notes)
                .font(.scarletBody)
                .scarletReadingLineSpacing()
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(rtl ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
    }
}
