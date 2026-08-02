# Scarlet for Mac — the Orb Companion

**Status:** Direction locked (Aug 2026). Native macOS build target.
**One line:** an always-available Scarlet ball in the menu bar that toggles her
on/off, blooms into a small floating edit panel, and expands to the full
three-pane app — one codebase, a new Mac-only *face*.

---

## 1. The experience

- **The orb** lives in the **menu bar** (`NSStatusItem`) — the little Scarlet
  ball, always there, never in the way. It pulses when she's listening.
- **Click to toggle** a live session on/off. That's the "easy button."
- **It blooms** into a small **floating panel** (`NSPanel`, always-on-top,
  non-activating so it never steals focus from Outlook) when she surfaces
  content or a draft starts — the panel shows the **edit screen** (the existing
  `DraftView`: read, revise by voice or type, approve).
- **Expand** — one button opens the **full three-pane app** (`SplitShell`).
- Optional later: a **free-floating desktop orb** (same panel, detached) that
  hovers wherever he puts it.

## 2. Why it reuses everything (one app, many faces)

Nothing new is invented — the Mac companion is a new *surface* hosting views
that already exist:

| Piece            | Reuses            |
|------------------|-------------------|
| The orb visual   | `ScarletPresenceView` (the presence capsule) |
| Edit panel       | `DraftView`       |
| Expand → full app| `SplitShell` (three-pane) |
| The brain        | `Conversation` (unchanged) |

Same SwiftUI, same account, same server. The Mac-only additions are AppKit
plumbing: the status item, the floating panel window, and window management.

## 3. Distribution: Developer ID + notarization (decided)

The Mac App Store sandbox does not allow always-on-top floating panels, a
menu-bar agent as the primary surface, or reading desktop Outlook via the
Accessibility API. The orb companion needs all three → **Developer ID
(notarized), direct download**, not the Mac App Store.

Consequence: this is a **separate signing lane** from the iOS TestFlight build.
It is its own CI workstream, not a toggle.

## 4. Prerequisites (the real work before v1)

1. **Developer-ID Mac signing in CI** — a *Developer ID Application*
   certificate (created via the ASC API key we already use), a `:mac` lane that
   archives with `destination: macOS,variant=Mac Catalyst` + Hardened Runtime,
   then **notarizes** (`notarytool`) and staples. The existing cert-cleanup
   (`ci/team.js`) must be made Mac-aware so it never revokes the Mac identity.
2. **HealthKit guards** — `HealthSync.swift` / `HealthView.swift` import
   HealthKit unconditionally; HealthKit does not exist on macOS. Wrap in
   `#if !targetEnvironment(macCatalyst)` and hide the Health section on Mac, or
   the Mac target won't link.
3. **Entitlements for Mac** — no App Sandbox (Developer ID doesn't require it);
   add microphone + network + (later) Accessibility usage; a Mac-specific
   entitlements file selected per-SDK.
4. **AppKit bridge** — a small `.appKit` bundle (or bridging) for what Catalyst
   can't express: window level (`.floating`), `collectionBehavior`
   (join-all-spaces), non-activating panel, `NSApplication.setActivationPolicy(.accessory)`,
   `NSStatusItem`, and (optional) a global hotkey to summon the orb.

## 5. Milestones

- **M0 — Foundation (partly done):** `MacCatalyst.swift` (menu, window chrome,
  keep-awake) already committed, inert.
- **M1 — Mac signing lane:** Developer-ID cert + notarized `:mac` build in CI;
  HealthKit guarded; a plain windowed Catalyst app installs on the Mac.
- **M2 — The orb:** menu-bar `NSStatusItem` + toggle a live session; pulses
  while listening.
- **M3 — The bloom:** floating `NSPanel` hosting `DraftView`; edit by voice/type.
- **M4 — Expand:** button to open the full `SplitShell` app; panel⇄window
  continuity (a draft started in the orb is live in the full app).
- **M5 — Desk sense (optional):** read desktop Outlook focus locally via the
  Accessibility API (replaces the server `mac_focus` poll on the Mac).

## 6. What we need from Ido

- Confirmation to spend on the **Developer-ID Mac signing lane** (M1) — this is
  the gate; everything visual (M2–M4) follows quickly once it exists.
- First run will prompt for **Microphone** and (at M5) **Accessibility**
  permissions — one-time.

## 7. Meanwhile

The **iPad-on-Mac** build already delivers the full three-pane desktop app
today with zero new signing. The orb companion is the polished native layer on
top, not a blocker to using Scarlet on the Mac now.
