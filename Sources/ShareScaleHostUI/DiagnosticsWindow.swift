import AppKit
import Combine
import ShareScaleHostCore
import SwiftUI

/// 診断の窓（`DiagnosticsReport.items` を並べるだけ。「結果をコピー」は同じ行をクリップボードへ（押すと 2 秒間「コピーしました」）。
/// 「もう一度確認」は `reload` を呼ぶ。✗ と ? の行に対処の操作があれば「〜の設定を開く…」（計画 2f-1 案 5。`SystemSettingsLink`）。
/// `show` は出して前面に、`update` は出ている窓の中身を書き直すだけ（前面には出さない）
@MainActor
public final class DiagnosticsWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let language: HostLanguage
    private let reload: () -> Void
    private let opener: SystemSettingsOpening
    private let content = HostDiagnosticsContent()

    public init(language: HostLanguage, opener: SystemSettingsOpening = SystemSettingsLink.live, reload: @escaping () -> Void) {
        self.language = language; self.opener = opener; self.reload = reload
    }

    public func show(_ items: [DiagnosticsReport.Item]) {
        let panel = self.panel ?? make()
        update(items)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// 中身だけを書き直す（出ていなければ何もしない）
    public func update(_ items: [DiagnosticsReport.Item]) {
        guard panel != nil else { return }
        content.items = items
    }
    public var isShown: Bool { panel?.isVisible ?? false }

    private func make() -> NSPanel {
        let panel = makeFloatingPanel(title: language.t("診断", "Diagnostics"), width: 560, height: 460)
        let opener = opener
        let view = HostDiagnosticsView(content: content, language: language,
                                       onAction: { SystemSettingsLink.open($0, using: opener) },
                                       onReload: { [weak self] in self?.reload() },
                                       copy: { text in
                                           let pb = NSPasteboard.general
                                           pb.clearContents()
                                           pb.setString(text, forType: .string)
                                       })
        panel.contentView = NSHostingView(rootView: view)
        panel.delegate = self
        self.panel = panel
        return panel
    }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { panel?.orderOut(nil); return false }
}

/// 窓の中身の行（窓を出したまま書き直すための入れ物）
@MainActor
public final class HostDiagnosticsContent: ObservableObject {
    @Published public var items: [DiagnosticsReport.Item]
    public init(items: [DiagnosticsReport.Item] = []) { self.items = items }
}

/// 診断の窓の中身（書き出しでも使う。DESIGN.md「診断の窓」と同じ形: 1 枚のカードに ✓／✗／? の記号と文を並べ、色だけに頼らない）
public struct HostDiagnosticsView: View {
    @ObservedObject var content: HostDiagnosticsContent
    let language: HostLanguage
    let onAction: (DiagnosticAction) -> Void
    let onReload: () -> Void
    let copy: (String) -> Void
    /// 確認の行と一覧をスクロールに入れるか（書き出しは偽にして中身を描く。`ImageRenderer` はスクロールの中身を描かないため）
    let scrolls: Bool
    /// 確認の行と一覧の中身の高さ（測った値。スクロールの高さを中身に合わせ、上限で止める）
    @State private var listHeight: CGFloat = 0

    public init(content: HostDiagnosticsContent, language: HostLanguage, onAction: @escaping (DiagnosticAction) -> Void,
                onReload: @escaping () -> Void, copy: @escaping (String) -> Void, scrolls: Bool = true) {
        self.content = content; self.language = language; self.onAction = onAction; self.onReload = onReload; self.copy = copy
        self.scrolls = scrolls
    }

    /// 確認の行と一覧の高さの上限: 画面の見える高さの 70% と 560 の小さい方（ボタンの行は外に固定。接続元の Mac が多い時もボタンに届くように。
    /// 行の数で切り替える形をやめ、常にスクロールに入れて高さを中身に合わせる。点検 2f-1 の再点検）
    @MainActor static var maxListHeight: CGFloat {
        min((NSScreen.main?.visibleFrame.height ?? 800) * 0.7, 560)
    }

    public var body: some View {
        let items = content.items
        let header = items.filter { $0.section == .header }       // 版
        let checks = items.filter { $0.section == .check }        // 確認の行
        let viewers = items.filter { $0.section == .viewers }     // 接続元の Mac の一覧
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(header.enumerated()), id: \.offset) { _, i in
                Text(verbatim: i.text).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if scrolls {
                ScrollView {
                    lists(checks, viewers).padding(.trailing, 12)
                        .background(GeometryReader { g in Color.clear.preference(key: ListHeightKey.self, value: g.size.height) })
                }
                .frame(height: listHeight > 0 ? min(listHeight, Self.maxListHeight) : Self.maxListHeight)
                .onPreferenceChange(ListHeightKey.self) { h in listHeight = h }
            } else {
                lists(checks, viewers)
            }
            HStack {
                Button(action: onReload) { Label(language.t("もう一度確認", "Check Again"), systemImage: "arrow.clockwise") }
                Spacer()
                CopyFeedbackButton(title: language.t("結果をコピー", "Copy Results"), copied: language.t("コピーしました", "Copied")) {
                    copy(items.map(\.line).joined(separator: "\n"))
                }
            }
            .font(.system(size: 13))
        }
        .padding(20)
        .frame(width: 560, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 確認の行（カード）と接続元の Mac の一覧
    private func lists(_ checks: [DiagnosticsReport.Item], _ viewers: [DiagnosticsReport.Item]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(checks.enumerated()), id: \.offset) { n, i in
                    if n > 0 { Divider().padding(.leading, 40) }
                    row(i)
                }
            }
            .cardStyle()
            if !viewers.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(viewers.enumerated()), id: \.offset) { _, i in
                        Text(verbatim: i.text.trimmingCharacters(in: .whitespaces)).font(.system(size: 12))
                            .foregroundStyle(i.text.hasPrefix(" ") ? .secondary : .primary)
                            .padding(.leading, i.text.hasPrefix(" ") ? 12 : 0)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// 1 行。ボタンの無い行は 1 つの読みにまとめ（「問題あり、<文>」）、ボタンのある行は子を残して文にだけ記号の読みを付ける（読みを二重にしない。見る側の診断の窓と同じ）
    private func row(_ i: DiagnosticsReport.Item) -> some View {
        let label = Self.markWord(i.mark, language) + language.t("、", ", ") + i.text
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(i.mark)).foregroundStyle(Self.color(i.mark)).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: i.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityLabel(label)
                if let a = i.action {
                    Button { onAction(a) } label: { Text(verbatim: a.title(language)) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RowAccessibility(hasAction: i.action != nil, label: label))
    }

    static func symbol(_ m: DiagnosticsReport.Item.Mark?) -> String {
        switch m { case .ok?: return "checkmark.circle"; case .bad?: return "xmark.circle"; case .unknown?, nil: return "questionmark.circle" }
    }
    static func color(_ m: DiagnosticsReport.Item.Mark?) -> Color {
        switch m { case .ok?: return .green; case .bad?: return .orange; case .unknown?, nil: return .secondary }
    }
    static func markWord(_ m: DiagnosticsReport.Item.Mark?, _ L: HostLanguage) -> String {
        switch m { case .ok?: return L.t("問題なし", "OK"); case .bad?: return L.t("問題あり", "Problem"); case .unknown?, nil: return L.t("不明", "Unknown") }
    }
}

/// 確認の行と一覧の中身の高さ（スクロールの高さを合わせるため）
struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 行の読み上げ: ボタンの無い行は 1 つの読みにまとめ、ボタンのある行は子を残す（ボタンを押せるように。文の読みは文そのものに付けてある）
struct RowAccessibility: ViewModifier {
    let hasAction: Bool
    let label: String
    @ViewBuilder func body(content: Content) -> some View {
        if hasAction { content.accessibilityElement(children: .contain) }
        else { content.accessibilityElement(children: .combine).accessibilityLabel(label) }
    }
}

/// カードの面（ShareScaleUI の `cardStyle` と同じ。角丸 12・カード背景・境界 0.5pt）。
/// ShareScaleHostUI は ShareScaleUI に依存しない（Host は見る側の画面を持たない）ため、この 1 つだけを Host の側に置く（ほかの Host の窓はカードを使わない）
extension View {
    func cardStyle() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}
