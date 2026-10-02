import AppKit
import Combine
import ShareScaleHostCore
import SwiftUI

/// コードの窓。「コピー」（接続コード）と「キーをコピー」は `org.nspasteboard.ConcealedType`・`org.nspasteboard.TransientType` の印を付けて書く
/// （クリップボードの履歴に残さないため。R1 で見る側に届かなければ `concealed` を外す）。「アドレスをコピー」は秘密ではないので印を付けない
/// （`CodePresentation.clipboard`）。
/// 残り時間は 1 秒ごとに更新し、期限・取り消し・名乗りの完了で閉じる（`HostAppController` が `close()` を呼ぶ）。
/// 隠した時は中身の View を外す（1 秒ごとの `Timer.publish` を止めるため。出し直す時は新しい View を作る）
@MainActor
public final class CodeWindowController: NSObject, NSWindowDelegate {
    public static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private var panel: NSPanel?
    private let language: HostLanguage
    private let onRevoke: () -> Void
    /// 秘密（接続コード・キー）をコピーした時の `changeCount`（コードが消えた時、クリップボードがまだその時のままなら消す。中身は読まない）
    private var copiedChangeCount: Int?

    public init(language: HostLanguage, onRevoke: @escaping () -> Void) { self.language = language; self.onRevoke = onRevoke }

    public var isShown: Bool { panel?.isVisible ?? false }

    public func show(_ p: CodePresentation) {
        let panel = self.panel ?? makeFloatingPanel(title: p.title, width: 520, height: 400)
        let view = CodeView(p: p, language: language, copy: { [weak self] item in self?.copy(p, item) }, revoke: { [weak self] in self?.onRevoke() })
        panel.contentView = NSHostingView(rootView: view)
        panel.delegate = self
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    public func close() {
        panel?.orderOut(nil)
        panel?.contentView = NSView()   // 1 秒ごとの更新を止める
    }
    /// コードが消えた（名乗りの完了・期限・取り消し・終了）: クリップボードが秘密をコピーした時のままなら消す
    public func clearClipboardIfUnchanged() {
        guard let n = copiedChangeCount else { return }
        copiedChangeCount = nil
        if NSPasteboard.general.changeCount == n { NSPasteboard.general.clearContents() }
    }
    private func copy(_ p: CodePresentation, _ item: CodePresentation.Item) {
        let (text, concealed) = p.clipboard(item)
        let pb = NSPasteboard.general
        pb.clearContents()
        if concealed {
            pb.declareTypes([.string, Self.concealed, Self.transient], owner: nil)
            pb.setString(text, forType: .string)
            pb.setString("", forType: Self.concealed)
            pb.setString("", forType: Self.transient)
            copiedChangeCount = pb.changeCount
        } else {
            pb.setString(text, forType: .string)
        }
    }
    /// 閉じるボタンは隠すだけ（コードは有効なまま。メニューの「接続コードを表示」で戻る）
    public func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}

/// コードの窓の中身（書き出しでも使う）。接続コード・アドレス・キーは選択でき、それぞれにコピーのボタンがある
public struct CodeView: View {
    let p: CodePresentation
    let language: HostLanguage
    let copy: (CodePresentation.Item) -> Void
    let revoke: () -> Void
    @State private var now: Date
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(p: CodePresentation, language: HostLanguage, now: Date = Date(), copy: @escaping (CodePresentation.Item) -> Void, revoke: @escaping () -> Void) {
        self.p = p; self.language = language; self.copy = copy; self.revoke = revoke; _now = State(initialValue: now)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: p.hint).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top) {
                Text(verbatim: p.code).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                // ⌘C は選択した文字のコピーに残す（キーやアドレスを選んで ⌘C を押すと、接続コードがコピーされていた。計画 2f-1）
                CopyFeedbackButton(title: p.copy, copied: p.copied) { copy(.code) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help(p.copyHelp)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow(alignment: .firstTextBaseline) {
                    Text(verbatim: p.addressLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(verbatim: p.address).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyFeedbackButton(title: p.copyAddress, copied: p.copied, small: true) { copy(.address) }
                }
                GridRow(alignment: .top) {
                    Text(verbatim: p.keyLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                    keyGroups.frame(maxWidth: .infinity, alignment: .leading)
                    CopyFeedbackButton(title: p.copyKey, copied: p.copied, small: true) { copy(.key) }
                }
            }
            HStack {
                Text(verbatim: p.remaining(now: now, language: language)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(action: revoke) { Text(verbatim: p.revoke) }
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(tick) { now = $0 }
    }
    /// 4 文字ずつのまとまり（VoiceOver はまとまりごとに文字を 1 つずつ読む）。まとめて選択してコピーできる
    private var keyGroups: some View {
        let rows = stride(from: 0, to: p.keyGroups.count, by: 5).map { Array(p.keyGroups[$0..<min($0 + 5, p.keyGroups.count)]) }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Text(verbatim: row.joined(separator: " ")).font(.system(size: 13, design: .monospaced))
                    .accessibilityLabel(row.map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", "))
            }
        }
        .textSelection(.enabled)
    }
}

/// 押すと 2 秒間「✓ コピーしました」に変わるボタン（ShareScale の `NoticeView` の `copied` と同じ流儀）。VoiceOver にも「コピーしました」を知らせる
struct CopyFeedbackButton: View {
    let title: String
    let copied: String
    var small = false
    let action: () -> Void
    @State private var shown = false
    @State private var presses = 0

    var body: some View {
        Button {
            action()
            presses += 1
            let mine = presses
            shown = true
            announce(copied)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if presses == mine { shown = false }
            }
        } label: {
            if shown { Label(copied, systemImage: "checkmark") } else { Text(verbatim: title) }
        }
        .controlSize(small ? .small : .regular)
    }
}

/// VoiceOver に短い知らせを読ませる（「コピーしました」など）
@MainActor func announce(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}
