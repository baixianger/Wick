import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Compression

/// App-side extraction pipeline that turns a dropped/picked file URL into a
/// `ChatAttachment`. This is the macOS-only counterpart to Phase A's
/// Foundation-only `LLMImage`: AppKit / PDFKit / ImageIO / Compression all
/// live here, NEVER in the `TradingFloor` package (which stays Linux-clean).
///
/// - **Images** → downscaled to ≤1568px longest side (the Anthropic/most-vision
///   sweet spot), re-encoded JPEG q≈0.8 (PNG when alpha matters), base64.
/// - **PDF**    → PDFKit page text, concatenated, capped.
/// - **CSV / text** → UTF-8 string, capped.
/// - **xlsx**   → minimal ZIP + raw-DEFLATE reader (Compression) → sharedStrings
///   + per-sheet cells → CSV-ish text. Degrades to a placeholder on failure.
///
/// All work runs off the main actor (the type is plain `enum` with `static`
/// async fns); no force-unwraps; every path returns a value (a placeholder
/// rather than throwing) so a malformed file can never crash the composer.
enum AttachmentExtractor {

    /// Total character budget for any single extracted document. Vision images
    /// are sized separately (by pixels). 50k chars ≈ a large statement; beyond
    /// that we truncate with a visible note so the model knows it's partial.
    static let textBudget = 50_000

    /// Longest-side pixel cap for vision images.
    static let imageMaxDimension: CGFloat = 1568

    enum ExtractError: Error, LocalizedError {
        case unreadable(String)
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let f):   return "无法读取文件：\(f)"
            case .unsupported(let f):  return "不支持的文件类型：\(f)"
            }
        }
    }

    // MARK: - Entry point

    /// Classify `url` by UTType / extension and run the matching extractor.
    /// Throws only for a genuinely unreadable/unsupported file; partial or
    /// best-effort results (truncation, xlsx parse failure) come back as a
    /// populated `ChatAttachment` instead.
    static func extract(url: URL) async throws -> ChatAttachment {
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let uti = UTType(filenameExtension: ext)

        // Image branch — anything that conforms to public.image, plus the
        // common explicit extensions in case UTType resolution is fuzzy.
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"]
        if imageExts.contains(ext) || (uti?.conforms(to: .image) ?? false) {
            return try await extractImage(url: url, filename: filename)
        }

        if ext == "pdf" || (uti?.conforms(to: .pdf) ?? false) {
            return try await extractPDF(url: url, filename: filename)
        }

        if ext == "xlsx" {
            return await extractXLSX(url: url, filename: filename)
        }

        // CSV / TSV / plain text / anything text-conforming.
        let textExts: Set<String> = ["csv", "tsv", "txt", "text", "md", "json", "log"]
        if textExts.contains(ext) || (uti?.conforms(to: .text) ?? false) {
            let kind: ChatAttachment.Kind = (ext == "csv" || ext == "tsv") ? .csv : .text
            return try await extractText(url: url, filename: filename, kind: kind)
        }

        // Last resort: try to read it as UTF-8 text; if that fails, give up.
        if let attachment = try? await extractText(url: url, filename: filename, kind: .text) {
            return attachment
        }
        throw ExtractError.unsupported(filename)
    }

    // MARK: - Image

    /// Load via ImageIO, downscale the longest side to `imageMaxDimension`, and
    /// re-encode. JPEG q0.8 for opaque images (smaller); PNG when the source has
    /// an alpha channel (preserve transparency). Returns base64 + mimeType.
    static func extractImage(url: URL, filename: String) async throws -> ChatAttachment {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ExtractError.unreadable(filename) }

        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0
        else { throw ExtractError.unreadable(filename) }

        // Thumbnail transform does the decode + downscale in one pass, honoring
        // EXIF orientation, capped at the longest side.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: imageMaxDimension,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ExtractError.unreadable(filename)
        }

        let hasAlpha: Bool = {
            switch cg.alphaInfo {
            case .first, .last, .premultipliedFirst, .premultipliedLast: return true
            default: return false
            }
        }()

        let (encoded, mime): (Data, String)
        if hasAlpha, let png = encode(cg, as: .png, quality: 1.0) {
            (encoded, mime) = (png, "image/png")
        } else if let jpeg = encode(cg, as: .jpeg, quality: 0.8) {
            (encoded, mime) = (jpeg, "image/jpeg")
        } else if let png = encode(cg, as: .png, quality: 1.0) {
            (encoded, mime) = (png, "image/png")
        } else {
            throw ExtractError.unreadable(filename)
        }

        return .image(filename: filename,
                      base64: encoded.base64EncodedString(),
                      mimeType: mime)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, type.identifier as CFString, 1, nil)
        else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - PDF

    static func extractPDF(url: URL, filename: String) async throws -> ChatAttachment {
        guard let doc = PDFDocument(url: url) else {
            throw ExtractError.unreadable(filename)
        }
        var text = ""
        let pageCount = doc.pageCount
        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let s = page.string, !s.isEmpty {
                text += "\n--- 第 \(i + 1) 页 ---\n"
                text += s
            }
            if text.count >= textBudget { break }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty
            ? "[PDF 无可提取文本（可能为扫描件 / 纯图片）：\(filename)]"
            : cap(trimmed)
        return .document(filename: filename, kind: .pdf, text: body)
    }

    // MARK: - xlsx

    /// Best-effort `.xlsx` → CSV-ish text. On any parse failure we degrade to a
    /// placeholder string (never throw / crash) so a malformed workbook still
    /// produces a benign attachment.
    static func extractXLSX(url: URL, filename: String) async -> ChatAttachment {
        if let rendered = XLSXReader.renderText(url: url, charBudget: textBudget) {
            return .document(filename: filename, kind: .excel, text: cap(rendered))
        }
        return .document(filename: filename, kind: .excel,
                         text: "[无法解析的 Excel 文件：\(filename)]")
    }

    // MARK: - CSV / text

    static func extractText(url: URL, filename: String, kind: ChatAttachment.Kind) async throws -> ChatAttachment {
        let raw: String
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            raw = s
        } else if let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: .isoLatin1) {
            raw = s
        } else {
            throw ExtractError.unreadable(filename)
        }
        return .document(filename: filename, kind: kind, text: cap(raw))
    }

    // MARK: - Helpers

    /// Cap a string to `textBudget`, appending a visible truncation note so the
    /// model knows the content is partial.
    static func cap(_ s: String) -> String {
        guard s.count > textBudget else { return s }
        let head = String(s.prefix(textBudget))
        return head + "\n\n[… 内容过长，已截断（共 \(s.count) 字符，保留前 \(textBudget) 字符）…]"
    }
}
