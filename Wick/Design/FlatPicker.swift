import SwiftUI

/// Apple-Stocks-style row of flat text pickers. Each item is rendered as
/// plain text; only the selected one gets a subtle filled capsule behind
/// it. Generic over any `Identifiable` + `Hashable` + `RawRepresentable`
/// enum whose raw value is a `String` — the raw value is the visible
/// label.
struct FlatPicker<Item: Hashable & Identifiable & RawRepresentable>: View
    where Item.RawValue == String
{
    let items: [Item]
    @Binding var selection: Item
    var font: Font = .system(size: 12, weight: .semibold, design: .rounded)
    /// Visible label for each item. Defaults to the raw value (the original
    /// behavior); pass a closure to localize (e.g. `{ $0.label }`) without
    /// touching the persisted raw value.
    var label: (Item) -> String = { $0.rawValue }
    /// `.fill` stretches each pill to share the available width equally
    /// (the screenshot-style row across a wide pane). `.compact` packs
    /// items to natural intrinsic width and left-aligns them with a
    /// trailing spacer.
    var layout: Layout = .fill

    enum Layout { case fill, compact }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    withAnimation(.snappy(duration: 0.18)) { selection = item }
                } label: {
                    // Background is applied to the *padded text* — not to
                    // the outer frame — so the selection capsule hugs the
                    // label width even when items spread evenly across
                    // the picker (Apple Stocks style).
                    Text(label(item))
                        .font(font)
                        .foregroundStyle(selection == item ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            if selection == item {
                                Capsule().fill(Color.primary.opacity(0.10))
                            }
                        }
                        .frame(maxWidth: layout == .fill ? .infinity : nil)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if layout == .compact { Spacer(minLength: 0) }
        }
    }
}
