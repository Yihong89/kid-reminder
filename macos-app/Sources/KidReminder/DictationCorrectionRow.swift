import SwiftUI

/// One graded dictation word, drawn for 订正 (correction) rather than for the parent's
/// dense grading table.
///
/// The word is the thing the kid has to write, so it is the hero of the row: rendered
/// at 42 pt, far larger than a standard macOS list line, so it can be read at a glance
/// from across a desk. A wrong word is red end to end — glyphs, the tested-character
/// badge and a faint red wash behind the row — because the whole point of this screen
/// is to make the handful of words to correct impossible to miss among 40 correct ones.
///
/// Pure presentation: it takes plain strings and a verdict, with no API/model types, so
/// it can be rendered on its own for visual checks.
struct DictationCorrectionRow: View {
    let character: String
    let word: String
    let pinyin: String
    let sentence: String
    let isCorrect: Bool

    /// Correct rows keep the normal ink colour; red is reserved for what needs fixing.
    private var ink: Color { isCorrect ? .primary : .red }
    private var statusColor: Color { isCorrect ? .green : .red }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24)
                // Nudge the icon onto the word's visual centre line, not the row top.
                .padding(.top, 9)
                .accessibilityLabel(isCorrect ? "写对了" : "写错了")

            VStack(alignment: .leading, spacing: 2) {
                Text(word)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)

                if !pinyin.isEmpty {
                    Text(pinyin)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if !sentence.isEmpty {
                    Text(sentence)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 12)

            // The single character this vocab entry tests, kept as a reference badge:
            // the word already contains it, so it must not compete with the word itself.
            if !character.isEmpty {
                Text(character)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(isCorrect ? Color.secondary.opacity(0.09) : Color.red.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(
                                isCorrect ? Color.secondary.opacity(0.18) : Color.red.opacity(0.35),
                                lineWidth: 1
                            )
                    )
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCorrect ? Color.clear : Color.red.opacity(0.06))
        )
    }
}
