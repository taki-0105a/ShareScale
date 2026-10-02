import AppKit
import ShareScaleCore
import ShareScaleHostCore
import SwiftUI

// 色・余白・文字は DESIGN.md に従う（セマンティックカラーのみ・角丸 12・余白 16・境界 0.5pt・太さは regular と medium）

/// バッジ: 角丸 6、左右 8 / 上下 3、文字 11
struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(verbatim: text).font(.system(size: 11))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// カードの面（DESIGN.md「形・余白」: 角丸 12・カード背景・境界 0.5pt）
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}
extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}

/// 高さを「中の部品の理想の高さ」と上限の小さい方に固定する配置（計画 2h）。中の部品は 1 つ（`ScrollView`）。
/// `ScrollView` は理想の高さが中身の高さでも、最小の高さが 0 なので、そのまま設定のタブに置くと、窓が前のタブの高さのまま残る。
/// ここでは、どの大きさを聞かれても同じ高さを答え（最小・理想・最大が同じ）、窓がその高さになるようにする
struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let ideal = s.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// 設定のタブの入れ物（DESIGN.md「設定の窓」。計画 2h）: 高さは中身に合わせ、画面に収まる上限（`SettingsLayout.maxPaneHeight`）で止める。
/// 上限を超える分は、タブの中をスクロールする（接続元の Mac や接続先が多い時・小さい画面）。
/// `maxHeight` を渡すと上限を決め打ちにする（試験と書き出し）。渡さなければ、**この入れ物が載っている窓のある画面**の見える高さから決める
/// （`WindowScreenReader`。その窓の知らせだけを見る。窓に載る前の最初の配置だけは、キーの窓のある画面で見積もる。点検 2h）。
/// 幅は外が決める（設定の窓は `TabView` に `.frame(width: 560)`）。`ScrollView` は渡された幅いっぱいに広がり、中身はその幅で折り返す
public struct SettingsPane<Content: View>: View {
    let maxHeight: CGFloat?
    let content: Content
    /// 上限の計算に使っている画面（切り替えた直後は、小さくなる向きの知らせだけを採る。`SettingsLayout.adopt`）
    @State private var screen = SettingsLayout.PaneScreen()

    public init(maxHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight; self.content = content()
    }

    public var body: some View {
        let visible = screen.visibleHeight ?? NSScreen.main.map { Double($0.visibleFrame.height) }
        let limit = maxHeight ?? CGFloat(SettingsLayout.maxPaneHeight(visibleHeight: visible))
        let pane = CappedHeightLayout(maxHeight: limit) {
            ScrollView { content }
        }
        if maxHeight == nil {
            pane.background(WindowScreenReader { height in
                screen = SettingsLayout.adopt(height, at: ProcessInfo.processInfo.systemUptime, into: screen)
            })
        } else {
            pane
        }
    }
}

/// 自分が載っている窓のある画面の、見える高さ（メニューバーと Dock を除く）を知らせる。窓に載った時・その窓が別の画面に移った時・画面の構成が変わった時。
/// ほかの窓の知らせは見ない（`NSWindow.didChangeScreenNotification` は、その窓を相手に指定して受ける）
struct WindowScreenReader: NSViewRepresentable {
    let onChange: (Double?) -> Void
    func makeNSView(context: Context) -> ProbeView { let v = ProbeView(); v.onChange = onChange; return v }
    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.onChange = onChange }

    final class ProbeView: NSView {
        var onChange: ((Double?) -> Void)?
        private let observers = ObserverBag()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.removeAll()
            guard let window else { return }
            observers.add(forName: NSWindow.didChangeScreenNotification, object: window) { [weak self] in self?.report() }
            observers.add(forName: NSApplication.didChangeScreenParametersNotification, object: nil) { [weak self] in self?.report() }
            report()
        }

        /// 今の値を知らせる。配置の途中で画面の状態を書き換えないよう、次の番で渡す
        private func report() {
            let height = window?.screen.map { Double($0.visibleFrame.height) }
            Task { @MainActor [weak self] in self?.onChange?(height) }
        }
    }
}

/// 知らせの受け取りをまとめて持ち、捨てる時に外す
final class ObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    func add(forName name: Notification.Name, object: AnyObject?, _ handler: @escaping @MainActor @Sendable () -> Void) {
        let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in MainActor.assumeIsolated { handler() } }
        lock.withLock { tokens.append(token) }
    }
    func removeAll() {
        let old: [NSObjectProtocol] = lock.withLock { defer { tokens = [] }; return tokens }
        old.forEach { NotificationCenter.default.removeObserver($0) }
    }
    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}

/// 状態の記号と文字（色だけで示さない。DESIGN.md「状態の記号」）
struct StatusLabel: View {
    let symbol: String
    let text: String
    let color: Color
    var size: CGFloat = 12
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(verbatim: text).foregroundStyle(.secondary)
        }
        .font(.system(size: size))
        .accessibilityElement(children: .combine)
    }
}

/// 案内。注意は `exclamationmark.triangle`（orange）、お知らせは `info.circle`（secondary）。
/// 「接続先の設定…」「診断…」「詳細をコピー」を添えられる
struct NoticeView: View {
    let title: String
    let detail: String
    let isError: Bool
    var showsSettingsLink = false
    var copyableDetail: String? = nil
    var onDiagnostics: (() -> Void)? = nil
    /// 「〜の設定を開く…」（計画 2f-1 案 5。ローカルネットワークが許可されていない時など）
    var action: DiagnosticAction? = nil
    /// 開き方（既定は `openSystemSettings`。書き出しでは何もしない口に差し替える）
    var onAction: ((DiagnosticAction) -> Void)? = nil
    /// そのほかの操作（「ShareScale を終了して開き直す…」など。点検 2f-2）
    var extraAction: (title: String, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(isError ? Color.orange : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 13, weight: .medium))
                Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if let e = extraAction {
                        Button(action: e.run) { Text(verbatim: e.title) }
                    }
                    if let a = action {
                        Button { if let f = onAction { f(a) } else { openSystemSettings(a) } } label: { Text(verbatim: a.title(AppLanguage.current.host)) }
                    }
                    if showsSettingsLink {
                        SettingsLink { Text(verbatim: tr("接続先の設定…", "Target Settings…")) }
                    }
                    if let open = onDiagnostics {
                        Button(action: open) { Text(verbatim: tr("診断…", "Diagnostics…")) }
                    }
                    if let d = copyableDetail {
                        CopyButton(title: tr("詳細をコピー", "Copy Details"), text: d)
                    }
                }
                .buttonStyle(.link).font(.system(size: 12)).padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

/// コピーのボタン（「詳細をコピー」「結果をコピー」）。押すとクリップボードに書き、2 秒間「✓ コピーしました」に変わる（VoiceOver にも知らせる）。
/// 2 秒の間にもう一度押したら、最後に押してから 2 秒で戻す。コピーする内容が変わったら、すぐ元の文言に戻す
struct CopyButton: View {
    let title: String
    var symbol: String? = nil
    let text: String
    @State private var shown = false
    @State private var presses = 0

    var body: some View {
        Button {
            copyToClipboard(text)
            presses += 1
            let mine = presses
            shown = true
            announce(CopyButton.copied)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if presses == mine { shown = false }
            }
        } label: {
            if shown { Label(CopyButton.copied, systemImage: "checkmark") }
            else if let symbol { Label(title, systemImage: symbol) }
            else { Text(verbatim: title) }
        }
        .onChange(of: text) { shown = false }
    }

    static var copied: String { tr("コピーしました", "Copied") }
}

/// VoiceOver に短い知らせを読ませる（「コピーしました」など）
@MainActor func announce(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}

/// システム設定の該当の場所を開く（利用者の操作でだけ呼ぶ。候補の表と開き方は `SystemSettingsLink`）
@MainActor func openSystemSettings(_ a: DiagnosticAction) {
    SystemSettingsLink.open(a, using: SystemSettingsLink.live)
}

/// 利用者の操作（「結果をコピー」「詳細をコピー」）でだけクリップボードに書く
func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// 見る側（接続元の Mac）のクリップボードの口の本物（`changeCount` と消去だけ。中身は読まない）
public final class SystemPasteboard: PasteboardAccess {
    public init() {}
    public var changeCount: Int { NSPasteboard.general.changeCount }
    public func clearContents() { NSPasteboard.general.clearContents() }
}
