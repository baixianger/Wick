import SwiftUI
import MarkdownUI

// MARK: - Waterfall theme

/// Document-style MarkdownUI theme for the Wicker chat. Agent output
/// is long-form (multi-paragraph analyses with headings, lists, code
/// blocks); the previous bubble + `AttributedString(markdown:)`
/// rendering collapsed block-level structure into inline text.
/// "Waterfall" because the rendering style is borrowed from
/// `clawbox`'s document-waterfall chat surface — assistant messages
/// flow like a README, not like IM bubbles.
extension Theme {
    @MainActor static var wickerWaterfall: Theme {
        Theme()
            .text {
                FontSize(15)
                ForegroundColor(.primary)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(13)
                ForegroundColor(.primary)
                BackgroundColor(Color.secondary.opacity(0.12))
            }
            .codeBlock { configuration in
                WickerCodeBlock(configuration: configuration)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(22)
                    }
                    .padding(.bottom, 2)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(19)
                    }
                    .padding(.bottom, 2)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(17)
                    }
            }
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }
            .link { ForegroundColor(Color.accentColor) }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(.secondary) }
                        .padding(.leading, 10)
                }
                .padding(.vertical, 2)
            }
            .table { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .markdownTableBorderStyle(
                            TableBorderStyle(color: Color.secondary.opacity(0.30),
                                              width: 1))
                        .markdownTableBackgroundStyle(
                            .alternatingRows(
                                Color.clear,
                                Color.secondary.opacity(0.06)))
                        .clipShape(RoundedRectangle(cornerRadius: 8,
                                                     style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8,
                                              style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.30),
                                                lineWidth: 1))
                }
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(14)
                        if configuration.row == 0 { FontWeight(.semibold) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
    }
}

// MARK: - Code block

/// One `lang` header + monospace body + copy button. NSPasteboard
/// rather than UIPasteboard since Wick is macOS-only.
struct WickerCodeBlock: View {
    let configuration: CodeBlockConfiguration
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let lang = configuration.language, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 11, weight: .medium,
                                       design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(configuration.content, forType: .string)
                    isCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        isCopied = false
                    }
                } label: {
                    Label(isCopied ? "Copied" : "Copy",
                           systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(isCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.10))

            Divider().opacity(0.6)

            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12)
                        ForegroundColor(.primary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1))
    }
}

// MARK: - Stable wrapper

/// `EquatableView` wrapper around `Markdown` so completed messages
/// don't re-parse on every body evaluation (scroll, focus changes,
/// sibling view re-renders). Streaming messages should NOT use this
/// — their content changes per token so the equatable optimisation
/// would prevent updates.
struct StableMarkdownView: View, Equatable {
    let content: String

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content
    }

    var body: some View {
        Markdown(content)
            .markdownTheme(.wickerWaterfall)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
