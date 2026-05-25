import SwiftUI

/// Lightweight SwiftUI markdown renderer purpose-built for desk
/// reports. Apple's `AttributedString(markdown:)` covers inline marks
/// (`**bold**`, `*italic*`, links) but stops at block-level — no
/// headings, lists, blockquotes. The full `swift-markdown-ui` Swift
/// Package would solve that but pulls a remote dependency Wick doesn't
/// otherwise carry; everything we need for analyst transcripts is a
/// small grammar:
///
///   - `### Heading` → bold caption
///   - `- item` → bulleted lists (with role-tinted leading dot)
///   - `1. item` → numbered lists (chip-style index circles)
///   - blank-line separated paragraphs
///   - inline `**bold**` / `*italic*` (via AttributedString)
///
/// The view defers the inline parse to `AttributedString(markdown:)`,
/// only owning the block layout — that's where Apple's built-in
/// markdown stops and where the visual hierarchy lives.
struct WickMarkdown: View {

    let text: String
    /// Used to tint bullet dots and numbered-list chips so the
    /// markdown surface inherits the speaker's role colour.
    var accent: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Block parsing

    private enum Block {
        case heading(String)
        case bullets([String])
        case ordered([String])
        case paragraph(String)
    }

    /// Parse `text` into a sequence of block-level chunks. Blocks are
    /// separated by blank lines; within a block, line breaks separate
    /// list items (for list blocks) or are kept verbatim (for prose).
    private var blocks: [Block] {
        let chunks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return chunks.map { chunk in
            let lines = chunk.components(separatedBy: "\n")
            // Heading
            if let first = lines.first, first.hasPrefix("### ") {
                return .heading(String(first.dropFirst(4)))
            }
            // Bullet list
            if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces)
                                    .hasPrefix("- ") }) {
                let items = lines.map { line -> String in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return String(t.dropFirst(2))
                }
                return .bullets(items)
            }
            // Numbered list — accept "1.", "1)", with optional whitespace
            if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces)
                                    .range(of: #"^\d+[.)]\s+"#,
                                            options: .regularExpression) != nil }) {
                let items = lines.map { line -> String in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if let r = t.range(of: #"^\d+[.)]\s+"#,
                                       options: .regularExpression) {
                        return String(t[r.upperBound...])
                    }
                    return t
                }
                return .ordered(items)
            }
            return .paragraph(chunk)
        }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let s):
            Text(attributed(s))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 4)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(accent)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(attributed(item))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                        Spacer(minLength: 0)
                    }
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.system(size: 10, weight: .heavy,
                                          design: .monospaced))
                            .foregroundStyle(accent)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .stroke(accent, lineWidth: 1)
                                    .background(Circle().fill(.black.opacity(0.25)))
                            )
                            .padding(.top, 1)
                        Text(attributed(item))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                        Spacer(minLength: 0)
                    }
                }
            }

        case .paragraph(let s):
            Text(attributed(s))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
    }

    /// Inline-mark parse via Apple's built-in markdown attributer.
    /// Soft-line-breaks (within a paragraph) are preserved as actual
    /// newlines so the view doesn't collapse multi-line bullet items.
    private func attributed(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attr = try? AttributedString(markdown: s, options: options) {
            return attr
        }
        return AttributedString(s)
    }
}
