import Foundation

/// A single file the user attached to a chat message. **Generic, by design.**
/// An attachment carries either an image (for true vision) or extracted text
/// (for documents) — Wicker reads it and composes behaviour with its existing
/// tools (`portfolio.add`, `get_market_data`, …). There is deliberately NO
/// holdings-specific / transaction-extraction pipeline here; attachments and
/// portfolio writes are decoupled. The agent decides what to do with what it
/// reads.
///
/// **Payload shape per kind:**
///   - `.image`  → `imageBase64` + `mimeType` are set; `extractedText` is nil.
///                 Rides onto the user `LLMMessage` as an `LLMImage` part (real
///                 vision content block).
///   - docs (`.pdf` / `.csv` / `.excel` / `.text`) → `extractedText` is set;
///                 `imageBase64` / `mimeType` are nil. Folded into the message
///                 `content` as a delimited `[附件 …]` block.
struct ChatAttachment: Identifiable, Codable, Equatable, Hashable {

    /// What we extracted from the file, and therefore how it rides onto the
    /// turn. `excel` covers `.xlsx` only (legacy binary `.xls` is out of scope).
    enum Kind: String, Codable {
        case image
        case pdf
        case csv
        case excel
        case text
    }

    let id: UUID
    /// Original filename, shown on the chip and used in the folded `[附件 …]`
    /// delimiter so the model knows what it's reading.
    let filename: String
    let kind: Kind

    // Image payload (kind == .image).
    /// Raw base64, NO `data:` prefix — matches `LLMImage.base64`.
    var imageBase64: String?
    /// e.g. "image/jpeg", "image/png".
    var mimeType: String?

    // Document payload (kind != .image).
    /// Plain text extracted from the document (capped, with a truncation note
    /// if it was clipped). Folded into the message content on send.
    var extractedText: String?

    init(id: UUID = UUID(),
         filename: String,
         kind: Kind,
         imageBase64: String? = nil,
         mimeType: String? = nil,
         extractedText: String? = nil)
    {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.imageBase64 = imageBase64
        self.mimeType = mimeType
        self.extractedText = extractedText
    }

    /// Convenience: build an image attachment from an extractor result.
    static func image(filename: String, base64: String, mimeType: String) -> ChatAttachment {
        ChatAttachment(filename: filename, kind: .image,
                       imageBase64: base64, mimeType: mimeType)
    }

    /// Convenience: build a document attachment from extracted text.
    static func document(filename: String, kind: Kind, text: String) -> ChatAttachment {
        ChatAttachment(filename: filename, kind: kind, extractedText: text)
    }

    var isImage: Bool { kind == .image }

    /// SF Symbol used on the doc chip (image chips show a thumbnail instead).
    var symbolName: String {
        switch kind {
        case .image:  return "photo"
        case .pdf:    return "doc.richtext"
        case .csv:    return "tablecells"
        case .excel:  return "tablecells"
        case .text:   return "doc.text"
        }
    }
}
