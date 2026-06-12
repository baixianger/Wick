import SwiftUI

/// Confirmation sheet shown after `LLMDocumentImporter` extracts a
/// broker statement. Lists every transaction the importer surfaced
/// with a "new" or "duplicate" badge, lets the user toggle individual
/// rows in or out, and calls `HoldingsStore.importBatch` on confirm.
struct TransactionImportSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(HoldingsStore.self) private var holdings

    let document: ExtractedDocument
    let onImported: (ImportReport) -> Void

    @State private var rows: [Row] = []
    @State private var phase: Phase = .preview
    @State private var result: ImportReport? = nil

    enum Phase: Hashable {
        case preview
        case importing
        case done
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .toolbar { toolbar }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 600)
        .task { preview() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if phase == .preview {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("Cancel", "取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(importButtonTitle) { runImport() }
                    .disabled(selectedRows.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        } else if phase == .done {
            ToolbarItem(placement: .confirmationAction) {
                Button(L("Done", "完成")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preview:    previewView
        case .importing:  importingView
        case .done:       resultView
        }
    }

    // MARK: - Preview

    private var previewView: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            List {
                ForEach($rows) { $row in
                    rowView(for: $row)
                }
            }
            .listStyle(.inset)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(document.broker)
                    .font(.headline)
                Spacer()
                Text(document.document)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 12) {
                Label(L("\(newCount) new", "\(newCount) 条新增"), systemImage: "plus.circle.fill")
                    .foregroundStyle(.green)
                Label(L("\(duplicateCount) duplicate", "\(duplicateCount) 条重复"), systemImage: "equal.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
    }

    private func rowView(for row: Binding<Row>) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: row.included)
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    sideBadge(row.wrappedValue.preview.transaction.side)
                    Text(row.wrappedValue.preview.transaction.symbol)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(row.wrappedValue.preview.transaction.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    statusBadge(row.wrappedValue.preview)
                }
                HStack(spacing: 14) {
                    Text(quantityPriceLine(row.wrappedValue.preview.transaction))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(dateLine(row.wrappedValue.preview.transaction.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let eid = row.wrappedValue.preview.transaction.externalId {
                        Text(L("ID \(eid)", "编号 \(eid)"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if let existing = row.wrappedValue.preview.existing {
                    Text(L("matches existing \(existing.symbol) " +
                         "\(formatQuantity(existing.quantity)) @ \(formatPrice(existing.price)) " +
                         "(\(dateLine(existing.date)))",
                         "匹配已有 \(existing.symbol) " +
                         "\(formatQuantity(existing.quantity)) @ \(formatPrice(existing.price)) " +
                         "(\(dateLine(existing.date)))"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func sideBadge(_ side: HoldingSide) -> some View {
        Text(side.label)
            .font(.system(size: 9).weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(side == .buy ? Color.green.opacity(0.18)
                                            : Color.red.opacity(0.18)))
            .foregroundStyle(side == .buy ? Color.green : Color.red)
    }

    private func statusBadge(_ preview: DedupPreview) -> some View {
        let (label, color): (String, Color) = {
            guard let reason = preview.reason else { return (L("NEW", "新增"), .green) }
            switch reason {
            case .externalIdMatch: return (L("EXACT DUP", "完全重复"), .orange)
            case .fuzzyMatch:      return (L("LIKELY DUP", "疑似重复"), .yellow)
            }
        }()
        return Text(label)
            .font(.system(size: 9).weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    // MARK: - Importing / done

    private var importingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L("Importing \(selectedRows.count) transactions…", "正在导入 \(selectedRows.count) 笔交易…"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let r = result {
                Text(L("Imported \(r.newCount) transaction\(r.newCount == 1 ? "" : "s") from \(r.broker).",
                       "已从 \(r.broker) 导入 \(r.newCount) 笔交易。"))
                    .font(.headline)
                if r.skippedCount > 0 {
                    Text(L("Skipped \(r.skippedCount) duplicate\(r.skippedCount == 1 ? "" : "s").",
                           "已跳过 \(r.skippedCount) 笔重复交易。"))
                        .foregroundStyle(.secondary)
                }
                if !r.added.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(r.added) { h in
                                HStack(spacing: 8) {
                                    sideBadge(h.side)
                                    Text(h.symbol)
                                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                                        .frame(width: 80, alignment: .leading)
                                    Text("\(formatQuantity(h.quantity)) @ \(formatPrice(h.price)) \(h.currency)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(dateLine(h.date))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Actions

    private func preview() {
        let p = holdings.previewImport(document.transactions)
        rows = p.map { Row(preview: $0, included: !$0.isDuplicate) }
    }

    private func runImport() {
        phase = .importing
        let selected = selectedRows.map(\.preview.transaction)
        let report = holdings.importBatch(selected,
                                          broker: document.broker,
                                          document: document.document)
        result = report
        onImported(report)
        phase = .done
    }

    // MARK: - Helpers

    private var newCount: Int     { rows.filter { !$0.preview.isDuplicate }.count }
    private var duplicateCount: Int { rows.filter { $0.preview.isDuplicate }.count }
    private var selectedRows: [Row] { rows.filter(\.included) }
    private var importButtonTitle: String {
        let n = selectedRows.count
        return L("Import \(n) transaction\(n == 1 ? "" : "s")", "导入 \(n) 笔交易")
    }
    private var title: String {
        switch phase {
        case .preview, .importing: return L("Review transactions", "核对交易")
        case .done:                return L("Import complete", "导入完成")
        }
    }

    private func quantityPriceLine(_ tx: ImportedTransaction) -> String {
        "\(formatQuantity(tx.quantity)) @ \(formatPrice(tx.price)) \(tx.currency)"
    }
    private func dateLine(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }
    private func formatQuantity(_ q: Double) -> String {
        let nf = NumberFormatter()
        nf.maximumFractionDigits = q.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 4
        nf.minimumFractionDigits = 0
        return nf.string(from: NSNumber(value: q)) ?? "\(q)"
    }
    private func formatPrice(_ p: Double) -> String {
        let nf = NumberFormatter()
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        return nf.string(from: NSNumber(value: p)) ?? "\(p)"
    }

    struct Row: Identifiable, Hashable {
        var id: UUID { preview.id }
        var preview: DedupPreview
        var included: Bool
    }
}
