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
        case .remarkable: return Color(red: 0.52, green: 0.64, blue: 0.82) // graphite blue
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

    // MARK: Spacing (one rhythm across every screen)

    /// Screen horizontal inset — the reading margin, same on every section.
    static let gutter: CGFloat = 16
    /// Gap between stacked rows / cards in a list.
    static let rowGap: CGFloat = 12
    /// Gap between major sections within a screen.
    static let sectionGap: CGFloat = 26
    /// Inner padding of a card.
    static let cardPadding: CGFloat = 16

    // MARK: Elevation

    /// The soft ambient shadow that lifts a card off `ink`. Subtle by design —
    /// depth, not drama.
    static let shadowColor = Color.black.opacity(0.28)
    static let shadowRadius: CGFloat = 12
    static let shadowY: CGFloat = 6

    // MARK: Motion (one feel — calm, never springy-cartoonish)

    /// Standard ease for content transitions (appear/disappear, layout shifts).
    static let ease: Animation = .easeInOut(duration: 0.28)
    /// Gentle spring for interactive/selected-state moves.
    static let spring: Animation = .spring(response: 0.42, dampingFraction: 0.86)
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
            // A soft ambient lift so cards read as one elevation everywhere.
            .shadow(color: ScarletTheme.shadowColor,
                    radius: ScarletTheme.shadowRadius,
                    x: 0, y: ScarletTheme.shadowY)
    }
}

extension View {
    /// The consistent, readable near-black base for a section's screen.
    func scarletScreen() -> some View { modifier(ScarletScreen()) }
    /// An elevated card on the base surface.
    func scarletCard(strong: Bool = false) -> some View { modifier(ScarletCard(strong: strong)) }
    /// Standard inner padding for a card's content (pairs with `.scarletCard()`).
    func scarletCardPadding() -> some View { padding(ScarletTheme.cardPadding) }
}

// MARK: - Shared header idioms
//
// One header vocabulary the whole app shares so every section reads like a
// page in the same publication: a big hero title with an accent-tinted glyph,
// an optional subtitle, and an optional trailing control.

/// The one screen-header: accent glyph · hero title (+ optional subtitle) ·
/// trailing control. Drop it at the top of a section's `VStack` in place of an
/// ad-hoc `Text(...).font(.scarletHero)` row.
struct ScarletHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var accent: Color = ScarletTheme.rose
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(accent.opacity(0.16))
                    )
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.scarletHero)
                    .foregroundStyle(ScarletTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.scarletDetail)
                        .foregroundStyle(ScarletTheme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, ScarletTheme.gutter)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

extension ScarletHeader where Trailing == EmptyView {
    init(_ title: String,
         subtitle: String? = nil,
         systemImage: String? = nil,
         accent: Color = ScarletTheme.rose) {
        self.init(title: title, subtitle: subtitle,
                  systemImage: systemImage, accent: accent,
                  trailing: { EmptyView() })
    }
}

/// A grouping header *within* a screen: a short accent bar + a section-size
/// label. The consistent way to title a block below the screen header.
struct ScarletSectionHeader: View {
    let title: String
    var accent: Color = ScarletTheme.rose
    init(_ title: String, accent: Color = ScarletTheme.rose) {
        self.title = title
        self.accent = accent
    }
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 3, height: 18)
            Text(title)
                .font(.scarletSection)
                .foregroundStyle(ScarletTheme.textPrimary)
            Spacer(minLength: 0)
        }
    }
}

/// An accent chip — the shared idiom for a small status/tag pill (chrome only,
/// accent tint on `ink`, never a reading ground).
struct ScarletChip: View {
    let text: String
    var systemImage: String? = nil
    var accent: Color = ScarletTheme.rose
    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
            }
            Text(text).font(.scarletCaptionEmph)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(accent.opacity(0.15)))
        .overlay(Capsule().stroke(accent.opacity(0.30), lineWidth: 1))
    }
}
