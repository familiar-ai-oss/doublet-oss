import DuetKit
import SwiftUI

/// A section label over a group of cards or rows: Exo 2 overline, with an optional trailing control.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.space8) {
            Text(title).overline()
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, DS.space4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// One row of a grouped list: a leading symbol, a title, a mono subtitle (a path, a model) and a trailing accessory.
struct ListRow<Accessory: View>: View {
    var symbol: String?
    var state: DesignState?
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: DS.space12) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(state?.color ?? .textSecondary)
                    .frame(width: DS.indent)
            }
            VStack(alignment: .leading, spacing: DS.space2) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.caption.monospaced()).foregroundStyle(.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: DS.space8)
            accessory
        }
        .frame(minHeight: 44)
        .padding(.horizontal, DS.space12)
        .contentShape(Rectangle())
    }
}

extension ListRow where Accessory == EmptyView {
    init(symbol: String? = nil, state: DesignState? = nil, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, state: state, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Rows in one card, divided by hairlines.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    row
                    if i < rows.count - 1 { Rectangle().fill(.slateLine).frame(height: 1) }
                }
            }
        }
        .background(shape.fill(.slateRaised))
        .overlay(shape.strokeBorder(.slateLine, lineWidth: 1))
        .clipShape(shape)
    }
}

/// A setting with a few choices: its name and help on the left, a segmented picker and its Default/Changed tag on the
/// right.
struct SegmentedRow<Value: Hashable>: View {
    let title: String
    var help: String?
    let options: [(Value, String)]
    let defaultValue: Value
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: DS.space12) {
            VStack(alignment: .leading, spacing: DS.space2) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.textPrimary)
                if let help { Text(help).font(.caption).foregroundStyle(.textSecondary) }
            }
            Spacer(minLength: DS.space8)
            DefaultTag(changed: selection != defaultValue)
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .frame(minHeight: 56)
        .padding(.horizontal, DS.space16)
    }
}
