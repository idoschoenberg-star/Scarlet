import Foundation
import SwiftUI

/// The native drafting studio: Scarlet composes an email in Ido's voice, he
/// refines it with plain words, and Approve lands a TRUE threaded Reply-All
/// in his Outlook Drafts folder. Talks to the exact same edge-function ops
/// the web app uses (draft_compose / draft_active / draft_action).

// MARK: - Seed

/// What the studio needs to know about the message being replied to. Field
/// shapes mirror exactly what the web reader sends to `op=draft_compose`:
/// recipient "Name <email>", original "Subject — preview", and the Graph
/// message id so approval creates a real threaded Reply-All.
struct DraftSeed {
    let messageId: String
    let fromName: String
    let fromEmail: String
    let subject: String
    let preview: String
    /// The original message's To/Cc lines (comma-joined, as `op=mailread`
    /// returns them). Informational only — approval builds the true
    /// Reply-All server-side; these let the header show it up front.
    var toLine: String = ""
    var ccLine: String = ""

    var recipientLine: String {
        var s = ""
        if !fromName.isEmpty { s += fromName + " " }
        if !fromEmail.isEmpty { s += "<" + fromEmail + ">" }
        return s.trimmingCharacters(in: .whitespaces)
    }

    var originalLine: String {
        if subject.isEmpty { return preview }
        if preview.isEmpty { return subject }
        return subject + " — " + preview
    }
}

/// Seed for drafting INTO a chat channel (WhatsApp/iMessage/Teams) straight
/// from its thread — recipient is the chat's display name (the server
/// resolves the real address), contextLines ride into Scarlet's focus.
struct ChannelDraftSeed: Identifiable {
    let channel: String        // "whatsapp" | "imessage" | "teams"
    let recipient: String      // chat display name, e.g. "Adam"
    var contextLines: String = ""   // last ~6 thread lines, "Name: text"
    var instruction: String = ""    // optional pre-typed ask

    /// `.sheet(item:)` identity — one channel draft per chat at a time.
    var id: String { channel + recipient }
}

// MARK: - Model

@MainActor
final class DraftModel: ObservableObject {

    /// One draft row, as `op=draft_active` returns it.
    struct ActiveDraft {
        let id: String
        let channel: String
        let recipient: String
        let subject: String
        let body: String
        let revision: Int
        let status: String
        let outcome: String
        /// Teams approval carries a deep link that opens Teams with the message
        /// pre-typed; nil for every other channel.
        var link: String? = nil
    }

    /// One autocomplete row, as `op=contactsearch` returns it — the server
    /// ranks by relevance (frequent contacts first), like Outlook's own.
    struct Contact: Identifiable {
        let name: String
        let email: String
        let title: String

        var id: String { email }
    }

    enum Phase: Equatable {
        case idle       // new-mail form (or nothing started yet)
        case writing    // first compose in flight
        case ready      // draft on screen, awaiting Ido
        case revising   // revise in flight
        case approving  // approve in flight
        case saved      // approved — show the green check, then dismiss
    }

    @Published var draft: ActiveDraft?
    @Published var phase: Phase = .idle
    @Published var errorText = ""
    /// Teams deep link from the last approval — opened automatically, and
    /// offered as an "Open in Teams" button in case the auto-open was blocked.
    @Published var teamsLink: URL?
    /// To-field autocomplete rows for the new-mail form. Never blocks
    /// "Start the draft" — free-typed text stays valid (the server resolves
    /// names at approval).
    @Published var suggestions: [Contact] = []

    private var draftId: String?
    private var pendingCompose: [String: Any]?
    /// Set when the sheet closed before compose returned a draft_id — the
    /// in-flight compose reads it and dismisses the draft it just created.
    private var dismissRequested = false
    private var timer: Timer?
    /// The in-flight (debouncing or fetching) contact search, cancelled by
    /// every keystroke so only the latest query lands.
    private var searchTask: Task<Void, Never>?
    /// The exact To text a suggestion tap produced — typing it back should
    /// not reopen the list.
    private var pickedSuggestion = ""
    /// Voice-attach mode: Scarlet's compose_draft tool already started the
    /// draft server-side, so this sheet adopts whatever `op=draft_active`
    /// returns instead of composing its own.
    private var adoptActive = false

    // MARK: intents

    /// Reply mode: compose immediately from the open message, exactly like the
    /// web reader's "↩ Reply" (message_id rides along for threaded Reply-All).
    func startReply(seed: DraftSeed, instruction: String) {
        guard phase == .idle, draftId == nil else { return }
        var body: [String: Any] = [
            "channel": "email_outlook",
            "recipient": seed.recipientLine,
            "instruction": instruction,
            "message_id": seed.messageId,
        ]
        let original = seed.originalLine
        if !original.isEmpty { body["original"] = original }
        compose(body)
    }

    /// Channel-draft mode: compose INTO a chat channel (WhatsApp/iMessage/
    /// Teams) straight from its thread. draft_compose accepts any channel; no
    /// message_id/original — the server resolves the display name to a real
    /// address and channel rules govern what Approve does.
    func startChannelDraft(seed: ChannelDraftSeed, instruction: String) {
        guard phase == .idle, draftId == nil else { return }
        let instr = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        compose([
            "channel": seed.channel,
            "recipient": seed.recipient,
            "instruction": instr.isEmpty ? "Draft this message." : instr,
        ])
    }

    /// New-mail mode: no original message — the backend composes fresh and
    /// approval resolves the free-form recipient to a real address.
    func startNewMail(recipient: String, instruction: String) {
        guard phase == .idle, draftId == nil else { return }
        let to = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let instr = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { return }
        compose([
            "channel": "email_outlook",
            "recipient": to,
            "instruction": instr.isEmpty ? "Draft this email." : instr,
        ])
    }

    /// Outlook-style To-field autocomplete: debounce ~350ms, then ask the
    /// server for relevance-ranked matches. Skips (and clears) when the text
    /// already holds an address ("@" or "<"), is under 2 characters, or is
    /// exactly the suggestion just picked.
    func searchContacts(_ q: String) {
        searchTask?.cancel()
        let text = q.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, !text.contains("@"), !text.contains("<"),
              text != pickedSuggestion else {
            suggestions = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            // Percent-encode down to alphanumerics before the query string,
            // same as InboxModel does with Graph ids.
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
            guard let data = try? await Self.request("op=contactsearch&q=\(encoded)", method: "GET") else { return }
            if Task.isCancelled { return }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let found: [Contact] = ((obj?["contacts"] as? [[String: Any]]) ?? []).compactMap { c in
                guard let email = c["email"] as? String, !email.isEmpty else { return nil }
                return Contact(
                    name: (c["name"] as? String) ?? "",
                    email: email,
                    title: (c["title"] as? String) ?? ""
                )
            }
            if Task.isCancelled { return }
            self?.suggestions = found
        }
    }

    /// A suggestion row was tapped: remember the resulting To text so the
    /// onChange it triggers doesn't reopen the list.
    func suggestionPicked(_ text: String) {
        searchTask?.cancel()
        pickedSuggestion = text
        suggestions = []
    }

    /// Attach mode: the compose is already in flight on the server (started
    /// by voice) — find the active draft and follow it.
    func attachToActive() {
        guard draftId == nil else { return }
        adoptActive = true
        phase = .writing
        startPolling()
        Task {
            if let d = try? await Self.fetchActive() { adopt(d) }
            // If the compose hasn't landed yet, the poll adopts it when it does.
        }
    }

    /// True when THIS window's Approve button did the approving — the view
    /// then tells Scarlet out loud, so she never re-asks "shall I send it?".
    /// Voice approvals (her approve_draft tool) leave this false: she already
    /// knows, the window just closes.
    var approvedViaButton = false

    private func adopt(_ d: ActiveDraft) {
        draftId = d.id
        draft = d
        if phase == .writing && d.status == "draft" { phase = .ready }
        // Approved by voice while this window is open: show the same green
        // "sent" state the button shows, then the sheet auto-dismisses.
        if d.status == "approved" && (phase == .ready || phase == .writing) {
            phase = .saved
        }
    }

    /// Re-run the last failed compose.
    func retry() {
        guard let body = pendingCompose, draftId == nil else { return }
        compose(body)
    }

    func revise(_ instruction: String) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = draftId, phase == .ready, !text.isEmpty else { return }
        phase = .revising
        errorText = ""
        Task {
            do {
                let data = try await Self.request("op=draft_action", method: "POST",
                                                  body: ["id": id, "action": "revise", "instruction": text])
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else { throw URLError(.badServerResponse) }
                if let d = try? await Self.fetchActive(), d.id == id { draft = d }
                phase = .ready
            } catch {
                errorText = "That revision didn't go through — try again."
                phase = .ready
            }
        }
    }

    func approve() {
        guard let id = draftId, phase == .ready else { return }
        phase = .approving
        approvedViaButton = true
        errorText = ""
        Task {
            do {
                let data = try await Self.request("op=draft_action", method: "POST",
                                                  body: ["id": id, "action": "approve"])
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if (obj?["ok"] as? Bool) == true {
                    // Teams: approval returns a deep link that OPENS Teams with
                    // the message already typed (Teams never auto-sends). Open it
                    // now and keep it for the "Open in Teams" button, so the
                    // message actually reaches Teams instead of dead-ending.
                    if let s = (obj?["link"] as? String), let u = URL(string: s) {
                        teamsLink = u
                        UIApplication.shared.open(u)
                    }
                    phase = .saved
                } else {
                    errorText = (obj?["error"] as? String) ?? "Couldn't save to Outlook — the draft is still here."
                    phase = .ready
                }
            } catch {
                errorText = "Couldn't reach Scarlet — the draft is still here."
                phase = .ready
            }
        }
    }

    /// Server-side dismiss (same as the web's ✕), fire-and-forget — the sheet
    /// closes immediately either way.
    func discard() {
        stopPolling()
        guard let id = draftId else {
            // A compose is still in flight (no draft_id yet). Remember the
            // dismiss so compose() cleans up the draft the moment it lands —
            // otherwise it's created server-side with nothing to close it.
            if phase == .writing { dismissRequested = true }
            return
        }
        Task {
            _ = try? await Self.request("op=draft_action", method: "POST",
                                        body: ["id": id, "action": "dismiss"])
        }
    }

    /// Called when the sheet CLOSES (incl. swipe-down, which bypasses the ✕ and
    /// Discard buttons). A draft Ido opened himself (Reply / new mail / channel)
    /// that was never approved must be dismissed server-side — otherwise it
    /// stays the "active" draft and a later spoken "send it" would send the
    /// window he swiped away. Voice-attached drafts belong to the live session,
    /// so their lifecycle is left to the conversation.
    func discardIfAbandoned() {
        guard !adoptActive, phase != .saved else { return }
        discard()
    }

    // MARK: compose + polling

    private func compose(_ body: [String: Any]) {
        pendingCompose = body
        errorText = ""
        phase = .writing
        startPolling()
        Task {
            do {
                let data = try await Self.request("op=draft_compose", method: "POST", body: body)
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let id = obj?["draft_id"] as? String else { throw URLError(.badServerResponse) }
                draftId = id
                // The sheet was closed while this compose was in flight — dismiss
                // the just-created draft so it doesn't linger as active.
                if dismissRequested { dismissRequested = false; discard(); return }
                if let d = try? await Self.fetchActive(), d.id == id {
                    draft = d
                    phase = .ready
                }
                // If that fetch missed, the poll flips to .ready on its next tick.
            } catch {
                errorText = "Scarlet couldn't start this draft."
                phase = .idle
            }
        }
    }

    /// Light 1.5s heartbeat while the sheet is open: keeps the sheet current
    /// if Ido also revises by voice, and backstops a missed fetch.
    func startPolling() {
        stopPolling()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollTick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func pollTick() async {
        guard phase == .writing || phase == .ready else { return }
        if adoptActive {
            // Adopt whatever the server calls active — the voice flow may
            // replace the draft entirely. Active-nil (approved or dismissed
            // by voice) keeps the last draft on screen rather than blanking.
            guard let d = try? await Self.fetchActive() else { return }
            adopt(d)
            return
        }
        guard let want = draftId else { return }
        guard let d = try? await Self.fetchActive() else { return }
        if d.id == want {
            draft = d
            if phase == .writing && d.status == "draft" { phase = .ready }
            // Voice approval (her approve_draft tool) — mirror it here so the
            // button, the green check, and her voice stay one single story.
            if d.status == "approved" && phase == .ready { phase = .saved }
        } else if d.status == "draft" {
            // The active draft IS the window's truth. If voice work replaced
            // it under a different id (Scarlet revised or re-composed), follow
            // it instead of showing a stale copy forever.
            draftId = d.id
            draft = d
            if phase == .writing { phase = .ready }
        }
    }

    // MARK: plumbing (same shape as InboxModel: apiBase + x-scarlet-token)

    private static func fetchActive() async throws -> ActiveDraft? {
        let data = try await request("op=draft_active", method: "GET")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let d = obj?["draft"] as? [String: Any],
              let id = d["id"] as? String else { return nil }
        return ActiveDraft(
            id: id,
            channel: (d["channel"] as? String) ?? "",
            recipient: (d["recipient"] as? String) ?? "",
            subject: (d["subject"] as? String) ?? "",
            body: (d["body"] as? String) ?? "",
            revision: (d["revision"] as? Int) ?? 0,
            status: (d["status"] as? String) ?? "",
            outcome: (d["outcome"] as? String) ?? "",
            link: (d["link"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

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

struct DraftView: View {
    /// nil → new-mail mode (recipient + instruction form first).
    let seed: DraftSeed?
    var instruction: String = "Reply helpfully in Ido's voice."
    /// Voice-attach mode: skip composing and adopt the active server draft
    /// (Scarlet's compose_draft tool already started it).
    var attachToActive: Bool = false
    /// Channel-draft mode: opened from a chat thread (WhatsApp/iMessage/
    /// Teams). With a pre-typed instruction Scarlet composes immediately;
    /// without one the sheet asks first (recipient is fixed — the chat).
    var channelSeed: ChannelDraftSeed? = nil

    @StateObject private var model = DraftModel()
    @Environment(\.dismiss) private var dismiss
    /// The live conversation: the open draft window rides into her ambient
    /// focus (with its draft_id) so spoken change requests land on THIS draft.
    @EnvironmentObject private var convo: Conversation
    @State private var focusBeforeDraft: String?

    /// The unified input row's text: pre-draft it's the INSTRUCTION, with a
    /// draft on screen it's the revision ask.
    @State private var revisionText = ""
    @State private var newTo = ""
    @FocusState private var revisionFocused: Bool

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)
    private let scarletRed = Color(red: 0.75, green: 0.15, blue: 0.23)
    private let savedGreen = Color(red: 0.16, green: 0.55, blue: 0.32)
    private let outlookBlue = Color(red: 0.29, green: 0.62, blue: 1.0)
    private let paper = Color(red: 0.96, green: 0.94, blue: 0.94)

    var body: some View {
        VStack(spacing: 14) {
            header
            content
                // Keyboard avoidance squeezes the sheet's content; keep the
                // draft card from collapsing into the header/footer.
                .frame(minHeight: 120)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ScarletBackground().ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // Tell the shell a draft sheet is up (the presence capsule hides).
            NotificationCenter.default.post(name: .scarletDraftSheetVisible,
                                            object: nil,
                                            userInfo: ["visible": true])
            if attachToActive {
                model.attachToActive()
            } else if let channelSeed {
                let instr = channelSeed.instruction
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !instr.isEmpty {
                    model.startChannelDraft(seed: channelSeed, instruction: instr)
                }
                // Empty ask → the unified input row collects it.
            } else if let seed {
                model.startReply(seed: seed, instruction: instruction)
            }
            // Pre-draft focus: onChange won't fire for the initial value, so
            // announce the open window here (channel / new-mail modes emit a
            // line even before any draft exists).
            if let line = draftFocusLine {
                if focusBeforeDraft == nil { focusBeforeDraft = convo.currentFocus }
                convo.setFocus(line)
            }
        }
        .onDisappear {
            NotificationCenter.default.post(name: .scarletDraftSheetVisible,
                                            object: nil,
                                            userInfo: ["visible": false])
            // Swipe-down must behave like the ✕/Discard buttons for a draft he
            // opened himself and never approved — never leave it silently
            // sendable by voice.
            model.discardIfAbandoned()
            model.stopPolling()
            // Give her ears back whatever was focused before the window
            // opened — unless another screen already claimed focus.
            if let previous = focusBeforeDraft,
               convo.currentFocus?.hasPrefix("[FOCUS] A draft window is OPEN") == true {
                convo.setFocus(previous)
            }
        }
        .onChange(of: model.phase) { _, newPhase in
            if newPhase == .saved {
                // Button and voice must tell one story: when IDO pressed the
                // button, say so in her ear — otherwise she keeps offering to
                // send a draft that's already gone.
                if model.approvedViaButton {
                    let ch = model.draft?.channel ?? ""
                    let outcome: String
                    switch ch {
                    case "email_outlook":
                        outcome = "saved to his Outlook Drafts (corporate mail is never auto-sent)"
                    case "teams":
                        outcome = "opened in Teams with the message ready — he just taps Send there"
                    case "apple_note":
                        outcome = "saved to his Apple Notes"
                    case "reminder":
                        outcome = "added to his Reminders"
                    default:
                        outcome = "sent"
                    }
                    convo.sendSystemNudge(
                        "[SYSTEM] Ido just pressed the Approve button in the draft window HIMSELF. "
                        + "The \(ch) draft to \(model.draft?.recipient ?? "the recipient") was \(outcome). "
                        + "The window is closing by itself. Acknowledge in a couple of words at most "
                        + "— and do NOT ask whether to send it; it is already done.")
                }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    dismiss()
                }
            }
        }
        // The draft on screen (and each revision of it) is what "the draft"
        // means in conversation — stream it to her as ambient focus.
        .onChange(of: draftFocusLine) { _, newLine in
            guard let newLine else { return }
            if focusBeforeDraft == nil { focusBeforeDraft = convo.currentFocus }
            convo.setFocus(newLine)
        }
    }

    /// One line per (draft id, revision) — plus a pre-draft line in channel /
    /// new-mail mode so the open window announces itself before any draft
    /// exists. Built deterministically (it feeds onChange): the seed fields
    /// are constant for the sheet's lifetime, so the line only changes when
    /// the draft itself does.
    private var draftFocusLine: String? {
        guard let d = model.draft else { return preDraftFocusLine }
        var line = "[FOCUS] A draft window is OPEN on Ido's screen.\n"
            + "channel: \(d.channel)\n"
            + "draft_id: \(d.id)\n"
            + "recipient: \(d.recipient)\n"
            + "revision: v\(d.revision)\n"
            + "Any spoken change request refers to THIS draft — call revise_draft."
        // Conversation grounding: the thread this draft answers rides along so
        // spoken revisions can reference what was actually said.
        if let cs = channelSeed, !cs.contextLines.isEmpty {
            line += "\nconversation with \(cs.recipient):\n\(cs.contextLines)"
        }
        // Email grounding: what's being replied to, in one breath.
        if let seed {
            line += "\nreplying to: \(seed.fromName) — \(seed.subject)\npreview: \(seed.preview.prefix(200))"
        }
        return line
    }

    /// No draft yet: the open window itself is the focus — only in channel /
    /// new-mail mode (email replies auto-compose on appear). Deterministic
    /// for the sheet's lifetime, so it emits exactly once.
    private var preDraftFocusLine: String? {
        guard channelSeed != nil || (seed == nil && !attachToActive) else { return nil }
        var line = "[FOCUS] A draft window is OPEN on Ido's screen.\n"
            + "channel: \(channel)\n"
            + "recipient: \(channelSeed?.recipient ?? "not chosen yet")\n"
            + "NO draft started yet — his next words are the INSTRUCTION; "
            + "call compose_draft for this channel and recipient."
        if let cs = channelSeed, !cs.contextLines.isEmpty {
            line += "\nconversation with \(cs.recipient):\n\(cs.contextLines)"
        }
        return line
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Draft")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
                Text(badgeText)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(badgeColor.opacity(0.16), in: Capsule())
                    .overlay(Capsule().stroke(badgeColor.opacity(0.4), lineWidth: 1))
                Spacer()
                Button {
                    model.discard()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: Circle())
                }
            }
            if !recipientText.isEmpty {
                Text("To: \(recipientText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Reply mode: surface the Reply-All audience up front, like
            // Outlook. Informational only — approval builds the true
            // Reply-All server-side.
            if let seed, !seed.toLine.isEmpty {
                Text(replyAllText(seed))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }
            statusLine
                .frame(minHeight: 18)
        }
    }

    private func replyAllText(_ seed: DraftSeed) -> String {
        var s = "Reply-All: " + seed.toLine
        if !seed.ccLine.isEmpty { s += " · Cc: " + seed.ccLine }
        return s
    }

    private var recipientText: String {
        if let r = model.draft?.recipient, !r.isEmpty { return r }
        if let seed { return seed.recipientLine }
        if let cs = channelSeed { return cs.recipient }
        return ""
    }

    // MARK: channel branding
    // Voice drafts arrive for any channel (teams/whatsapp/imessage too, via
    // attach mode) — the badge and approve wording follow the draft itself.

    private var channel: String {
        model.draft?.channel ?? channelSeed?.channel ?? "email_outlook"
    }

    private var badgeText: String {
        switch channel {
        case "email_gmail": return "GMAIL"
        case "teams": return "TEAMS"
        case "whatsapp": return "WHATSAPP"
        case "imessage": return "IMESSAGE"
        case "apple_note": return "NOTE"
        case "reminder": return "REMINDER"
        default: return "AMWELL EMAIL"
        }
    }

    private var badgeColor: Color {
        switch channel {
        case "email_gmail": return Color(red: 0.92, green: 0.36, blue: 0.31)
        case "teams": return Color(red: 0.55, green: 0.56, blue: 0.85)
        case "whatsapp": return Color(red: 0.14, green: 0.80, blue: 0.44)
        case "imessage": return Color(red: 0.25, green: 0.60, blue: 1.0)
        // Apple Notes yellow #FFD60A.
        case "apple_note": return Color(red: 1, green: 214 / 255, blue: 10 / 255)
        // iOS Reminders blue #0A84FF.
        case "reminder": return Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
        default: return outlookBlue
        }
    }

    /// What Approve actually does per channel — Outlook stays drafts-only,
    /// Teams stays staged; Gmail/WhatsApp/iMessage truly send (rules live
    /// server-side; these labels just tell the truth).
    private var approveLabel: String {
        switch channel {
        case "teams": return "Approve → Stage in Teams"
        case "whatsapp": return "Approve → Send WhatsApp"
        case "imessage": return "Approve → Send iMessage"
        case "email_gmail": return "Approve → Send Gmail"
        case "apple_note": return "Approve → Save to Notes"
        case "reminder": return "Approve → Add Reminder"
        default: return "Approve → Outlook Drafts"
        }
    }

    private var savedLabel: String {
        switch channel {
        case "teams": return "Staged in Teams ✓"
        case "whatsapp": return "Sent on WhatsApp ✓"
        case "imessage": return "Sent by iMessage ✓"
        case "email_gmail": return "Sent from Gmail ✓"
        case "apple_note": return "Saved to Apple Notes ✓"
        case "reminder": return "Added to Reminders ✓"
        default: return "Saved in Outlook Drafts ✓"
        }
    }

    private var approvingLabel: String {
        switch channel {
        case "email_outlook": return "Saving to Outlook…"
        case "teams": return "Staging in Teams…"
        case "apple_note": return "Saving to Notes…"
        case "reminder": return "Adding Reminder…"
        default: return "Sending…"
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .writing:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).tint(scarletRose)
                Text("Scarlet is writing…").font(.footnote).foregroundStyle(scarletRose.opacity(0.95))
            }
        case .revising:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).tint(scarletRose)
                Text("Revising…").font(.footnote).foregroundStyle(scarletRose.opacity(0.95))
            }
        case .approving:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).tint(scarletRose)
                Text(approvingLabel).font(.footnote).foregroundStyle(scarletRose.opacity(0.95))
            }
        case .ready:
            Text("Ready for your review").font(.footnote).foregroundStyle(.secondary)
        case .saved:
            Text(savedLabel).font(.footnote)
                .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.62))
        case .idle:
            if channelSeed != nil && model.draft == nil {
                Text("Tell Scarlet what to say").font(.footnote).foregroundStyle(.secondary)
            } else if seed == nil && !attachToActive && model.draft == nil {
                Text("A fresh email from your Amwell address").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if let draft = model.draft {
            draftCard(draft)
        } else if model.phase == .writing {
            writingCard
        } else if !model.errorText.isEmpty {
            errorRetry
        } else if channelSeed != nil {
            // Channel-draft mode with no pre-typed ask: the unified input row
            // below collects it — this is just the hint.
            channelHint
        } else if seed == nil && !attachToActive && channelSeed == nil {
            newMailForm
        } else {
            Spacer()
        }
    }

    /// True when the text is dominated by Hebrew — the draft then lays out
    /// right-to-left exactly as it will read in Outlook/WhatsApp.
    private func isHebrew(_ s: String) -> Bool {
        var heb = 0, lat = 0
        for u in s.unicodeScalars.prefix(400) {
            if (0x0590...0x05FF).contains(u.value) { heb += 1 }
            else if (0x41...0x7A).contains(u.value) { lat += 1 }
        }
        return heb > lat
    }

    /// The draft itself: an elegant dark card, readable serif-feel body,
    /// scrollable and selectable. Hebrew drafts read right-to-left.
    private func draftCard(_ draft: DraftModel.ActiveDraft) -> some View {
        let rtl = isHebrew(draft.body)
        return ScrollView {
            VStack(alignment: rtl ? .trailing : .leading, spacing: 12) {
                if !draft.subject.isEmpty {
                    Text(draft.subject)
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
                        .multilineTextAlignment(rtl ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                }
                Text(draft.body)
                    .font(.system(size: 17))
                    .lineSpacing(4)
                    .foregroundStyle(paper)
                    .textSelection(.enabled)
                    .multilineTextAlignment(rtl ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            }
            .padding(18)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.10), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            // Only show a revision badge once he's actually revised — "v0" on a
            // first draft is meaningless noise.
            if draft.revision > 0 {
                Text("v\(draft.revision)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(10)
            }
        }
        .opacity(model.phase == .revising ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    /// Placeholder while the first draft composes.
    private var writingCard: some View {
        VStack(spacing: 12) {
            ProgressView().tint(scarletRose)
            Text("Composing in your voice…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private var errorRetry: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(model.errorText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { model.retry() }
                .buttonStyle(.bordered)
                .tint(scarletRose)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// New-mail mode: just the To field (with autocomplete) — the instruction
    /// arrives through the unified input row below.
    private var newMailForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("To — a name or an email address…", text: $newTo)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(12)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .onChange(of: newTo) { _, newValue in
                    model.searchContacts(newValue)
                }
            if !suggestionRows.isEmpty {
                suggestionList
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    /// Channel-draft mode, no draft yet: the recipient is fixed (the chat
    /// this sheet was opened from) — a simple hint points at the unified
    /// input row below.
    private var channelHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Tell Scarlet what to say to \(channelSeed?.recipient ?? "them") — speak or type below")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// At most five rows on screen, like Outlook's dropdown.
    private var suggestionRows: [DraftModel.Contact] {
        Array(model.suggestions.prefix(5))
    }

    /// Outlook-style autocomplete dropdown under the To field: name over
    /// address, styled like the form fields it sits between.
    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestionRows) { contact in
                Button {
                    pickSuggestion(contact)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.name.isEmpty ? contact.email : contact.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(contact.email)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                if contact.id != suggestionRows.last?.id {
                    Divider().overlay(.white.opacity(0.10))
                }
            }
        }
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Tap-to-fill: "Name <email>" lands in To, the list closes, and focus
    /// hops to the unified input row — free typing stays just as valid.
    private func pickSuggestion(_ contact: DraftModel.Contact) {
        let line = contact.name.isEmpty
            ? contact.email
            : "\(contact.name) <\(contact.email)>"
        model.suggestionPicked(line)
        newTo = line
        revisionFocused = true
    }

    // MARK: footer (unified voice + text input row, present in ALL modes)

    private var footer: some View {
        VStack(spacing: 12) {
            if model.draft != nil && !model.errorText.isEmpty {
                Text(model.errorText)
                    .font(.footnote)
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            inputRow
            if model.draft != nil {
                approveRow
            }
        }
    }

    /// THE drafting surface's one input row: [mic] [field] [send]. Pre-draft
    /// the field carries the instruction; with a draft on screen it carries
    /// the revision ask. The mic is the voice path to the same place —
    /// Scarlet's focus + persona route speech as instruction or revision.
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            micButton
            TextField(inputPlaceholder, text: $revisionText, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .focused($revisionFocused)
                .disabled(model.phase == .revising || model.phase == .approving || model.phase == .saved)
            Button {
                sendInput()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSendInput ? scarletRose : scarletRose.opacity(0.35))
                    // Same 30pt box as the mic circle, so both flanking
                    // controls bottom-align identically against the field.
                    .frame(width: 30, height: 30)
            }
            .disabled(!canSendInput)
        }
    }

    private var inputPlaceholder: String {
        model.draft == nil
            ? "Speak or type what Scarlet should write…"
            : "Speak or type your changes…"
    }

    private var canSendInput: Bool {
        let text = revisionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if model.draft != nil { return model.phase == .ready }
        // Pre-draft: only channel / new-mail mode can start a compose here
        // (email replies and voice-attach are already in flight on appear).
        guard model.phase == .idle else { return false }
        if channelSeed != nil { return true }
        if seed == nil && !attachToActive {
            return !newTo.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return false
    }

    private func sendInput() {
        guard canSendInput else { return }
        let text = revisionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.draft != nil {
            model.revise(text)
        } else if let cs = channelSeed {
            model.startChannelDraft(seed: cs, instruction: text)
        } else {
            model.startNewMail(recipient: newTo, instruction: text)
        }
        revisionText = ""
        revisionFocused = false
    }

    // MARK: mic (the sheet's ONE voice affordance)

    /// Her ears are hot: mic open and not in text-only chat mode.
    private var micIsHot: Bool {
        convo.micOn && !convo.chatMode
    }

    private var micButton: some View {
        Button {
            micTapped()
        } label: {
            Image(systemName: micIsHot ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(micIsHot ? scarletRose : .white.opacity(0.6))
                .frame(width: 30, height: 30)
                .background(micIsHot ? scarletRose.opacity(0.18) : .white.opacity(0.08),
                            in: Circle())
                .overlay(Circle().stroke(micIsHot ? scarletRose.opacity(0.5) : .white.opacity(0.14),
                                         lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Idle → wake her with the mic hot; live → exit chat mode toward voice,
    /// or plain-toggle the mic. Speech then reaches Scarlet, whose focus +
    /// persona route it as instruction or revision for THIS window.
    private func micTapped() {
        if convo.state == .idle {
            convo.hasAutoStarted = true
            convo.start(token: TokenStore.token ?? "")
            if convo.chatMode { convo.setChatMode(false) }
            if !convo.micOn { convo.toggleMic() }
        } else if convo.chatMode {
            // Leaving chat mode IS the voice ask — end with the mic hot.
            convo.setChatMode(false)
            if !convo.micOn { convo.toggleMic() }
        } else {
            convo.toggleMic()
        }
    }

    private var approveRow: some View {
        VStack(spacing: 8) {
            Button {
                model.approve()
            } label: {
                Group {
                    if model.phase == .saved {
                        Label(savedLabel, systemImage: "checkmark.circle.fill")
                    } else if model.phase == .approving {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text(approvingLabel)
                        }
                    } else {
                        Text(approveLabel)
                    }
                }
                .font(.headline)
                .frame(maxWidth: 340)
                .padding(16)
                .background(model.phase == .saved ? savedGreen : scarletRed,
                            in: RoundedRectangle(cornerRadius: 30))
                .foregroundStyle(.white)
                .opacity(model.phase == .ready || model.phase == .approving || model.phase == .saved ? 1 : 0.55)
            }
            .disabled(model.phase != .ready)
            .animation(.easeInOut(duration: 0.25), value: model.phase)
            // (No footer "Discard" — the always-visible ✕ in the header already
            // discards; two controls for one action was clutter.)
        }
    }
}
