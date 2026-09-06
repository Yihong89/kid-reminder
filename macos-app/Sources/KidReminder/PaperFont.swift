import SwiftUI

/// Produces scaled fonts for the paper runners (English / Science). The kid can
/// zoom the reading text with A− / A+ in the toolbar; the scale comes from
/// SettingsStore.paperFontScale. The base sizes mirror the standard dynamic
/// type styles so the default (scale = 1.0) looks unchanged.
struct PaperFont {
    let scale: CGFloat

    static let title2 = Font.title2       // headers / seq label
    static let headline = Font.headline   // step header
    static let body = Font.body           // prompt / passage
    static let callout = Font.callout     // context / answers / subtext
    static let caption = Font.caption     // metas / hints
    static let footnote = Font.footnote

    /// Scale a base point size by the user's scale (clamped to a sane range).
    func size(_ base: CGFloat) -> Font { .system(size: base * scale) }
    func size(_ base: CGFloat, weight: Font.Weight) -> Font { .system(size: base * scale, weight: weight) }

    // Scaled equivalents of the common styles, for drop-in use.
    var scaledBody: Font { size(17) }        // ~ .body
    var scaledCallout: Font { size(16) }     // ~ .callout
    var scaledCaption: Font { size(12) }     // ~ .caption
    var scaledFootnote: Font { size(13) }    // ~ .footnote
    var scaledHeadline: Font { size(17, weight: .semibold) }  // ~ .headline
    var scaledTitle2: Font { size(22, weight: .bold) }        // ~ .title2
}
