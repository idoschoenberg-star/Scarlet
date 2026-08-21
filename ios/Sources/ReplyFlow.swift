import SwiftUI

/// The READ-FIRST reply flow (docs/DRAFTING_FLOW_SPEC.md, Ido 2026-08-21):
/// tapping an inbound item opens a full READ view and NEVER starts a draft;
/// "Reply" presents exactly three choices — identical order and wording on
/// every surface — and all three land in the same review screen where Ido
/// decides: send / refine / edit himself / save for later / discard.
///
/// This file is the flow's shared layer: the three-choice model, the chooser
/// UI (bottom sheet on iPhone, menu on iPad/Mac), and the app-api ops that
/// record the choice and the review (`draft_mode`, `draft_review_seen`, the
/// extended `draft_action`). The review surface itself is DraftView.

// MARK: - The three choices (one source of truth for order AND wording)

/// The chooser's options, in the canonical order. Raw values are the wire
/// values `op=draft_mode` records ('scarlet' | 'manual' | 'instructed').
enum ReplyMode: String, CaseIterable, Identifiable {
    /// ✨ Scarlet drafts it (no comments from me)
    case scarlet
    /// ⌨️ I'll write it myself
    case manual
    /// 🎙 Tell Scarlet what to say (mic/keyboard opens immediately)
    case instructed

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .scarlet: return "✨"
        case .manual: return "⌨️"
        case .instructed: return "🎙"
        }
    }

    var title: String {
        switch self {
        case .scarlet: return "Scarlet drafts it"
        case .manual: return "I'll write it myself"
        case .instructed: return "Tell Scarlet what to say"
        }
    }

    var subtitle: String {
        switch self {
        case .scarlet: return "No comments from me — she writes, you review"
        case .manual: return "Type the reply yourself"
        case .instructed: return "Speak or type what the reply should say"
        }
    }

    /// One-line form for the iPad/Mac menu — same wording, same order.
    var menuTitle: String { "\(emoji) \(title)" }

    /// The exact no-comments instruction option 1 sends to `draft_compose`.
    static let scarletInstruction =
        "Reply in Ido's voice. He has no comments or additions — draft the appropriate reply from the conversation itself."

    /// Option 2's compose instruction: Ido's own words must survive verbatim.
    /// (When the backend's manual mode lands, `draft_mode` makes this exact;
    /// until then the drafting persona's only-what-he-asked rule keeps it
    /// honest.) The review screen still shows the final text before any send.
    static func verbatimInstruction(_ text: String) -> String {
        "Ido wrote this message himself. Use EXACTLY this text as the final message body, verbatim, word for word — do not rewrite, rephrase, add, or remove anything:\n\n" + text
    }
}

// MARK: - Chooser (bottom sheet, iPhone)

/// The three-option chooser as a bottom sheet. Same rows, same order, same
/// wording as the iPad/Mac menu — the consistency rule is the whole point.
struct ReplyChooserView: View {
    /// Who the reply goes to — the sheet's title line ("Reply to ארז").
    let recipient: String
    let onChoose: (ReplyMode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(recipient.isEmpty ? "Reply" : "Reply to \(recipient)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
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
            ForEach(ReplyMode.allCases) { mode in
                choiceRow(mode)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ScarletBackground().ignoresSafeArea())
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func choiceRow(_ mode: ReplyMode) -> some View {
        Button {
            // Dismiss FIRST; the caller presents the review surface from the
            // sheet's onDismiss (the reliable Catalyst sheet-swap pattern).
            onChoose(mode)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Text(mode.emoji)
                    .font(.system(size: 24))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(mode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.10), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chooser (menu, iPad/Mac)

/// The SAME three choices as a pull-down menu from the Reply control — the
/// work-surface form (§5). Wording and order are shared with the sheet via
/// ReplyMode, so the two presentations can never drift apart.
struct ReplyChooserMenu<MenuLabel: View>: View {
    let onChoose: (ReplyMode) -> Void
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu {
            ForEach(ReplyMode.allCases) { mode in
                Button(mode.menuTitle) { onChoose(mode) }
            }
        } label: {
            label()
        }
    }
}

// MARK: - Flow ops (`draft_mode` / `draft_review_seen` / extended `draft_action`)

/// The read-first flow's app-api calls (spec §6). Fire-and-forget where the
/// UI must never block on bookkeeping; awaited where the outcome matters
/// (save_for_later). Every body carries the draft id under BOTH keys the two
/// backend generations read (`id` and `draft_id`) so neither shape 400s.
enum DraftFlowAPI {

    /// Record which chooser option opened this draft ('scarlet' | 'manual' |
    /// 'instructed'), with the instruction when there was one. Bookkeeping —
    /// never blocks the compose it annotates.
    static func mode(draftId: String, mode: ReplyMode, instructions: String? = nil) {
        var body: [String: Any] = ["id": draftId, "draft_id": draftId,
                                   "mode": mode.rawValue]
        if let instructions, !instructions.isEmpty { body["instructions"] = instructions }
        Task { _ = try? await request("op=draft_mode", body: body) }
    }

    /// Stamp reviewed_at the moment the review surface actually renders the
    /// finished draft — the send path's read-back gate depends on it.
    static func reviewSeen(draftId: String) {
        Task {
            _ = try? await request("op=draft_review_seen",
                                   body: ["id": draftId, "draft_id": draftId])
        }
    }

    /// Extended draft_action: save_for_later / discard / undo_send. Returns
    /// true only when the server said ok — callers that fall back on an older
    /// backend (which answers "unknown action") need the honest answer.
    @discardableResult
    static func action(draftId: String, action: String) async -> Bool {
        guard let data = try? await request("op=draft_action",
                                            body: ["id": draftId, "draft_id": draftId,
                                                   "action": action]),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return (obj["ok"] as? Bool) == true
    }

    // MARK: waiting-on-you (the list section for review/saved drafts)

    /// One draft awaiting Ido, as `op=draft_active` returns it — enough for
    /// the "Waiting on you" card (§5); tapping it opens the full review
    /// surface in attach mode.
    struct WaitingDraft {
        let id: String
        let channel: String
        let recipient: String
        let status: String
        /// 'pin' → the card and the review surface wear the from-your-pin badge.
        let origin: String
    }

    /// The active draft, if one is waiting (status writing/draft). Absence —
    /// or an older backend — simply means no section renders.
    static func fetchWaiting() async -> WaitingDraft? {
        guard let data = try? await request("op=draft_active", method: "GET"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = obj["draft"] as? [String: Any],
              let id = d["id"] as? String, !id.isEmpty else { return nil }
        let status = (d["status"] as? String) ?? ""
        guard status == "writing" || status == "draft" else { return nil }
        return WaitingDraft(
            id: id,
            channel: (d["channel"] as? String) ?? "",
            recipient: (d["recipient"] as? String) ?? "",
            status: status,
            origin: (d["origin"] as? String) ?? ""
        )
    }

    // Same plumbing shape as DraftModel/ChatsAPI: apiBase + v=2 + x-scarlet-token.
    private static func request(_ query: String, method: String = "POST",
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

// MARK: - Channel naming (the recipient chip's "on WhatsApp" half)

/// Human name for a draft channel — the review chip ("To ארז, on WhatsApp")
/// and the waiting-on-you card share it.
func draftChannelDisplayName(_ channel: String) -> String {
    switch channel {
    case "whatsapp": return "WhatsApp"
    case "imessage": return "iMessage"
    case "teams": return "Teams"
    case "email_gmail": return "Gmail"
    case "email_outlook": return "Amwell email"
    case "apple_note": return "Apple Notes"
    case "reminder": return "Reminders"
    default: return channel.isEmpty ? "…" : channel
    }
}

// MARK: - Waiting-on-you card

/// One review/saved draft waiting for Ido — pinned at the top of the unified
/// list (§5: "Waiting on you"; §4: pin drafts land here). Tapping opens the
/// standard review surface.
struct WaitingDraftRow: View {
    let draft: DraftFlowAPI.WaitingDraft

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: draft.status == "writing" ? "pencil.line" : "doc.text.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(scarletRose)
                .frame(width: 34, height: 34)
                .background(Circle().fill(scarletRose.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(draft.status == "writing"
                         ? "Scarlet is writing a draft…"
                         : "Draft ready: reply to \(draft.recipient.isEmpty ? "…" : draft.recipient)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if draft.origin == "pin" {
                        Text("🎙 from your pin")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(scarletRose)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(scarletRose.opacity(0.16)))
                    }
                }
                Text("\(draftChannelDisplayName(draft.channel)) · tap to review — nothing sends without you")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.vertical, 8)
    }
}
