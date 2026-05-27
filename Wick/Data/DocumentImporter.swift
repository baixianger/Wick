import Foundation

/// What a `DocumentImporter` returns from a single file. The
/// transactions list is already filtered to equity Buy/Sell rows;
/// cash, dividends, deposits, and tax entries are stripped before
/// the result reaches the store.
struct ExtractedDocument: Hashable {
    let broker: String
    /// Display name of the source document (typically the file's
    /// `lastPathComponent`). Stored on the resulting `Holding.source`
    /// so the user can audit which file produced which row.
    let document: String
    let transactions: [ImportedTransaction]
}

/// Surface used by `WickerView` and the import sheet to turn a broker
/// statement on disk into a structured batch of transactions. Designed
/// to be format-pluggable: the v1 implementation (`LLMDocumentImporter`)
/// covers PDF/text via an LLM; later implementations can plug in for
/// CSV, Excel, image OCR, or broker-specific parsers without touching
/// the call sites.
protocol DocumentImporter {
    func extract(url: URL) async throws -> ExtractedDocument
}

enum DocumentImportError: LocalizedError {
    case unsupportedFormat(String)
    case extractionFailed(String)
    case decodingFailed(String)
    case providerUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let msg):  return msg
        case .extractionFailed(let msg):   return msg
        case .decodingFailed(let msg):     return msg
        case .providerUnavailable:
            return "No LLM provider is configured. Set one up in Settings before importing documents."
        }
    }
}
