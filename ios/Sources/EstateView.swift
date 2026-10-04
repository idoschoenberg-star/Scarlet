import SwiftUI

// MARK: - Estate (Ido 2026-10-03: "surface the estate functions in the Scarlet
// application"). Five leaves — Tickets · Recurring · Suppliers · Payments ·
// Homes — over the Estate Desk's own database. Every op is `estate_<name>`
// on app-api, which proxies to the desk (`_shared/estate_app.ts`), so the app,
// the voice tool and the daily sweep share one engine.
//
// Rules this screen honors (docs/IDO_DESIGN_GUIDE.md):
//   • iPad/Mac first: list pane + detail pane side by side; iPhone pushes.
//   • Reading/editing text is white on pure black; the estate green marks
//     chrome only (§13).
//   • Approving a supplier message opens the SAME draft window as every
//     other channel (draft_action pickup → RootView's draft sheet), so the
//     propose → approve → act loop is identical everywhere (§2).
//   • One `.sheet(item:)` per view (Catalyst crash rule, §6).
//   • Bank details are never editable here (the desk verifies by callback).

private enum EstateUI {
    static let bg = Color.black
    static let card = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let card2 = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let line = Color(white: 0.22)
    static let muted = Color(white: 0.64)
    static let accent = Color(red: 0.30, green: 0.76, blue: 0.52)   // estate green — chrome only
    static let scarlet = Color(red: 1, green: 0.35, blue: 0.42)
    static let warn = Color(red: 0.94, green: 0.64, blue: 0.23)
    static let blue = Color(red: 0.36, green: 0.61, blue: 1.0)
    static let body = Font.system(size: 17)
    static let title = Font.system(size: 21, weight: .semibold)
    static let small = Font.system(size: 14)
}

enum EstateLeaf: String, CaseIterable, Identifiable {
    case tickets, recurring, suppliers, payments, homes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tickets: return "Tickets"
        case .recurring: return "Recurring"
        case .suppliers: return "Suppliers"
        case .payments: return "Payments"
        case .homes: return "Homes"
        }
    }
}

// MARK: - Wire models (loose JSON → typed rows)

private func s(_ o: [String: Any], _ k: String) -> String { (o[k] as? String) ?? "" }
private func i(_ o: [String: Any], _ k: String) -> Int { (o[k] as? Int) ?? Int((o[k] as? Double) ?? 0) }

struct EstateTicket: Identifiable, Equatable {
    let id: String, title: String, kind: String, status: String, stage: String, waiting: String
    let priority: String, home: String, supplier: String, supplierID: String, device: String, zone: String
    let reportedBy: String, openedAt: String, scheduledFor: String, draftID: String, planID: String
    let proposedDate: String, proposedTime: String
    init(_ o: [String: Any]) {
        id = s(o, "id"); title = s(o, "title"); kind = s(o, "kind"); status = s(o, "status")
        stage = s(o, "stage"); waiting = s(o, "waiting"); priority = s(o, "priority"); home = s(o, "home")
        supplier = s(o, "supplier"); supplierID = s(o, "supplier_id"); device = s(o, "device"); zone = s(o, "zone")
        reportedBy = s(o, "reported_by"); openedAt = s(o, "opened_at"); scheduledFor = s(o, "scheduled_for")
        draftID = s(o, "draft_id"); planID = s(o, "plan_id")
        let pv = (o["proposed_visit"] as? [String: Any]) ?? [:]
        proposedDate = s(pv, "date"); proposedTime = s(pv, "time")
    }
}

struct EstateEvent: Identifiable {
    let id: String, at: String, kind: String, actor: String, body: String
    init(_ o: [String: Any]) { id = s(o, "id"); at = s(o, "at"); kind = s(o, "kind"); actor = s(o, "actor"); body = s(o, "body") }
}

struct EstateTicketDetail {
    let ticket: EstateTicket
    let symptom: String
    let supplierLine: String
    let draftID: String, draftBody: String, draftRecipient: String, draftChannel: String
    let events: [EstateEvent]
}

struct EstateTask: Identifiable, Equatable {
    let id: String, title: String, home: String, every: String, nextDue: String, lastDone: String
    let supplier: String, supplierID: String, status: String, statusLabel: String, mode: String
    let intervalDays: Int, leadDays: Int, openTicketID: String, active: Bool
    init(_ o: [String: Any]) {
        id = s(o, "id"); title = s(o, "title"); home = s(o, "home"); every = s(o, "every")
        nextDue = s(o, "next_due"); lastDone = s(o, "last_done"); supplier = s(o, "supplier"); supplierID = s(o, "supplier_id")
        status = s(o, "status"); statusLabel = s(o, "status_label"); mode = s(o, "mode")
        intervalDays = i(o, "interval_days"); leadDays = i(o, "lead_days"); openTicketID = s(o, "open_ticket_id")
        active = (o["active"] as? Bool) ?? true
    }
}

struct EstateCycle: Identifiable {
    let id: String, cycleDue: String, status: String, waiting: String, closedAt: String, paid: String
    init(_ o: [String: Any]) {
        id = s(o, "id"); cycleDue = s(o, "cycle_due"); status = s(o, "status"); waiting = s(o, "waiting")
        closedAt = s(o, "closed_at")
        if let p = o["paid"] as? [String: Any], let a = p["amount"] as? Double { paid = "\(Int(a)) \(s(p, "currency"))" } else { paid = "" }
    }
}

struct EstateContact: Identifiable, Equatable {
    var id = UUID()
    var name = "", phone = "", email = "", role = ""
}

struct EstateSupplier: Identifiable, Equatable {
    var id: String
    var name: String, nameHe: String, display: String
    var trades: [String], language: String
    var phone: String, whatsapp: String, email: String, note: String
    var contacts: [EstateContact]
    var reachableBy: String, missingContact: Bool, hasBank: Bool
    var openTickets: Int, devices: Int, transitionState: String
    init(_ o: [String: Any]) {
        id = s(o, "id"); name = s(o, "name"); nameHe = s(o, "name_he"); display = s(o, "display")
        trades = (o["trades"] as? [String]) ?? []; language = s(o, "language")
        phone = s(o, "phone"); whatsapp = s(o, "whatsapp"); email = s(o, "email"); note = s(o, "note")
        contacts = ((o["contacts"] as? [[String: Any]]) ?? []).map { EstateContact(name: s($0, "name"), phone: s($0, "phone"), email: s($0, "email"), role: s($0, "role")) }
        reachableBy = s(o, "reachable_by"); missingContact = (o["missing_contact"] as? Bool) ?? false
        hasBank = (o["has_bank_details"] as? Bool) ?? false
        openTickets = i(o, "open_tickets"); devices = i(o, "devices")
        transitionState = s((o["transition"] as? [String: Any]) ?? [:], "state")
    }
    static func blank() -> EstateSupplier {
        EstateSupplier(["id": "", "language": "he"])
    }
    var wireFields: [String: Any] {
        ["name": name, "name_he": nameHe, "trades": trades, "language": language,
         "phone": phone, "whatsapp": whatsapp, "email": email, "note": note,
         "contacts": contacts.map { ["name": $0.name, "phone": $0.phone, "email": $0.email, "role": $0.role] }]
    }
}

struct EstatePayment: Identifiable {
    let id: String, amount: Double, currency: String, payee: String, supplier: String, description: String
    let requestedAt: String, verdict: String, deviation: Double?, flags: [String]
    init(_ o: [String: Any]) {
        id = s(o, "id"); amount = (o["amount"] as? Double) ?? Double(i(o, "amount")); currency = s(o, "currency")
        payee = s(o, "payee"); supplier = s(o, "supplier"); description = s(o, "description"); requestedAt = s(o, "requested_at")
        let r = (o["review"] as? [String: Any]) ?? [:]
        verdict = s(r, "verdict"); deviation = r["deviation_pct"] as? Double; flags = (r["flags"] as? [String]) ?? []
    }
}

struct EstateDevice: Identifiable {
    let id: String, name: String, zoneID: String, make: String, model: String, warranty: String, status: String, supplier: String
    init(_ o: [String: Any]) {
        id = s(o, "id"); name = s(o, "name_he").isEmpty ? s(o, "name") : s(o, "name_he"); zoneID = s(o, "zone_id")
        make = s(o, "make"); model = s(o, "model"); warranty = s(o, "warranty_until"); status = s(o, "status"); supplier = s(o, "supplier")
    }
}

struct EstateStaff: Identifiable {
    let id: String, name: String, role: String, phone: String, email: String
    init(_ o: [String: Any]) { id = s(o, "id"); name = s(o, "name"); role = s(o, "role"); phone = s(o, "phone"); email = s(o, "email") }
}

// MARK: - Model

@MainActor
final class EstateModel: ObservableObject {
    @Published var leaf: EstateLeaf = .tickets
    @Published var homeFilter: String = ""          // "" = all homes
    @Published var homes: [(id: String, name: String)] = []

    @Published var tickets: [EstateTicket] = []
    @Published var tasks: [EstateTask] = []
    @Published var suppliers: [EstateSupplier] = []
    @Published var payments: [EstatePayment] = []
    @Published var devices: [EstateDevice] = []
    @Published var zones: [String: String] = [:]
    @Published var staff: [EstateStaff] = []
    @Published var needsYou = 0

    @Published var loading = false
    @Published var errorText = ""
    @Published var toast = ""

    func load() async {
        loading = true
        defer { loading = false }
        errorText = ""
        async let o = try? Self.call("estate_overview", [:])
        do {
            switch leaf {
            case .tickets:
                let r = try await Self.call("estate_tickets", homeFilter.isEmpty ? [:] : ["home_id": homeFilter])
                tickets = ((r["tickets"] as? [[String: Any]]) ?? []).map(EstateTicket.init)
                homes = ((r["homes"] as? [[String: Any]]) ?? []).map { (id: s($0, "id"), name: s($0, "name")) }
            case .recurring:
                let r = try await Self.call("estate_recurring", homeFilter.isEmpty ? [:] : ["home_id": homeFilter])
                tasks = ((r["items"] as? [[String: Any]]) ?? []).map(EstateTask.init)
            case .suppliers:
                let r = try await Self.call("estate_suppliers", [:])
                suppliers = ((r["items"] as? [[String: Any]]) ?? []).map(EstateSupplier.init)
            case .payments:
                let r = try await Self.call("estate_payments", [:])
                payments = ((r["pending"] as? [[String: Any]]) ?? []).map(EstatePayment.init)
            case .homes:
                let r = try await Self.call("estate_homes", homeFilter.isEmpty ? [:] : ["home_id": homeFilter])
                devices = ((r["devices"] as? [[String: Any]]) ?? []).map(EstateDevice.init)
                var z: [String: String] = [:]
                for row in (r["zones"] as? [[String: Any]]) ?? [] { z[s(row, "id")] = s(row, "name_he").isEmpty ? s(row, "name") : s(row, "name_he") }
                zones = z
                staff = ((r["staff"] as? [[String: Any]]) ?? []).map(EstateStaff.init)
                if homes.isEmpty { homes = ((r["homes"] as? [[String: Any]]) ?? []).map { (id: s($0, "id"), name: s($0, "name")) } }
            }
        } catch {
            errorText = "Couldn't load \(leaf.title.lowercased()). Pull to retry."
        }
        if let ov = await o { needsYou = i(ov, "needs_you") }
        // Suppliers feed the pickers on every leaf.
        if suppliers.isEmpty, leaf != .suppliers, let r = try? await Self.call("estate_suppliers", [:]) {
            suppliers = ((r["items"] as? [[String: Any]]) ?? []).map(EstateSupplier.init)
        }
    }

    /// Runs an action op, shows its outcome, reloads the current leaf.
    @discardableResult
    func act(_ op: String, _ body: [String: Any], success: String) async -> [String: Any]? {
        do {
            let r = try await Self.call(op, body)
            if (r["ok"] as? Bool) == false {
                errorText = (r["error"] as? String) ?? "That didn't work."
                return nil
            }
            toast = (r["outcome"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? success
            Task { try? await Task.sleep(nanoseconds: 2_500_000_000); self.toast = "" }
            await load()
            return r
        } catch {
            errorText = "No connection — nothing was changed."
            return nil
        }
    }

    /// The parked supplier message → the shared draft window (same approve
    /// loop as every other channel). Pickup moves it to the review lane;
    /// RootView's draft sheet adopts it.
    func openDraft(_ draftID: String) async {
        do {
            let r = try await Self.call("draft_action", ["draft_id": draftID, "action": "pickup"])
            if (r["ok"] as? Bool) == false, let e = r["error"] as? String, !e.contains("not a saved draft") {
                errorText = e
                return
            }
            NotificationCenter.default.post(name: .scarletVoiceDraftStarted, object: draftID)
        } catch {
            errorText = "Couldn't open the message."
        }
    }

    func ticketDetail(_ id: String) async -> EstateTicketDetail? {
        guard let r = try? await Self.call("estate_ticket", ["id": id]), (r["ok"] as? Bool) == true,
              let t = r["ticket"] as? [String: Any] else { return nil }
        let d = (r["draft"] as? [String: Any]) ?? [:]
        let sup = (r["supplier"] as? [String: Any]) ?? [:]
        var supLine = s(sup, "name")
        let reach = [s(sup, "person"), s(sup, "phone"), s(sup, "email")].filter { !$0.isEmpty }.joined(separator: " · ")
        if !reach.isEmpty { supLine += supLine.isEmpty ? reach : " — " + reach }
        return EstateTicketDetail(
            ticket: EstateTicket(t), symptom: s(t, "symptom"), supplierLine: supLine,
            draftID: s(d, "id"), draftBody: s(d, "body"), draftRecipient: s(d, "recipient"), draftChannel: s(d, "channel"),
            events: ((r["events"] as? [[String: Any]]) ?? []).map(EstateEvent.init))
    }

    func taskCycles(_ id: String) async -> [EstateCycle] {
        guard let r = try? await Self.call("estate_recurring_get", ["id": id]) else { return [] }
        return ((r["cycles"] as? [[String: Any]]) ?? []).map(EstateCycle.init)
    }

    // MARK: plumbing — op in the query string, params in the JSON body.
    static func call(_ op: String, _ body: [String: Any]) async throws -> [String: Any] {
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "op", value: op)]
        var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
}

// MARK: - Page

struct EstateView: View {
    @StateObject private var model = EstateModel()
    @EnvironmentObject private var convo: Conversation
    @Environment(\.horizontalSizeClass) private var hSize

    enum EstateSheet: Identifiable {
        case report
        case schedule(EstateTicket)
        case newSupplier
        case newTask
        var id: String {
            switch self {
            case .report: return "report"
            case .schedule(let t): return "schedule-\(t.id)"
            case .newSupplier: return "new-supplier"
            case .newTask: return "new-task"
            }
        }
    }
    @State private var activeSheet: EstateSheet?
    @State private var selTicket: String?
    @State private var selTask: String?
    @State private var selSupplier: String?
    @State private var search = ""

    private var wide: Bool { hSize == .regular }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if wide {
                    HStack(spacing: 0) {
                        listPane.frame(width: 380)
                        Divider().background(EstateUI.line)
                        detailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    listPane
                }
            }
            .background(EstateUI.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if !model.toast.isEmpty {
                        Text(model.toast).font(EstateUI.small.weight(.semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(EstateUI.accent.opacity(0.85)))
                    }
                    ScarletPresenceView(convo: convo).padding(.vertical, 6)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.load() }
            .onChange(of: model.leaf) { _, _ in
                search = ""
                Task { await model.load() }
                convo.setFocus(focusLine)
            }
            .onChange(of: model.homeFilter) { _, _ in Task { await model.load() } }
            .onAppear { convo.setFocus(focusLine) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await model.load() }
            }
            .reportsModalPresence(activeSheet != nil)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .report: EstateReportSheet(model: model)
                case .schedule(let t): EstateScheduleSheet(model: model, ticket: t)
                case .newSupplier: EstateSupplierSheet(model: model)
                case .newTask: EstateNewTaskSheet(model: model)
                }
            }
        }
    }

    private var focusLine: String {
        "[FOCUS] Ido is in the Estate section, \(model.leaf.title) (\(model.needsYou) waiting on him). Estate questions → the estate tool."
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Estate").font(.system(size: 34, weight: .bold)).foregroundColor(.white)
                if model.needsYou > 0 {
                    Text("\(model.needsYou) need you").font(EstateUI.small.weight(.bold)).foregroundColor(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(EstateUI.scarlet))
                }
                Spacer()
                if model.loading { ProgressView().tint(EstateUI.muted) }
                Button { activeSheet = .report } label: {
                    Label("Report a problem", systemImage: "exclamationmark.bubble")
                        .font(EstateUI.small.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(EstateUI.accent)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            Picker("Section", selection: $model.leaf) {
                ForEach(EstateLeaf.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if [.tickets, .recurring, .homes].contains(model.leaf), model.homes.count > 1 {
                Picker("Home", selection: $model.homeFilter) {
                    Text("All homes").tag("")
                    ForEach(model.homes, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
            }
            if !model.errorText.isEmpty {
                Text(model.errorText).font(EstateUI.small).foregroundColor(EstateUI.warn)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: list pane

    @ViewBuilder private var listPane: some View {
        switch model.leaf {
        case .tickets: ticketList
        case .recurring: taskList
        case .suppliers: supplierList
        case .payments: paymentList
        case .homes: homesList
        }
    }

    @ViewBuilder private var detailPane: some View {
        switch model.leaf {
        case .tickets:
            if let id = selTicket { EstateTicketPane(model: model, ticketID: id, onSchedule: { activeSheet = .schedule($0) }).id(id) }
            else { placeholder("Select a ticket to see its history and next step.") }
        case .recurring:
            if let id = selTask, let t = model.tasks.first(where: { $0.id == id }) { EstateTaskPane(model: model, task: t).id(id) }
            else { placeholder("Select a task to see its cycles and record what was done.") }
        case .suppliers:
            if let id = selSupplier, let sp = model.suppliers.first(where: { $0.id == id }) { EstateSupplierPane(model: model, original: sp).id(id) }
            else { placeholder("Select a supplier to edit their details.") }
        case .payments, .homes:
            placeholder(model.leaf == .payments ? "Approving a payment puts the wire draft on your shelf. You still send it from Outlook." : "Devices by zone, with the supplier who services each one.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack { Spacer(); Text(text).font(EstateUI.body).foregroundColor(EstateUI.muted).multilineTextAlignment(.center).padding(40); Spacer() }
            .frame(maxWidth: .infinity)
    }

    /// Wide: a selectable row that fills the detail pane. Compact: a push.
    @ViewBuilder private func rowLink<Content: View, Dest: View>(selected: Bool, select: @escaping () -> Void,
                                                                  @ViewBuilder dest: @escaping () -> Dest,
                                                                  @ViewBuilder content: () -> Content) -> some View {
        if wide {
            Button(action: select) {
                HStack { content(); Image(systemName: "chevron.right").font(.caption).foregroundColor(EstateUI.muted) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selected ? EstateUI.card2 : EstateUI.bg)
        } else {
            NavigationLink { dest().background(EstateUI.bg.ignoresSafeArea()) } label: { content() }
                .listRowBackground(EstateUI.bg)
        }
    }

    // Tickets, grouped by stage — the stage IS the group.
    private static let stages: [(key: String, title: String)] = [
        ("needs_you", "Needs you"), ("with_supplier", "With the supplier"), ("scheduled", "Scheduled"),
        ("finishing", "Finishing"), ("closed", "Closed recently"),
    ]

    private var ticketList: some View {
        let q = search.lowercased()
        let rows = model.tickets.filter { q.isEmpty || "\($0.title) \($0.supplier) \($0.device) \($0.zone)".lowercased().contains(q) }
        return List {
            ForEach(Self.stages, id: \.key) { st in
                let group = rows.filter { $0.stage == st.key }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { t in
                            rowLink(selected: selTicket == t.id, select: { selTicket = t.id },
                                    dest: { EstateTicketPane(model: model, ticketID: t.id, onSchedule: { activeSheet = .schedule($0) }) }) {
                                ticketRow(t)
                            }
                        }
                    } header: {
                        Text("\(st.title) · \(group.count)").font(.system(size: 13, weight: .semibold)).foregroundColor(st.key == "needs_you" ? EstateUI.scarlet : EstateUI.muted)
                    }
                }
            }
            if rows.isEmpty && !model.loading { Text("No tickets.").font(EstateUI.body).foregroundColor(EstateUI.muted).listRowBackground(EstateUI.bg) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: "Search tickets")
        .refreshable { await model.load() }
    }

    private func dotColor(_ stage: String) -> Color {
        switch stage {
        case "needs_you": return EstateUI.scarlet
        case "scheduled": return EstateUI.blue
        case "finishing": return EstateUI.warn
        case "closed": return EstateUI.accent
        default: return Color(white: 0.55)
        }
    }

    private func ticketRow(_ t: EstateTicket) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(dotColor(t.stage)).frame(width: 10, height: 10).padding(.top, 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(t.title).font(EstateUI.body.weight(.semibold)).foregroundColor(.white).lineLimit(2)
                        .multilineTextAlignment(t.title.readingAlignment)
                    if t.priority == "urgent" || t.priority == "high" {
                        Text(t.priority == "urgent" ? "Urgent" : "High").font(.system(size: 12, weight: .bold)).foregroundColor(EstateUI.warn)
                    }
                }
                Text(t.waiting).font(EstateUI.small).foregroundColor(EstateUI.muted).lineLimit(2)
                let meta = [t.supplier, t.home].filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.system(size: 13)).foregroundColor(Color(white: 0.5)).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // Recurring — sorted by urgency, status as a pill.
    private var taskList: some View {
        let order = ["needs_you": 0, "overdue": 1, "due_soon": 2, "in_progress": 3, "scheduled": 4, "on_track": 5, "done_cycle": 6, "no_date": 7, "standing": 8, "on_demand": 9, "paused": 10]
        let q = search.lowercased()
        let rows = model.tasks
            .filter { q.isEmpty || "\($0.title) \($0.supplier)".lowercased().contains(q) }
            .sorted { (order[$0.status] ?? 9, $0.nextDue.isEmpty ? "9" : $0.nextDue) < (order[$1.status] ?? 9, $1.nextDue.isEmpty ? "9" : $1.nextDue) }
        return List {
            ForEach(rows) { t in
                rowLink(selected: selTask == t.id, select: { selTask = t.id }, dest: { EstateTaskPane(model: model, task: t) }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(t.title).font(EstateUI.body.weight(.semibold)).foregroundColor(.white).lineLimit(2)
                            Spacer()
                            EstatePill(text: t.statusLabel, status: t.status)
                        }
                        Text([t.every, t.nextDue.isEmpty ? "" : "next \(EstateDates.short(t.nextDue))", t.supplier].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(EstateUI.small).foregroundColor(EstateUI.muted).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
            }
            Button { activeSheet = .newTask } label: { Label("Add a recurring task", systemImage: "plus") }
                .foregroundColor(EstateUI.accent).listRowBackground(EstateUI.bg)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: "Search tasks")
        .refreshable { await model.load() }
    }

    private var supplierList: some View {
        let q = search.lowercased()
        let rows = model.suppliers.filter { q.isEmpty || "\($0.display) \($0.name) \($0.trades.joined(separator: " "))".lowercased().contains(q) }
        return List {
            Button { activeSheet = .newSupplier } label: { Label("Add a supplier", systemImage: "plus") }
                .foregroundColor(EstateUI.accent).listRowBackground(EstateUI.bg)
            ForEach(rows) { sp in
                rowLink(selected: selSupplier == sp.id, select: { selSupplier = sp.id }, dest: { EstateSupplierPane(model: model, original: sp) }) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(sp.display.isEmpty ? sp.name : sp.display).font(EstateUI.body.weight(.semibold)).foregroundColor(.white).lineLimit(1)
                            Spacer()
                            if sp.openTickets > 0 { Text("\(sp.openTickets) open").font(.system(size: 12, weight: .bold)).foregroundColor(EstateUI.blue) }
                        }
                        Text(sp.trades.joined(separator: ", ").capitalized).font(EstateUI.small).foregroundColor(EstateUI.muted).lineLimit(1)
                        if sp.missingContact { Text("No phone or email on file").font(.system(size: 13)).foregroundColor(EstateUI.warn) }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: "Search suppliers or trades")
        .refreshable { await model.load() }
    }

    private var paymentList: some View {
        List {
            if model.payments.isEmpty && !model.loading {
                Text("No payments waiting for you.").font(EstateUI.body).foregroundColor(EstateUI.muted).listRowBackground(EstateUI.bg)
            }
            ForEach(model.payments) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.supplier.isEmpty ? p.payee : p.supplier).font(EstateUI.title).foregroundColor(.white)
                        Spacer()
                        Text(EstateMoney.format(p.amount, p.currency)).font(EstateUI.title.monospacedDigit()).foregroundColor(.white)
                    }
                    if !p.description.isEmpty { Text(p.description).font(EstateUI.body).foregroundColor(.white).multilineTextAlignment(p.description.readingAlignment) }
                    if let d = p.deviation {
                        Text(abs(d) < 5 ? "In line with past invoices" : "\(Int(abs(d)))% \(d > 0 ? "above" : "below") what this usually costs")
                            .font(EstateUI.small.weight(.semibold)).foregroundColor(abs(d) < 5 ? EstateUI.accent : EstateUI.warn)
                    }
                    ForEach(p.flags, id: \.self) { Text("⚠︎ \($0)").font(EstateUI.small).foregroundColor(EstateUI.warn) }
                    HStack {
                        Button("Approve → wire draft") { Task { await model.act("estate_payment_action", ["id": p.id, "action": "approve"], success: "Wire draft is on your shelf") } }
                            .buttonStyle(.borderedProminent).tint(EstateUI.scarlet)
                        Button("Dispute") { Task { await model.act("estate_payment_action", ["id": p.id, "action": "dispute"], success: "Marked disputed") } }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(EstateUI.card))
                .listRowBackground(EstateUI.bg).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private var homesList: some View {
        let byZone = Dictionary(grouping: model.devices) { model.zones[$0.zoneID] ?? "Other" }
        return List {
            if !model.staff.isEmpty {
                Section {
                    ForEach(model.staff) { st in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(st.name).font(EstateUI.body.weight(.semibold)).foregroundColor(.white)
                            Text([st.role, st.phone, st.email].filter { !$0.isEmpty }.joined(separator: " · ")).font(EstateUI.small).foregroundColor(EstateUI.muted).textSelection(.enabled)
                        }
                        .listRowBackground(EstateUI.bg)
                    }
                } header: { Text("Staff").foregroundColor(EstateUI.muted) }
            }
            ForEach(byZone.keys.sorted(), id: \.self) { zone in
                Section {
                    ForEach(byZone[zone] ?? []) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(d.name).font(EstateUI.body).foregroundColor(.white).multilineTextAlignment(d.name.readingAlignment)
                                Spacer()
                                if d.status != "ok" && !d.status.isEmpty { Text(d.status.capitalized).font(.system(size: 12, weight: .bold)).foregroundColor(EstateUI.warn) }
                            }
                            let meta = [[d.make, d.model].filter { !$0.isEmpty }.joined(separator: " "), d.supplier, d.warranty.isEmpty ? "" : "warranty to \(EstateDates.short(d.warranty))"].filter { !$0.isEmpty }
                            if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(EstateUI.small).foregroundColor(EstateUI.muted) }
                        }
                        .listRowBackground(EstateUI.bg)
                    }
                } header: { Text(zone).foregroundColor(EstateUI.muted) }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }
}

// MARK: - Shared bits

struct EstatePill: View {
    let text: String, status: String
    var body: some View {
        let (bg, fg): (Color, Color) = {
            switch status {
            case "overdue": return (Color(red: 0.29, green: 0.08, blue: 0.08), Color(red: 1, green: 0.6, blue: 0.6))
            case "needs_you": return (Color(red: 0.78, green: 0.06, blue: 0.18), .white)
            case "due_soon", "in_progress": return (Color(red: 0.29, green: 0.2, blue: 0.06), Color(red: 1, green: 0.81, blue: 0.48))
            case "scheduled": return (Color(red: 0.04, green: 0.24, blue: 0.38), Color(red: 0.62, green: 0.82, blue: 1))
            case "on_track", "done_cycle": return (Color(red: 0.07, green: 0.24, blue: 0.13), Color(red: 0.5, green: 0.88, blue: 0.63))
            default: return (Color(white: 0.23), Color(white: 0.85))
            }
        }()
        return Text(text).font(.system(size: 12, weight: .bold)).foregroundColor(fg).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(bg))
    }
}

enum EstateDates {
    private static let iso: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    static func date(_ s: String) -> Date? { iso.date(from: String(s.prefix(10))) }
    static func wire(_ d: Date) -> String { iso.string(from: d) }
    static func short(_ s: String) -> String {
        guard let d = date(s) else { return s }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
    static func stamp(_ s: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        return d.map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? String(s.prefix(16))
    }
}

enum EstateMoney {
    static func format(_ a: Double, _ cur: String) -> String {
        let sym = ["ILS": "₪", "USD": "$", "EUR": "€"][cur.uppercased()] ?? (cur + " ")
        return sym + a.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// Reading text: white on pure black, direction per paragraph (§5, §13).
struct EstateReadingText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, para in
                Text(para).font(EstateUI.body).foregroundColor(.white)
                    .multilineTextAlignment(para.readingAlignment)
                    .frame(maxWidth: .infinity, alignment: para.readingFrameAlignment)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(EstateUI.line))
    }
}

private struct EstateCard<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundColor(EstateUI.muted)
            content
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(EstateUI.card))
    }
}

// MARK: - Ticket pane

struct EstateTicketPane: View {
    @ObservedObject var model: EstateModel
    let ticketID: String
    let onSchedule: (EstateTicket) -> Void
    @State private var detail: EstateTicketDetail?
    @State private var note = ""
    @State private var confirmCancel = false

    var body: some View {
        ScrollView {
            if let d = detail {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(d.ticket.title).font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                            .multilineTextAlignment(d.ticket.title.readingAlignment)
                        Spacer()
                        EstatePill(text: d.ticket.waiting, status: d.ticket.stage == "needs_you" ? "needs_you" : d.ticket.stage == "scheduled" ? "scheduled" : d.ticket.stage == "closed" ? "on_track" : "in_progress")
                    }
                    facts(d)
                    if !d.draftID.isEmpty { draftCard(d) }
                    if !d.ticket.proposedDate.isEmpty { proposedCard(d.ticket) }
                    actions(d.ticket)
                    noteBox
                    history(d.events)
                }
                .padding(20)
            } else {
                ProgressView().tint(EstateUI.muted).padding(60)
            }
        }
        .background(EstateUI.bg)
        .task { detail = await model.ticketDetail(ticketID) }
        .onChange(of: model.tickets) { _, _ in Task { detail = await model.ticketDetail(ticketID) } }
        .confirmationDialog("Cancel this ticket?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel ticket", role: .destructive) { Task { await model.act("estate_ticket_action", ["id": ticketID, "action": "cancel"], success: "Cancelled") } }
        }
    }

    private func facts(_ d: EstateTicketDetail) -> some View {
        let rows: [(String, String)] = [
            ("Home", [d.ticket.home, d.ticket.zone].filter { !$0.isEmpty }.joined(separator: " · ")),
            ("Device", d.ticket.device), ("Supplier", d.supplierLine), ("Reported by", d.ticket.reportedBy),
            ("Opened", d.ticket.openedAt.isEmpty ? "" : EstateDates.stamp(d.ticket.openedAt)),
            ("Visit", d.ticket.scheduledFor.isEmpty ? "" : EstateDates.stamp(d.ticket.scheduledFor)),
            ("Priority", d.ticket.priority.capitalized),
        ].filter { !$0.1.isEmpty }
        return VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        Text(r.0).font(EstateUI.small).foregroundColor(EstateUI.muted)
                        Text(r.1).font(EstateUI.body).foregroundColor(.white).textSelection(.enabled)
                    }
                }
            }
            if !d.symptom.isEmpty { EstateReadingText(text: d.symptom) }
        }
    }

    private func draftCard(_ d: EstateTicketDetail) -> some View {
        EstateCard(label: "Message ready to send\(d.draftRecipient.isEmpty ? "" : " · to " + d.draftRecipient)") {
            EstateReadingText(text: d.draftBody.isEmpty ? "(writing…)" : d.draftBody)
            Button { Task { await model.openDraft(d.draftID) } } label: {
                Label("Review & send", systemImage: "paperplane.fill").font(EstateUI.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent).tint(EstateUI.scarlet)
            .keyboardShortcut(.return, modifiers: .command)
            Text("Opens your draft window: edit by voice or text, then approve, or say \"send it\".")
                .font(EstateUI.small).foregroundColor(EstateUI.muted)
        }
    }

    private func proposedCard(_ t: EstateTicket) -> some View {
        EstateCard(label: "Supplier proposed a visit") {
            Text("\(EstateDates.short(t.proposedDate))\(t.proposedTime.isEmpty ? "" : " at " + t.proposedTime)").font(EstateUI.title).foregroundColor(.white)
            HStack {
                Button("Confirm") { Task { await model.act("estate_ticket_action", ["id": t.id, "action": "confirm_visit"], success: "Visit confirmed") } }
                    .buttonStyle(.borderedProminent).tint(EstateUI.accent)
                Button("Other time…") { onSchedule(t) }.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder private func actions(_ t: EstateTicket) -> some View {
        let open = ["open", "scheduled", "in_progress", "verifying"].contains(t.status)
        HStack(spacing: 10) {
            if open {
                Button("Mark done") { Task { await model.act("estate_ticket_action", ["id": t.id, "action": "done"], success: "Marked done") } }
                    .buttonStyle(.borderedProminent).tint(EstateUI.accent)
                Button("Schedule visit…") { onSchedule(t) }.buttonStyle(.bordered)
                Menu {
                    Menu("Priority") {
                        ForEach(["urgent", "high", "normal", "low"], id: \.self) { p in
                            Button(p.capitalized) { Task { await model.act("estate_ticket_action", ["id": t.id, "action": "priority", "priority": p], success: "Priority \(p)") } }
                        }
                    }
                    Menu("Supplier") {
                        ForEach(model.suppliers) { sp in
                            Button(sp.display.isEmpty ? sp.name : sp.display) { Task { await model.act("estate_ticket_action", ["id": t.id, "action": "supplier", "supplier_id": sp.id], success: "Supplier changed") } }
                        }
                    }
                    Divider()
                    Button("Cancel ticket", role: .destructive) { confirmCancel = true }
                } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuStyle(.button).buttonStyle(.bordered)
            } else {
                Button("Reopen") { Task { await model.act("estate_ticket_action", ["id": t.id, "action": "reopen"], success: "Reopened") } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var noteBox: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Add a note to this ticket", text: $note, axis: .vertical)
                .font(EstateUI.body).foregroundColor(.white).lineLimit(1...4)
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(EstateUI.line))
                .environment(\.layoutDirection, note.layoutDir)
            Button("Add") {
                let n = note; note = ""
                Task { await model.act("estate_ticket_action", ["id": ticketID, "action": "note", "note": n], success: "Noted") }
            }
            .buttonStyle(.bordered).disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func history(_ events: [EstateEvent]) -> some View {
        EstateCard(label: "History") {
            if events.isEmpty { Text("No events yet.").font(EstateUI.small).foregroundColor(EstateUI.muted) }
            ForEach(events.reversed()) { e in
                HStack(alignment: .top, spacing: 12) {
                    Text(EstateDates.stamp(e.at)).font(.system(size: 13).monospacedDigit()).foregroundColor(EstateUI.muted).frame(width: 110, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.body).font(.system(size: 16)).foregroundColor(.white).multilineTextAlignment(e.body.readingAlignment)
                            .frame(maxWidth: .infinity, alignment: e.body.readingFrameAlignment).textSelection(.enabled)
                        if !e.actor.isEmpty { Text(e.actor).font(.system(size: 13)).foregroundColor(EstateUI.muted) }
                    }
                }
            }
        }
    }
}

// MARK: - Recurring task pane

struct EstateTaskPane: View {
    @ObservedObject var model: EstateModel
    let task: EstateTask
    @State private var cycles: [EstateCycle] = []
    @State private var nextDue = Date()
    @State private var interval = 30
    @State private var supplierID = ""
    @State private var dirty = false
    @State private var visitDate = Date()
    @State private var pickingVisit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.title).font(.system(size: 24, weight: .bold)).foregroundColor(.white).multilineTextAlignment(task.title.readingAlignment)
                    Spacer()
                    EstatePill(text: task.statusLabel, status: task.status)
                }
                Text([task.home, task.every, task.lastDone.isEmpty ? "never recorded" : "last done \(EstateDates.short(task.lastDone))"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(EstateUI.body).foregroundColor(EstateUI.muted)

                EstateCard(label: "This cycle") {
                    HStack(spacing: 10) {
                        Button("Done today") { Task { await model.act("estate_recurring_action", ["id": task.id, "action": "done"], success: "Recorded as done") } }
                            .buttonStyle(.borderedProminent).tint(EstateUI.accent)
                        Button("Schedule…") { pickingVisit.toggle() }.buttonStyle(.bordered)
                        Button("Snooze 2 weeks") { Task { await model.act("estate_recurring_action", ["id": task.id, "action": "snooze", "days": 14], success: "Postponed") } }.buttonStyle(.bordered)
                        Button("Skip") { Task { await model.act("estate_recurring_action", ["id": task.id, "action": "skip"], success: "Cycle skipped") } }.buttonStyle(.bordered)
                    }
                    if pickingVisit {
                        HStack {
                            DatePicker("Visit on", selection: $visitDate, in: Date()..., displayedComponents: .date).foregroundColor(.white)
                            Button("Set visit") {
                                pickingVisit = false
                                Task { await model.act("estate_recurring_action", ["id": task.id, "action": "scheduled", "date": EstateDates.wire(visitDate)], success: "Visit scheduled") }
                            }
                            .buttonStyle(.borderedProminent).tint(EstateUI.accent)
                        }
                    }
                    if !task.openTicketID.isEmpty {
                        Text("An open ticket tracks this cycle (see Tickets).").font(EstateUI.small).foregroundColor(EstateUI.muted)
                    }
                }

                EstateCard(label: "Schedule") {
                    DatePicker("Next due", selection: $nextDue, displayedComponents: .date)
                        .font(EstateUI.body).foregroundColor(.white).onChange(of: nextDue) { _, _ in dirty = true }
                    Stepper("Every \(interval) days", value: $interval, in: 1...3650, step: interval >= 60 ? 30 : 7)
                        .font(EstateUI.body).foregroundColor(.white).onChange(of: interval) { _, _ in dirty = true }
                    Picker("Supplier", selection: $supplierID) {
                        Text("None").tag("")
                        ForEach(model.suppliers) { Text($0.display.isEmpty ? $0.name : $0.display).tag($0.id) }
                    }
                    .font(EstateUI.body).onChange(of: supplierID) { _, _ in dirty = true }
                    if dirty {
                        Button("Save changes") { save() }.buttonStyle(.borderedProminent).tint(EstateUI.accent)
                            .keyboardShortcut("s", modifiers: .command)
                    }
                }

                EstateCard(label: "Past cycles") {
                    if cycles.isEmpty { Text("No cycles recorded yet.").font(EstateUI.small).foregroundColor(EstateUI.muted) }
                    ForEach(cycles) { c in
                        HStack {
                            Text(c.cycleDue.isEmpty ? "—" : EstateDates.short(c.cycleDue)).font(EstateUI.body.monospacedDigit()).foregroundColor(.white).frame(width: 80, alignment: .leading)
                            Text(c.status == "done" ? "Done\(c.closedAt.isEmpty ? "" : " " + EstateDates.short(c.closedAt))" : c.status == "cancelled" ? "Skipped" : c.waiting)
                                .font(EstateUI.body).foregroundColor(c.status == "done" ? EstateUI.accent : c.status == "cancelled" ? EstateUI.muted : .white)
                            Spacer()
                            if !c.paid.isEmpty { Text(c.paid).font(EstateUI.small.monospacedDigit()).foregroundColor(EstateUI.muted) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(EstateUI.bg)
        .task {
            nextDue = EstateDates.date(task.nextDue) ?? Date()
            interval = max(task.intervalDays, 1)
            supplierID = task.supplierID
            dirty = false
            cycles = await model.taskCycles(task.id)
        }
        // Leave-saves (§11): an edited schedule is never lost by navigating away.
        .onDisappear { if dirty { save() } }
    }

    private func save() {
        dirty = false
        let fields: [String: Any] = ["next_due": EstateDates.wire(nextDue), "interval_days": interval, "supplier_id": supplierID]
        Task { await model.act("estate_recurring_save", ["id": task.id, "fields": fields], success: "Saved") }
    }
}

// MARK: - Supplier pane (edit in place)

struct EstateSupplierPane: View {
    @ObservedObject var model: EstateModel
    let original: EstateSupplier
    @State private var edit = EstateSupplier.blank()
    @State private var tradesText = ""
    @State private var loaded = false

    private var dirty: Bool { loaded && (edit != original || tradesText != original.trades.joined(separator: ", ")) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(edit.display.isEmpty ? edit.name : edit.display).font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    if dirty {
                        Button("Save") { save() }.buttonStyle(.borderedProminent).tint(EstateUI.accent).keyboardShortcut("s", modifiers: .command)
                        Button("Revert") { reset() }.buttonStyle(.bordered)
                    }
                }
                EstateSupplierForm(edit: $edit, tradesText: $tradesText)
                if original.hasBank {
                    Text("Bank details are on file. They can't be changed here: the desk confirms any bank change by phone.")
                        .font(EstateUI.small).foregroundColor(EstateUI.muted)
                }
                if !original.transitionState.isEmpty {
                    Text("Handover from Dror and Doron: \(original.transitionState.replacingOccurrences(of: "_", with: " "))")
                        .font(EstateUI.small).foregroundColor(EstateUI.muted)
                }
            }
            .padding(20)
        }
        .background(EstateUI.bg)
        .onAppear { if !loaded { reset() } }
        .onDisappear { if dirty { save() } }   // leave-saves
    }

    private func reset() {
        edit = original
        tradesText = original.trades.joined(separator: ", ")
        loaded = true
    }

    private func save() {
        edit.trades = tradesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let body: [String: Any] = ["id": original.id, "fields": edit.wireFields]
        Task { await model.act("estate_supplier_save", body, success: "Supplier saved") }
    }
}

struct EstateSupplierForm: View {
    @Binding var edit: EstateSupplier
    @Binding var tradesText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EstateCard(label: "Details") {
                field("Name", $edit.name)
                field("Hebrew name", $edit.nameHe)
                field("Trades (comma-separated)", $tradesText)
                Picker("Language", selection: $edit.language) {
                    Text("Hebrew").tag("he"); Text("English").tag("en")
                }
                .pickerStyle(.segmented)
            }
            EstateCard(label: "How to reach them") {
                field("Mobile / WhatsApp", $edit.whatsapp, keyboard: .phonePad)
                field("Phone", $edit.phone, keyboard: .phonePad)
                field("Email", $edit.email, keyboard: .emailAddress)
            }
            EstateCard(label: "Contact people") {
                ForEach($edit.contacts) { $c in
                    VStack(spacing: 6) {
                        HStack { field("Name", $c.name); field("Role", $c.role) }
                        HStack { field("Phone", $c.phone, keyboard: .phonePad); field("Email", $c.email, keyboard: .emailAddress) }
                        Button(role: .destructive) { edit.contacts.removeAll { $0.id == c.id } } label: { Label("Remove", systemImage: "minus.circle") }
                            .font(EstateUI.small).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Divider().background(EstateUI.line)
                }
                Button { edit.contacts.append(EstateContact()) } label: { Label("Add contact person", systemImage: "plus") }
                    .foregroundColor(EstateUI.accent)
            }
            EstateCard(label: "Notes") {
                TextField("Anything the desk should know", text: $edit.note, axis: .vertical)
                    .font(EstateUI.body).foregroundColor(.white).lineLimit(2...8)
                    .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                    .environment(\.layoutDirection, edit.note.layoutDir)
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 13)).foregroundColor(EstateUI.muted)
            TextField(label, text: text)
                .font(EstateUI.body).foregroundColor(.white).keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .default ? .sentences : .never)
                .autocorrectionDisabled(keyboard != .default)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(EstateUI.line))
                .environment(\.layoutDirection, text.wrappedValue.layoutDir)
        }
    }
}

// MARK: - Sheets (all driven by EstateView's single .sheet(item:))

struct EstateReportSheet: View {
    @ObservedObject var model: EstateModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var urgent = false
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("What's wrong, and where?").font(EstateUI.title).foregroundColor(.white)
                TextField("e.g. The gate in Kisch is stuck again", text: $text, axis: .vertical)
                    .font(EstateUI.body).foregroundColor(.white).lineLimit(3...8).focused($focused)
                    .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(EstateUI.line))
                    .environment(\.layoutDirection, text.layoutDir)
                Toggle("Urgent", isOn: $urgent).font(EstateUI.body).foregroundColor(.white)
                Text("Scarlet finds the device and its supplier, opens the ticket and prepares the message for your approval. Nothing is sent yet.")
                    .font(EstateUI.small).foregroundColor(EstateUI.muted)
                Spacer()
            }
            .padding(20)
            .background(EstateUI.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Opening…" : "Open ticket") {
                        sending = true
                        Task {
                            let ok = await model.act("estate_ticket_create", ["text": text, "urgency": urgent ? "urgent" : "normal"], success: "Ticket opened")
                            sending = false
                            if ok != nil { model.leaf = .tickets; dismiss() }
                        }
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .onAppear { focused = true }
        }
        .preferredColorScheme(.dark)
    }
}

struct EstateScheduleSheet: View {
    @ObservedObject var model: EstateModel
    let ticket: EstateTicket
    @Environment(\.dismiss) private var dismiss
    @State private var when = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(ticket.title).font(EstateUI.title).foregroundColor(.white)
                DatePicker("Visit", selection: $when, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical).tint(EstateUI.accent)
                Text("The supplier is told from the estate number, the visit goes on the estate calendar, and Anton and Edison are informed.")
                    .font(EstateUI.small).foregroundColor(EstateUI.muted)
                Spacer()
            }
            .padding(20)
            .background(EstateUI.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm visit") {
                        let date = EstateDates.wire(when)
                        let hm = DateFormatter(); hm.locale = Locale(identifier: "en_US_POSIX"); hm.dateFormat = "HH:mm"
                        let time = hm.string(from: when)
                        Task {
                            if await model.act("estate_ticket_action", ["id": ticket.id, "action": "scheduled", "date": date, "time": time], success: "Visit scheduled") != nil { dismiss() }
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct EstateSupplierSheet: View {
    @ObservedObject var model: EstateModel
    @Environment(\.dismiss) private var dismiss
    @State private var edit = EstateSupplier.blank()
    @State private var tradesText = ""

    var body: some View {
        NavigationStack {
            ScrollView { EstateSupplierForm(edit: $edit, tradesText: $tradesText).padding(20) }
                .background(EstateUI.bg.ignoresSafeArea())
                .navigationTitle("New supplier")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            edit.trades = tradesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            Task { if await model.act("estate_supplier_save", ["fields": edit.wireFields], success: "Supplier added") != nil { dismiss() } }
                        }
                        .disabled(edit.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

struct EstateNewTaskSheet: View {
    @ObservedObject var model: EstateModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var interval = 90
    @State private var first = Date()
    @State private var supplierID = ""
    @State private var home = "kfar_kisch"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Task (e.g. Clean the AC filters)", text: $title).environment(\.layoutDirection, title.layoutDir)
                if model.homes.count > 1 {
                    Picker("Home", selection: $home) { ForEach(model.homes, id: \.id) { Text($0.name).tag($0.id) } }
                }
                Stepper("Every \(interval) days", value: $interval, in: 1...3650, step: interval >= 60 ? 30 : 7)
                DatePicker("First due", selection: $first, displayedComponents: .date)
                Picker("Supplier", selection: $supplierID) {
                    Text("None yet").tag("")
                    ForEach(model.suppliers) { Text($0.display.isEmpty ? $0.name : $0.display).tag($0.id) }
                }
            }
            .scrollContentBackground(.hidden).background(EstateUI.bg.ignoresSafeArea())
            .navigationTitle("New recurring task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let fields: [String: Any] = ["title": title, "interval_days": interval, "next_due": EstateDates.wire(first), "supplier_id": supplierID, "mode": "scheduled"]
                        Task { if await model.act("estate_recurring_save", ["home_id": home, "fields": fields], success: "Task added") != nil { dismiss() } }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
