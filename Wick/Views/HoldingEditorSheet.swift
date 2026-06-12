import SwiftUI
import CoreCharts
import DataAdapters

struct HoldingEditorSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(LiveDataStore.self) private var data

    let mode: Mode
    let onSave: (Holding) -> Void

    enum Mode {
        case add
        case edit(Holding)
    }

    @State private var symbol: String = ""
    @State private var name: String = ""
    @State private var side: HoldingSide = .buy
    @State private var dateMode: DateMode = .auto
    @State private var manualDate: Date = Date()
    @State private var quantityText: String = ""
    @State private var priceText: String = ""
    @State private var currency: String = "USD"
    @State private var existingId: UUID?

    enum DateMode: Hashable {
        case auto
        case manual
    }

    @State private var searchResults: [YahooSearchResult] = []
    @State private var searchQuery: String = ""
    @State private var searching: Bool = false
    private let searchAdapter = YahooSearchAdapter()

    private var canSave: Bool {
        !symbol.trimmingCharacters(in: .whitespaces).isEmpty
        && (Double(quantityText) ?? 0) > 0
        && (Double(priceText) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Symbol") {
                    HStack {
                        TextField("e.g. AAPL", text: $symbol)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: symbol) { _, new in
                                searchQuery = new.trimmingCharacters(in: .whitespaces)
                            }
                        if !name.isEmpty {
                            Text(name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if !searchResults.isEmpty {
                        ForEach(searchResults.prefix(5)) { r in
                            Button {
                                applySearchPick(r)
                            } label: {
                                HStack {
                                    Text(r.symbol)
                                        .font(.system(.callout, design: .monospaced))
                                        .frame(width: 80, alignment: .leading)
                                    Text(r.displayName)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    if let ex = r.exchangeLabel {
                                        Text(ex)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Transaction") {
                    Picker("Side", selection: $side) {
                        Text("Buy").tag(HoldingSide.buy)
                        Text("Sell").tag(HoldingSide.sell)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Quantity") {
                        TextField("e.g. 10", text: $quantityText)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent(side == .buy ? String(localized: "Buy price", locale: LocaleHolder.current) : String(localized: "Sell price", locale: LocaleHolder.current)) {
                        TextField("e.g. 175.50", text: $priceText)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Currency") {
                        TextField("USD", text: $currency)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                    }
                    Picker("Date", selection: $dateMode) {
                        Text("Auto from price").tag(DateMode.auto)
                        Text("Manual").tag(DateMode.manual)
                    }
                    .pickerStyle(.segmented)
                    if dateMode == .manual {
                        DatePicker("Date",
                                   selection: $manualDate,
                                   in: ...Date(),
                                   displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    } else {
                        Text("We'll snap to the most recent 1-hour bar whose open–close body covers this price.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(titleText)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 460)
        .onAppear { preload() }
        .task(id: searchQuery) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let q = searchQuery
            guard q.count >= 1 else { searchResults = []; return }
            do {
                let r = try await searchAdapter.search(query: q)
                if !Task.isCancelled { searchResults = r }
            } catch {
                if !Task.isCancelled { searchResults = [] }
            }
        }
    }

    private var titleText: String {
        switch mode {
        case .add:   return String(localized: "Add holding", locale: LocaleHolder.current)
        case .edit:  return String(localized: "Edit holding", locale: LocaleHolder.current)
        }
    }

    private func preload() {
        if case .edit(let h) = mode {
            existingId = h.id
            symbol = h.symbol
            name = h.name
            side = h.side
            manualDate = h.date
            quantityText = String(h.quantity)
            priceText = String(h.price)
            currency = h.currency
            dateMode = .manual
        }
    }

    private func applySearchPick(_ r: YahooSearchResult) {
        symbol = r.symbol
        name = r.displayName
        searchResults = []
        searchQuery = ""
        warmHourly(for: r.symbol)
    }

    /// Kick off the 1-hour Yahoo fetch so the price-based date lookup has
    /// real bars to walk by the time the user hits Save.
    private func warmHourly(for symbol: String) {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty else { return }
        _ = data.series(for: trimmed,
                        interval: .h1,
                        fallback: CandleSeries(symbol: trimmed,
                                               interval: .h1,
                                               candles: []))
    }

    private func save() {
        let trimmedSym = symbol.uppercased().trimmingCharacters(in: .whitespaces)
        guard !trimmedSym.isEmpty,
              let q = Double(quantityText), q > 0,
              let p = Double(priceText), p > 0 else { return }
        let date: Date = {
            switch dateMode {
            case .manual:
                return manualDate
            case .auto:
                return autoDetectDate(symbol: trimmedSym, price: p)
                    ?? Date()
            }
        }()
        let holding = Holding(
            id: existingId ?? UUID(),
            symbol: trimmedSym,
            name: name.isEmpty ? trimmedSym : name,
            side: side,
            date: date,
            quantity: q,
            price: p,
            currency: currency.isEmpty ? "USD" : currency.uppercased())
        onSave(holding)
        dismiss()
    }

    /// Walk the symbol's 1-hour candles back from the most recent and
    /// return the first bar whose open–close body brackets `price`. Used
    /// when the user leaves the date on "Auto from price" — gives a
    /// best-guess timestamp without forcing them to remember the exact
    /// fill time. Returns nil if no bar's body covers the price (in
    /// which case `save` falls back to `Date()`).
    private func autoDetectDate(symbol: String, price: Double) -> Date? {
        let fallback = CandleSeries(symbol: symbol, interval: .h1, candles: [])
        let series = data.series(for: symbol, interval: .h1, fallback: fallback)
        for c in series.candles.reversed() {
            let lo = min(c.open, c.close)
            let hi = max(c.open, c.close)
            if price >= lo && price <= hi { return c.time }
        }
        return nil
    }
}
