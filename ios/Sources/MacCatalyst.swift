//  MacCatalyst.swift
//
//  Mac-only enhancements for the true Mac Catalyst build. EVERYTHING in this
//  file is behind `#if targetEnvironment(macCatalyst)`, so the file compiles to
//  nothing on iOS/iPad (including "Designed for iPad on Mac") and cannot change
//  or break the existing shipping build. It is purely additive: hook points are
//  opt-in modifiers/commands that ScarletTalkApp attaches only when compiled
//  for Catalyst (see the reported snippets in the accompanying report).
//
//  What it adds, all reusing existing app machinery:
//    • ScarletCommands — a real Mac menu bar mirroring the sidebar sections and
//      the ⌘1…⌘n mapping already defined on SplitShell.ShellSection, plus
//      Start/End Call. Menu items drive the shell over NotificationCenter (the
//      same decoupling the app already uses for `.scarletGoToTalk` etc.).
//    • .macWindowChrome() — sensible minimum window size + a clean, unified
//      titlebar so the custom scarlet sidebar reaches the top of the window.
//    • .macKeepAwake(during:) — disables the idle timer while a call is live so
//      the Mac display never sleeps mid-conversation.

#if targetEnvironment(macCatalyst)

import SwiftUI
import UIKit

// MARK: - Menu → shell channel

extension Notification.Name {
    /// Posted by a menu item to select a sidebar section. userInfo["section"]
    /// carries a `SplitShell.ShellSection` rawValue. SplitShell observes this
    /// and sets its `section` (see reported SplitShell snippet).
    static let scarletMenuSelectSection = Notification.Name("scarletMenuSelectSection")
    /// Posted by the "Start Call" menu item. SplitShell wakes the conversation.
    static let scarletMenuStartCall = Notification.Name("scarletMenuStartCall")
    /// Posted by the "End Call" menu item. SplitShell ends the conversation.
    static let scarletMenuEndCall = Notification.Name("scarletMenuEndCall")
}

// MARK: - Mac menu bar

/// The Mac menu bar. Attach with `.commands { ScarletCommands() }` on the
/// WindowGroup (guarded by `#if targetEnvironment(macCatalyst)`).
///
/// Navigation items reuse `SplitShell.ShellSection` verbatim — same order,
/// same titles, and the SAME `shortcutKey` (⌘1…⌘n) already wired to the
/// sidebar buttons — so the menu bar and the sidebar can never drift apart.
struct ScarletCommands: Commands {
    var body: some Commands {
        // A dedicated top-level menu keeps the app's own verbs together and
        // out of the way of the standard File/Edit/View/Window/Help menus.
        CommandMenu("Scarlet") {
            ForEach(SplitShell.ShellSection.allCases) { section in
                Button(section.title) {
                    NotificationCenter.default.post(
                        name: .scarletMenuSelectSection,
                        object: nil,
                        userInfo: ["section": section.rawValue]
                    )
                }
                // Reuse the exact ⌘n mapping SplitShell defines.
                .keyboardShortcut(section.shortcutKey, modifiers: .command)
            }

            Divider()

            // Call controls. Keys chosen to avoid the ⌘1…⌘n section range and
            // the standard menus: ⌘R starts, ⌘. ends (a natural "stop").
            // Always enabled; the handlers are idempotent (Conversation.start
            // guards on `.idle`, end() is always safe).
            Button("Start Call") {
                NotificationCenter.default.post(name: .scarletMenuStartCall, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("End Call") {
                NotificationCenter.default.post(name: .scarletMenuEndCall, object: nil)
            }
            .keyboardShortcut(".", modifiers: .command)
        }
    }
}

// MARK: - Window chrome (size + titlebar)

/// Applies Mac window chrome by reaching the hosting `UIWindowScene` from a
/// trivial backing view. A UIViewRepresentable is used (rather than a bare
/// `.onAppear` scene lookup) because it reliably has a `window` by the time
/// `updateUIView` runs, and re-applies if the window/scene changes.
private struct MacWindowConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let scene = uiView.window?.windowScene else { return }

            // A three-pane shell needs real width; below this it stops being
            // usable. No maximum — let the user go as large as they like.
            scene.sizeRestrictions?.minimumSize = CGSize(width: 900, height: 640)
            scene.sizeRestrictions?.maximumSize = CGSize(width: .greatestFiniteMagnitude,
                                                         height: .greatestFiniteMagnitude)

            // Unified titlebar: the custom scarlet sidebar owns the whole left
            // edge, so hide the system title text and drop the toolbar to get a
            // clean, edge-to-edge look. `titlebar` is non-nil only in the true
            // "Optimized for Mac" Catalyst idiom (nil under Designed-for-iPad),
            // so the optional-chain is also the correct feature gate.
            if let titlebar = scene.titlebar {
                titlebar.titleVisibility = .hidden
                titlebar.toolbar = nil
                titlebar.separatorStyle = .none
            }
        }
    }
}

extension View {
    /// Attach once, high in the view tree (e.g. on RootView's content), to set
    /// the window's minimum size and unify the titlebar on Mac Catalyst.
    func macWindowChrome() -> some View {
        background(MacWindowConfigurator().frame(width: 0, height: 0))
    }
}

// MARK: - Keep the Mac awake during a live call

/// While a call is live (`state != .idle`) the display must not sleep — a
/// hands-free conversation with a dark screen would drop audio focus and look
/// dead. On Catalyst `isIdleTimerDisabled` maps to preventing display sleep.
private struct MacKeepAwakeModifier: ViewModifier {
    @ObservedObject var convo: Conversation

    func body(content: Content) -> some View {
        content
            .onChange(of: convo.state) { _, newState in
                apply(callActive: newState != .idle)
            }
            .onAppear { apply(callActive: convo.state != .idle) }
            .onDisappear { apply(callActive: false) }
    }

    private func apply(callActive: Bool) {
        UIApplication.shared.isIdleTimerDisabled = callActive
    }
}

extension View {
    /// Keeps the Mac display awake for as long as `convo` has a live call.
    func macKeepAwake(during convo: Conversation) -> some View {
        modifier(MacKeepAwakeModifier(convo: convo))
    }
}

#endif
