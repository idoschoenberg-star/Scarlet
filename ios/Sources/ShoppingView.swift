import SwiftUI

// MARK: - Shopping (Ido 2026-11-23: "really very easily order items and do
// sophisticated product searches"; his choice the same day: "One tap, I
// press Buy in the store").
// Four leaves over the Shopping Desk: Buy · On the way · Lists · Watches.
// Every op is `shopping_<name>` on app-api, proxied to shopping-desk
// (`_shared/shopping_app.ts`); the whole page is one read, `shopping_board`.
//
// • The desk never buys. The Buy button here is his yes to the exact line on
//   the screen: the server records it and hands the store page, the app
//   opens that page in his own account, and the store's Buy is his own tap.
// • A line is read back when its sheet opens (`shopping_proposal` stamps
//   it); the yes echoes the line as shown, so a line that changed in the
//   meantime is refused by the server and shown again.
// • iPad/Mac first: two columns (what waits and the search on the left,
//   what is due on the right). iPhone stacks the same cards.
// • Same rules as Estate, Travel and Finance: reading text white on black;
//   one `.sheet(item:)` per view; per-paragraph text direction.

private enum ShopUI {
    static let bg = Color.black
    static let card = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let card2 = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let muted = Color(white: 0.64)
    static let accent = Color(red: 0.96, green: 0.62, blue: 0.26)   // parcel amber, chrome only
    static let scarlet = Color(red: 1, green: 0.35, blue: 0.42)
    static let ok = Color(red: 0.30, green: 0.76, blue: 0.52)
    static let warn = Color(red: 0.94, green: 0.64, blue: 0.23)
    static let body = Font.system(size: 17)
    static let title = Font.system(size: 21, weight: .semibold)
    static let small = Font.system(size: 14)
    static let figure = Font.system(size: 17, weight: .semibold).monospacedDigit()
}

enum ShoppingLeaf: String, CaseIterable, Identifiable {
    case buy, onTheWay, lists, watches
    var id: String { rawValue }
    var title: String {
        switch self {
        case .buy: return "Buy"
        case .onTheWay: return "On the way"
        case .lists: return "Lists"
        case .watches: return "Watches"
        }
    }
}

// MARK: - Wire helpers (rows stay dictionaries: the server owns the shapes)

typealias ShopRow = [String: Any]

private func ss(_ o: ShopRow, _ k: String) -> String {
    if let s = o[k] as? String { return s }
    if let n = o[k] as? NSNumber { return n.stringValue }
    return ""
}
private func sd(_ o: ShopRow, _ k: String) -> Double? {
    if let n = o[k] as? NSNumber { return n.doubleValue }
    if let s = o[k] as? String { return Double(s) }
    return nil
}
private func so(_ o: ShopRow, _ k: String) -> ShopRow { (o[k] as? ShopRow) ?? [:] }
private func sa(_ o: ShopRow, _ k: String) -> [ShopRow] { (o[k] as? [ShopRow]) ?? [] }

private enum ShopMoney {
    static func text(_ amount: Double?, _ currency: String) -> String {
        guard let amount else { return "no price" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        let n = f.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
        switch currency.uppercased() {
        case "ILS": return "₪\(n)"
        case "USD": return "$\(n)"
        case "EUR": return "€\(n)"
        case "CHF": return "CHF \(n)"
        case "": return n
        default: return "\(n) \(currency.uppercased())"
        }
    }
}

private enum ShopStore {
    static func label(_ r: String) -> String {
        switch r {
        case "amazon_us": return "Amazon"
        case "amazon_de": return "Amazon Germany"
        case "whole_foods": return "Whole Foods"
        case "wolt": return "Wolt"
        case "grubhub": return "Grubhub"
        case "local": return "A shop"
        case "": return ""
        default: return r.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    static func day(_ iso: String) -> String {
        let d = String(iso.prefix(10))
        let inF = DateFormatter()
        inF.calendar = Calendar(identifier: .gregorian)
        inF.locale = Locale(identifier: "en_US_POSIX")
        inF.timeZone = TimeZone(identifier: "UTC")
        inF.dateFormat = "yyyy-MM-dd"
        guard let date = inF.date(from: d) else { return d }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = "d MMM"
        return out.string(from: date)
    }
}

// MARK: - Model

@MainActor
final class ShoppingModel: ObservableObject {
    @Published var leaf: ShoppingLeaf = .buy
    @Published var paused = false
    @Published var researchOn = true
    @Published var proposals: [ShopRow] = []
    @Published var due: [ShopRow] = []
    @Published var deliveries: [ShopRow] = []
    @Published var lists: [ShopRow] = []
    @Published var orders: [ShopRow] = []
    @Published var watches: [ShopRow] = []
    @Published var choices: [ShopRow] = []
    @Published var loading = false
    @Published var busy = false
    @Published var errorText = ""
    @Published var toast = ""

    // The search box
    @Published var need = ""
    @Published var ceiling = ""
    @Published var currency = "USD"
    @Published var store = ""

    private var loadedOnce = false
    private var pollsLeft = 0

    var waiting: [ShopRow] { proposals.filter { ss($0, "status") == "proposed" } }
    var handed: [ShopRow] { proposals.filter { ss($0, "status") == "approved" } }
    var searching: Bool { waiting.contains { ($0["order_line"] as? ShopRow) == nil && sa($0, "options").isEmpty } }

    func load(force: Bool = false) async {
        if loadedOnce && !force { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await Self.call("shopping_board", [:])
            if (r["ok"] as? Bool) == false {
                errorText = ss(r, "error").isEmpty ? "Shopping did not answer." : ss(r, "error")
                return
            }
            errorText = ""
            AuthLapse.accepted()
            paused = ss(r, "status") == "paused"
            researchOn = (r["research_on"] as? Bool) ?? true
            proposals = sa(r, "proposals")
            due = sa(r, "due")
            deliveries = sa(r, "deliveries")
            lists = sa(r, "lists")
            orders = sa(r, "orders")
            watches = sa(r, "watches")
            loadedOnce = true
        } catch is ScarletAuthError {
            errorText = AuthLapse.rejected()
        } catch {
            errorText = "Couldn't load Shopping. Pull to retry."
        }
    }

    /// A search takes about a minute: read the board again a few times, then stop.
    func pollWhileSearching() {
        pollsLeft = 8
        Task {
            while pollsLeft > 0 {
                pollsLeft -= 1
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await load(force: true)
                if !searching { pollsLeft = 0 }
            }
        }
    }

    /// One act, then the board is read again. Returns the server's answer, or nil when it refused.
    @discardableResult
    func act(_ op: String, _ body: ShopRow, success: String) async -> ShopRow? {
        busy = true
        defer { busy = false }
        do {
            let r = try await Self.call(op, body)
            if (r["ok"] as? Bool) == false {
                errorText = ss(r, "error").isEmpty ? "That didn't work. Nothing was changed." : ss(r, "error")
                return nil
            }
            errorText = ""
            if !success.isEmpty { show(success) }
            await load(force: true)
            return r
        } catch {
            errorText = "No connection. Nothing was changed."
            return nil
        }
    }

    func show(_ text: String) {
        toast = text
        Task { try? await Task.sleep(nanoseconds: 2_600_000_000); if self.toast == text { self.toast = "" } }
    }

    static func call(_ op: String, _ body: ShopRow) async throws -> ShopRow {
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
        return ((try? JSONSerialization.jsonObject(with: data)) as? ShopRow) ?? [:]
    }
}

// MARK: - Page

struct ShoppingView: View {
    @StateObject private var model = ShoppingModel()
    @EnvironmentObject private var convo: Conversation
    @Environment(\.horizontalSizeClass) private var hSize

    /// The one sheet of this view (Mac Catalyst allows one per view).
    enum ShoppingSheet: Identifiable {
        case proposal(id: String)
        case addToList(listID: String, name: String)
        var id: String {
            switch self {
            case .proposal(let p): return "proposal-\(p)"
            case .addToList(let l, _): return "add-\(l)"
            }
        }
    }
    @State private var activeSheet: ShoppingSheet?

    private var wide: Bool { hSize == .regular }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                content
            }
            .background(ShopUI.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if !model.toast.isEmpty {
                        Text(model.toast).font(ShopUI.small.weight(.semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(ShopUI.accent.opacity(0.85)))
                    }
                    ScarletPresenceView(convo: convo).padding(.vertical, 6)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.load() }
            .onAppear { convo.setFocus(focusLine) }
            .onChange(of: model.leaf) { _, _ in convo.setFocus(focusLine) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await model.load(force: true) }
            }
            .reportsModalPresence(activeSheet != nil)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .proposal(let id):
                    ShoppingProposalSheet(proposalID: id, model: model)
                case .addToList(let listID, let name):
                    ShoppingTextSheet(title: "Add to \(name)", placeholder: "What to add, in your words") { text in
                        Task { await model.act("shopping_list_add", ["list_id": listID, "item": text], success: "Added") }
                    }
                }
            }
        }
    }

    private var focusLine: String {
        "[FOCUS] Ido is in the Shopping section, \(model.leaf.title) (\(model.waiting.count) waiting for his yes, \(model.due.count) due). Shopping asks → the shopping tool. The desk never buys: he presses Buy in the store."
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Shopping").font(.system(size: 34, weight: .bold)).foregroundColor(.white)
                if model.waiting.count > 0 {
                    Text("\(model.waiting.count) waiting").font(ShopUI.small.weight(.bold)).foregroundColor(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(ShopUI.scarlet))
                }
                Spacer()
                if model.loading || model.busy { ProgressView().tint(ShopUI.muted) }
                Button { Task { await model.load(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).font(ShopUI.small)
            }
            Picker("Section", selection: $model.leaf) {
                ForEach(ShoppingLeaf.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if model.paused {
                Text("The Shopping Desk is switched off.").font(ShopUI.small).foregroundColor(ShopUI.warn)
            }
            if !model.errorText.isEmpty { Text(model.errorText).font(ShopUI.small).foregroundColor(ShopUI.warn) }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch model.leaf {
                case .buy: buyPane
                case .onTheWay: onTheWayPane
                case .lists: listsPane
                case .watches: watchesPane
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .refreshable { await model.load(force: true) }
    }

    // MARK: shared pieces

    private func card<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { inner() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(ShopUI.card))
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(1.2).foregroundColor(ShopUI.muted)
    }

    /// A product name as the store wrote it: its own direction.
    private func nameText(_ s: String, size: CGFloat = 17, weight: Font.Weight = .regular, lines: Int = 2) -> some View {
        Text(s.isEmpty ? "(no name)" : s)
            .font(.system(size: size, weight: weight))
            .foregroundColor(.white)
            .lineLimit(lines)
            .multilineTextAlignment(s.isRTLDominant ? .trailing : .leading)
            .environment(\.layoutDirection, s.layoutDir)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().stroke(color.opacity(0.7), lineWidth: 1))
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(ShopUI.body).foregroundColor(ShopUI.muted)
    }

    // MARK: Buy

    @ViewBuilder private var buyPane: some View {
        if wide {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) { searchCard; waitingCard; handedCard }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) { dueCard }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            searchCard
            waitingCard
            handedCard
            dueCard
        }
    }

    private var searchCard: some View {
        card {
            sectionTitle("What do you need?")
            TextField("Melatonin, a carry-on under 300 dollars, printer paper", text: $model.need, axis: .vertical)
                .font(ShopUI.body).foregroundColor(.white).lineLimit(1...3)
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(ShopUI.card2))
            HStack(spacing: 8) {
                TextField("At most", text: $model.ceiling)
                    .keyboardType(.decimalPad)
                    .font(ShopUI.small).foregroundColor(.white)
                    .padding(8).frame(width: 96).background(RoundedRectangle(cornerRadius: 8).fill(ShopUI.card2))
                Picker("Currency", selection: $model.currency) {
                    Text("$").tag("USD"); Text("₪").tag("ILS"); Text("€").tag("EUR")
                }
                .pickerStyle(.menu).tint(.white)
                TextField("Store you prefer", text: $model.store)
                    .font(ShopUI.small).foregroundColor(.white)
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(ShopUI.card2))
            }
            HStack(spacing: 10) {
                Button { Task { await buyAgain() } } label: { Label("Buy it again", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.borderedProminent).tint(ShopUI.accent)
                Button { Task { await findNew() } } label: { Label("Find the best", systemImage: "magnifyingglass") }
                    .buttonStyle(.bordered).tint(.white)
                Spacer()
            }
            .disabled(model.busy || model.need.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            if !model.researchOn {
                Text("Web search is switched off, so a new product is filed and not searched.").font(ShopUI.small).foregroundColor(ShopUI.warn)
            }
            if !model.choices.isEmpty {
                sectionTitle("Which one?")
                ForEach(Array(model.choices.enumerated()), id: \.offset) { _, c in
                    Button { Task { await again(itemID: ss(c, "item_id")) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                nameText(ss(c, "name"))
                                Text([ShopStore.label(ss(c, "retailer")), ss(c, "last_bought").isEmpty ? "" : "last bought \(ShopStore.day(ss(c, "last_bought")))"].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(ShopUI.small).foregroundColor(ShopUI.muted)
                            }
                            Spacer()
                            Text(ShopMoney.text(sd(c, "last_price"), ss(c, "currency"))).font(ShopUI.figure).foregroundColor(.white)
                        }
                        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(ShopUI.card2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var waitingCard: some View {
        card {
            sectionTitle("Waiting for your yes")
            if model.waiting.isEmpty { empty("Nothing is waiting.") }
            ForEach(Array(model.waiting.enumerated()), id: \.offset) { _, p in
                Button { activeSheet = .proposal(id: ss(p, "id")) } label: { proposalRow(p) }
                    .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var handedCard: some View {
        if !model.handed.isEmpty {
            card {
                sectionTitle("Opened in the store")
                ForEach(Array(model.handed.enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 6) {
                        nameText(ss(so(p, "order_line"), "text"))
                        HStack(spacing: 10) {
                            if let url = URL(string: ss(p, "link")), !ss(p, "link").isEmpty {
                                Button { UIApplication.shared.open(url) } label: { Label("Open the store page", systemImage: "arrow.up.right.square") }
                                    .buttonStyle(.bordered).tint(ShopUI.accent)
                            }
                            Button { Task { await model.act("shopping_bought", ["proposal_id": ss(p, "id")], success: "Marked as bought") } } label: { Text("I bought it") }
                                .buttonStyle(.bordered).tint(.white)
                        }
                        .font(ShopUI.small)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(ShopUI.card2))
                }
            }
        }
    }

    private func proposalRow(_ p: ShopRow) -> some View {
        let line = so(p, "order_line")
        let ready = !line.isEmpty
        let options = sa(p, "options")
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                nameText(ready ? ss(line, "item") : (ss(p, "need").isEmpty ? "A search" : ss(p, "need")), weight: .semibold)
                if ready {
                    Text("\(Int(sd(line, "qty") ?? 1)) to \(ss(line, "destination"))").font(ShopUI.small).foregroundColor(ShopUI.muted)
                } else {
                    Text(options.isEmpty ? "Searching, about a minute" : "\(options.count) options, no price yet").font(ShopUI.small).foregroundColor(ShopUI.warn)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if ready { Text(ShopMoney.text(sd(line, "price"), ss(line, "currency"))).font(ShopUI.figure).foregroundColor(.white) }
                if options.count > 1 { chip("\(options.count) options", ShopUI.accent) }
            }
            Image(systemName: "chevron.right").foregroundColor(ShopUI.muted)
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(ShopUI.card2))
    }

    private var dueCard: some View {
        card {
            sectionTitle("Due to buy again")
            if model.due.isEmpty { empty("Nothing is due.") }
            ForEach(Array(model.due.enumerated()), id: \.offset) { _, d in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        nameText(ss(d, "name"))
                        Text(dueNote(d)).font(ShopUI.small).foregroundColor(ShopUI.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(ShopMoney.text(sd(d, "last_price"), ss(d, "currency"))).font(ShopUI.figure).foregroundColor(.white)
                        HStack(spacing: 8) {
                            Button { Task { await model.act("shopping_snooze", ["item_id": ss(d, "id"), "days": 14], success: "Later, in two weeks") } } label: { Text("Later") }
                                .buttonStyle(.bordered).tint(.white)
                            Button { Task { await again(itemID: ss(d, "id")) } } label: { Text("Buy") }
                                .buttonStyle(.borderedProminent).tint(ShopUI.accent)
                        }
                        .font(ShopUI.small)
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(ShopUI.card2))
            }
        }
    }

    private func dueNote(_ d: ShopRow) -> String {
        var parts: [String] = []
        let store = ShopStore.label(ss(d, "retailer"))
        if !store.isEmpty { parts.append(store) }
        if !ss(d, "last_bought").isEmpty { parts.append("last bought \(ShopStore.day(ss(d, "last_bought")))") }
        if let over = sd(d, "days_overdue"), over > 0 { parts.append("\(Int(over)) days over") }
        return parts.joined(separator: " · ")
    }

    // MARK: Buy acts

    private func buyAgain() async {
        let q = model.need.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        guard let r = await model.act("shopping_again", ["q": q], success: "") else { return }
        handleAgain(r)
    }

    private func again(itemID: String) async {
        guard !itemID.isEmpty, let r = await model.act("shopping_again", ["item_id": itemID], success: "") else { return }
        handleAgain(r)
    }

    private func handleAgain(_ r: ShopRow) {
        switch ss(r, "status") {
        case "choose":
            model.choices = sa(r, "choices")
        case "not_in_history":
            model.choices = []
            model.show("Not bought before. Searching the web, about a minute.")
            model.pollWhileSearching()
        case "no_price":
            model.choices = []
            model.errorText = "Found it, but no price is on file, so there is no line to approve. Try Find the best."
        default:
            model.choices = []
            model.need = ""
            let id = ss(r, "proposal_id")
            if !id.isEmpty { activeSheet = .proposal(id: id) }
        }
    }

    private func findNew() async {
        let q = model.need.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else { return }
        var body: ShopRow = ["need": q]
        if let b = Double(model.ceiling.replacingOccurrences(of: ",", with: ".")), b > 0 { body["budget"] = b; body["currency"] = model.currency }
        let st = model.store.trimmingCharacters(in: .whitespaces)
        if !st.isEmpty { body["store"] = st }
        guard await model.act("shopping_want", body, success: model.researchOn ? "Searching, about a minute" : "Filed, not searched") != nil else { return }
        model.need = ""; model.ceiling = ""; model.store = ""; model.choices = []
        if model.researchOn { model.pollWhileSearching() }
    }

    // MARK: On the way

    @ViewBuilder private var onTheWayPane: some View {
        card {
            sectionTitle("On the way")
            if model.deliveries.isEmpty { empty("Nothing is on the way.") }
            ForEach(Array(model.deliveries.enumerated()), id: \.offset) { _, d in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        nameText(ss(d, "first_item").isEmpty ? ShopStore.label(ss(d, "retailer")) : ss(d, "first_item"))
                        Text(deliveryNote(d)).font(ShopUI.small).foregroundColor(ShopUI.muted)
                    }
                    Spacer()
                    chip(deliveryStatus(d), ss(d, "status") == "late" ? ShopUI.warn : ShopUI.ok)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(ShopUI.card2))
            }
        }
        card {
            sectionTitle("Last orders")
            if model.orders.isEmpty { empty("No orders on file.") }
            ForEach(Array(model.orders.enumerated()), id: \.offset) { _, o in
                let items = sa(o, "items")
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        nameText(items.first.map { ss($0, "name") } ?? ShopStore.label(ss(o, "retailer")))
                        Text([ShopStore.label(ss(o, "retailer")), ShopStore.day(ss(o, "ordered_at")), items.count > 1 ? "\(items.count) items" : "", ss(o, "destination")].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(ShopUI.small).foregroundColor(ShopUI.muted)
                    }
                    Spacer()
                    Text(ShopMoney.text(sd(o, "total"), ss(o, "currency"))).font(ShopUI.figure).foregroundColor(.white)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(ShopUI.card2))
            }
        }
    }

    private func deliveryStatus(_ d: ShopRow) -> String {
        switch ss(d, "status") {
        case "late": return "No word yet"
        case "shipped": return "Shipped"
        default: return "Expected"
        }
    }

    private func deliveryNote(_ d: ShopRow) -> String {
        var parts: [String] = []
        let store = ShopStore.label(ss(d, "retailer"))
        if !store.isEmpty && !ss(d, "first_item").isEmpty { parts.append(store) }
        if let n = sd(d, "items"), n > 1 { parts.append("\(Int(n)) items") }
        if !ss(d, "eta").isEmpty { parts.append("due \(ShopStore.day(ss(d, "eta")))") }
        if !ss(d, "destination").isEmpty { parts.append(ss(d, "destination")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Lists

    @ViewBuilder private var listsPane: some View {
        if model.lists.isEmpty { card { empty("No lists yet.") } }
        ForEach(Array(model.lists.enumerated()), id: \.offset) { _, l in
            let items = sa(l, "items")
            card {
                HStack {
                    sectionTitle(listTitle(l))
                    Spacer()
                    Button { activeSheet = .addToList(listID: ss(l, "id"), name: listTitle(l)) } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.bordered).font(ShopUI.small).tint(.white)
                }
                if items.isEmpty { empty("Empty.") }
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack {
                        nameText(ss(it, "name"))
                        Spacer()
                        if let q = sd(it, "qty"), q > 1 { Text("× \(Int(q))").font(ShopUI.figure).foregroundColor(ShopUI.muted) }
                        if !ss(it, "item_id").isEmpty {
                            Button { Task { await again(itemID: ss(it, "item_id")) } } label: { Text("Buy") }
                                .buttonStyle(.bordered).font(ShopUI.small).tint(ShopUI.accent)
                            Button { Task { await model.act("shopping_list_remove", ["list_id": ss(l, "id"), "item_id": ss(it, "item_id")], success: "Removed") } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundColor(ShopUI.muted)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func listTitle(_ l: ShopRow) -> String {
        let name = ss(l, "name").replacingOccurrences(of: "_", with: " ").capitalized
        return name.isEmpty ? "List" : name
    }

    // MARK: Watches

    @ViewBuilder private var watchesPane: some View {
        card {
            sectionTitle("Price watches")
            if model.watches.isEmpty { empty("Nothing is watched. Say \"watch the price of\" something to Scarlet.") }
            ForEach(Array(model.watches.enumerated()), id: \.offset) { _, w in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        nameText(ss(w, "name"))
                        Text(watchNote(w)).font(ShopUI.small).foregroundColor(ShopUI.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if ss(w, "status") == "hit" { chip("Price is down", ShopUI.ok) }
                        HStack(spacing: 8) {
                            if let url = URL(string: ss(w, "link")), !ss(w, "link").isEmpty {
                                Button { UIApplication.shared.open(url) } label: { Text("Open") }
                                    .buttonStyle(.bordered).tint(ShopUI.accent)
                            }
                            Button { Task { await model.act("shopping_unwatch", ["watch_id": ss(w, "id")], success: "Stopped") } } label: { Text("Stop") }
                                .buttonStyle(.bordered).tint(.white)
                        }
                        .font(ShopUI.small)
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(ShopUI.card2))
            }
        }
    }

    private func watchNote(_ w: ShopRow) -> String {
        var parts: [String] = []
        if let p = sd(w, "last_price") { parts.append("now \(ShopMoney.text(p, ss(w, "currency")))") }
        if let t = sd(w, "threshold") { parts.append("tell me under \(ShopMoney.text(t, ss(w, "currency")))") }
        if !ss(w, "last_checked").isEmpty { parts.append("checked \(ShopStore.day(ss(w, "last_checked")))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - One proposal: the options, the line, the one tap

private struct ShoppingProposalSheet: View {
    let proposalID: String
    @ObservedObject var model: ShoppingModel
    @Environment(\.dismiss) private var dismiss
    @State private var proposal: ShopRow = [:]
    @State private var loading = true
    @State private var working = false
    @State private var message = ""
    @State private var openedURL: URL?

    private var line: ShopRow { so(proposal, "order_line") }
    private var options: [ShopRow] { sa(proposal, "options") }
    private var status: String { ss(proposal, "status") }
    private var pick: Int { Int(sd(proposal, "pick") ?? 0) }
    private var qty: Int { Int(sd(line, "qty") ?? 1) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if loading && proposal.isEmpty {
                        ProgressView().tint(ShopUI.muted).frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        if !ss(proposal, "need").isEmpty {
                            Text(ss(proposal, "need")).font(ShopUI.small).foregroundColor(ShopUI.muted)
                                .multilineTextAlignment(ss(proposal, "need").isRTLDominant ? .trailing : .leading)
                                .environment(\.layoutDirection, ss(proposal, "need").layoutDir)
                        }
                        if options.count > 1 { optionsBlock }
                        lineBlock
                        if !message.isEmpty { Text(message).font(ShopUI.small).foregroundColor(ShopUI.warn) }
                        actions
                    }
                }
                .padding(18)
            }
            .background(ShopUI.bg.ignoresSafeArea())
            .navigationTitle(status == "approved" ? "Opened in the store" : "Your order line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await read() }
        }
        .preferredColorScheme(.dark)
    }

    private var optionsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OPTIONS").font(.system(size: 12, weight: .semibold)).tracking(1.2).foregroundColor(ShopUI.muted)
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button { Task { await choose(option: i, qty: nil) } } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: i == pick ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(i == pick ? ShopUI.accent : ShopUI.muted).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ss(o, "name")).font(ShopUI.body).foregroundColor(.white).lineLimit(3)
                                .multilineTextAlignment(ss(o, "name").isRTLDominant ? .trailing : .leading)
                                .environment(\.layoutDirection, ss(o, "name").layoutDir)
                            if !ss(o, "reason").isEmpty { Text(ss(o, "reason")).font(ShopUI.small).foregroundColor(ShopUI.muted) }
                            if !ss(o, "retailer").isEmpty { Text(ShopStore.label(ss(o, "retailer"))).font(ShopUI.small).foregroundColor(ShopUI.muted) }
                        }
                        Spacer()
                        Text(ShopMoney.text(sd(o, "price"), ss(o, "currency"))).font(ShopUI.figure).foregroundColor(.white)
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(i == pick ? ShopUI.card2 : ShopUI.card))
                }
                .buttonStyle(.plain)
                .disabled(working || status != "proposed")
            }
            if !ss(proposal, "pick_reason").isEmpty {
                Text("Why this one: \(ss(proposal, "pick_reason"))").font(ShopUI.small).foregroundColor(ShopUI.muted)
            }
        }
    }

    @ViewBuilder private var lineBlock: some View {
        if line.isEmpty {
            Text(options.isEmpty ? "Still searching. It takes about a minute." : "No option has a price and a page yet, so there is no line to approve.")
                .font(ShopUI.body).foregroundColor(ShopUI.warn)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(ss(line, "item")).font(ShopUI.title).foregroundColor(.white)
                    .multilineTextAlignment(ss(line, "item").isRTLDominant ? .trailing : .leading)
                    .environment(\.layoutDirection, ss(line, "item").layoutDir)
                HStack(alignment: .firstTextBaseline) {
                    Text(ShopMoney.text(sd(line, "price"), ss(line, "currency"))).font(.system(size: 28, weight: .bold).monospacedDigit()).foregroundColor(.white)
                    if qty > 1 { Text("each").font(ShopUI.small).foregroundColor(ShopUI.muted) }
                    Spacer()
                    if status == "proposed" {
                        Stepper("Quantity \(qty)", value: Binding(get: { qty }, set: { n in Task { await choose(option: nil, qty: n) } }), in: 1...20)
                            .font(ShopUI.body).foregroundColor(.white).fixedSize()
                            .disabled(working)
                    } else {
                        Text("Quantity \(qty)").font(ShopUI.body).foregroundColor(.white)
                    }
                }
                Text("To \(ss(line, "destination"))").font(ShopUI.body).foregroundColor(ShopUI.muted)
                if !ss(proposal, "price_note").isEmpty { Text(ss(proposal, "price_note")).font(ShopUI.small).foregroundColor(ShopUI.muted) }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(ShopUI.card))
        }
    }

    @ViewBuilder private var actions: some View {
        if status == "proposed" {
            if !line.isEmpty {
                Button { Task { await buy() } } label: {
                    Label("Buy: open it in the store", systemImage: "cart.fill")
                        .font(.system(size: 19, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(ShopUI.accent).disabled(working)
                Text("This is your yes to the line above. The store page opens in your own account and you press Buy there. Scarlet orders nothing.")
                    .font(ShopUI.small).foregroundColor(ShopUI.muted)
            }
            HStack(spacing: 10) {
                Button { Task { await finish("shopping_snooze", ["proposal_id": proposalID, "days": 7], "Later, in a week") } } label: { Text("Later") }
                    .buttonStyle(.bordered).tint(.white)
                Button { Task { await finish("shopping_decline", ["proposal_id": proposalID], "Dropped") } } label: { Text("Not this") }
                    .buttonStyle(.bordered).tint(ShopUI.scarlet)
            }
            .disabled(working)
        } else if status == "approved" {
            if let url = openedURL ?? URL(string: ss(proposal, "link")) {
                Button { UIApplication.shared.open(url) } label: {
                    Label("Open the store page", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(ShopUI.accent)
            }
            Button { Task { await finish("shopping_bought", ["proposal_id": proposalID], "Marked as bought") } } label: { Text("I bought it") }
                .buttonStyle(.bordered).tint(.white).disabled(working)
        } else if !status.isEmpty {
            Text("This one is \(status).").font(ShopUI.body).foregroundColor(ShopUI.muted)
        }
    }

    /// Showing the line is the read-back: the server stamps it on this read.
    private func read() async {
        loading = true
        defer { loading = false }
        guard let r = try? await ShoppingModel.call("shopping_proposal", ["proposal_id": proposalID]) else {
            message = "No connection."
            return
        }
        if (r["ok"] as? Bool) == false { message = ss(r, "error"); return }
        proposal = so(r, "proposal")
    }

    private func choose(option: Int?, qty: Int?) async {
        working = true
        defer { working = false }
        var body: ShopRow = ["proposal_id": proposalID]
        if let option { body["option"] = option }
        if let qty { body["qty"] = qty }
        guard let r = try? await ShoppingModel.call("shopping_pick", body) else { message = "No connection. Nothing was changed."; return }
        if (r["ok"] as? Bool) == false { message = ss(r, "error"); return }
        message = ""
        proposal = so(r, "proposal")
    }

    /// The one tap: his yes to the line as shown, then the store page opens.
    private func buy() async {
        working = true
        defer { working = false }
        var body: ShopRow = [
            "proposal_id": proposalID,
            "item": ss(line, "item"),
            "currency": ss(line, "currency"),
            "destination": ss(line, "destination"),
            "qty": qty,
            "said": "Tapped Buy on this line in the app",
        ]
        if let price = sd(line, "price") { body["price"] = price }
        guard let r = try? await ShoppingModel.call("shopping_approve", body) else { message = "No connection. Nothing was changed."; return }
        if (r["ok"] as? Bool) == false {
            // The line changed or its time passed: show it again, he taps again.
            message = ss(r, "error")
            await read()
            return
        }
        message = ""
        if let url = URL(string: ss(r, "open_url")), !ss(r, "open_url").isEmpty {
            openedURL = url
            _ = await UIApplication.shared.open(url)
        } else {
            message = "Approved, but the store gave no page to open."
        }
        await read()
        await model.load(force: true)
    }

    private func finish(_ op: String, _ body: ShopRow, _ success: String) async {
        working = true
        let r = await model.act(op, body, success: success)
        working = false
        if r != nil { dismiss() } else { message = model.errorText }
    }
}

// MARK: - A one-line text sheet

private struct ShoppingTextSheet: View {
    let title: String
    let placeholder: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(ShopUI.body).foregroundColor(.white).lineLimit(1...4)
                    .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(ShopUI.card))
                Spacer()
            }
            .padding(18)
            .background(ShopUI.bg.ignoresSafeArea())
            .navigationTitle(title)
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
