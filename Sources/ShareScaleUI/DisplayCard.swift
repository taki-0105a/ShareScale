import ShareScaleCore
import SwiftUI

/// ディスプレイのカード（DESIGN.md「形・余白」）。
/// 処理中（`busy`）は押せず、無効の見た目（不透明度 0.55）にする（2d-1「2d-2 への注記」: いま送っていることが分かるように）
struct DisplayCard: View {
    let display: LocalDisplay
    let chosen: DisplayMode
    let settingText: String
    /// 値の横の注記（「（接続後に適用）」。ふつうの字 12・secondary）
    var settingNote: String? = nil
    let active: Bool
    let badge: ViewerModel.CardBadge
    let accessibilityLabel: String
    let busy: Bool
    let onApply: () -> Void
    let onChoose: (DisplayMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 本体：押すと、このディスプレイ用に選んである倍率を適用する
            Button(action: onApply) { main }
                .buttonStyle(.plain)
                .disabled(busy)
                .help(tr("このディスプレイで見る時の設定（\(chosen.rawValue)）を適用します", "Apply this display’s setting (\(chosen.rawValue))"))
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(tr("クリックすると、この設定を適用します", "Applies this setting"))
            // 下端の行：倍率の切り替え。本体のボタンの中に入れるとクリックが外側に吸われるので、独立した行にする
            scaleRow
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(active ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: active ? 2 : 0.5))
        .opacity(busy ? 0.55 : 1)
        .animation(.easeOut(duration: 0.15), value: busy)
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: display.symbol).font(.system(size: 20))
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Spacer()
                switch badge {
                case .applied: Badge(text: tr("適用中", "Applied"), color: .accentColor)
                case .selected: Badge(text: tr("選択中", "Selected"), color: .secondary)
                case .none: EmptyView()
                }
            }
            .padding(.bottom, 10)
            Text(verbatim: display.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Text(verbatim: "\(display.pixels) · \(display.panelLabel)")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .padding(.bottom, 12)
            Divider().padding(.bottom, 10)
            Text(verbatim: tr("適用する設定", "Setting to apply")).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: settingText).font(.system(size: 13, design: .monospaced))
                if let settingNote {
                    Text(verbatim: settingNote).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var scaleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker(tr("表示倍率", "Display scale"), selection: Binding(get: { chosen }, set: { onChoose($0) })) {
                    Text(verbatim: DataSaving.optionLabel(.x1)).tag(DisplayMode.x1)
                    Text(verbatim: DataSaving.optionLabel(.x2)).tag(DisplayMode.x2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(busy)
                .help(DataSaving.optionHelp)
                .accessibilityLabel(tr("\(jaName(display.name, "の"))表示倍率", "Display scale for \(display.name)"))
                Spacer()
            }
            savingLine
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// 通信量の目安（実測）。数字の出どころは DataSaving
    @ViewBuilder private var savingLine: some View {
        if let s = DataSaving.summary(chosen: chosen) {
            (Text(verbatim: s.lead) + Text(verbatim: s.emphasis).fontWeight(.medium) + Text(verbatim: s.trail)
             + Text(verbatim: chosen != display.recommended
                    ? tr("・推奨は \(DataSaving.optionLabel(display.recommended))", " · Suggested: \(DataSaving.optionLabel(display.recommended))") : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(DataSaving.detail)
        }
    }
}
