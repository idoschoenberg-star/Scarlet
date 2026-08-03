import SwiftUI

/// Per-message writing direction. Hebrew (and Arabic) correspondence must read
/// right-to-left; English stays left-to-right. Used by the draft window and the
/// chat bubbles so both flip correctly with the content.
extension String {
    /// True when this text is dominated by a right-to-left script. Counts
    /// strong RTL letters (Hebrew 0590–05FF, Arabic 0600–06FF / 0750–077F /
    /// presentation forms FB1D–FDFF, FE70–FEFF) against strong LTR letters
    /// (basic Latin A–Z / a–z). Digits, punctuation, emoji and whitespace are
    /// neutral and ignored — so "שלום David 3" still resolves by its letters.
    var isRTLDominant: Bool {
        var rtl = 0, ltr = 0
        for u in unicodeScalars {
            let v = u.value
            if (0x0590...0x05FF).contains(v) || (0x0600...0x06FF).contains(v)
                || (0x0750...0x077F).contains(v) || (0x08A0...0x08FF).contains(v)
                || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v) {
                rtl += 1
            } else if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
                ltr += 1
            }
            if rtl + ltr >= 240 { break }   // enough signal; don't scan huge bodies
        }
        return rtl > ltr
    }

    /// SwiftUI layout direction for this text.
    var layoutDir: LayoutDirection { isRTLDominant ? .rightToLeft : .leftToRight }
    /// Text alignment that hugs the reading edge (right for Hebrew, left for English).
    var readingAlignment: TextAlignment { isRTLDominant ? .trailing : .leading }
    /// Frame alignment matching the reading edge.
    var readingFrameAlignment: Alignment { isRTLDominant ? .trailing : .leading }
    /// Horizontal-stack alignment matching the reading edge.
    var readingHAlignment: HorizontalAlignment { isRTLDominant ? .trailing : .leading }
}
