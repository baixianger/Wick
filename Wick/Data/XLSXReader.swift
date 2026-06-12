import Foundation
import Compression

/// Minimal `.xlsx` reader. A `.xlsx` is a ZIP container of XML parts; we read it
/// WITHOUT any third-party dependency:
///   1. Parse the ZIP **end-of-central-directory** + central-directory records
///      to locate each entry, then read its local header to find the compressed
///      bytes.
///   2. Entries are STORED (method 0) or raw-DEFLATE (method 8). DEFLATE is
///      inflated via the `Compression` framework (`COMPRESSION_ZLIB`, which is
///      raw DEFLATE — no zlib header).
///   3. Parse `xl/sharedStrings.xml` (`<si><t>…</t></si>` strings),
///      `xl/workbook.xml` (sheet names), and each `xl/worksheets/sheetN.xml`
///      (`<c r=.. t=..><v>idx</v></c>` cells: `t="s"` ⇒ shared-string index,
///      `t="inlineStr"` ⇒ inline `<is><t>`, else literal `<v>`).
///   4. Render each sheet to a CSV-ish text block.
///
/// All failures degrade to `nil` (the caller substitutes a placeholder) — never
/// a crash. Pure `XMLParser` + manual byte parsing, off the main actor.
enum XLSXReader {

    /// Read `url` and render every sheet to a single text blob, or `nil` if the
    /// file can't be parsed as a valid xlsx.
    static func renderText(url: URL, charBudget: Int) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entries = ZipArchive.entries(in: data) else { return nil }

        var byName: [String: Data] = [:]
        for entry in entries {
            // Only the parts we need — avoids inflating large media blobs.
            let n = entry.name
            if n == "xl/sharedStrings.xml"
                || n == "xl/workbook.xml"
                || n.hasPrefix("xl/worksheets/")
                || n == "xl/_rels/workbook.xml.rels"
            {
                if let inflated = ZipArchive.data(for: entry, in: data) {
                    byName[n] = inflated
                }
            }
        }

        let shared = byName["xl/sharedStrings.xml"].map(parseSharedStrings) ?? []
        let sheetNames = byName["xl/workbook.xml"].map(parseSheetNames) ?? []

        // Worksheet files, sorted by their numeric suffix so sheet1, sheet2, …
        // line up with the workbook's declared order as closely as we can
        // without resolving the rels graph (good enough for display).
        let sheetFiles = byName.keys
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { sheetIndex($0) < sheetIndex($1) }

        guard !sheetFiles.isEmpty else { return nil }

        var blocks: [String] = []
        var used = 0
        for (i, file) in sheetFiles.enumerated() {
            guard let sheetData = byName[file] else { continue }
            let rows = parseSheet(sheetData, shared: shared)
            let title = i < sheetNames.count ? sheetNames[i] : sheetTitleFromFile(file)
            var block = "## 工作表：\(title)\n"
            block += rows.map { $0.joined(separator: ",") }.joined(separator: "\n")
            blocks.append(block)
            used += block.count
            if used >= charBudget { break }
        }

        guard !blocks.isEmpty else { return nil }
        let joined = blocks.joined(separator: "\n\n")
        return joined
    }

    // MARK: - sheet ordering helpers

    private static func sheetIndex(_ name: String) -> Int {
        // "xl/worksheets/sheet12.xml" → 12
        let digits = name.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? Int.max
    }
    private static func sheetTitleFromFile(_ file: String) -> String {
        (file as NSString).lastPathComponent
    }

    // MARK: - sharedStrings.xml

    /// `<sst><si><t>foo</t></si><si><r><t>a</t></r><r><t>b</t></r></si></sst>`.
    /// We concatenate all `<t>` text within each `<si>`, in order, to handle
    /// rich-text runs (`<r>`).
    private static func parseSharedStrings(_ data: Data) -> [String] {
        let delegate = SharedStringsDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    // MARK: - workbook.xml (sheet names)

    private static func parseSheetNames(_ data: Data) -> [String] {
        let delegate = WorkbookDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.names
    }

    // MARK: - worksheet sheetN.xml

    private static func parseSheet(_ data: Data, shared: [String]) -> [[String]] {
        let delegate = SheetDelegate(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }
}

// MARK: - XML delegates

private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inItem = false
    private var inText = false

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if el == "si" { inItem = true; current = "" }
        else if el == "t" && inItem { inText = true }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) {
        if inText { current += s }
    }
    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName: String?) {
        if el == "t" { inText = false }
        else if el == "si" { strings.append(current); inItem = false }
    }
}

private final class WorkbookDelegate: NSObject, XMLParserDelegate {
    var names: [String] = []
    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if el == "sheet", let name = attributes["name"] { names.append(name) }
    }
}

/// Streams `<row>`/`<c>`/`<v>` and lays cells out by their A1 column reference so
/// gaps (empty cells the file omitted) are preserved as empty CSV fields.
private final class SheetDelegate: NSObject, XMLParserDelegate {
    let shared: [String]
    var rows: [[String]] = []

    private var currentRow: [Int: String] = [:]   // col index → value
    private var maxCol = -1
    private var cellType = ""        // t attribute: "s", "str", "inlineStr", "b", ""
    private var cellCol = 0
    private var inValue = false
    private var inInlineText = false
    private var valueBuffer = ""

    init(shared: [String]) { self.shared = shared }

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        switch el {
        case "row":
            currentRow = [:]; maxCol = -1
        case "c":
            cellType = attributes["t"] ?? ""
            cellCol = Self.columnIndex(fromRef: attributes["r"] ?? "")
            valueBuffer = ""
        case "v":
            inValue = true; valueBuffer = ""
        case "t":
            // inline string text (<is><t>) — only capture when not a shared <v>
            if cellType == "inlineStr" { inInlineText = true; valueBuffer = "" }
        default:
            break
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) {
        if inValue || inInlineText { valueBuffer += s }
    }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch el {
        case "v":
            inValue = false
            let resolved: String
            if cellType == "s", let idx = Int(valueBuffer), idx >= 0, idx < shared.count {
                resolved = shared[idx]
            } else {
                resolved = valueBuffer
            }
            if cellCol >= 0 {
                currentRow[cellCol] = resolved
                maxCol = max(maxCol, cellCol)
            }
        case "t":
            if inInlineText {
                inInlineText = false
                if cellCol >= 0 {
                    currentRow[cellCol] = valueBuffer
                    maxCol = max(maxCol, cellCol)
                }
            }
        case "row":
            guard maxCol >= 0 else { rows.append([]); return }
            var line: [String] = []
            line.reserveCapacity(maxCol + 1)
            for c in 0...maxCol {
                line.append(escape(currentRow[c] ?? ""))
            }
            rows.append(line)
        default:
            break
        }
    }

    /// CSV-escape a field: quote when it contains comma / quote / newline.
    private func escape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// "B7" → 1, "AA10" → 26. Parses the leading letters of an A1 reference.
    static func columnIndex(fromRef ref: String) -> Int {
        var col = 0
        var sawLetter = false
        for ch in ref.uppercased() {
            guard let ascii = ch.asciiValue, ascii >= 65, ascii <= 90 else { break }
            sawLetter = true
            col = col * 26 + Int(ascii - 64)   // A=1
        }
        return sawLetter ? col - 1 : -1        // 0-based; -1 if no column letters
    }
}

// MARK: - Minimal ZIP archive reader

/// Just enough of the ZIP format to enumerate entries and inflate STORED /
/// DEFLATE members. Reads the End-Of-Central-Directory record, walks the
/// central directory, then for each entry reads its local-file-header to skip
/// to the compressed payload.
enum ZipArchive {

    struct Entry {
        let name: String
        let compressionMethod: UInt16   // 0 = stored, 8 = deflate
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    // Little-endian readers.
    private static func u16(_ d: Data, _ i: Int) -> UInt16 {
        guard i + 1 < d.count else { return 0 }
        return UInt16(d[d.startIndex + i]) | (UInt16(d[d.startIndex + i + 1]) << 8)
    }
    private static func u32(_ d: Data, _ i: Int) -> UInt32 {
        guard i + 3 < d.count else { return 0 }
        let b = d.startIndex
        return UInt32(d[b + i]) | (UInt32(d[b + i + 1]) << 8)
            | (UInt32(d[b + i + 2]) << 16) | (UInt32(d[b + i + 3]) << 24)
    }

    /// Enumerate central-directory entries. Returns nil if the EOCD signature
    /// isn't found (not a valid ZIP).
    static func entries(in data: Data) -> [Entry]? {
        let eocdSig: UInt32 = 0x0605_4B50
        let cenSig: UInt32 = 0x0201_4B50

        // EOCD is at the end, within the last 64KB (+22 byte record). Scan back.
        let minEOCD = 22
        guard data.count >= minEOCD else { return nil }
        var eocd = -1
        let scanStart = max(0, data.count - (65_536 + minEOCD))
        var i = data.count - minEOCD
        while i >= scanStart {
            if u32(data, i) == eocdSig { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }

        let entryCount = Int(u16(data, eocd + 10))
        var cdOffset = Int(u32(data, eocd + 16))
        guard cdOffset >= 0, cdOffset < data.count else { return nil }

        var result: [Entry] = []
        result.reserveCapacity(entryCount)
        var off = cdOffset
        for _ in 0..<entryCount {
            guard off + 46 <= data.count, u32(data, off) == cenSig else { break }
            let method = u16(data, off + 10)
            let compSize = Int(u32(data, off + 20))
            let uncompSize = Int(u32(data, off + 24))
            let nameLen = Int(u16(data, off + 28))
            let extraLen = Int(u16(data, off + 30))
            let commentLen = Int(u16(data, off + 32))
            let localOffset = Int(u32(data, off + 42))
            let nameStart = off + 46
            guard nameStart + nameLen <= data.count else { break }
            let nameData = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            result.append(Entry(name: name,
                                compressionMethod: method,
                                compressedSize: compSize,
                                uncompressedSize: uncompSize,
                                localHeaderOffset: localOffset))
            off = nameStart + nameLen + extraLen + commentLen
            _ = cdOffset  // silence
        }
        return result
    }

    /// Read + inflate one entry's bytes. Resolves the local header (whose
    /// name/extra lengths can differ from the central directory) to find the
    /// real payload offset.
    static func data(for entry: Entry, in data: Data) -> Data? {
        let lfhSig: UInt32 = 0x0403_4B50
        let lo = entry.localHeaderOffset
        guard lo + 30 <= data.count, u32(data, lo) == lfhSig else { return nil }
        let nameLen = Int(u16(data, lo + 26))
        let extraLen = Int(u16(data, lo + 28))
        let payloadStart = lo + 30 + nameLen + extraLen
        guard payloadStart + entry.compressedSize <= data.count else { return nil }
        let b = data.startIndex
        let payload = data.subdata(in: (b + payloadStart)..<(b + payloadStart + entry.compressedSize))

        switch entry.compressionMethod {
        case 0:   // stored
            return payload
        case 8:   // raw DEFLATE
            return inflate(payload, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    /// Inflate raw DEFLATE bytes via `compression_decode_buffer` with the ZLIB
    /// algorithm (which, in Apple's Compression framework, is *raw* DEFLATE —
    /// no zlib 2-byte header, matching ZIP method 8).
    private static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        // Generous output cap: trust the declared size, but allow a floor so a
        // zero/garbage declared size still gets a working buffer, and grow if
        // the first pass fills the buffer exactly.
        var capacity = max(expectedSize, input.count * 4, 64 * 1024)
        for _ in 0..<6 {
            let result: Data? = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return nil }
                let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
                defer { dst.deallocate() }
                let written = compression_decode_buffer(
                    dst, capacity,
                    srcBase, input.count,
                    nil, COMPRESSION_ZLIB)
                guard written > 0 else { return nil }
                // If it filled the buffer exactly, we may have truncated — retry
                // bigger (signalled by returning nil from this closure).
                if written == capacity && expectedSize == 0 { return nil }
                return Data(bytes: dst, count: written)
            }
            if let result { return result }
            capacity *= 2
        }
        return nil
    }
}
