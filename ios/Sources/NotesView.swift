import Foundation
import SwiftUI
import UIKit

/// Notes — Ido's Apple Notes, read on demand through the home-Mac agent, on
/// their OWN focused page. Split out of the old Desk so Reminders and Notes
/// each stand alone with a clear name. Local-first: the last fetched titles are
/// cached to Documents/notes-cache.json and render instantly on open while a
/// background refresh brings the truth in.
///
/// Reuses the exact backend ops / flows the Desk used — nothing new invented:
///   • `notes_list`  the note titles (or a queued/asleep signal)
///   • `note_read`   the body of one note (by title query)
///   • NEW note is created through the standard drafting window on the
///     "apple_note" channel — dictate/type → Scarlet tidies → Approve saves it
///     to Apple Notes (DraftView + ChannelDraftSeed, unchanged).
///
/// Self-contained (its own palette, model, and request pipe) so it survives the
/// removal of DeskView.swift.

// MARK: - Native dark palette (Apple Notes design language)

private enum NotesUI {
    static let background = Color.black
    static let card = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let separator = Color(red: 56 / 255, green: 56 / 255, blue: 58 / 255)
    static let gray = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    /// Notes accent — yellow-amber #FFD60A.
    static let yellow = Color(red: 1, green: 214 / 255, blue: 10 / 255)
    static let red = Color(red: 1, green: 69 / 255, blue: 58 / 255)
}

// MARK: - Wire type

/// One Apple Note title from the Mac agent's `notes_list`. The body arrives
/// only when the note is opened (`note_read`). Hashable so it can drive a
/// `navigationDestination(item:)` push.
struct NoteItem: Identifiable, Hashable {
    let id: String
    let title: String
    let modified: Date?
    let modifiedRaw: String?

    var modifiedText: String? {
        if let modified {
            return NotesDates.relative.localizedString(for: modified, relativeTo: Date())
        }
        if let modifiedRaw, !modifiedRaw.isEmpty { return modifiedRaw }
        return nil
    }
}

// MARK: - Dates

enum NotesDates {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()

    static func updatedStamp(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "updated just now" }
        if s < 3600 { return "updated \(s / 60)m ago" }
        if s < 86400 { return "updated \(s / 3600)h ago" }
        return "updated " + relative.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Model

@MainActor
final class NotesModel: ObservableObject {
    @Published var notes: [NoteItem] = []
    /// The Mac agent answered queued/error — the home Mac is asleep. Cached
    /// notes (if any) keep rendering under an asleep banner.
    @Published var macAsleep = false
    @Published var loading = false
    @Published var errorText = ""
    @Published var updatedAt: Date?

    private var rawNotes: [[String: Any]] = []
    private var loadGeneration = 0

    init() { loadCache() }

    func load() async {
        guard TokenStore.token != nil else {
            errorText = "Locked — unlock Scarlet to see your notes."
            return
        }
        if notes.isEmpty { loading = true }
        loadGeneration += 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { loading = false } }
        do {
            let data = try await Self.request(["op": "notes_list"])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let payload = (obj["result"] as? [String: Any]) ?? obj
            guard generation == loadGeneration else { return }
            if let parsed = Self.parseNotes(payload) {
                rawNotes = parsed.raw
                notes = parsed.notes
                macAsleep = false
                updatedAt = Date()
                errorText = ""
                saveCache()
            } else {
                // queued / error / unrecognized → the home Mac is asleep.
                macAsleep = true
            }
        } catch {
            guard generation == loadGeneration else { return }
            errorText = "Couldn't reach the notes bridge — check your connection."
        }
    }

    // MARK: parsing (defensive — the payload is the Mac agent's JSON)

    /// Success needs a `notes` array (dicts with `title`, or bare title
    /// strings) at the top level or one nesting down; queued/error/anything
    /// else returns nil so the view shows the Mac-asleep state.
    static func parseNotes(_ payload: [String: Any]) -> (raw: [[String: Any]], notes: [NoteItem])? {
        let queued = (payload["queued"] as? Bool) ?? (payload["queued"] != nil)
        if queued { return nil }
        if let err = payload["error"] as? String, !err.isEmpty { return nil }
        var list = payload["notes"] as? [Any]
        if list == nil, let inner = payload["result"] as? [String: Any] {
            list = inner["notes"] as? [Any]
        }
        guard let entries = list else { return nil }
        var raw: [[String: Any]] = []
        for entry in entries {
            if let s = entry as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { raw.append(["title": t]) }
            } else if let d = entry as? [String: Any] {
                let t = ((d["title"] as? String) ?? (d["name"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                var norm: [String: Any] = ["title": t]
                if let m = (d["modified"] as? String)
                    ?? (d["modified_at"] as? String)
                    ?? (d["updated_at"] as? String) {
                    norm["modified"] = m
                }
                raw.append(norm)
            }
        }
        return (raw, buildNotes(raw))
    }

    static func buildNotes(_ raw: [[String: Any]]) -> [NoteItem] {
        raw.enumerated().map { i, d in
            let title = (d["title"] as? String) ?? "Untitled"
            let modified = d["modified"] as? String
            return NoteItem(id: "\(i)-" + title,
                            title: title,
                            modified: MailDates.parse(modified),
                            modifiedRaw: modified)
        }
    }

    // MARK: cache — Documents/notes-cache.json

    static var cacheURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("notes-cache.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        rawNotes = (obj["notes"] as? [[String: Any]]) ?? []
        notes = Self.buildNotes(rawNotes)
        updatedAt = MailDates.parse(obj["updated"] as? String)
    }

    private func saveCache() {
        var obj: [String: Any] = ["notes": rawNotes]
        if let d = updatedAt { obj["updated"] = MailDates.isoPlain.string(from: d) }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: plumbing — op rides the query string, params ride the JSON body.
    // Internal (not private) so NoteReaderView reads through the same pipe.

    static func request(_ body: [String: Any]) async throws -> Data {
        var body = body
        let op = (body.removeValue(forKey: "op") as? String) ?? ""
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        var qItems = comps.queryItems ?? []
        qItems.append(URLQueryItem(name: "op", value: op))
        comps.queryItems = qItems
        var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Page

struct NotesView: View {
    @StateObject private var model = NotesModel()
    @EnvironmentObject var convo: Conversation

    /// The note being read — drives a PUSH into the detail column (not a
    /// window-covering sheet) so the Scarlet sidebar stays reachable.
    @State private var reading: NoteItem?
    /// The new-note draft window — the SINGLE `.sheet` on this view (Mac
    /// Catalyst allows only one). One `.sheet` + one push is fine.
    @State private var draftSeed: ChannelDraftSeed?
    /// The focus line last claimed for an open note; the pop restores browsing
    /// focus only if this still owns it (stale-guard).
    @State private var openedFocus: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                content
            }
            .background(NotesUI.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                ScarletPresenceView(convo: convo)
                    .padding(.vertical, 6)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { convo.setFocus(browsingFocus) }
            .reportsModalPresence(reading != nil || draftSeed != nil)
            // The reader PUSHES into the detail column; on pop, restore focus
            // and refresh so an approved note shows right away.
            .navigationDestination(item: $reading) { note in
                NoteReaderView(note: note)
                    // Mac Catalyst drops @EnvironmentObject across the
                    // navigation boundary; re-inject to match the app-wide push
                    // pattern (harmless — the reader is self-contained today).
                    .environmentObject(convo)
                    .preferredColorScheme(.dark)
            }
            .onChange(of: reading) { _, newValue in
                if newValue == nil {
                    restoreBrowsingFocus()
                    Task { await model.load() }
                }
            }
            // The new-note drafting window — the single `.sheet`.
            .sheet(item: $draftSeed, onDismiss: {
                Task { await model.load() }
            }) { seed in
                DraftView(seed: nil, channelSeed: seed)
                    .environmentObject(convo)
                    .preferredColorScheme(.dark)
            }
        }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await model.load() }
        }
    }

    // MARK: header (title + new-note compose + refresh)

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text("Notes")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                newNoteButton
                Button { Task { await model.load() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(NotesUI.yellow)
                }
                .disabled(model.loading)
            }
            if let stamp = model.updatedAt {
                Text(NotesDates.updatedStamp(stamp))
                    .font(.system(size: 12))
                    .foregroundStyle(NotesUI.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// Apple-Notes-style compose (square-and-pencil, Notes yellow) — opens the
    /// standard drafting window on the "apple_note" channel: dictate or type
    /// the ask, Scarlet tidies it into a note, Approve saves it to Apple Notes.
    private var newNoteButton: some View {
        Button {
            draftSeed = ChannelDraftSeed(channel: "apple_note", recipient: "Notes")
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(NotesUI.yellow)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Note")
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if model.loading && model.notes.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Asking your Mac…")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.notes.isEmpty && model.macAsleep {
            VStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title2).foregroundStyle(.secondary)
                Text("Your home Mac is asleep — notes will load when it wakes.")
                    .font(.system(size: 17)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
                    .tint(NotesUI.yellow)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.notes.isEmpty && !model.errorText.isEmpty {
            retryState(model.errorText)
        } else if model.notes.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.title2).foregroundStyle(.secondary)
                Text("No notes found on your Mac — tap the pencil to write one.")
                    .font(.system(size: 17)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if model.macAsleep {
                Text("Your home Mac is asleep — showing the last snapshot; notes will refresh when it wakes.")
                    .font(.system(size: 14))
                    .foregroundStyle(NotesUI.yellow)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !model.errorText.isEmpty { errorRow }
            Section {
                ForEach(model.notes) { note in
                    Button { open(note) } label: { NoteRow(note: note) }
                        .buttonStyle(.plain)
                        .listRowBackground(NotesUI.card)
                        .listRowSeparatorTint(NotesUI.separator)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    // MARK: shared bits

    private var errorRow: some View {
        Text(model.errorText)
            .font(.system(size: 14))
            .foregroundStyle(NotesUI.red)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func retryState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2).foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 17)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await model.load() } }
                .buttonStyle(.bordered)
                .tint(NotesUI.yellow)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Scarlet focus

    private var browsingFocus: String {
        "[FOCUS] Ido is on his Notes page — his Apple Notes, read on demand "
            + "through his home Mac (apple notes tools). He can open one to read "
            + "it, or tap the pencil to dictate a new note."
    }

    private func noteFocus(_ note: NoteItem) -> String {
        "[FOCUS] Ido opened an Apple Note from his Mac: \"\(note.title)\". "
            + "He is reading it now.\n"
            + "note_id: \(note.id)"
    }

    private func open(_ note: NoteItem) {
        let f = noteFocus(note)
        openedFocus = f
        convo.setFocus(f)
        reading = note
    }

    /// Restore the browsing focus only if the closed reader still owns it —
    /// another screen may have claimed focus while it was up.
    private func restoreBrowsingFocus() {
        if let f = openedFocus, convo.currentFocus == f {
            convo.setFocus(browsingFocus)
        }
        openedFocus = nil
    }
}

// MARK: - Note row

/// One note, Apple Notes dark style: white semibold title over a gray date
/// line — no doc tile, no chevron.
struct NoteRow: View {
    let note: NoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(note.title.readingAlignment)
                .frame(maxWidth: .infinity, alignment: note.title.readingFrameAlignment)
            if let stamp = note.modifiedText {
                Text(stamp)
                    .font(.system(size: 15))
                    .foregroundStyle(NotesUI.gray)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Note reader

/// The reader: fetches the note body on appearance (`note_read` with the title
/// as the query) and shows it Apple-Notes style — black page, bold title as the
/// first line, white 18pt system body. Queued/error from the Mac agent becomes
/// the friendly asleep state. Self-contained; pushed into the Notes stack.
struct NoteReaderView: View {
    let note: NoteItem
    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var text = ""
    @State private var shownTitle = ""
    @State private var alsoMatched: [String] = []
    @State private var asleep = false
    @State private var errorText = ""

    var body: some View {
        // The list root hides the system nav bar app-wide and Mac Catalyst has
        // no edge-swipe-back, so the only reliable exit is one we draw
        // ourselves — the app-wide reader pattern.
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Notes").font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(NotesUI.yellow)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            Group {
                if loading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Asking your Mac…")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if asleep {
                    stateView(icon: "moon.zzz.fill",
                              message: "Your home Mac is asleep — notes will load when it wakes.")
                } else if !errorText.isEmpty {
                    stateView(icon: "wifi.exclamationmark", message: errorText)
                } else {
                    reader
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(NotesUI.background.ignoresSafeArea())
        .task { await load() }
    }

    private var reader: some View {
        let displayTitle = shownTitle.isEmpty ? note.title : shownTitle
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(displayTitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .multilineTextAlignment(displayTitle.readingAlignment)
                    .frame(maxWidth: .infinity, alignment: displayTitle.readingFrameAlignment)
                if !alsoMatched.isEmpty {
                    Text("Also matched: " + alsoMatched.joined(separator: ", "))
                        .font(.system(size: 13))
                        .foregroundStyle(NotesUI.gray)
                }
                Text(text)
                    .font(.system(size: 18))
                    .lineSpacing(6)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .multilineTextAlignment(text.readingAlignment)
                    .frame(maxWidth: .infinity, alignment: text.readingFrameAlignment)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func stateView(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2).foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 17)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .buttonStyle(.bordered)
                .tint(NotesUI.yellow)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        asleep = false
        errorText = ""
        defer { loading = false }
        do {
            let data = try await NotesModel.request([
                "op": "note_read",
                "query": note.title,
            ])
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let result = (obj["result"] as? [String: Any]) ?? obj
            let queued = (result["queued"] as? Bool) ?? (result["queued"] != nil)
            if queued { asleep = true; return }
            if let err = result["error"] as? String, !err.isEmpty { asleep = true; return }
            if (result["found"] as? Bool) == false {
                errorText = "Your Mac couldn't find a note matching \"\(note.title)\"."
                return
            }
            shownTitle = (result["title"] as? String) ?? note.title
            alsoMatched = (result["also_matched"] as? [String]) ?? []
            let body = ((result["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            text = body.isEmpty ? "(This note is empty.)" : body
        } catch {
            errorText = "Couldn't reach the notes bridge — check your connection and try again."
        }
    }
}
