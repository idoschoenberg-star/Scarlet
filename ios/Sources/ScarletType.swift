import SwiftUI

/// # ScarletType — the app's ONE type scale
///
/// Ido reads on eyes that tire of small print. Every screen's body text should
/// land at roughly the chat font size (~17pt) or a hair larger — legible first,
/// never clumsy or oversized. This file is the single source of truth for that:
/// one small, reusable ramp every view adopts with `.font(.scarletBody)` and
/// friends, so the whole app reads as one system and a size change happens in
/// exactly one place.
///
/// The ramp (intent → size / weight):
///
/// | Token              | Size | Weight    | Where it's used                         |
/// |--------------------|------|-----------|-----------------------------------------|
/// | `.scarletHero`     | 32   | bold      | Big screen titles ("Inbox", "Calendar") |
/// | `.scarletSection`  | 24   | semibold  | Section headers within a screen         |
/// | `.scarletTitle`    | 21   | semibold  | List / card titles (a reader's subject) |
/// | `.scarletBody`     | 17   | regular   | Body / reading text — the baseline      |
/// | `.scarletBodyEmph` | 17   | semibold  | Body text that needs weight (a sender)  |
/// | `.scarletDetail`   | 15   | regular   | Secondary detail (previews, times)      |
/// | `.scarletDetailEmph`|15   | semibold  | Secondary detail that needs weight      |
/// | `.scarletCaption`  | 13   | regular   | Captions / labels (stamps, small meta)  |
/// | `.scarletCaptionEmph`|13  | semibold  | Captions / labels that need weight      |
///
/// Rules of thumb when adopting:
/// - Text Ido *reads* (a message preview, an event location, a body line) is
///   `.scarletBody` or `.scarletDetail` — never `.footnote`/`.caption2`.
/// - A weight can still be layered per-state (e.g. bold an unread sender) with
///   `.fontWeight(_:)` on top of a token, or by picking the `…Emph` variant.
/// - Pair reading blocks with `.scarletReadingLineSpacing()` so lines breathe
///   at the larger size without looking loose.
extension Font {
    /// Large title / hero — the big screen name at the top of a page.
    static let scarletHero = Font.system(size: 32, weight: .bold)
    /// Section header — a grouping title within a screen.
    static let scarletSection = Font.system(size: 24, weight: .semibold)
    /// List / card title — a row's headline or a reader's subject line.
    static let scarletTitle = Font.system(size: 21, weight: .semibold)

    /// Body / reading text — the app's baseline, matched to the chat size.
    static let scarletBody = Font.system(size: 17, weight: .regular)
    /// Body text that needs emphasis (a sender name, a primary label).
    static let scarletBodyEmph = Font.system(size: 17, weight: .semibold)

    /// Secondary detail — previews, times, sub-labels. Still comfortably read.
    static let scarletDetail = Font.system(size: 15, weight: .regular)
    /// Secondary detail that needs emphasis.
    static let scarletDetailEmph = Font.system(size: 15, weight: .semibold)

    /// Caption / label — freshness stamps, tiny meta. The floor; nothing Ido
    /// has to *read* should be smaller than this.
    static let scarletCaption = Font.system(size: 13, weight: .regular)
    /// Caption / label that needs emphasis (a small-caps day header).
    static let scarletCaptionEmph = Font.system(size: 13, weight: .semibold)
}

extension View {
    /// Comfortable line spacing for multi-line reading blocks at the body
    /// size. Applied to previews and body copy so the larger type breathes
    /// without the lines drifting apart. Default 4pt reads well at 15–17pt.
    func scarletReadingLineSpacing(_ spacing: CGFloat = 4) -> some View {
        self.lineSpacing(spacing)
    }
}
