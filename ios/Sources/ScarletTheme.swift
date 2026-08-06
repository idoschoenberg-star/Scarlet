import SwiftUI

/// The one readability-first design system for the whole app.
///
/// Ido's directive (2026-08-06): the reddish-scarlet gradient behind text reads
/// worse than the Inbox's near-black. So EVERY section's reading surface is a
/// consistent dark near-black (`ink`), text is high-contrast, and each section
/// keeps its own **accent** — used on titles, chips, rings, and active states,
/// never as the ground behind bodies of text. The scarlet gradient
/// (`ScarletBackground`) is reserved for the Talk hero and brand moments.
///
/// Apply with the modifiers at the bottom: `.scarletScreen()` for a section's
/// base, `.scarletCard()` for an elevated panel. Colors come from the tokens so
/// every screen stays consistent and legible in one place.
enum ScarletTheme {
    // MARK: Surfaces (the shared, readable base)

    /// The reading ground — a warm near-black, consistent on every screen.
    static let ink = Color(red: 0.043, green: 0.038, blue: 0.043)
    /// One step up for grouped backgrounds behind cards.
    static let inkRaised = Color(red: 0.075, green: 0.067, blue: 0.075)
    /// Elevated card fill (sits on `ink`).
    static let card = Color.white.opacity(0.055)
    /// Slightly stronger card for the primary panel on a screen.
    static let cardStrong = Color.white.opacity(0.08)
    /// Hairline separators / card strokes.
    static let hairline = Color.white.opacity(0.10)

    // MARK: Text (high contrast on `ink`)

    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.66)
    static let textTertiary = Color.white.opacity(0.45)

    // MARK: Accents

    /// The brand rose — the global accent and Talk's color.
    static let rose = Color(red: 1.0, green: 0.35, blue: 0.42)

    /// Each section's accent. Chrome only (titles, chips, rings, active states),
    /// never the reading background. Distinct hues so sections "shine," all
    /// legible on `ink`.
    static func accent(for section: AppSection) -> Color {
        switch section {
        case .talk:      return rose
        case .inbox:     return Color(red: 0.36, green: 0.62, blue: 1.0)   // blue
        case .calendar:  return Color(red: 1.0, green: 0.42, blue: 0.42)   // red
        case .chats:     return Color(red: 0.30, green: 0.80, blue: 0.52)  // green
        case .reminders: return Color(red: 0.42, green: 0.66, blue: 1.0)   // blue
        case .notes:     return Color(red: 1.0, green: 0.78, blue: 0.36)   // amber
        case .news:      return Color(red: 1.0, green: 0.44, blue: 0.40)   // warm red
        case .amwell:    return Color(red: 0.30, green: 0.82, blue: 0.74)  // teal
        case .music:     return Color(red: 0.40, green: 0.85, blue: 0.55)  // spotify-ish green
        case .video:     return Color(red: 1.0, green: 0.38, blue: 0.42)   // red
        case .photos:    return rose
        case .health:    return Color(red: 1.0, green: 0.45, blue: 0.55)   // pink-red
        case .food:      return Color(red: 0.55, green: 0.82, blue: 0.42)  // fresh green
        case .library:   return Color(red: 0.78, green: 0.62, blue: 1.0)   // violet
        case .settings:  return rose
        }
    }

    // MARK: Metrics
    static let cardRadius: CGFloat = 18
    static let screenPadding: CGFloat = 16
}

// MARK: - Modifiers

private struct ScarletScreen: ViewModifier {
    func body(content: Content) -> some View {
        content.background(ScarletTheme.ink.ignoresSafeArea())
    }
}

private struct ScarletCard: ViewModifier {
    var strong: Bool
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: ScarletTheme.cardRadius, style: .continuous)
                    .fill(strong ? ScarletTheme.cardStrong : ScarletTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScarletTheme.cardRadius, style: .continuous)
                    .stroke(ScarletTheme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    /// The consistent, readable near-black base for a section's screen.
    func scarletScreen() -> some View { modifier(ScarletScreen()) }
    /// An elevated card on the base surface.
    func scarletCard(strong: Bool = false) -> some View { modifier(ScarletCard(strong: strong)) }
}
