import SwiftUI

// MARK: - Finance (Ido 2026-10-25: "have Scarlet help me manage my finances";
// section name and shortcut his answer of the same day: Finance, ⌘M).
// Seven leaves over the Finance Desk's ledger: Overview · Transactions · Open ·
// Recurring · Documents · Wires · Sitting. Every op is `finance_<name>` on
// app-api, proxied to finance-desk (`_shared/finance_app.ts`).
//
// • The desk never pays, cancels or moves money. Every button here records
//   his word in the ledger (a category, a class, "paid elsewhere", "I
//   cancelled it") and nothing else.
// • The Sitting is the necessity review: step 1 marks each category
//   necessary, a commitment or optional; step 2 marks each recurring line
//   keep, cut or later. A cut is his intent, shown until he says it is done.
// • iPad/Mac first: a dense table with inline menus. iPhone shows three
//   leaves only (Overview, Open, Sitting) in big type.
// • Shekels and dollars never share a total. Card numbers never appear:
//   the last four digits only, as the server sends them.
// • Same rules as Estate and Travel: reading text white on black; one
//   `.sheet(item:)` per view; per-paragraph text direction.

private enum FinUI {
    static let bg = Color.black
    static let card = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let card2 = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let line = Color(white: 0.22)
    static let muted = Color(white: 0.64)
    static let accent = Color(red: 0.33, green: 0.72, blue: 0.62)   // ledger green, chrome only
    static let scarlet = Color(red: 1, green: 0.35, blue: 0.42)
    static let ok = Color(red: 0.30, green: 0.76, blue: 0.52)
    static let warn = Color(red: 0.94, green: 0.64, blue: 0.23)
    static let body = Font.system(size: 17)
    static let title = Font.system(size: 21, weight: .semibold)
    static let small = Font.system(size: 14)
    static let figure = Font.system(size: 17, weight: .semibold).monospacedDigit()
}

enum FinanceLeaf: String, CaseIterable, Identifiable {
    case overview, transactions, open, recurring, documents, wires, sitting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .transactions: return "Transactions"
        case .open: return "Open"
        case .recurring: return "Recurring"
        case .documents: return "Documents"
        case .wires: return "Wires"
        case .sitting: return "Sitting"
        }
    }
    /// The phone carries the three leaves a small screen is good for.
    static let phone: [FinanceLeaf] = [.overview, .open, .sitting]
}

// MARK: - Wire helpers (rows stay dictionaries: the server owns the shapes)

typealias FinRow = [String: Any]

private func fs(_ o: FinRow, _ k: String) -> String {
    if let s = o[k] as? String { return s }
    if let n = o[k] as? NSNumber { return n.stringValue }
    return ""
}
private func fd(_ o: FinRow, _ k: String) -> Double {
    if let n = o[k] as? NSNumber { return n.doubleValue }
    if let s = o[k] as? String { return Double(s) ?? 0 }
    return 0
}
private func fo(_ o: FinRow, _ k: String) -> FinRow { (o[k] as? FinRow) ?? [:] }
private func fa(_ o: FinRow, _ k: String) -> [FinRow] { (o[k] as? [FinRow]) ?? [] }

private enum FinMoney {
    static func text(_ amount: Double, _ currency: String, cents: Bool = false) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = cents ? 2 : 0
        f.minimumFractionDigits = cents ? 2 : 0
        let n = f.string(from: NSNumber(value: amount)) ?? String(format: "%.0f", amount)
        switch currency.uppercased() {
        case "ILS": return "₪\(n)"
        case "USD": return "$\(n)"
        case "EUR": return "€\(n)"
        case "CHF": return "CHF \(n)"
        case "": return n
        default: return "\(n) \(currency.uppercased())"
        }
    }
    /// "₪1,200 · $300" from a {currency: amount} bag, never one mixed total.
    static func bag(_ o: FinRow) -> String {
        let keys = o.keys.sorted()
        let parts = keys.compactMap { k -> String? in
            let v = fd(o, k)
            return v == 0 ? nil : text(v, k)
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

private enum FinClass {
    static let all = ["essential", "committed", "discretionary"]
    static func label(_ c: String) -> String {
        switch c {
        case "essential": return "Necessary"
        case "committed": return "Commitment"
        case "discretionary": return "Optional"
        case "transfer": return "Transfer"
        case "income": return "Income"
        default: return c.isEmpty ? "—" : c.capitalized
        }
    }
    static func color(_ c: String) -> Color {
        switch c {
        case "essential": return FinUI.ok
        case "committed": return FinUI.accent
        case "discretionary": return FinUI.warn
        default: return FinUI.muted
        }
    }
}

// MARK: - Model

@MainActor
final class FinanceModel: ObservableObject {
    @Published var leaf: FinanceLeaf = .overview
    @Published var mode = ""
    @Published var overview: FinRow = [:]
    @Published var proposals: [FinRow] = []
    @Published var openItems: [FinRow] = []
    @Published var transactions: [FinRow] = []
    @Published var transactionsTotal = 0
    @Published var recurring: [FinRow] = []
    @Published var recurringTotals: FinRow = [:]
    @Published var documents: [FinRow] = []
    @Published var wireMonths: [FinRow] = []
    @Published var wires: [FinRow] = []
    @Published var categories: [FinRow] = []
    @Published var sitting: FinRow = [:]
    @Published var loading = false
    @Published var errorText = ""
    @Published var toast = ""

    // Transactions filters
    @Published var month = FinanceModel.thisMonth()
    @Published var query = ""
    @Published var onlyUncategorized = false

    private var loaded: Set<FinanceLeaf> = []

    static func thisMonth() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }
    static func shift(_ month: String, by delta: Int) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return month }
        var y = parts[0], m = parts[1] + delta
        while m < 1 { m += 12; y -= 1 }
        while m > 12 { m -= 12; y += 1 }
        return String(format: "%04d-%02d", y, m)
    }

    var openCount: Int { openItems.count }
    var sittingLeft: Int { Int(fd(fo(sitting, "progress"), "left")) }
    var paused: Bool { mode == "off" }

    func load(_ which: FinanceLeaf, force: Bool = false) async {
        if !force && loaded.contains(which) { return }
        loading = true
        defer { loading = false }
        errorText = ""
        do {
            switch which {
            case .overview:
                async let o = Self.call("finance_overview", [:])
                async let p = Self.call("finance_proposals", [:])
                async let q = Self.call("finance_open", [:])
                let (or, pr, qr) = try await (o, p, q)
                try check(or)
                overview = or
                mode = fs(or, "mode")
                proposals = fa(pr, "proposals")
                openItems = fa(qr, "items")
            case .transactions:
                if categories.isEmpty { await loadCategories() }
                var body: FinRow = ["month": month, "limit": 300]
                let q = query.trimmingCharacters(in: .whitespaces)
                if q.count >= 2 { body["q"] = q; body.removeValue(forKey: "month") }
                if onlyUncategorized { body["uncategorized"] = true }
                let r = try await Self.call("finance_transactions", body)
                try check(r)
                transactions = fa(r, "rows")
                transactionsTotal = Int(fd(r, "total"))
            case .open:
                if categories.isEmpty { await loadCategories() }
                let r = try await Self.call("finance_open", [:])
                try check(r)
                openItems = fa(r, "items")
            case .recurring:
                let r = try await Self.call("finance_recurring", [:])
                try check(r)
                recurring = fa(r, "lines")
                recurringTotals = fo(r, "annual_by_necessity")
            case .documents:
                let r = try await Self.call("finance_documents", ["limit": 150])
                try check(r)
                documents = fa(r, "documents")
            case .wires:
                let r = try await Self.call("finance_wires", ["months": 12])
                try check(r)
                wireMonths = fa(r, "months")
                wires = fa(r, "wires")
            case .sitting:
                let r = try await Self.call("finance_review", [:])
                try check(r)
                sitting = r
            }
            loaded.insert(which)
        } catch FinanceError.server(let message) {
            errorText = message
        } catch is ScarletAuthError {
            errorText = AuthLapse.rejected()
        } catch {
            errorText = "Couldn't load Finance. Pull to retry."
        }
    }

    private func loadCategories() async {
        guard let r = try? await Self.call("finance_categories", [:]) else { return }
        categories = fa(r, "categories").sorted { fs($0, "name") < fs($1, "name") }
    }

    enum FinanceError: Error { case server(String) }
    private func check(_ r: FinRow) throws {
        if (r["ok"] as? Bool) == false { throw FinanceError.server(fs(r, "error").isEmpty ? "Finance did not answer." : fs(r, "error")) }
    }

    /// One act: his word into the ledger, then the current leaf is read again.
    @discardableResult
    func act(_ op: String, _ body: FinRow, success: String) async -> Bool {
        do {
            let r = try await Self.call(op, body)
            if (r["ok"] as? Bool) == false {
                errorText = fs(r, "error").isEmpty ? "That didn't work. Nothing was changed." : fs(r, "error")
                return false
            }
            errorText = ""
            show(success)
            loaded.remove(.overview)
            await load(leaf, force: true)
            return true
        } catch {
            errorText = "No connection. Nothing was changed."
            return false
        }
    }

    func show(_ text: String) {
        toast = text
        Task { try? await Task.sleep(nanoseconds: 2_600_000_000); if self.toast == text { self.toast = "" } }
    }

    static func call(_ op: String, _ body: FinRow) async throws -> FinRow {
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "op", value: op)]
        var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 { throw ScarletAuthError() }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return ((try? JSONSerialization.jsonObject(with: data)) as? FinRow) ?? [:]
    }
}

// MARK: - Page

struct FinanceView: View {
    @StateObject private var model = FinanceModel()
    @EnvironmentObject private var convo: Conversation
    @Environment(\.horizontalSizeClass) private var hSize

    /// The one sheet of this view (Mac Catalyst allows one per view).
    enum FinanceSheet: Identifiable {
        case answer(questionID: String, title: String)
        case note(recurringID: String, title: String)
        var id: String {
            switch self {
            case .answer(let q, _): return "answer-\(q)"
            case .note(let r, _): return "note-\(r)"
            }
        }
    }
    @State private var activeSheet: FinanceSheet?
    @State private var sittingStep = 0

    private var wide: Bool { hSize == .regular }
    private var leaves: [FinanceLeaf] { wide ? FinanceLeaf.allCases : FinanceLeaf.phone }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                content
            }
            .background(FinUI.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if !model.toast.isEmpty {
                        Text(model.toast).font(FinUI.small.weight(.semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(FinUI.accent.opacity(0.85)))
                    }
                    ScarletPresenceView(convo: convo).padding(.vertical, 6)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.load(model.leaf) }
            .onAppear {
                if !leaves.contains(model.leaf) { model.leaf = .overview }
                convo.setFocus(focusLine)
            }
            .onChange(of: model.leaf) { _, newLeaf in
                convo.setFocus(focusLine)
                Task { await model.load(newLeaf) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await model.load(model.leaf, force: true) }
            }
            .reportsModalPresence(activeSheet != nil)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .answer(let qid, let title):
                    FinanceTextSheet(title: title, prompt: "Your answer", placeholder: "One line. It becomes a rule.") { text in
                        Task { await model.act("finance_answer", ["question_id": qid, "answer": text], success: "Answered") }
                    }
                case .note(let rid, let title):
                    FinanceTextSheet(title: title, prompt: "A note of use", placeholder: "When you last used it, or why you keep it") { text in
                        Task { await model.act("finance_note", ["recurring_id": rid, "note": text], success: "Noted") }
                    }
                }
            }
        }
    }

    private var focusLine: String {
        "[FOCUS] Ido is in the Finance section, \(model.leaf.title) (\(model.openCount) open). Finance questions → the finance tool. The desk never pays or cancels."
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Finance").font(.system(size: 34, weight: .bold)).foregroundColor(.white)
                if model.openCount > 0 {
                    Text("\(model.openCount) open").font(FinUI.small.weight(.bold)).foregroundColor(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(FinUI.scarlet))
                }
                Spacer()
                if model.loading { ProgressView().tint(FinUI.muted) }
                Button { Task { await model.load(model.leaf, force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).font(FinUI.small)
            }
            Picker("Section", selection: $model.leaf) {
                ForEach(leaves) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if model.paused {
                Text("The Finance Desk is paused. What you see is the ledger as it was.").font(FinUI.small).foregroundColor(FinUI.warn)
            }
            if !model.errorText.isEmpty { Text(model.errorText).font(FinUI.small).foregroundColor(FinUI.warn) }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        switch model.leaf {
        case .overview: overviewPane
        case .transactions: transactionsPane
        case .open: openPane
        case .recurring: recurringPane
        case .documents: documentsPane
        case .wires: wiresPane
        case .sitting: sittingPane
        }
    }

    // MARK: shared pieces

    private func card<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { inner() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(FinUI.card))
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(1.2).foregroundColor(FinUI.muted)
    }

    /// A merchant or a bank line as the bank wrote it: its own direction.
    private func nameText(_ s: String, size: CGFloat = 17, weight: Font.Weight = .regular) -> some View {
        Text(s.isEmpty ? "—" : s)
            .font(.system(size: size, weight: weight))
            .foregroundColor(.white)
            .lineLimit(2)
            .multilineTextAlignment(s.isRTLDominant ? .trailing : .leading)
            .environment(\.layoutDirection, s.layoutDir)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().stroke(color.opacity(0.7), lineWidth: 1))
    }

    private func emptyState(_ text: String) -> some View {
        Text(text).font(FinUI.body).foregroundColor(FinUI.muted)
            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
    }

    private func pane<Content: View>(@ViewBuilder _ inner: @escaping () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { inner() }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 24)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .refreshable { await model.load(model.leaf, force: true) }
    }

    // MARK: overview

    private var overviewPane: some View {
        pane {
            let spend = fo(model.overview, "spend")
            let month = fd(spend, "month_ils"), last = fd(spend, "last_month_ils")
            card {
                sectionTitle("This month, \(fs(model.overview, "month"))")
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(FinMoney.text(month, "ILS")).font(.system(size: wide ? 40 : 46, weight: .bold).monospacedDigit()).foregroundColor(.white)
                    Text("last month \(FinMoney.text(last, "ILS"))").font(FinUI.small).foregroundColor(FinUI.muted)
                }
                Text("Spending only, at the month's rate. Transfers between your own accounts and card repayments are not counted.")
                    .font(FinUI.small).foregroundColor(FinUI.muted)
                necessityBars(fo(spend, "by_necessity"))
            }
            if !fa(spend, "top_categories").isEmpty {
                card {
                    sectionTitle("Where it went")
                    ForEach(Array(fa(spend, "top_categories").enumerated()), id: \.offset) { _, c in
                        HStack {
                            Text(fs(c, "name")).font(FinUI.body).foregroundColor(.white)
                            chip(FinClass.label(fs(c, "necessity")), FinClass.color(fs(c, "necessity")))
                            Spacer()
                            if c["delta_pct"] is NSNumber {
                                let d = fd(c, "delta_pct")
                                Text("\(d >= 0 ? "+" : "")\(Int(d))% vs 3 months").font(FinUI.small).foregroundColor(d > 15 ? FinUI.warn : FinUI.muted)
                            }
                            Text(FinMoney.text(fd(c, "ils"), "ILS")).font(FinUI.figure).foregroundColor(.white)
                        }
                    }
                }
            }
            if model.sittingLeft > 0 {
                card {
                    sectionTitle("The sitting")
                    Text("\(model.sittingLeft) marks are left: which categories are necessary, and which recurring lines you keep.")
                        .font(FinUI.body).foregroundColor(.white)
                    Button("Open the sitting") { model.leaf = .sitting }.buttonStyle(.borderedProminent).tint(FinUI.accent)
                }
            }
            if !model.proposals.isEmpty {
                card {
                    sectionTitle("Ideas to spend less")
                    ForEach(Array(model.proposals.prefix(6).enumerated()), id: \.offset) { _, p in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                nameText(fs(p, "action"), weight: .semibold)
                                Spacer()
                                Text("\(FinMoney.text(fd(p, "annual_saving"), fs(p, "currency"))) a year").font(FinUI.figure).foregroundColor(FinUI.ok)
                            }
                            Text(fs(p, "evidence")).font(FinUI.small).foregroundColor(FinUI.muted)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            card {
                sectionTitle("Accounts")
                ForEach(Array(fa(model.overview, "accounts").enumerated()), id: \.offset) { _, a in
                    HStack {
                        Text("\(fs(a, "name")) ·\(fs(a, "last4").isEmpty ? "—" : fs(a, "last4"))").font(FinUI.body).foregroundColor(.white)
                        Spacer()
                        if (a["stale"] as? Bool) == true { chip("No recent sync", FinUI.warn) }
                        Text(String(fs(a, "last_good_sync_at").prefix(10))).font(FinUI.small).foregroundColor(FinUI.muted)
                    }
                }
                if fa(model.overview, "accounts").isEmpty { Text("No account is connected.").font(FinUI.small).foregroundColor(FinUI.muted) }
            }
        }
    }

    private func necessityBars(_ by: FinRow) -> some View {
        let keys = FinClass.all.filter { fd(by, $0) > 0 }
        let total = max(keys.reduce(0.0) { $0 + fd(by, $1) }, 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(keys, id: \.self) { k in
                HStack(spacing: 10) {
                    Text(FinClass.label(k)).font(FinUI.small).foregroundColor(.white).frame(width: 96, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4).fill(FinClass.color(k))
                            .frame(width: max(4, geo.size.width * CGFloat(fd(by, k) / total)))
                    }
                    .frame(height: 10)
                    Text(FinMoney.text(fd(by, k), "ILS")).font(FinUI.small.monospacedDigit()).foregroundColor(.white).frame(width: 96, alignment: .trailing)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: transactions

    private var transactionsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.month = FinanceModel.shift(model.month, by: -1); reloadTransactions() } label: { Image(systemName: "chevron.left") }
                Text(model.month).font(FinUI.figure).foregroundColor(.white)
                Button { model.month = FinanceModel.shift(model.month, by: 1); reloadTransactions() } label: { Image(systemName: "chevron.right") }
                    .disabled(model.month >= FinanceModel.thisMonth())
                TextField("Search a merchant, any month", text: $model.query)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    .onSubmit { reloadTransactions() }
                Toggle("No category yet", isOn: $model.onlyUncategorized)
                    .toggleStyle(.button).font(FinUI.small)
                    .onChange(of: model.onlyUncategorized) { _, _ in reloadTransactions() }
                Spacer()
                Text("\(model.transactions.count) of \(model.transactionsTotal)").font(FinUI.small).foregroundColor(FinUI.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider().background(FinUI.line)
            if model.transactions.isEmpty && !model.loading {
                emptyState("No rows for this view.")
                Spacer()
            } else {
                List {
                    ForEach(model.transactions.indices, id: \.self) { i in
                        transactionRow(model.transactions[i])
                            .listRowBackground(FinUI.bg)
                            .listRowSeparatorTint(FinUI.line)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await model.load(.transactions, force: true) }
            }
        }
    }

    private func reloadTransactions() { Task { await model.load(.transactions, force: true) } }

    private func transactionRow(_ t: FinRow) -> some View {
        let incoming = fs(t, "direction") == "in"
        let name = fs(t, "merchant").isEmpty ? (fs(t, "merchant_raw").isEmpty ? fs(t, "counterparty") : fs(t, "merchant_raw")) : fs(t, "merchant")
        let cls = fs(t, "necessity_effective")
        return HStack(spacing: 12) {
            Text(String(fs(t, "posted_at").suffix(5))).font(FinUI.small.monospacedDigit()).foregroundColor(FinUI.muted).frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                nameText(name)
                if !fs(t, "note").isEmpty { Text(fs(t, "note")).font(FinUI.small).foregroundColor(FinUI.muted).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if fs(t, "status") == "pending" { chip("Pending", FinUI.muted) }
            categoryMenu(current: fs(t, "category"), transactionID: fs(t, "id"))
            classMenu(current: cls) { c in
                Task { await model.act("finance_categorize", ["transaction_id": fs(t, "id"), "necessity": c], success: "Marked \(FinClass.label(c).lowercased())") }
            }
            Text("\(incoming ? "+" : "")\(FinMoney.text(fd(t, "amount"), fs(t, "currency"), cents: true))")
                .font(FinUI.figure).foregroundColor(incoming ? FinUI.ok : .white)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    /// Inline categorise, like a cell in a sheet. His choice teaches the rule
    /// and applies to the same merchant's rows he has not reviewed.
    private func categoryMenu(current: String, transactionID: String) -> some View {
        Menu {
            ForEach(Array(model.categories.enumerated()), id: \.offset) { _, c in
                Button(fs(c, "name")) {
                    Task { await model.act("finance_categorize", ["transaction_id": transactionID, "category_id": fs(c, "id")], success: "Filed under \(fs(c, "name"))") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.isEmpty ? "No category" : current).font(FinUI.small).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10))
            }
            .foregroundColor(current.isEmpty ? FinUI.warn : .white)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(FinUI.card2))
            .frame(width: 190, alignment: .leading)
        }
    }

    private func classMenu(current: String, pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(FinClass.all, id: \.self) { c in
                Button(FinClass.label(c)) { pick(c) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(FinClass.label(current)).font(FinUI.small).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10))
            }
            .foregroundColor(FinClass.color(current))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(FinUI.card2))
            .frame(width: 130, alignment: .leading)
        }
    }

    // MARK: open

    private var openPane: some View {
        pane {
            if model.openItems.isEmpty && !model.loading { emptyState("Nothing is open.") }
            ForEach(Array(model.openItems.enumerated()), id: \.offset) { _, item in
                openCard(item)
            }
        }
    }

    private func openCard(_ item: FinRow) -> some View {
        let ids = fo(item, "ids")
        let qid = fs(ids, "question_id"), tid = fs(ids, "transaction_id"), did = fs(ids, "document_id"), rid = fs(ids, "recurring_id")
        let kind = fs(item, "kind")
        return card {
            HStack(alignment: .top) {
                Circle().fill(fd(item, "severity") >= 3 ? FinUI.scarlet : (fd(item, "severity") >= 2 ? FinUI.warn : FinUI.muted)).frame(width: 9, height: 9).padding(.top, 7)
                VStack(alignment: .leading, spacing: 4) {
                    nameText(fs(item, "title"), size: wide ? 17 : 19, weight: .semibold)
                    if !fs(item, "detail").isEmpty { Text(fs(item, "detail")).font(FinUI.small).foregroundColor(FinUI.muted) }
                    Text(fs(item, "next_step")).font(FinUI.small).foregroundColor(.white.opacity(0.85))
                }
            }
            HStack(spacing: 8) {
                if !qid.isEmpty {
                    Button("Answer") { activeSheet = .answer(questionID: qid, title: fs(item, "title")) }.buttonStyle(.borderedProminent).tint(FinUI.accent)
                    Button("Later") { Task { await model.act("finance_snooze", ["question_id": qid, "days": 7], success: "Asked again in a week") } }.buttonStyle(.bordered)
                    Button("Not needed") { Task { await model.act("finance_dismiss_question", ["question_id": qid], success: "Closed") } }.buttonStyle(.bordered)
                }
                if !tid.isEmpty && qid.isEmpty {
                    categoryMenu(current: "", transactionID: tid)
                }
                if !did.isEmpty && qid.isEmpty {
                    Button("Paid elsewhere") { Task { await model.act("finance_paid", ["document_id": did], success: "Marked paid elsewhere") } }.buttonStyle(.bordered)
                    Button("Not a bill") { Task { await model.act("finance_dismiss_document", ["document_id": did], success: "Closed") } }.buttonStyle(.bordered)
                }
                if kind == "price_jump" && !rid.isEmpty {
                    Button("This is normal") {
                        Task { await model.act("finance_note", ["recurring_id": rid, "note": "Accepted as the normal amount", "accept_amount": fd(item, "amount")], success: "Accepted as normal") }
                    }.buttonStyle(.bordered)
                }
                if kind == "charged_after_cancel" && !rid.isEmpty {
                    Button("It is active again") { Task { await model.act("finance_reactivate", ["recurring_id": rid], success: "Marked active") } }.buttonStyle(.bordered)
                }
            }
            .font(FinUI.small)
        }
    }

    // MARK: recurring

    private var recurringPane: some View {
        pane {
            card {
                sectionTitle("A year of the active lines, by class")
                ForEach(model.recurringTotals.keys.sorted(), id: \.self) { cur in
                    let by = fo(model.recurringTotals, cur)
                    HStack(spacing: 14) {
                        ForEach(FinClass.all.filter { fd(by, $0) > 0 }, id: \.self) { k in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(FinClass.label(k)).font(FinUI.small).foregroundColor(FinClass.color(k))
                                Text(FinMoney.text(fd(by, k), cur)).font(FinUI.figure).foregroundColor(.white)
                            }
                        }
                    }
                }
            }
            ForEach(Array(model.recurring.enumerated()), id: \.offset) { _, l in
                recurringRow(l)
            }
        }
    }

    private func recurringRow(_ l: FinRow) -> some View {
        let rid = fs(l, "id"), status = fs(l, "status"), incoming = fs(l, "direction") == "in"
        return card {
            HStack(alignment: .firstTextBaseline) {
                nameText(fs(l, "merchant"), weight: .semibold)
                if status != "active" { chip(status == "cancelled_by_ido" ? "Cancelled by you" : "Lapsed", FinUI.muted) }
                if incoming { chip("Income", FinUI.ok) }
                Spacer()
                Text("\(FinMoney.text(fd(l, "typical_amount"), fs(l, "currency"), cents: true)) \(fs(l, "cadence"))").font(FinUI.small).foregroundColor(FinUI.muted)
                Text("\(FinMoney.text(fd(l, "annual"), fs(l, "currency"))) a year").font(FinUI.figure).foregroundColor(.white)
            }
            HStack(spacing: 8) {
                Text("\(fs(l, "category").isEmpty ? "No category" : fs(l, "category")) · last seen \(fs(l, "last_seen"))").font(FinUI.small).foregroundColor(FinUI.muted)
                Spacer()
                if !incoming {
                    classMenu(current: fs(l, "necessity_effective")) { c in
                        Task { await model.act("finance_necessity", ["recurring_id": rid, "necessity": c], success: "Marked \(FinClass.label(c).lowercased())") }
                    }
                    Button("Note") { activeSheet = .note(recurringID: rid, title: fs(l, "merchant")) }.buttonStyle(.bordered)
                    if status == "cancelled_by_ido" {
                        Button("Active again") { Task { await model.act("finance_reactivate", ["recurring_id": rid], success: "Marked active") } }.buttonStyle(.bordered)
                    } else {
                        Button("I cancelled it") { Task { await model.act("finance_cancelled", ["recurring_id": rid], success: "Recorded. I will flag a new charge.") } }.buttonStyle(.bordered)
                    }
                }
            }
            .font(FinUI.small)
            if !fs(l, "last_used_note").isEmpty { Text(fs(l, "last_used_note")).font(FinUI.small).foregroundColor(.white.opacity(0.85)) }
        }
    }

    // MARK: documents

    private var documentsPane: some View {
        pane {
            if model.documents.isEmpty && !model.loading { emptyState("No documents yet.") }
            ForEach(Array(model.documents.enumerated()), id: \.offset) { _, d in
                let status = fs(d, "status"), did = fs(d, "id")
                card {
                    HStack(alignment: .firstTextBaseline) {
                        nameText(fs(d, "payee").isEmpty ? fs(d, "kind").capitalized : fs(d, "payee"), weight: .semibold)
                        chip(status.replacingOccurrences(of: "_", with: " ").capitalized, status == "open" ? FinUI.warn : (status == "matched" ? FinUI.ok : FinUI.muted))
                        Spacer()
                        Text(fs(d, "doc_date")).font(FinUI.small).foregroundColor(FinUI.muted)
                        Text(FinMoney.text(fd(d, "amount"), fs(d, "currency"), cents: true)).font(FinUI.figure).foregroundColor(.white)
                    }
                    if !fs(d, "summary").isEmpty {
                        let s = fs(d, "summary")
                        Text(s).font(FinUI.small).foregroundColor(FinUI.muted).lineLimit(3)
                            .multilineTextAlignment(s.isRTLDominant ? .trailing : .leading)
                            .frame(maxWidth: .infinity, alignment: s.isRTLDominant ? .trailing : .leading)
                    }
                    if status == "open" {
                        HStack(spacing: 8) {
                            Button("Paid elsewhere") { Task { await model.act("finance_paid", ["document_id": did], success: "Marked paid elsewhere") } }.buttonStyle(.bordered)
                            Button("Not a bill") { Task { await model.act("finance_dismiss_document", ["document_id": did], success: "Closed") } }.buttonStyle(.bordered)
                        }
                        .font(FinUI.small)
                    }
                }
            }
        }
    }

    // MARK: wires

    private var wiresPane: some View {
        pane {
            card {
                sectionTitle("By month")
                HStack {
                    Text("Month").frame(width: 80, alignment: .leading)
                    Text("Into Bank of America").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("To suppliers, dollars").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("To suppliers, shekels").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(FinUI.small).foregroundColor(FinUI.muted)
                ForEach(Array(model.wireMonths.enumerated()), id: \.offset) { _, m in
                    HStack {
                        Text(fs(m, "month")).frame(width: 80, alignment: .leading)
                        Text(FinMoney.text(fd(m, "inflow_usd"), "USD")).frame(maxWidth: .infinity, alignment: .trailing)
                        Text(FinMoney.text(fd(m, "supplier_usd"), "USD")).frame(maxWidth: .infinity, alignment: .trailing)
                        Text(FinMoney.text(fd(m, "supplier_ils"), "ILS")).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(FinUI.body.monospacedDigit()).foregroundColor(.white)
                }
            }
            ForEach(Array(model.wires.enumerated()), id: \.offset) { _, w in
                let status = fs(w, "status")
                card {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: fs(w, "direction") == "in" ? "arrow.down.left" : "arrow.up.right").foregroundColor(FinUI.muted)
                        nameText(fs(w, "payee").isEmpty ? fs(w, "originator") : fs(w, "payee"), weight: .semibold)
                        chip(status.capitalized, status == "stale" ? FinUI.scarlet : FinUI.muted)
                        Spacer()
                        Text(String((fs(w, "arrived_at").isEmpty ? fs(w, "instructed_at") : fs(w, "arrived_at")).prefix(10))).font(FinUI.small).foregroundColor(FinUI.muted)
                        Text(FinMoney.text(fd(w, "amount"), fs(w, "currency"))).font(FinUI.figure).foregroundColor(.white)
                    }
                }
            }
        }
    }

    // MARK: the sitting

    private var sittingPane: some View {
        let progress = fo(model.sitting, "progress")
        let cats = fa(model.sitting, "categories"), lines = fa(model.sitting, "lines")
        let total = cats.count + lines.count
        let left = Int(fd(progress, "left"))
        return pane {
            card {
                sectionTitle("What is necessary, and what is not")
                Text(total == 0 ? "Nothing to mark yet." : (left == 0 ? "Every line is marked." : "\(left) of \(total) marks are left."))
                    .font(FinUI.title).foregroundColor(.white)
                ProgressView(value: Double(max(total - left, 0)), total: Double(max(total, 1))).tint(FinUI.accent)
                Text("Step 1 marks each category. Step 2 marks each recurring line, largest first. A cut is your decision; nothing is cancelled for you, and I list the cuts until you tell me each one is done.")
                    .font(FinUI.small).foregroundColor(FinUI.muted)
                Picker("Step", selection: $sittingStep) {
                    Text("1. Categories (\(Int(fd(progress, "categories_marked")))/\(cats.count))").tag(0)
                    Text("2. Recurring (\(Int(fd(progress, "lines_decided")))/\(lines.count))").tag(1)
                }
                .pickerStyle(.segmented)
            }
            if sittingStep == 0 {
                ForEach(Array(cats.enumerated()), id: \.offset) { _, c in sittingCategoryRow(c) }
                let unc = fo(model.sitting, "uncategorized")
                if fd(unc, "rows") > 0 {
                    Text("\(Int(fd(unc, "rows"))) rows of the year have no category yet (\(FinMoney.text(fd(unc, "year_ils"), "ILS"))). They are in Transactions, under \"No category yet\".")
                        .font(FinUI.small).foregroundColor(FinUI.muted)
                }
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in sittingLineRow(l) }
                sittingSummaryCard
            }
        }
    }

    private func sittingCategoryRow(_ c: FinRow) -> some View {
        let cid = fs(c, "id"), cls = fs(c, "necessity"), marked = (c["marked"] as? Bool) == true
        return card {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: marked ? "checkmark.circle.fill" : "circle").foregroundColor(marked ? FinUI.ok : FinUI.muted)
                Text(fs(c, "name")).font(wide ? FinUI.body.weight(.semibold) : FinUI.title).foregroundColor(.white)
                Spacer()
                Text("\(FinMoney.bag(fo(c, "year_by_currency"))) in a year").font(FinUI.figure).foregroundColor(.white)
            }
            HStack(spacing: 8) {
                ForEach(FinClass.all, id: \.self) { k in
                    choiceButton(FinClass.label(k), on: marked && cls == k, hint: !marked && cls == k, color: FinClass.color(k)) {
                        Task { await model.act("finance_review_mark", ["category_id": cid, "necessity": k], success: "\(fs(c, "name")): \(FinClass.label(k).lowercased())") }
                    }
                }
            }
        }
    }

    private func sittingLineRow(_ l: FinRow) -> some View {
        let rid = fs(l, "id"), decision = fs(l, "decision")
        return card {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: decision.isEmpty ? "circle" : (decision == "later" ? "clock" : "checkmark.circle.fill"))
                    .foregroundColor(decision.isEmpty ? FinUI.muted : (decision == "cut" ? FinUI.scarlet : FinUI.ok))
                nameText(fs(l, "merchant"), size: wide ? 17 : 19, weight: .semibold)
                chip(FinClass.label(fs(l, "necessity")), FinClass.color(fs(l, "necessity")))
                Spacer()
                Text("\(FinMoney.text(fd(l, "annual"), fs(l, "currency"))) a year").font(FinUI.figure).foregroundColor(.white)
            }
            Text("\(FinMoney.text(fd(l, "typical_amount"), fs(l, "currency"), cents: true)) \(fs(l, "cadence")) · \(fs(l, "category").isEmpty ? "no category" : fs(l, "category")) · last seen \(fs(l, "last_seen"))")
                .font(FinUI.small).foregroundColor(FinUI.muted)
            if !fs(l, "last_used_note").isEmpty { Text(fs(l, "last_used_note")).font(FinUI.small).foregroundColor(.white.opacity(0.85)) }
            HStack(spacing: 8) {
                choiceButton("Keep", on: decision == "keep", hint: false, color: FinUI.ok) {
                    Task { await model.act("finance_review_mark", ["recurring_id": rid, "decision": "keep"], success: "Keep") }
                }
                choiceButton("Cut", on: decision == "cut", hint: false, color: FinUI.scarlet) {
                    Task { await model.act("finance_review_mark", ["recurring_id": rid, "decision": "cut"], success: "Marked to cut. Nothing is cancelled for you.") }
                }
                choiceButton("Later", on: decision == "later", hint: false, color: FinUI.muted) {
                    Task { await model.act("finance_review_mark", ["recurring_id": rid, "decision": "later"], success: "Asked again next time") }
                }
                Spacer()
                classMenu(current: fs(l, "necessity")) { c in
                    Task { await model.act("finance_review_mark", ["recurring_id": rid, "necessity": c], success: "Marked \(FinClass.label(c).lowercased())") }
                }
            }
            if decision == "cut" && !fs(l, "cancel_path").isEmpty {
                Text("How to cancel: \(fs(l, "cancel_path"))").font(FinUI.small).foregroundColor(FinUI.warn)
            }
        }
    }

    private var sittingSummaryCard: some View {
        let summary = fo(model.sitting, "summary")
        let byDecision = fo(summary, "annual_by_decision")
        return card {
            sectionTitle("A year of the recurring lines, by your decision")
            ForEach(byDecision.keys.sorted(), id: \.self) { cur in
                let by = fo(byDecision, cur)
                HStack(spacing: 14) {
                    ForEach(["keep", "cut", "later", "undecided"].filter { fd(by, $0) > 0 }, id: \.self) { k in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.capitalized).font(FinUI.small).foregroundColor(k == "cut" ? FinUI.scarlet : FinUI.muted)
                            Text(FinMoney.text(fd(by, k), cur)).font(FinUI.figure).foregroundColor(.white)
                        }
                    }
                }
            }
            Button("Close the sitting") {
                Task { await model.act("finance_review_finish", [:], success: "The sitting is closed. The cuts lead your ideas list.") }
            }
            .buttonStyle(.borderedProminent).tint(FinUI.accent)
        }
    }

    private func choiceButton(_ title: String, on: Bool, hint: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: wide ? 15 : 17, weight: .semibold))
                .foregroundColor(on ? .black : (hint ? color : .white))
                .padding(.horizontal, 14).padding(.vertical, wide ? 7 : 10)
                .background(RoundedRectangle(cornerRadius: 9).fill(on ? color : FinUI.card2))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(hint ? color.opacity(0.8) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The one text sheet (an answer, a note)

private struct FinanceTextSheet: View {
    let title: String
    let prompt: String
    let placeholder: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 19, weight: .semibold)).foregroundColor(.white)
                    .multilineTextAlignment(title.isRTLDominant ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: title.isRTLDominant ? .trailing : .leading)
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 17))
                Spacer()
            }
            .padding(18)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(prompt)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { onSave(t) }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
