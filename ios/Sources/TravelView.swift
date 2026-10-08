import SwiftUI
import PassKit
import CoreImage.CIFilterBuiltins

// MARK: - Travel (Ido 2026-10-08: "go ahead and build Travel"). Four leaves —
// Up next · Passes · Reservations · Past — over the Travel Desk's tables
// (travel_legs / travel_passes / travel_reservations). Every op is
// `travel_<name>` on app-api, proxied to travel-desk (`_shared/travel_app.ts`).
//
// • Check-in: automatic when the window opens (the desk's watcher), with
//   "Check in now" as the manual override. A leg is "Checked in" only once
//   El Al's boarding-pass mail arrives — never from a run verdict alone.
// • Boarding passes: full-screen barcode at max brightness for the gate, and
//   "Add to Apple Wallet" from the airline's own .pkpass.
// • Same rules as Estate: iPad/Mac list + detail, iPhone push; reading text
//   white on black; one `.sheet(item:)` (+ one fullScreenCover) per view.

private enum TravelUI {
    static let bg = Color.black
    static let card = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let card2 = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let line = Color(white: 0.22)
    static let muted = Color(white: 0.64)
    static let accent = Color(red: 0.36, green: 0.61, blue: 1.0)    // travel blue — chrome only
    static let scarlet = Color(red: 1, green: 0.35, blue: 0.42)
    static let ok = Color(red: 0.30, green: 0.76, blue: 0.52)
    static let warn = Color(red: 0.94, green: 0.64, blue: 0.23)
    static let body = Font.system(size: 17)
    static let title = Font.system(size: 21, weight: .semibold)
    static let small = Font.system(size: 14)
}

enum TravelLeaf: String, CaseIterable, Identifiable {
    case upNext, passes, reservations, past
    var id: String { rawValue }
    var title: String {
        switch self {
        case .upNext: return "Up next"
        case .passes: return "Passes"
        case .reservations: return "Reservations"
        case .past: return "Past"
        }
    }
}

private func ts(_ o: [String: Any], _ k: String) -> String { (o[k] as? String) ?? "" }

enum TravelTime {
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let iso = ISO8601DateFormatter()
    static func date(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }
    /// Time in the place it happens (a Zurich departure reads in Zurich time).
    static func local(_ s: String, tz: String, style: Date.FormatStyle = .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) -> String {
        guard let d = date(s) else { return "" }
        var st = style
        if let zone = TimeZone(identifier: tz) { st.timeZone = zone }
        return d.formatted(st)
    }
    static func clock(_ s: String, tz: String) -> String { local(s, tz: tz, style: .dateTime.hour().minute()) }
    static func day(_ s: String, tz: String) -> String { local(s, tz: tz, style: .dateTime.weekday(.wide).day().month(.wide)) }
}

// MARK: - Wire models

struct TravelPass: Identifiable, Equatable {
    let id: String, legID: String, passenger: String, flight: String, date: String, origin: String, destination: String
    let seat: String, boarding: String, gate: String, sequence: String, barcode: String, barcodeFormat: String
    let hasPkpass: Bool, hasPdf: Bool
    init(_ o: [String: Any]) {
        id = ts(o, "id"); legID = ts(o, "leg_id"); passenger = ts(o, "passenger"); flight = ts(o, "flight_no"); date = ts(o, "date")
        origin = ts(o, "origin"); destination = ts(o, "destination"); seat = ts(o, "seat"); boarding = ts(o, "boarding_time")
        gate = ts(o, "gate"); sequence = ts(o, "sequence"); barcode = ts(o, "barcode"); barcodeFormat = ts(o, "barcode_format")
        hasPkpass = (o["has_pkpass"] as? Bool) ?? false; hasPdf = (o["has_pdf"] as? Bool) ?? false
    }
}

struct TravelLeg: Identifiable, Equatable {
    let id: String, flight: String, origin: String, destination: String
    let depart: String, departTZ: String, arrive: String, arriveTZ: String
    let locator: String, cabin: String, trip: String, travelers: [String], canAuto: Bool
    let status: String, statusLabel: String, opensAt: String, auto: Bool, note: String, runURL: String
    let seats: [String: String], passes: [TravelPass]
    init(_ o: [String: Any]) {
        id = ts(o, "id"); flight = ts(o, "flight_no"); origin = ts(o, "origin"); destination = ts(o, "destination")
        depart = ts(o, "depart"); departTZ = ts(o, "depart_tz"); arrive = ts(o, "arrive"); arriveTZ = ts(o, "arrive_tz")
        locator = ts(o, "record_locator"); cabin = ts(o, "cabin"); trip = ts(o, "trip")
        travelers = (o["travelers"] as? [String]) ?? []; canAuto = (o["can_auto"] as? Bool) ?? false
        let c = (o["checkin"] as? [String: Any]) ?? [:]
        status = ts(c, "status"); statusLabel = ts(c, "label"); opensAt = ts(c, "opens_at"); auto = (c["auto"] as? Bool) ?? false
        note = ts(c, "note"); runURL = ts(c, "run_id")
        seats = (o["seats"] as? [String: String]) ?? [:]
        passes = ((o["passes"] as? [[String: Any]]) ?? []).map(TravelPass.init)
    }
    var departed: Bool { status == "departed" }
    var needsYou: Bool { status == "failed" || (status == "open" && !auto) }
}

struct TravelReservation: Identifiable, Equatable {
    var id: String, kind: String, title: String, venue: String, address: String
    var startsAt: String, endsAt: String, tz: String, confirmation: String, party: String, status: String, notes: String, source: String
    init(_ o: [String: Any]) {
        id = ts(o, "id"); kind = ts(o, "kind"); title = ts(o, "title"); venue = ts(o, "venue"); address = ts(o, "address")
        startsAt = ts(o, "starts_at"); endsAt = ts(o, "ends_at"); tz = ts(o, "tz"); confirmation = ts(o, "confirmation")
        party = ts(o, "party"); status = ts(o, "status"); notes = ts(o, "notes"); source = ts(o, "source")
    }
    var icon: String {
        switch kind {
        case "hotel": return "bed.double.fill"
        case "dining": return "fork.knife"
        case "car": return "car.fill"
        case "transfer": return "car.side.fill"
        case "lounge": return "sofa.fill"
        case "flight": return "airplane"
        case "activity": return "figure.walk"
        default: return "calendar"
        }
    }
    var zone: String { tz.isEmpty ? TimeZone.current.identifier : tz }
}

// MARK: - Model

@MainActor
final class TravelModel: ObservableObject {
    @Published var leaf: TravelLeaf = .upNext
    @Published var legs: [TravelLeg] = []
    @Published var reservations: [TravelReservation] = []
    @Published var loading = false
    @Published var errorText = ""
    @Published var toast = ""

    var upcomingLegs: [TravelLeg] { legs.filter { !$0.departed } }
    var pastLegs: [TravelLeg] { legs.filter { $0.departed }.reversed() }
    var upcomingReservations: [TravelReservation] {
        let now = Date()
        return reservations.filter { r in
            guard r.status != "cancelled" else { return false }
            guard let d = TravelTime.date(r.endsAt.isEmpty ? r.startsAt : r.endsAt) else { return true }
            return d >= now.addingTimeInterval(-3 * 3600)
        }
    }
    var allPasses: [(TravelLeg, TravelPass)] { upcomingLegs.flatMap { l in l.passes.map { (l, $0) } } }
    var needsYou: Int { upcomingLegs.filter(\.needsYou).count }

    func load() async {
        loading = true
        defer { loading = false }
        errorText = ""
        do {
            async let l = Self.call("travel_legs", ["past_days": 60])
            async let r = Self.call("travel_reservations", ["past_days": 60])
            let (lr, rr) = try await (l, r)
            legs = ((lr["legs"] as? [[String: Any]]) ?? []).map(TravelLeg.init)
            reservations = ((rr["items"] as? [[String: Any]]) ?? []).map(TravelReservation.init)
        } catch {
            errorText = "Couldn't load travel. Pull to retry."
        }
    }

    @discardableResult
    func act(_ op: String, _ body: [String: Any], success: String) async -> [String: Any]? {
        do {
            let r = try await Self.call(op, body)
            if (r["ok"] as? Bool) == false {
                errorText = (r["error"] as? String) ?? "That didn't work."
                return nil
            }
            toast = (r["outcome"] as? String) ?? success
            Task { try? await Task.sleep(nanoseconds: 2_800_000_000); self.toast = "" }
            await load()
            return r
        } catch {
            errorText = "No connection — nothing was changed."
            return nil
        }
    }

    /// Pull passes and reservations from the mail now (the desk also does
    /// this every 30 minutes on its own).
    func syncNow() async {
        toast = "Checking your mail for passes and bookings…"
        _ = try? await Self.call("travel_sync", ["days": 21, "budget": 12])
        toast = ""
        await load()
    }

    /// Downloads a pass file (signed URL) to a temp file.
    func passFile(_ pass: TravelPass, kind: String) async -> URL? {
        guard let r = try? await Self.call("travel_pass_file", ["id": pass.id, "kind": kind]),
              let s = r["url"] as? String, let url = URL(string: s) else {
            errorText = "Couldn't fetch the \(kind == "pdf" ? "PDF" : "Wallet pass")."
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let name = "\(pass.flight)-\(pass.passenger.split(separator: " ").first ?? "pass").\(kind == "pdf" ? "pdf" : "pkpass")"
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            errorText = "Couldn't download the file."
            return nil
        }
    }

    static func call(_ op: String, _ body: [String: Any]) async throws -> [String: Any] {
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "op", value: op)]
        var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
        req.httpMethod = "POST"
        req.timeoutInterval = op == "travel_sync" ? 150 : 40
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
}

// MARK: - Page

struct TravelView: View {
    @StateObject private var model = TravelModel()
    @EnvironmentObject private var convo: Conversation
    @Environment(\.horizontalSizeClass) private var hSize

    enum Selection: Hashable { case leg(String), reservation(String) }
    enum TravelSheet: Identifiable {
        case newReservation
        case editReservation(TravelReservation)
        case wallet(PKPass)
        case file(PreviewFile)
        var id: String {
            switch self {
            case .newReservation: return "new"
            case .editReservation(let r): return "edit-\(r.id)"
            case .wallet(let p): return "wallet-\(p.serialNumber)"
            case .file(let f): return "file-\(f.id)"
            }
        }
    }
    @State private var activeSheet: TravelSheet?
    @State private var gatePass: TravelPass?
    @State private var selection: Selection?

    private var wide: Bool { hSize == .regular }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if wide {
                    HStack(spacing: 0) {
                        listPane.frame(width: 390)
                        Divider().background(TravelUI.line)
                        detailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    listPane
                }
            }
            .background(TravelUI.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if !model.toast.isEmpty {
                        Text(model.toast).font(TravelUI.small.weight(.semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(TravelUI.accent.opacity(0.85)))
                    }
                    ScarletPresenceView(convo: convo).padding(.vertical, 6)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.load() }
            .onAppear { convo.setFocus(focusLine) }
            .onChange(of: model.leaf) { _, _ in convo.setFocus(focusLine) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await model.load() }
            }
            .reportsModalPresence(activeSheet != nil || gatePass != nil)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .newReservation: TravelReservationSheet(model: model, original: nil)
                case .editReservation(let r): TravelReservationSheet(model: model, original: r)
                case .wallet(let pass): AddPassSheet(pass: pass)
                case .file(let f): QuickLookPreview(url: f.url).ignoresSafeArea()
                }
            }
            .fullScreenCover(item: $gatePass) { p in GatePassView(pass: p) }
        }
    }

    private var focusLine: String {
        let next = model.upcomingLegs.first.map { "\($0.flight) \($0.origin)→\($0.destination)" } ?? "no upcoming flight"
        return "[FOCUS] Ido is in the Travel section, \(model.leaf.title) (next: \(next)). Travel questions → the travel tool."
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Travel").font(.system(size: 34, weight: .bold)).foregroundColor(.white)
                if model.needsYou > 0 {
                    Text("\(model.needsYou) need\(model.needsYou == 1 ? "s" : "") you").font(TravelUI.small.weight(.bold)).foregroundColor(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(TravelUI.scarlet))
                }
                Spacer()
                if model.loading { ProgressView().tint(TravelUI.muted) }
                Button { Task { await model.syncNow() } } label: { Label("Check mail", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).font(TravelUI.small)
                Button { activeSheet = .newReservation } label: { Label("Add booking", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(TravelUI.accent).font(TravelUI.small.weight(.semibold))
            }
            Picker("Section", selection: $model.leaf) {
                ForEach(TravelLeaf.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if !model.errorText.isEmpty { Text(model.errorText).font(TravelUI.small).foregroundColor(TravelUI.warn) }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: list pane

    @ViewBuilder private var listPane: some View {
        switch model.leaf {
        case .upNext: upNextList
        case .passes: passesList
        case .reservations: reservationList(model.upcomingReservations, empty: "No upcoming bookings. They appear here from your confirmation emails, or add one.")
        case .past: pastList
        }
    }

    @ViewBuilder private var detailPane: some View {
        switch selection {
        case .leg(let id):
            if let l = model.legs.first(where: { $0.id == id }) { legDetail(l).id(id) } else { placeholder }
        case .reservation(let id):
            if let r = model.reservations.first(where: { $0.id == id }) { reservationDetail(r).id(id) } else { placeholder }
        case nil: placeholder
        }
    }

    private var placeholder: some View {
        VStack { Spacer(); Text("Select a flight or booking.").font(TravelUI.body).foregroundColor(TravelUI.muted); Spacer() }
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func row<Content: View, Dest: View>(_ sel: Selection, @ViewBuilder dest: @escaping () -> Dest, @ViewBuilder content: () -> Content) -> some View {
        if wide {
            Button { selection = sel } label: {
                HStack { content(); Image(systemName: "chevron.right").font(.caption).foregroundColor(TravelUI.muted) }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selection == sel ? TravelUI.card2 : TravelUI.bg)
        } else {
            NavigationLink { dest().background(TravelUI.bg.ignoresSafeArea()) } label: { content() }
                .listRowBackground(TravelUI.bg)
        }
    }

    /// Flights and bookings in one timeline, grouped by day; anything that
    /// needs Ido sits on top.
    private var upNextList: some View {
        enum Item: Identifiable { case leg(TravelLeg), res(TravelReservation)
            var id: String { switch self { case .leg(let l): return "l" + l.id; case .res(let r): return "r" + r.id } }
            var when: Date { switch self { case .leg(let l): return TravelTime.date(l.depart) ?? .distantFuture; case .res(let r): return TravelTime.date(r.startsAt) ?? .distantFuture } }
        }
        let items = (model.upcomingLegs.map(Item.leg) + model.upcomingReservations.map(Item.res)).sorted { $0.when < $1.when }
        let byDay = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.when) }
        return List {
            let needs = model.upcomingLegs.filter(\.needsYou)
            if !needs.isEmpty {
                Section {
                    ForEach(needs) { l in row(.leg(l.id), dest: { legDetail(l) }) { legRow(l) } }
                } header: { Text("Needs you · \(needs.count)").foregroundColor(TravelUI.scarlet) }
            }
            ForEach(byDay.keys.sorted(), id: \.self) { day in
                Section {
                    ForEach(byDay[day] ?? []) { it in
                        switch it {
                        case .leg(let l): row(.leg(l.id), dest: { legDetail(l) }) { legRow(l) }
                        case .res(let r): row(.reservation(r.id), dest: { reservationDetail(r) }) { reservationRow(r) }
                        }
                    }
                } header: {
                    Text(day == .distantFuture ? "Date to confirm" : day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .foregroundColor(TravelUI.muted)
                }
            }
            if items.isEmpty && !model.loading {
                Text("Nothing coming up. Flights and bookings appear here from your email.").font(TravelUI.body).foregroundColor(TravelUI.muted).listRowBackground(TravelUI.bg)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private var pastList: some View {
        let pastRes = model.reservations.filter { r in !model.upcomingReservations.contains(r) }.reversed()
        return List {
            Section {
                ForEach(model.pastLegs) { l in row(.leg(l.id), dest: { legDetail(l) }) { legRow(l) } }
            } header: { Text("Flights").foregroundColor(TravelUI.muted) }
            Section {
                ForEach(Array(pastRes)) { r in row(.reservation(r.id), dest: { reservationDetail(r) }) { reservationRow(r) } }
            } header: { Text("Bookings").foregroundColor(TravelUI.muted) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private func reservationList(_ items: [TravelReservation], empty: String) -> some View {
        List {
            ForEach(items) { r in row(.reservation(r.id), dest: { reservationDetail(r) }) { reservationRow(r) } }
            if items.isEmpty && !model.loading { Text(empty).font(TravelUI.body).foregroundColor(TravelUI.muted).listRowBackground(TravelUI.bg) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private var passesList: some View {
        ScrollView {
            VStack(spacing: 14) {
                if model.allPasses.isEmpty && !model.loading {
                    Text("No boarding passes yet. They appear here as soon as El Al emails them after check-in.")
                        .font(TravelUI.body).foregroundColor(TravelUI.muted).padding(30)
                }
                ForEach(model.allPasses, id: \.1.id) { pair in
                    PassCard(leg: pair.0, pass: pair.1,
                             onGate: { gatePass = pair.1 },
                             onWallet: { Task { await addToWallet(pair.1) } },
                             onPDF: { Task { await openPDF(pair.1) } })
                }
            }
            .padding(16)
        }
        .refreshable { await model.load() }
    }

    // MARK: rows

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "done": return TravelUI.ok
        case "failed": return TravelUI.scarlet
        case "open", "requested", "running": return TravelUI.warn
        default: return TravelUI.muted
        }
    }

    private func legRow(_ l: TravelLeg) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "airplane").font(.system(size: 18)).foregroundColor(TravelUI.accent).frame(width: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(l.flight) · \(l.origin) → \(l.destination)").font(TravelUI.body.weight(.semibold)).foregroundColor(.white)
                Text("\(TravelTime.local(l.depart, tz: l.departTZ))\(l.arrive.isEmpty ? "" : " → " + TravelTime.clock(l.arrive, tz: l.arriveTZ))")
                    .font(TravelUI.small).foregroundColor(TravelUI.muted)
                Text(l.statusLabel).font(.system(size: 13, weight: .semibold)).foregroundColor(statusColor(l.status))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func reservationRow(_ r: TravelReservation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: r.icon).font(.system(size: 17)).foregroundColor(TravelUI.accent).frame(width: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(TravelUI.body.weight(.semibold)).foregroundColor(r.status == "cancelled" ? TravelUI.muted : .white)
                    .strikethrough(r.status == "cancelled").lineLimit(2).multilineTextAlignment(r.title.readingAlignment)
                let when = r.startsAt.isEmpty ? "Date to confirm" : TravelTime.local(r.startsAt, tz: r.zone)
                Text([when, r.venue].filter { !$0.isEmpty }.joined(separator: " · ")).font(TravelUI.small).foregroundColor(TravelUI.muted).lineLimit(2)
                if r.status == "pending" { Text("Not confirmed yet").font(.system(size: 13, weight: .semibold)).foregroundColor(TravelUI.warn) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: details

    private func legDetail(_ l: TravelLeg) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(l.flight)").font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    if !l.cabin.isEmpty { Text(l.cabin).font(TravelUI.small.weight(.semibold)).foregroundColor(TravelUI.muted) }
                }
                HStack(alignment: .center) {
                    VStack(alignment: .leading) {
                        Text(l.origin).font(.system(size: 40, weight: .bold).monospacedDigit()).foregroundColor(.white)
                        Text(TravelTime.clock(l.depart, tz: l.departTZ)).font(TravelUI.title).foregroundColor(.white)
                        Text(TravelTime.day(l.depart, tz: l.departTZ)).font(TravelUI.small).foregroundColor(TravelUI.muted)
                    }
                    Spacer()
                    Image(systemName: "airplane").font(.system(size: 26)).foregroundColor(TravelUI.accent)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(l.destination).font(.system(size: 40, weight: .bold).monospacedDigit()).foregroundColor(.white)
                        Text(l.arrive.isEmpty ? "—" : TravelTime.clock(l.arrive, tz: l.arriveTZ)).font(TravelUI.title).foregroundColor(.white)
                        Text(l.arrive.isEmpty ? "" : TravelTime.day(l.arrive, tz: l.arriveTZ)).font(TravelUI.small).foregroundColor(TravelUI.muted)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach([("Booking", l.locator), ("Travelers", l.travelers.joined(separator: ", ")),
                             ("Seats", l.seats.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " · "))].filter { !$0.1.isEmpty }, id: \.0) { r in
                        GridRow {
                            Text(r.0).font(TravelUI.small).foregroundColor(TravelUI.muted)
                            Text(r.1).font(TravelUI.body).foregroundColor(.white).textSelection(.enabled)
                        }
                    }
                }
                checkinCard(l)
                if !l.passes.isEmpty {
                    Text("BOARDING PASSES").font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundColor(TravelUI.muted)
                    ForEach(l.passes) { p in
                        PassCard(leg: l, pass: p, onGate: { gatePass = p },
                                 onWallet: { Task { await addToWallet(p) } }, onPDF: { Task { await openPDF(p) } })
                    }
                }
            }
            .padding(20)
        }
        .background(TravelUI.bg)
    }

    private func checkinCard(_ l: TravelLeg) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CHECK-IN").font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundColor(TravelUI.muted)
            HStack {
                Circle().fill(statusColor(l.status)).frame(width: 10, height: 10)
                Text(l.statusLabel).font(TravelUI.title).foregroundColor(.white)
            }
            if l.status == "not_open", !l.opensAt.isEmpty {
                Text("Opens \(TravelTime.local(l.opensAt, tz: l.departTZ)) (\(l.departTZ.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? l.departTZ) time).")
                    .font(TravelUI.body).foregroundColor(.white)
            }
            if !l.note.isEmpty { Text(l.note).font(TravelUI.body).foregroundColor(.white).multilineTextAlignment(l.note.readingAlignment) }
            if ["open", "failed"].contains(l.status) {
                Button { Task { await model.act("travel_checkin_request", ["id": l.id], success: "Check-in requested") } } label: {
                    Label("Check in now", systemImage: "checkmark.seal.fill").font(TravelUI.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(TravelUI.accent).disabled(!l.canAuto)
                if !l.canAuto { Text("Ticket numbers aren't on file for this flight yet. Ask the Travel Desk, or use the El Al app.").font(TravelUI.small).foregroundColor(TravelUI.muted) }
            }
            Text("Seats are never changed without asking you.").font(.system(size: 13)).foregroundColor(TravelUI.muted)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(TravelUI.card))
    }

    private func reservationDetail(_ r: TravelReservation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: r.icon).foregroundColor(TravelUI.accent).font(.system(size: 22))
                    Text(r.title).font(.system(size: 24, weight: .bold)).foregroundColor(.white).multilineTextAlignment(r.title.readingAlignment)
                    Spacer()
                }
                if r.status != "confirmed" {
                    Text(r.status == "cancelled" ? "Cancelled" : "Not confirmed yet").font(TravelUI.body.weight(.semibold))
                        .foregroundColor(r.status == "cancelled" ? TravelUI.scarlet : TravelUI.warn)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach([("When", r.startsAt.isEmpty ? "" : TravelTime.local(r.startsAt, tz: r.zone) + (r.endsAt.isEmpty ? "" : " → " + TravelTime.local(r.endsAt, tz: r.zone))),
                             ("Where", [r.venue, r.address].filter { !$0.isEmpty }.joined(separator: "\n")),
                             ("Confirmation", r.confirmation), ("Party", r.party)].filter { !$0.1.isEmpty }, id: \.0) { row in
                        GridRow(alignment: .top) {
                            Text(row.0).font(TravelUI.small).foregroundColor(TravelUI.muted)
                            Text(row.1).font(TravelUI.body).foregroundColor(.white).textSelection(.enabled)
                        }
                    }
                }
                if !r.notes.isEmpty {
                    Text(r.notes).font(TravelUI.body).foregroundColor(.white).padding(12).frame(maxWidth: .infinity, alignment: r.notes.readingFrameAlignment)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black)).overlay(RoundedRectangle(cornerRadius: 10).stroke(TravelUI.line))
                }
                HStack(spacing: 10) {
                    if let maps = mapsURL(r) {
                        Button { UIApplication.shared.open(maps) } label: { Label("Directions", systemImage: "map.fill") }
                            .buttonStyle(.borderedProminent).tint(TravelUI.accent)
                    }
                    if !r.confirmation.isEmpty {
                        Button { UIPasteboard.general.string = r.confirmation; model.toast = "Confirmation number copied" } label: { Label("Copy number", systemImage: "doc.on.doc") }
                            .buttonStyle(.bordered)
                    }
                    Button { activeSheet = .editReservation(r) } label: { Label("Edit", systemImage: "pencil") }.buttonStyle(.bordered)
                }
                if r.source == "email" { Text("Found in your email.").font(.system(size: 13)).foregroundColor(TravelUI.muted) }
            }
            .padding(20)
        }
        .background(TravelUI.bg)
    }

    private func mapsURL(_ r: TravelReservation) -> URL? {
        let q = [r.venue, r.address].filter { !$0.isEmpty }.joined(separator: ", ")
        guard !q.isEmpty, let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "http://maps.apple.com/?q=\(enc)")
    }

    // MARK: pass actions

    private func addToWallet(_ p: TravelPass) async {
        guard PKAddPassesViewController.canAddPasses() else { model.errorText = "Apple Wallet isn't available on this device."; return }
        guard let url = await model.passFile(p, kind: "pkpass"), let data = try? Data(contentsOf: url) else { return }
        do { activeSheet = .wallet(try PKPass(data: data)) } catch { model.errorText = "The airline's Wallet pass couldn't be read." }
    }

    private func openPDF(_ p: TravelPass) async {
        if let url = await model.passFile(p, kind: "pdf") { activeSheet = .file(PreviewFile(url: url)) }
    }
}

// MARK: - Pass card + gate view

struct PassCard: View {
    let leg: TravelLeg
    let pass: TravelPass
    let onGate: () -> Void
    let onWallet: () -> Void
    let onPDF: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(pass.passenger).font(TravelUI.title).foregroundColor(.white)
                Spacer()
                Text(pass.flight.isEmpty ? leg.flight : pass.flight).font(TravelUI.body.weight(.semibold)).foregroundColor(.white)
            }
            HStack(spacing: 22) {
                field("From", pass.origin.isEmpty ? leg.origin : pass.origin)
                field("To", pass.destination.isEmpty ? leg.destination : pass.destination)
                field("Seat", pass.seat.isEmpty ? "—" : pass.seat)
                field("Boarding", pass.boarding.isEmpty ? "—" : pass.boarding)
                if !pass.gate.isEmpty { field("Gate", pass.gate) }
            }
            HStack(spacing: 10) {
                if !pass.barcode.isEmpty {
                    Button(action: onGate) { Label("Show at gate", systemImage: "qrcode") }.buttonStyle(.borderedProminent).tint(TravelUI.accent)
                }
                if pass.hasPkpass { Button(action: onWallet) { Label("Add to Apple Wallet", systemImage: "wallet.pass.fill") }.buttonStyle(.bordered) }
                if pass.hasPdf { Button(action: onPDF) { Label("PDF", systemImage: "doc.richtext") }.buttonStyle(.bordered) }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [Color(red: 0.04, green: 0.16, blue: 0.36), Color(red: 0.07, green: 0.24, blue: 0.52)], startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundColor(.white.opacity(0.7))
            Text(value).font(.system(size: 20, weight: .bold).monospacedDigit()).foregroundColor(.white)
        }
    }
}

/// Full-screen pass for the gate: big barcode on white, screen at full
/// brightness while it's up, restored on close.
struct GatePassView: View {
    let pass: TravelPass
    @Environment(\.dismiss) private var dismiss
    @State private var savedBrightness: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundColor(.gray) }
                    .keyboardShortcut(.cancelAction)
            }
            Text(pass.passenger).font(.system(size: 26, weight: .bold)).foregroundColor(.black)
            Text("\(pass.flight) · \(pass.origin) → \(pass.destination)\(pass.seat.isEmpty ? "" : " · Seat \(pass.seat)")")
                .font(.system(size: 20, weight: .semibold)).foregroundColor(.black)
            if let img = Barcode.image(pass.barcode, format: pass.barcodeFormat) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 420, maxHeight: pass.barcodeFormat.contains("PDF417") ? 180 : 420)
            } else {
                Text("This pass has no barcode. Use the Wallet pass or the PDF.").foregroundColor(.black)
            }
            if !pass.boarding.isEmpty { Text("Boarding \(pass.boarding)\(pass.gate.isEmpty ? "" : " · Gate \(pass.gate)")").font(.system(size: 20)).foregroundColor(.black) }
            Spacer()
        }
        .padding(24)
        .background(Color.white.ignoresSafeArea())
        .onAppear { savedBrightness = UIScreen.main.brightness; UIScreen.main.brightness = 1.0 }
        .onDisappear { UIScreen.main.brightness = savedBrightness }
    }
}

enum Barcode {
    static func image(_ message: String, format: String) -> UIImage? {
        guard !message.isEmpty, let data = message.data(using: .isoLatin1) ?? message.data(using: .utf8) else { return nil }
        let ctx = CIContext()
        let output: CIImage?
        if format.contains("Aztec") {
            let f = CIFilter.aztecCodeGenerator(); f.message = data; output = f.outputImage
        } else if format.contains("PDF417") {
            let f = CIFilter.pdf417BarcodeGenerator(); f.message = data; output = f.outputImage
        } else {
            let f = CIFilter.qrCodeGenerator(); f.message = data; f.correctionLevel = "M"; output = f.outputImage
        }
        guard let out = output?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct AddPassSheet: UIViewControllerRepresentable {
    let pass: PKPass
    func makeUIViewController(context: Context) -> UIViewController {
        PKAddPassesViewController(pass: pass) ?? UIViewController()
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}

// MARK: - Add / edit a booking

struct TravelReservationSheet: View {
    @ObservedObject var model: TravelModel
    let original: TravelReservation?
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "dining"
    @State private var title = ""
    @State private var venue = ""
    @State private var address = ""
    @State private var start = Date()
    @State private var hasEnd = false
    @State private var end = Date().addingTimeInterval(7200)
    @State private var confirmation = ""
    @State private var party = ""
    @State private var notes = ""
    @State private var status = "confirmed"
    @State private var confirmCancel = false

    private static let kinds: [(String, String)] = [("dining", "Restaurant"), ("hotel", "Hotel"), ("car", "Car"), ("transfer", "Transfer"), ("lounge", "Lounge"), ("activity", "Activity"), ("other", "Other")]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) { ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) } }
                TextField("Name (e.g. Dinner at Kulm)", text: $title).environment(\.layoutDirection, title.layoutDir)
                TextField("Place", text: $venue).environment(\.layoutDirection, venue.layoutDir)
                TextField("Address", text: $address)
                DatePicker("Starts", selection: $start)
                Toggle("Has an end time", isOn: $hasEnd)
                if hasEnd { DatePicker("Ends", selection: $end) }
                TextField("Confirmation number", text: $confirmation).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Party (e.g. 4 people)", text: $party)
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...6).environment(\.layoutDirection, notes.layoutDir)
                if original != nil {
                    Picker("Status", selection: $status) { Text("Confirmed").tag("confirmed"); Text("Pending").tag("pending"); Text("Cancelled").tag("cancelled") }
                }
            }
            .scrollContentBackground(.hidden).background(Color.black.ignoresSafeArea())
            .navigationTitle(original == nil ? "Add booking" : "Edit booking")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            .onAppear(perform: fill)
        }
        .preferredColorScheme(.dark)
    }

    private func fill() {
        guard let r = original else { return }
        kind = r.kind.isEmpty ? "other" : r.kind; title = r.title; venue = r.venue; address = r.address
        if let d = TravelTime.date(r.startsAt) { start = d }
        if let d = TravelTime.date(r.endsAt) { end = d; hasEnd = true }
        confirmation = r.confirmation; party = r.party; notes = r.notes; status = r.status
    }

    private func save() {
        let iso = ISO8601DateFormatter()
        var fields: [String: Any] = ["kind": kind, "title": title, "venue": venue, "address": address, "starts_at": iso.string(from: start),
                                     "ends_at": hasEnd ? iso.string(from: end) : "", "confirmation": confirmation, "party": party, "notes": notes,
                                     "tz": TimeZone.current.identifier]
        if original != nil { fields["status"] = status }
        var body: [String: Any] = ["fields": fields]
        if let id = original?.id { body["id"] = id }
        Task { if await model.act("travel_reservation_save", body, success: original == nil ? "Booking added" : "Saved") != nil { dismiss() } }
    }
}
