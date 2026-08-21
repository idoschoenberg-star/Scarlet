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
    /// Unified-inbox binding (the All-new list): the `inbound_events` row id.
    /// When set, compose sends `event_id` INSTEAD of `message_id` — the
    /// server resolves the real message from the signal row and grounds the
    /// reply in THAT conversation (the same binding the web Signals reader
    /// and the voice sweep's `compose_draft original_event_id` use).
    var eventId: String = ""
    /// Compose channel — email_outlook by default (the Amwell inbox); the
    /// All-new list passes the item's own channel (email_gmail / whatsapp /
    /// imessage / teams), mirroring the web Signals page's DRAFT_SRC map.
    var channel: String = "email_outlook"

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
        /// The instruction Scarlet heard — shown on the writing card while the
        /// body streams in, so the window echoes his request immediately.
        var instruction: String = ""
        /// When generation began — drives the on-card processing timer.
        var writingStartedAt: Date? = nil
        /// Where this draft came from ('scarlet'|'manual'|'instructed'|'pin').
        /// 'pin' puts the from-your-pin badge + amend loop on the review
        /// surface (spec §4). Empty on an older backend — no badge.
        var origin: String = ""
        /// The conversation this draft answers (server-gathered, oldest→newest)
        /// — shown BELOW the draft so Ido can always re-read what he is
        /// replying to, on every channel (2026-08-12: WhatsApp parity with
        /// the original-email view under an email reply).
        var context: String = ""
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
        case ready      // draft on screen, awaiting Ido (the REVIEW state)
        case revising   // revise in flight
        case approving  // approve in flight
        case saved      // approved — show the green check, then dismiss
        case parked     // saved for later (read-first flow) — check, then dismiss
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
    /// Optimistic request context painted on the writing card BEFORE any server
    /// row exists — so the window echoes his request the instant it opens.
    @Published var pendingRecipient = ""
    @Published var pendingInstruction = ""
    @Published var pendingChannel = ""
    /// Client-side moment the window started writing — drives the on-card timer.
    @Published var writingStartedAt: Date?
    private var pendingCompose: [String: Any]?
    /// One silent second chance: a compose whose request never reached the
    /// server (transient network drop) is re-issued once before any error is
    /// shown. Reset on every fresh compose.
    private var composeRetried = false
    /// Guards against the original request landing AFTER a retry was issued —
    /// only the newest compose's response may adopt a draft.
    private var composeSeq = 0
    /// Set when the sheet closed before compose returned a draft_id — the
    /// in-flight compose reads it and dismisses the draft it just created.
    private var dismissRequested = false
    /// Poll pacing + a watchdog so "Scarlet is writing…" can never spin forever.
    private var tickCount = 0
    private var writingSince: Date?
    private var timer: Timer?
    /// True when a writing/revising body has stopped growing for a long window —
    /// a stalled server stream. Purely a UI hint (the ✕ always closes); it never
    /// changes the phase or interferes with streaming.
    @Published var writingStalled = false
    private var writingProgressAt: Date?
    private var lastBodyLen = -1
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
    /// Set the moment discard() runs, so the closing sheet's save-on-leave
    /// can never resurrect a draft Ido explicitly discarded.
    private var discardedExplicitly = false

    // MARK: intents

    /// Reply mode: compose immediately from the open message, exactly like the
    /// web reader's "↩ Reply" (message_id rides along for threaded Reply-All).
    func startReply(seed: DraftSeed, instruction: String) {
        guard phase == .idle, draftId == nil else { return }
        var body: [String: Any] = [
            "channel": seed.channel,
            "recipient": seed.recipientLine,
            "instruction": instruction,
        ]
        // Binding: a signal-row reply (the All-new list) rides its event_id —
        // the server resolves the real message from `inbound_events`; the
        // Amwell inbox rides the Graph message_id directly. One path, one
        // window — only the id field differs.
        if seed.eventId.isEmpty {
            body["message_id"] = seed.messageId
        } else {
            body["event_id"] = seed.eventId
        }
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

    /// READ-FIRST chooser start (spec §6): ONE `op=draft_mode` call carries
    /// the mode, the destination, and the threading binding; the backend
    /// composes (scarlet/instructed) or just stages the row (manual). Falls
    /// back to the legacy compose lane if the endpoint isn't there yet.
    func startFlow(mode: ReplyMode, instructions: String? = nil,
                   seed: DraftSeed? = nil, channelSeed: ChannelDraftSeed? = nil) {
        guard phase == .idle, draftId == nil else { return }
        var body: [String: Any] = ["mode": mode.rawValue]
        if let seed {
            body["channel"] = seed.channel
            body["recipient"] = seed.recipientLine
            if seed.eventId.isEmpty {
                body["message_id"] = seed.messageId
            } else {
                body["event_id"] = seed.eventId
            }
            let original = seed.originalLine
            if !original.isEmpty { body["original"] = original }
        } else if let cs = channelSeed {
            body["channel"] = cs.channel
            body["recipient"] = cs.recipient
        } else {
            return
        }
        if let instructions, !instructions.isEmpty { body["instructions"] = instructions }
        compose(body)
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
    /// by voice) — find the active draft and follow it. `intent` carries the
    /// tool-call arguments (recipient, instruction, channel) known locally the
    /// instant Scarlet called compose_draft, so the window paints his request
    /// immediately, before the server row exists.
    func attachToActive(intent: [String: String]? = nil) {
        guard draftId == nil else { return }
        adoptActive = true
        phase = .writing
        writingStartedAt = Date()
        if let intent {
            pendingRecipient = intent["recipient"] ?? ""
            pendingInstruction = intent["instruction"] ?? ""
            pendingChannel = intent["channel"] ?? ""
        }
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
        // 'writing' means a (re)compose is in flight server-side — a voice
        // revision flips the live row back to 'writing', so mirror that as the
        // writing phase (spinner + fast poll) instead of leaving a stale
        // "Ready" while the text is actually changing under him.
        if d.status == "writing" {
            if phase == .ready || phase == .revising { phase = .writing }
        } else if d.status == "draft" {
            if phase == .writing || phase == .revising { phase = .ready }
        }
        // Approved by voice while this window is open: show the same green
        // "sent" state the button shows, then the sheet auto-dismisses.
        if d.status == "approved" && (phase == .ready || phase == .writing || phase == .revising) {
            phase = .saved
        }
    }

    /// The review surface just rendered a finished draft — stamp reviewed_at
    /// server-side (spec §6: the send path's read-back gate keys off it).
    /// Fires on every writing→ready transition: a regeneration CLEARS the
    /// stamp server-side, so each new body needs its own; the op itself is
    /// idempotent (`.is null` guarded), so repeats can never overwrite.
    func noteReviewSeen() {
        guard let id = draftId else { return }
        DraftFlowAPI.reviewSeen(draftId: id)
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
        writingStartedAt = Date()
        pendingInstruction = text
        errorText = ""
        Task {
            // Read-first lane FIRST (spec §6 note): draft_mode with a
            // draft_id runs the same revise pipeline AND clears reviewed_at,
            // so a regenerated body must be re-reviewed before it can send.
            var accepted = false
            if let data = try? await Self.request("op=draft_mode", method: "POST",
                                                  body: ["draft_id": id,
                                                         "mode": "instructed",
                                                         "instructions": text]),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               (obj["ok"] as? Bool) == true {
                accepted = true
            }
            if !accepted {
                // Older backend — the legacy revise action (no reviewed_at
                // semantics, but the loop itself is identical).
                do {
                    let data = try await Self.request("op=draft_action", method: "POST",
                                                      body: ["id": id, "action": "revise", "instruction": text])
                    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    guard (obj?["ok"] as? Bool) == true else { throw URLError(.badServerResponse) }
                } catch {
                    errorText = "That revision didn't go through — try again."
                    phase = .ready
                    return
                }
            }
            // The revised body streams server-side — pull the first partial
            // now and let the heartbeat flip to .ready when it completes,
            // so the new text visibly writes instead of snapping in.
            if let d = try? await Self.fetchActive(), d.id == id {
                draft = d
                if d.status == "draft" { phase = .ready }
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
                        UIApplication.shared.open(u, options: [:], completionHandler: nil)
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
    /// closes immediately either way. This is the EXPLICIT-discard path only;
    /// merely leaving the screen goes through closeKeepingWork() instead.
    func discard() {
        stopPolling()
        discardedExplicitly = true
        guard let id = draftId else {
            // A compose is still in flight (no draft_id yet). Remember the
            // dismiss so compose() cleans up the draft the moment it lands —
            // otherwise it's created server-side with nothing to close it.
            if phase == .writing { dismissRequested = true }
            return
        }
        Task {
            // The read-first discard keeps the row (state 'discarded',
            // restorable); an older backend falls back to the legacy dismiss.
            let ok = await DraftFlowAPI.action(draftId: id, action: "discard")
            if !ok {
                _ = try? await Self.request("op=draft_action", method: "POST",
                                            body: ["id": id, "action": "dismiss"])
            }
        }
    }

    /// "Save draft" (read-first flow): park the draft for later. The window
    /// shows the parked check and auto-dismisses; the draft waits in
    /// "Waiting on you" until he picks it back up.
    func saveForLater() {
        guard let id = draftId, phase == .ready else { return }
        phase = .parked
        stopPolling()
        Task {
            // Older backend without save_for_later: the row simply stays as
            // it is — the 15-minute stale-guard keeps it from hijacking a
            // later launch, and nothing can send it without review.
            _ = await DraftFlowAPI.action(draftId: id, action: "save_for_later")
        }
    }

    /// Called when the sheet CLOSES (incl. swipe-down, which bypasses every
    /// button). HARD RULE (spec §1, never-events): leaving a screen with a
    /// non-empty draft SAVES it — never discards. save_for_later also takes
    /// the row out of the voice-sendable "active" slot, so a swiped-away
    /// window can't be sent by a later spoken "send it". Voice-attached
    /// drafts belong to the live session; their lifecycle stays with the
    /// conversation.
    func closeKeepingWork() {
        guard !adoptActive, phase != .saved, phase != .parked,
              !discardedExplicitly else { return }
        stopPolling()
        guard let id = draftId else {
            // Compose still in flight — save it the moment the id lands.
            if phase == .writing { dismissRequested = true }
            return
        }
        // A compose that failed outright (phase .idle, no draft row) left
        // nothing worth keeping — clean up the empty shell.
        if draft == nil && phase == .idle {
            Task {
                _ = try? await Self.request("op=draft_action", method: "POST",
                                            body: ["id": id, "action": "dismiss"])
            }
            return
        }
        Task { _ = await DraftFlowAPI.action(draftId: id, action: "save_for_later") }
    }

    // MARK: compose + polling

    /// A read-first body (has "mode") posts to `op=draft_mode`; everything
    /// else stays on the legacy `op=draft_compose`. Same response key
    /// (`draft_id`), same polling afterwards.
    private func compose(_ body: [String: Any], isRetry: Bool = false) {
        pendingCompose = body
        if !isRetry { composeRetried = false }
        composeSeq += 1
        let seq = composeSeq
        errorText = ""
        phase = .writing
        writingStartedAt = Date()
        pendingRecipient = (body["recipient"] as? String) ?? ""
        pendingInstruction = (body["instruction"] as? String)
            ?? (body["instructions"] as? String) ?? ""
        pendingChannel = (body["channel"] as? String) ?? ""
        startPolling()
        let op = body["mode"] != nil ? "op=draft_mode" : "op=draft_compose"
        Task {
            do {
                let data = try await Self.request(op, method: "POST", body: body)
                // A retry superseded this request while it was in flight — only
                // the newest compose may adopt a draft; the poll follows the
                // server's active row either way.
                guard seq == composeSeq else { return }
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let id = obj?["draft_id"] as? String else { throw URLError(.badServerResponse) }
                draftId = id
                // The sheet was closed while this compose was in flight — SAVE
                // the just-created draft (never-events: no lost draft; his
                // intent was captured, it waits in "Waiting on you").
                if dismissRequested {
                    dismissRequested = false
                    stopPolling()
                    Task { _ = await DraftFlowAPI.action(draftId: id, action: "save_for_later") }
                    return
                }
                // The row exists in the 'writing' state within ~1s (body streams
                // in after). Adopt it so the card shows his request + timer now;
                // only flip to .ready once the body is actually done.
                if let d = try? await Self.fetchActive(), d.id == id {
                    draft = d
                    if d.status == "draft" { phase = .ready }
                }
                // The poll flips to .ready when the streamed body completes.
            } catch {
                guard seq == composeSeq else { return }
                // A transient network drop (LTE handoff, tunnel) can swallow
                // the request before it reaches the server. Give it one silent
                // second chance before bothering him with an error.
                if !composeRetried, draftId == nil, !dismissRequested {
                    composeRetried = true
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if draftId == nil, !dismissRequested { compose(body, isRetry: true) }
                    return
                }
                // A draft_mode body that failed twice may have hit a backend
                // that predates the read-first ops — translate once to the
                // legacy compose shape (which cannot loop back here).
                if body["mode"] != nil, draftId == nil, !dismissRequested {
                    compose(Self.legacyComposeBody(body))
                    return
                }
                errorText = "Scarlet couldn't start this draft."
                phase = .idle
            }
        }
    }

    /// draft_mode body → draft_compose body: same destination and threading
    /// fields; the mode collapses into the instruction it implies.
    private static func legacyComposeBody(_ flow: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in ["channel", "recipient", "original", "event_id", "message_id",
                    "chat_id", "subject"] {
            if let v = flow[key] { out[key] = v }
        }
        out["instruction"] = (flow["instructions"] as? String)
            ?? ((flow["mode"] as? String) == "scarlet"
                ? ReplyMode.scarletInstruction
                : "Draft the appropriate reply.")
        return out
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
        guard phase == .writing || phase == .ready || phase == .revising else {
            writingSince = nil; writingProgressAt = nil; lastBodyLen = -1
            if writingStalled { writingStalled = false }
            return
        }
        tickCount += 1
        // Stall hint: while writing/revising, watch the body grow. If it stops
        // growing for ~40s the stream is stuck — surface a gentle note so Ido
        // knows to close and retry rather than staring at a spinner. Additive
        // only: never touches `phase`.
        if (phase == .writing || phase == .revising), let body = draft?.body {
            if body.count != lastBodyLen {
                lastBodyLen = body.count
                writingProgressAt = Date()
                if writingStalled { writingStalled = false }
            } else if writingProgressAt == nil {
                writingProgressAt = Date()
            } else if Date().timeIntervalSince(writingProgressAt!) > 40 {
                if !writingStalled { writingStalled = true }
            }
        } else {
            writingProgressAt = nil; lastBodyLen = -1
            if writingStalled { writingStalled = false }
        }
        // Once a draft is on screen and Ido is reviewing (.ready), the only
        // thing polling catches is a VOICE revision — back the 1.5s heartbeat
        // off to ~6s to stop hammering draft_active ~80x while he reads.
        if phase == .ready {
            writingSince = nil
            if tickCount % 4 != 0 { return }
        } else {
            // Writing watchdog: only fires while NOTHING has landed yet (no row
            // adopted). Once a 'writing' row is on screen the body is visibly
            // streaming in, so a longer draft must never trip this. A compose
            // that never even creates a row is the real failure.
            if draft != nil {
                writingSince = nil
            } else if writingSince == nil {
                writingSince = Date()
            } else if Date().timeIntervalSince(writingSince!) > 20 {
                writingSince = nil
                // The request likely never reached the server (transient
                // network drop). If this window started the compose itself,
                // re-issue it once silently — no row ever landed, so a retry
                // cannot duplicate a draft. Only then surface the error.
                if let body = pendingCompose, !composeRetried, draftId == nil {
                    composeRetried = true
                    compose(body, isRetry: true)
                    return
                }
                errorText = "Scarlet didn't get this draft started — close and try again."
                phase = .idle
                return
            }
        }
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
            // Streamed body finished → review; a revision put it back to
            // 'writing' → show the writing indicator again.
            if (phase == .writing || phase == .revising) && d.status == "draft" { phase = .ready }
            if phase == .ready && d.status == "writing" { phase = .writing }
            // Voice approval (her approve_draft tool) — mirror it here so the
            // button, the green check, and her voice stay one single story.
            if d.status == "approved" && phase == .ready { phase = .saved }
        } else if d.status == "draft" || d.status == "writing" {
            // The active draft IS the window's truth. If voice work replaced
            // it under a different id (Scarlet revised or re-composed), follow
            // it instead of showing a stale copy forever.
            draftId = d.id
            draft = d
            if d.status == "draft", phase == .writing || phase == .revising { phase = .ready }
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
            link: (d["link"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            instruction: (d["instruction"] as? String) ?? "",
            // writingStartedAt is left client-side (the moment the window
            // opened) — more reliable than reparsing the server timestamp, and
            // it's only used to drive the on-card timer.
            origin: (d["origin"] as? String) ?? "",
            context: (d["context"] as? String) ?? ""
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
    /// The compose_draft tool arguments known locally the instant Scarlet made
    /// the call (recipient, instruction, channel) — used to paint the writing
    /// card immediately, before the server row lands.
    var voiceIntent: [String: String]? = nil
    /// Channel-draft mode: opened from a chat thread (WhatsApp/iMessage/
    /// Teams). With a pre-typed instruction Scarlet composes immediately;
    /// without one the sheet asks first (recipient is fixed — the chat).
    var channelSeed: ChannelDraftSeed? = nil
    /// READ-FIRST FLOW: which chooser option opened this window. nil keeps
    /// the legacy behaviors (voice attach, channel pill, new mail).
    /// .scarlet → compose immediately with the no-comments instruction;
    /// .instructed → the input row (mic/keyboard) collects the instruction
    /// first; .manual → Ido types the reply himself in the manual editor.
    var replyMode: ReplyMode? = nil

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
    /// Manual mode ("I'll write it myself" / "Edit myself"): the editor's
    /// text and whether the editor is the showing surface.
    @State private var manualText = ""
    @State private var editingManually = false
    @FocusState private var manualFocused: Bool
    /// Discard-with-undo (spec §2: frequent actions get undo, not dialogs):
    /// while armed, a 5s countdown bar replaces the actions; Undo cancels,
    /// expiry (or closing the sheet) executes the discard for real.
    @State private var discardArmed = false
    @State private var discardTask: Task<Void, Never>?
    /// Pin drafts (§4): whether the original pin transcript card is open.
    @State private var showPinTranscript = false

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
                model.attachToActive(intent: voiceIntent)
            } else if let channelSeed {
                let instr = channelSeed.instruction
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !instr.isEmpty {
                    if replyMode == .instructed {
                        // 🎙 with the ask already typed — one draft_mode call.
                        model.startFlow(mode: .instructed, instructions: instr,
                                        channelSeed: channelSeed)
                    } else {
                        // Legacy compose lane (Desk notes, photo forwards).
                        model.startChannelDraft(seed: channelSeed, instruction: instr)
                    }
                } else if replyMode == .scarlet {
                    // ✨ Scarlet drafts it — no comments from him.
                    model.startFlow(mode: .scarlet, channelSeed: channelSeed)
                } else if replyMode == .manual {
                    // ⌨️ He writes it himself — the manual editor opens.
                    editingManually = true
                    manualFocused = true
                } else {
                    // 🎙 (or the legacy pill): the input row collects the ask.
                    revisionFocused = true
                }
            } else if let seed {
                switch replyMode {
                case .manual:
                    editingManually = true
                    manualFocused = true
                case .instructed:
                    // Mic/keyboard opens immediately; nothing composes until
                    // he says or types what the reply should say.
                    revisionFocused = true
                case .scarlet:
                    model.startFlow(mode: .scarlet, seed: seed)
                case nil:
                    // Legacy path (kept for voice/compat callers).
                    model.startReply(seed: seed, instruction: instruction)
                }
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
            // Leaving with a non-empty draft SAVES it (never-events: no lost
            // draft) — unless a discard was explicitly armed and still
            // pending, in which case the discard he asked for executes.
            discardTask?.cancel()
            if discardArmed {
                model.discard()
            } else {
                model.closeKeepingWork()
            }
            model.stopPolling()
            // Give her ears back whatever was focused before the window
            // opened — unless another screen already claimed focus.
            if let previous = focusBeforeDraft,
               convo.currentFocus?.hasPrefix("[FOCUS] A draft window is OPEN") == true {
                convo.setFocus(previous)
            }
        }
        .onChange(of: model.phase) { _, newPhase in
            // The finished draft is on screen — this render IS the review;
            // stamp reviewed_at (once) so the send gate knows he saw it.
            if newPhase == .ready { model.noteReviewSeen() }
            if newPhase == .parked {
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    dismiss()
                }
            }
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
        // Manual mode: he is typing his own words — his speech is NOT an
        // instruction, so no pre-draft line claims it.
        guard replyMode != .manual else { return nil }
        guard channelSeed != nil || (seed == nil && !attachToActive)
            || (seed != nil && replyMode == .instructed) else { return nil }
        let recipient = channelSeed?.recipient
            ?? (seed != nil ? recipientText : "not chosen yet")
        var line = "[FOCUS] A draft window is OPEN on Ido's screen.\n"
            + "channel: \(channel)\n"
            + "recipient: \(recipient)\n"
            + "NO draft started yet — his next words are the INSTRUCTION; "
            + "call compose_draft for this channel and recipient."
        if let cs = channelSeed, !cs.contextLines.isEmpty {
            line += "\nconversation with \(cs.recipient):\n\(cs.contextLines)"
        }
        return line
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Draft")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
                notSentPill
                Spacer()
                // ✕ = close, keeping the work: leaving a screen with a
                // non-empty draft saves it (onDisappear). Discard is its own
                // explicit action below, with undo.
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .keyboardShortcut(.cancelAction)
            }
            // The destination, pinned at the top of the review surface:
            // "To ארז, on WhatsApp" — recipient and channel in one breath,
            // in the channel's own color (wrong-thread/channel never-event).
            if !recipientText.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: channelGlyph(channel))
                        .font(.system(size: 12, weight: .semibold))
                    Text("To \(shortRecipient), on \(draftChannelDisplayName(channel))")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(badgeColor.opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(badgeColor.opacity(0.4), lineWidth: 1))
            }
            // Pin drafts (§4): the from-your-pin badge — tap to see (and
            // amend) the original pin instruction.
            if isPinDraft {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showPinTranscript.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("🎙 From your pin")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showPinTranscript ? 180 : 0))
                    }
                    .foregroundStyle(scarletRose)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(scarletRose.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(scarletRose.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
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

    /// The chip's compact recipient: the display name alone when the full
    /// line is "Name <address>" — the Reply-All line keeps the addresses.
    private var shortRecipient: String {
        let full = recipientText
        if let open = full.firstIndex(of: "<") {
            let name = String(full[..<open]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return full
    }

    /// "Draft — not sent", visible the whole time nothing has been sent —
    /// the review surface must never be mistakable for a sent message.
    @ViewBuilder
    private var notSentPill: some View {
        if model.phase != .saved && model.phase != .parked {
            Text("DRAFT — NOT SENT")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
        }
    }

    /// §4: this draft came from a voice pin.
    private var isPinDraft: Bool { model.draft?.origin == "pin" }

    /// The tappable pin-transcript card: the original instruction Scarlet
    /// heard, plus AMEND — correct the instruction (type or dictate) and she
    /// re-generates (Ido's Zafat ask, 2026-08-21).
    @ViewBuilder
    private var pinTranscriptCard: some View {
        if isPinDraft, showPinTranscript, let d = model.draft {
            VStack(alignment: .leading, spacing: 8) {
                Text("WHAT YOU SAID")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.4))
                paragraphLine(d.instruction.isEmpty ? "—" : d.instruction,
                              size: 14, weight: .regular,
                              color: .white.opacity(0.85))
                Button {
                    // Amend: the original instruction lands in the input row,
                    // ready to correct by keyboard or mic; sending it
                    // re-generates the draft against the fixed instruction.
                    revisionText = d.instruction
                    revisionFocused = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Amend — fix what she heard")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(scarletRose)
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .ready)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scarletRose.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(scarletRose.opacity(0.25), lineWidth: 1))
        }
    }

    // MARK: channel branding
    // Voice drafts arrive for any channel (teams/whatsapp/imessage too, via
    // attach mode) — the badge and approve wording follow the draft itself.

    private var channel: String {
        // Seed replies carry their own channel too (the All-new list replies
        // to Gmail/chat items through this same window) — the badge must
        // match from the first frame, not only once the draft row lands.
        model.draft?.channel ?? channelSeed?.channel ?? seed?.channel ?? "email_outlook"
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
                Text(model.writingStalled
                     ? "Taking longer than usual — you can close (✕) and try again."
                     : "Scarlet is writing…")
                    .font(.footnote).foregroundStyle(scarletRose.opacity(0.95))
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
        case .parked:
            Text("Saved for later ✓ — waiting in your list").font(.footnote)
                .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.62))
        case .idle:
            if editingManually && model.draft == nil {
                Text("Write it your way — you'll still review before anything sends")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if (channelSeed != nil || (seed != nil && replyMode == .instructed))
                        && model.draft == nil {
                Text("Tell Scarlet what to say").font(.footnote).foregroundStyle(.secondary)
            } else if seed == nil && !attachToActive && model.draft == nil {
                Text("A fresh email from your Amwell address").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        // Manual mode ("I'll write it myself" / "Edit myself"): the editor
        // replaces every other card until he hands the text back to review.
        if editingManually {
            manualCard
        // While writing with no body yet → the enriched writing card (his
        // request + timer). The moment streamed text exists, the draft card
        // takes over and fills in live.
        } else if model.phase == .writing, (model.draft?.body ?? "").isEmpty {
            writingCard
        } else if let draft = model.draft {
            draftCard(draft)
            pinTranscriptCard
            replyContextSection
        } else if model.phase == .writing {
            writingCard
        } else if !model.errorText.isEmpty {
            errorRetry
        } else if channelSeed != nil || (seed != nil && replyMode == .instructed) {
            // 🎙 mode (chat pill or email reply) with no ask yet: the unified
            // input row below collects it — this is just the hint.
            channelHint
        } else if seed == nil && !attachToActive && channelSeed == nil {
            newMailForm
        } else {
            Spacer()
        }
    }

    /// The manual editor: Ido's own words, ≥17pt, direction following the
    /// dominant script (a TextEditor is one surface — the review render
    /// applies true per-paragraph bidi). "Review draft" hands the exact text
    /// to the review screen; nothing sends from here.
    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $manualText)
                .font(.system(size: 17))
                .scrollContentBackground(.hidden)
                .foregroundStyle(paper)
                .focused($manualFocused)
                .multilineTextAlignment(manualText.readingAlignment)
                .environment(\.layoutDirection, manualText.layoutDir)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(0.10), lineWidth: 1))
            HStack(spacing: 10) {
                // Editing an existing draft can be abandoned back to review;
                // a from-scratch manual reply has nothing to fall back to.
                if model.draft != nil {
                    Button {
                        editingManually = false
                        manualFocused = false
                    } label: {
                        Text("Back to review")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button {
                    submitManualText()
                } label: {
                    Text(model.draft == nil ? "Review draft" : "Use my edit")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(canSubmitManual ? scarletRed : scarletRed.opacity(0.4),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitManual)
            }
        }
    }

    private var canSubmitManual: Bool {
        let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if model.draft != nil { return model.phase == .ready }
        return model.phase == .idle
    }

    /// Hand Ido's exact words to the draft row. First write → verbatim
    /// compose; edit of an existing draft → verbatim revise. Either way the
    /// result comes BACK to the review screen — send stays a separate,
    /// explicit decision.
    private func submitManualText() {
        guard canSubmitManual else { return }
        let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        let verbatim = ReplyMode.verbatimInstruction(text)
        editingManually = false
        manualFocused = false
        if model.draft != nil {
            model.revise(verbatim)
        } else if let cs = channelSeed {
            model.startFlow(mode: .instructed, instructions: verbatim, channelSeed: cs)
        } else if let seed {
            model.startFlow(mode: .instructed, instructions: verbatim, seed: seed)
        }
        // The writing card echoes the request — show HIS words, not the
        // verbatim wrapper around them.
        model.pendingInstruction = text
    }

    /// The draft itself: an elegant dark card, readable, scrollable, selectable.
    /// Ido writes Hebrew AND English together, so direction is decided PER
    /// PARAGRAPH — a Hebrew line reads right-to-left and hugs the right edge, an
    /// English line reads left-to-right and hugs the left, in the same draft. No
    /// window-wide flip; each paragraph keeps its own natural direction.
    private func draftCard(_ draft: DraftModel.ActiveDraft) -> some View {
        return ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if !draft.subject.isEmpty {
                    paragraphLine(draft.subject, size: 17, weight: .semibold,
                                  color: Color(red: 0.98, green: 0.92, blue: 0.92))
                        .padding(.bottom, 6)
                }
                // Render the body paragraph-by-paragraph; blank lines stay as gaps.
                ForEach(Array(draft.body.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        Color.clear.frame(height: 10)
                    } else {
                        paragraphLine(line, size: 17, weight: .regular, color: paper)
                    }
                }
            }
            .padding(18)
            .padding(.top, 4)
            .frame(maxWidth: .infinity)
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

    /// What this draft ANSWERS, always visible below the draft card — the
    /// WhatsApp/iMessage/Teams messages or email being replied to, so Ido can
    /// re-read the original at any moment (2026-08-12: parity with the
    /// original-email view under an email reply; same loop on every channel).
    /// Server-gathered thread first (voice-attached drafts have it), then the
    /// thread the sheet was opened from, then the email seed line.
    private var replyContextText: String {
        if let c = model.draft?.context, !c.isEmpty { return c }
        if let cs = channelSeed, !cs.contextLines.isEmpty { return cs.contextLines }
        if let seed {
            let line = seed.originalLine
            if line.isEmpty { return "" }
            return seed.fromName.isEmpty ? line : "\(seed.fromName): \(line)"
        }
        return ""
    }

    @ViewBuilder
    private var replyContextSection: some View {
        let ctx = replyContextText
        if !ctx.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("REPLYING TO")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.4))
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(ctx.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                                Color.clear.frame(height: 6)
                            } else {
                                paragraphLine(line, size: 13, weight: .regular,
                                              color: Color.white.opacity(0.65))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
            .padding(12)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.07), lineWidth: 1))
        }
    }

    /// One paragraph in ITS OWN direction — Hebrew right-aligned RTL, English
    /// left-aligned LTR — so a mixed draft stays harmonious. Intra-line mixing
    /// (an English name inside a Hebrew sentence) is handled by SwiftUI's bidi.
    private func paragraphLine(_ text: String, size: CGFloat, weight: Font.Weight, color: Color) -> some View {
        let rtl = text.isRTLDominant
        return Text(text)
            .font(.system(size: size, weight: weight))
            .lineSpacing(4)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .multilineTextAlignment(rtl ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    }

    /// The writing card echoes his request the instant the window opens —
    /// recipient headline, the instruction Scarlet heard, and a live timer —
    /// so it never feels like a blank spinner while the body composes.
    private var writingCard: some View {
        let recipient = !(model.draft?.recipient ?? "").isEmpty
            ? model.draft!.recipient : model.pendingRecipient
        let instruction = !(model.draft?.instruction ?? "").isEmpty
            ? model.draft!.instruction : model.pendingInstruction
        let channel = !model.pendingChannel.isEmpty
            ? model.pendingChannel : (model.draft?.channel ?? "")
        let since = model.writingStartedAt ?? Date()
        return VStack(alignment: .leading, spacing: 14) {
            if !recipient.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: channelGlyph(channel))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(scarletRose)
                    Text("To \(recipient)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
                        .lineLimit(2)
                }
            }
            if !instruction.isEmpty {
                paragraphLine(instruction, size: 16, weight: .regular,
                              color: paper.opacity(0.92))
                    .padding(.leading, 2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(scarletRose)
                Text("Scarlet is writing…")
                    .font(.footnote).foregroundStyle(scarletRose.opacity(0.95))
                Spacer()
                // A quiet processing clock — proof she's on it.
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Text(elapsedString(ctx.date.timeIntervalSince(since)))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .monospacedDigit()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.09), lineWidth: 1))
    }

    /// SF Symbol for the channel badge on the writing card.
    private func channelGlyph(_ channel: String) -> String {
        switch channel {
        case "whatsapp": return "message.fill"
        case "imessage": return "bubble.left.fill"
        case "teams": return "person.2.fill"
        case "email_gmail", "email_outlook": return "envelope.fill"
        case "apple_note": return "note.text"
        case "reminder": return "checklist"
        default: return "square.and.pencil"
        }
    }

    /// "0:03" processing-timer string from an elapsed interval.
    private func elapsedString(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d", s / 60, s % 60)
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
            Text("Tell Scarlet what to say to \(shortRecipient.isEmpty ? "them" : shortRecipient) — speak or type below")
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

    @ViewBuilder
    private var footer: some View {
        if discardArmed {
            // Discard armed: the ONLY thing on offer is the way back.
            discardUndoBar
        } else if editingManually {
            // The manual editor carries its own actions — no second input row.
            EmptyView()
        } else {
            VStack(spacing: 12) {
                if model.draft != nil && !model.errorText.isEmpty {
                    Text(model.errorText)
                        .font(.footnote)
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                inputRow
                if model.draft != nil {
                    if model.phase == .ready {
                        reviewActionsRow
                    }
                    approveRow
                }
            }
        }
    }

    // MARK: review actions (spec §2: Refine · Edit myself · Save draft · Discard)

    /// The quiet secondary actions under the draft — Send stays the big
    /// button below. Identical on every surface that reviews a draft.
    private var reviewActionsRow: some View {
        HStack(spacing: 8) {
            reviewChip("Refine", icon: "wand.and.stars") {
                revisionFocused = true
            }
            reviewChip("Edit myself", icon: "keyboard") {
                manualText = model.draft?.body ?? ""
                editingManually = true
                manualFocused = true
            }
            reviewChip("Save draft", icon: "tray.and.arrow.down") {
                model.saveForLater()
            }
            // ⌘S — the work-surface save (hidden twin of the chip above).
            .keyboardShortcut("s", modifiers: .command)
            reviewChip("Discard", icon: "trash", tint: Color(red: 1, green: 0.45, blue: 0.45)) {
                armDiscard()
            }
        }
    }

    private func reviewChip(_ label: String, icon: String,
                            tint: Color = .white.opacity(0.75),
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: discard with undo (never a silent delete, never a dialog)

    /// Arm the discard: 5 seconds of undo, then it really goes. Closing the
    /// sheet while armed executes it too (that's what he asked for).
    private func armDiscard() {
        guard model.phase == .ready else { return }
        withAnimation(.snappy) { discardArmed = true }
        discardTask?.cancel()
        discardTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            model.discard()
            discardArmed = false
            dismiss()
        }
    }

    private var discardUndoBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
            Text("Discarding the draft to \(shortRecipient.isEmpty ? "them" : shortRecipient)…")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Button {
                discardTask?.cancel()
                discardTask = nil
                withAnimation(.snappy) { discardArmed = false }
            } label: {
                Text("Undo")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(scarletRose, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z", modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(Color(red: 1, green: 0.45, blue: 0.45).opacity(0.35), lineWidth: 1))
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
                .disabled(model.phase == .revising || model.phase == .approving
                          || model.phase == .saved || model.phase == .parked)
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

    /// The placeholder never promises "Speak" while nobody is listening —
    /// with her ears cold it says exactly what to do instead (tap the mic).
    private var inputPlaceholder: String {
        if micIsHot {
            return model.draft == nil
                ? "Speak or type what Scarlet should write…"
                : "Speak or type your changes…"
        }
        return model.draft == nil
            ? "Type here — or tap the mic to speak…"
            : "Type your change — or tap the mic to speak…"
    }

    private var canSendInput: Bool {
        let text = revisionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if model.draft != nil { return model.phase == .ready }
        // Pre-draft: channel mode, 🎙-instructed email replies, and new mail
        // start their compose here (scarlet-mode replies and voice-attach are
        // already in flight on appear).
        guard model.phase == .idle else { return false }
        if channelSeed != nil { return true }
        if seed != nil && replyMode == .instructed { return true }
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
            if replyMode == nil {
                // Legacy pill lane (no chooser context).
                model.startChannelDraft(seed: cs, instruction: text)
            } else {
                model.startFlow(mode: .instructed, instructions: text,
                                channelSeed: cs)
            }
        } else if let seed, replyMode == .instructed {
            // 🎙 Tell Scarlet what to say — his words become the instruction.
            model.startFlow(mode: .instructed, instructions: text, seed: seed)
        } else {
            model.startNewMail(recipient: newTo, instruction: text)
        }
        revisionText = ""
        revisionFocused = false
    }

    // MARK: mic (the sheet's ONE voice affordance)

    /// Her ears are hot: a LIVE session with the mic open and not in text-only
    /// chat mode. `state` matters (2026-08-12, the Kulm revision bug): with the
    /// call idle the old check still showed a hot mic, Ido spoke his revision
    /// into dead air and nothing anywhere told him — the sheet promised
    /// "Speak…" while nobody was listening.
    private var micIsHot: Bool {
        convo.micOn && !convo.chatMode && convo.state != .idle
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
            // ⌘Return = send: the work-surface convention (§5) — and Return
            // alone never sends, so a stray keystroke can't fire a message.
            .keyboardShortcut(.return, modifiers: .command)
            .animation(.easeInOut(duration: 0.25), value: model.phase)
            // (No footer "Discard" — the always-visible ✕ in the header already
            // discards; two controls for one action was clutter.)
        }
    }
}
