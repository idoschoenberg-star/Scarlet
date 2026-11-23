import SwiftUI

// MARK: - Devices (the Device Boundary registry — docs/DEVICE_BOUNDARY.md)
//
// Settings → Devices: every paired device token and every Mac fleet node,
// each wearing its tier — green Personal / grey Corporate / amber Unknown
// (unknown RENDERS as corporate everywhere; the chip says so honestly).
// Tapping a row relabels its tier or revokes it (sign-out kill switch:
// "returned the corp laptop" ends that window and touches nothing else).
// Macs carry their MDM probe state; a Mac with a positive enrollment probe
// refuses "personal" server-side (409) and the alert repeats that honestly.

// MARK: wire types

struct RegisteredDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let platform: String
    let tier: String
    let tierSource: String
    let createdAt: Date?
    let lastSeen: Date?
    let expired: Bool
    let current: Bool
}

struct RegisteredMac: Identifiable, Equatable {
    let id: String
    let name: String
    let tier: String
    /// nil = the enrollment probe has not run yet ("Unchecked").
    let mdmEnrolled: Bool?
    let mdmCheckedAt: Date?
    let lastSeen: Date?
    let enabled: Bool
}

// MARK: model

@MainActor
final class DevicesModel: ObservableObject {
    @Published private(set) var devices: [RegisteredDevice] = []
    @Published private(set) var macs: [RegisteredMac] = []
    @Published private(set) var loading = false
    @Published var errorText = ""
    /// Row with a request in flight — its controls disable, no double-fires.
    @Published private(set) var busyId: String?
    /// Honest outcome/refusal to surface as an alert (the 409 MDM guard
    /// lands here too).
    @Published var alertText: String?

    func load() async {
        if devices.isEmpty && macs.isEmpty { loading = true }
        defer { loading = false }
        guard let (data, status) = await DeviceBoundary.call("op=devices", method: "GET"),
              (200...299).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            errorText = devices.isEmpty
                ? "Couldn't load the device list. Pull down to try again." : ""
            return
        }
        errorText = ""
        devices = ((obj["devices"] as? [[String: Any]]) ?? []).compactMap { d -> RegisteredDevice? in
            guard let id = d["id"] as? String, !id.isEmpty,
                  (d["revoked"] as? Bool) != true else { return nil }
            return RegisteredDevice(
                id: id,
                name: (d["name"] as? String) ?? "device",
                platform: (d["platform"] as? String) ?? "",
                tier: (d["tier"] as? String) ?? "unknown",
                tierSource: (d["tier_source"] as? String) ?? "",
                createdAt: MailDates.parse(d["created_at"] as? String),
                lastSeen: MailDates.parse(d["last_seen"] as? String),
                expired: (d["expired"] as? Bool) ?? false,
                current: (d["current"] as? Bool) ?? false)
        }
        // This device first, then most recently seen.
        .sorted {
            if $0.current != $1.current { return $0.current }
            return ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast)
        }
        macs = ((obj["macs"] as? [[String: Any]]) ?? []).compactMap { m -> RegisteredMac? in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            return RegisteredMac(
                id: id,
                name: (m["name"] as? String) ?? id,
                tier: (m["tier"] as? String) ?? "unknown",
                mdmEnrolled: m["mdm_enrolled"] as? Bool,
                mdmCheckedAt: MailDates.parse(m["mdm_checked_at"] as? String),
                lastSeen: MailDates.parse(m["last_seen"] as? String),
                enabled: (m["enabled"] as? Bool) ?? true)
        }
    }

    /// Relabel a device token's tier ({id, tier}) or a Mac node's ({mac_id, tier}).
    func setTier(_ tier: String, deviceId: String? = nil, macId: String? = nil,
                 isCurrentDevice: Bool = false) async {
        let rowId = deviceId ?? macId ?? ""
        guard busyId == nil else { return }
        busyId = rowId
        defer { busyId = nil }
        var body: [String: Any] = ["tier": tier]
        if let deviceId { body["id"] = deviceId }
        if let macId { body["mac_id"] = macId }
        guard let (data, status) = await DeviceBoundary.call("op=device_tier",
                                                             method: "POST", body: body) else {
            alertText = "Couldn't reach Scarlet — check your connection and try again."
            return
        }
        if status == 409 {
            // The MDM guard: a probe that PROVED enrollment outranks any label.
            alertText = "This Mac shows company management — it stays corporate while managed."
            return
        }
        guard (200...299).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            alertText = msg ?? "That didn't go through — try again."
            return
        }
        if isCurrentDevice { DeviceBoundary.shared.noteUnlockTier(tier) }
        await load()
    }

    /// Kill switch. Returns true when the CURRENT device revoked itself —
    /// the caller then signs this install out locally.
    func revoke(_ device: RegisteredDevice) async -> Bool {
        guard busyId == nil else { return false }
        busyId = device.id
        defer { busyId = nil }
        guard let (data, status) = await DeviceBoundary.call("op=device_revoke",
                                                             method: "POST",
                                                             body: ["id": device.id]),
              (200...299).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["ok"] as? Bool) == true else {
            alertText = "Couldn't revoke that device — check your connection and try again."
            return false
        }
        if !device.current {
            alertText = "\(device.name) is signed out."
            await load()
        }
        return device.current
    }
}

// MARK: view

struct DevicesView: View {
    @StateObject private var m = DevicesModel()

    /// What a row tap opens — ONE dialog slot for both sections, so the view
    /// never stacks presentation modifiers (Catalyst discipline).
    private enum Pick: Identifiable {
        case device(RegisteredDevice)
        case mac(RegisteredMac)
        var id: String {
            switch self {
            case .device(let d): return "d-" + d.id
            case .mac(let n): return "m-" + n.id
            }
        }
    }
    @State private var pick: Pick?
    /// Revoke gets its own explicit confirmation step.
    @State private var revokeTarget: RegisteredDevice?

    var body: some View {
        List {
            Section {
                if m.loading {
                    HStack { ProgressView(); Text("Loading devices…").foregroundStyle(.secondary) }
                }
                ForEach(m.devices) { d in
                    Button { pick = .device(d) } label: { deviceRow(d) }
                        .buttonStyle(.plain)
                        .disabled(m.busyId != nil)
                }
                if !m.errorText.isEmpty {
                    Text(m.errorText).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Paired devices")
            } footer: {
                Text("Unknown devices behave as corporate until you classify them — personal sections stay tucked away there. Tap a device to change its tier or sign it out.")
            }

            if !m.macs.isEmpty {
                Section {
                    ForEach(m.macs) { n in
                        Button { pick = .mac(n) } label: { macRow(n) }
                            .buttonStyle(.plain)
                            .disabled(m.busyId != nil)
                    }
                } header: {
                    Text("Macs")
                } footer: {
                    Text("Macs are probed for management automatically. A Mac that shows company management stays corporate while managed — no label can override the probe.")
                }
            }
        }
        .navigationTitle("Devices")
        .refreshable { await m.load() }
        .task { await m.load() }
        .confirmationDialog(pickTitle, isPresented: pickPresented,
                            titleVisibility: .visible, presenting: pick) { p in
            pickActions(p)
        } message: { p in
            if case .mac(let n) = p, n.mdmEnrolled == true {
                Text("This Mac shows company management, so it stays corporate while managed.")
            }
        }
        // Alerts are not sheets — the two below coexist safely with the
        // dialog above (only one is ever raised at a time).
        .alert("Sign this device out?", isPresented: revokePresented,
               presenting: revokeTarget) { d in
            Button("Revoke \(d.name)", role: .destructive) {
                Task { @MainActor in
                    if await m.revoke(d) {
                        // The current device revoked itself: sign out locally
                        // through the app's existing auth-expired path.
                        NotificationCenter.default.post(name: .scarletAuthExpired, object: nil)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This signs that device out immediately. Nothing else is affected.")
        }
        .alert(m.alertText ?? "", isPresented: alertPresented) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: rows

    private func deviceRow(_ d: RegisteredDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.glyph(d.platform))
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(d.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .multilineTextAlignment(d.name.readingAlignment)
                    if d.current {
                        Text("this device")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(red: 1, green: 0.35, blue: 0.42).opacity(0.25),
                                        in: Capsule())
                            .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.60))
                    }
                }
                Text(subtitle(for: d))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if m.busyId == d.id {
                ProgressView()
            } else {
                TierChip(tier: d.tier)
            }
        }
        .contentShape(Rectangle())
    }

    private func macRow(_ n: RegisteredMac) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "macbook")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(n.name).fontWeight(.semibold).lineLimit(1)
                Text(Self.macState(n) + (n.lastSeen.map { " · seen \(Self.rel($0))" } ?? ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if m.busyId == n.id {
                ProgressView()
            } else {
                TierChip(tier: n.tier)
            }
        }
        .contentShape(Rectangle())
    }

    private func subtitle(for d: RegisteredDevice) -> String {
        var bits: [String] = []
        if let seen = d.lastSeen { bits.append("seen \(Self.rel(seen))") }
        else if let made = d.createdAt { bits.append("paired \(Self.rel(made))") }
        if d.expired { bits.append("expired") }
        return bits.isEmpty ? "never seen" : bits.joined(separator: " · ")
    }

    // MARK: dialog plumbing

    private var pickTitle: String {
        switch pick {
        case .device(let d): return d.name
        case .mac(let n): return n.name
        case nil: return ""
        }
    }

    private var pickPresented: Binding<Bool> {
        Binding(get: { pick != nil }, set: { if !$0 { pick = nil } })
    }
    private var revokePresented: Binding<Bool> {
        Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } })
    }
    private var alertPresented: Binding<Bool> {
        Binding(get: { m.alertText != nil }, set: { if !$0 { m.alertText = nil } })
    }

    @ViewBuilder
    private func pickActions(_ p: Pick) -> some View {
        switch p {
        case .device(let d):
            if d.tier != "personal" {
                Button("Mark personal") {
                    Task { await m.setTier("personal", deviceId: d.id, isCurrentDevice: d.current) }
                }
            }
            if d.tier != "corporate" {
                Button("Mark corporate") {
                    Task { await m.setTier("corporate", deviceId: d.id, isCurrentDevice: d.current) }
                }
            }
            Button(d.current ? "Revoke — signs THIS device out" : "Revoke…",
                   role: .destructive) { revokeTarget = d }
            Button("Cancel", role: .cancel) {}
        case .mac(let n):
            if n.tier != "personal" {
                // Offered even when the probe says managed: the server's 409
                // answers with the honest refusal rather than a hidden button.
                Button("Mark personal") { Task { await m.setTier("personal", macId: n.id) } }
            }
            if n.tier != "corporate" {
                Button("Mark corporate") { Task { await m.setTier("corporate", macId: n.id) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: formatting

    static func glyph(_ platform: String) -> String {
        switch platform {
        case "ios": return "iphone"
        case "ipados": return "ipad"
        case "watchos": return "applewatch"
        case "mac": return "macbook"
        case "web": return "globe"
        default: return "questionmark.circle"
        }
    }

    static func macState(_ n: RegisteredMac) -> String {
        switch n.mdmEnrolled {
        case true: return "Managed — corporate"
        case false: return n.tier == "personal" ? "Verified personal" : "No management found"
        default: return "Unchecked"
        }
    }

    /// "just now" / "5m ago" / "3h ago" / "2d ago" — the Chats list's dialect.
    static func rel(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 90 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

/// The tier chip: green Personal / grey Corporate / amber Unknown. The
/// unknown chip says what it DOES ("acts corporate") — fail-closed, honestly.
struct TierChip: View {
    let tier: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
            .foregroundStyle(color)
    }

    private var label: String {
        switch tier {
        case "personal": return "Personal"
        case "corporate": return "Corporate"
        default: return "Unknown"
        }
    }

    private var color: Color {
        switch tier {
        case "personal": return Color(red: 0.35, green: 0.82, blue: 0.55)
        case "corporate": return Color(white: 0.72)
        default: return Color(red: 0.91, green: 0.69, blue: 0.31)
        }
    }
}
