import Foundation
import PDFKit
import TradingFloor

/// v1 `DocumentImporter` — extracts plain text from the file (PDFKit
/// for PDFs, raw decoder for CSV/TXT/MD), hands it to the configured
/// LLM with a broker-agnostic prompt, and decodes the response into
/// `ImportedTransaction` rows.
struct LLMDocumentImporter: DocumentImporter {
    let llm: any LLMProvider
    let model: String

    func extract(url: URL) async throws -> ExtractedDocument {
        let text = try Self.extractText(from: url)
        guard !text.isEmpty else {
            throw DocumentImportError.extractionFailed(
                "Couldn't read any text out of \(url.lastPathComponent).")
        }

        let request = LLMRequest(
            model: model,
            system: Self.systemPrompt,
            messages: [LLMMessage(role: .user, content: text)],
            maxTokens: 4000,
            temperature: 0.0)
        let raw: String
        do {
            raw = try await llm.complete(request)
        } catch {
            throw DocumentImportError.extractionFailed(
                "LLM call failed while extracting transactions: \(error.localizedDescription)")
        }

        let payload = try Self.decode(response: raw)
        let rows = payload.transactions.compactMap(Self.mapTransaction)
        return ExtractedDocument(
            broker: payload.broker,
            document: url.lastPathComponent,
            transactions: rows)
    }

    // MARK: - Text extraction

    private static func extractText(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else {
                throw DocumentImportError.extractionFailed(
                    "Couldn't open \(url.lastPathComponent) as a PDF.")
            }
            var parts: [String] = []
            parts.reserveCapacity(pdf.pageCount)
            for i in 0..<pdf.pageCount {
                if let s = pdf.page(at: i)?.string, !s.isEmpty {
                    parts.append(s)
                }
            }
            return parts.joined(separator: "\n")
        case "txt", "csv", "md", "tsv":
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        default:
            throw DocumentImportError.unsupportedFormat(
                "Importing .\(ext) files isn't supported yet — try a PDF, CSV, or plain-text statement.")
        }
    }

    // MARK: - JSON decode

    private static func decode(response: String) throws -> DTOPayload {
        let json = extractJSONObject(from: response)
        guard let data = json.data(using: .utf8) else {
            throw DocumentImportError.decodingFailed(
                "LLM response wasn't valid UTF-8.")
        }
        do {
            return try JSONDecoder().decode(DTOPayload.self, from: data)
        } catch {
            let preview = json.prefix(400)
            throw DocumentImportError.decodingFailed(
                "Couldn't parse extractor output as JSON (\(error.localizedDescription)).\nResponse preview:\n\(preview)")
        }
    }

    /// LLMs sometimes wrap JSON in ```json fences or prefix it with a
    /// short prose line, even when asked not to. Pull out the largest
    /// balanced { … } block we can find before handing it to
    /// JSONDecoder.
    private static func extractJSONObject(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = trimmed.range(of: "```json") ?? trimmed.range(of: "```") {
            let after = trimmed[fence.upperBound...]
            if let close = after.range(of: "```") {
                return String(after[..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let first = trimmed.firstIndex(of: "{") else { return trimmed }
        var depth = 0
        for idx in trimmed[first...].indices {
            switch trimmed[idx] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(trimmed[first...idx])
                }
            default: break
            }
        }
        return trimmed
    }

    // MARK: - DTO → ImportedTransaction

    private static func mapTransaction(_ dto: DTOTransaction) -> ImportedTransaction? {
        guard let date = parseDate(dto.date) else { return nil }
        guard let side = HoldingSide(rawValue: dto.side.lowercased()) else { return nil }
        let symbol = dto.symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !symbol.isEmpty else { return nil }
        guard dto.quantity > 0, dto.price > 0 else { return nil }
        return ImportedTransaction(
            externalId: dto.externalId?.trimmingCharacters(in: .whitespaces).nonEmpty,
            symbol: symbol,
            name: dto.name.trimmingCharacters(in: .whitespacesAndNewlines),
            side: side,
            date: date,
            quantity: dto.quantity,
            price: dto.price,
            currency: dto.currency.uppercased())
    }

    private static func parseDate(_ s: String) -> Date? {
        let raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let isoFormats = ["yyyy-MM-dd", "yyyy/MM/dd", "dd-MM-yyyy", "dd/MM/yyyy"]
        for fmt in isoFormats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = fmt
            if let d = f.date(from: raw) { return d }
        }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        return nil
    }

    // MARK: - DTOs

    private struct DTOPayload: Decodable {
        let broker: String
        let transactions: [DTOTransaction]
    }

    private struct DTOTransaction: Decodable {
        let externalId: String?
        let symbol: String
        let name: String
        let side: String
        let date: String
        let quantity: Double
        let price: Double
        let currency: String
    }

    // MARK: - Prompt

    static let systemPrompt: String = """
    You extract stock transactions from broker statements (PDF text).

    Rules:
      1. ONLY include equity Buy/Sell transactions. Skip cash movements,
         deposits, withdrawals, dividends, withholding tax, fees, FX
         conversions, interest, and corporate-action notices.
      2. Capture the broker-assigned transaction identifier (often
         labelled Trade ID, Order ID, Reference, Confirmation, or
         similar) as `externalId` when present. Use null when absent.
      3. Normalize:
         - Symbols to Yahoo Finance format. US listings keep their
           plain ticker (TSLA, AAPL). International listings use the
           Yahoo suffix: 00100.HK, NOVO-B.CO, RIO.L, 7203.T, 600519.SS.
           If only an instrument name is shown, infer the ticker; if
           you can't, put your best guess in `symbol` and the full
           instrument name in `name`.
         - Dates to ISO-8601 (YYYY-MM-DD).
         - European decimals (1.234,56) → 1234.56.
         - Quantity is always positive; `side` carries the direction.
      4. Identify the broker from the document header/footer
         (Saxo Bank, Interactive Brokers, Schwab, Trade Republic, …).

    Return ONLY a JSON object with this exact shape — no commentary,
    no markdown fence, no leading or trailing text:

    {
      "broker": "<detected broker name>",
      "transactions": [
        {
          "externalId": "<broker trade id or null>",
          "symbol": "TSLA",
          "name": "Tesla Inc.",
          "side": "buy",
          "date": "2026-05-26",
          "quantity": 12,
          "price": 433.26,
          "currency": "USD"
        }
      ]
    }
    """
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
