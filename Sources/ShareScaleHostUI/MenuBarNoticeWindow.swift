import AppKit
import ShareScaleHostCore
import SwiftUI

/// 初回の起動で出す「メニューバーで動作しています」の小さな窓（前面の `NSPanel`）。
/// メニューバーの記号が画面上部の切り欠きに隠れて見つからないことがあるため（実機確認 2026-09-30）、ShareScale の設定から操作できることを知らせる。
/// 出すかどうかは `HostAppController` が `HostPreferences.menuBarNoticeShown` で決める（出したら真にして保存する）
@MainActor
public final class MenuBarNoticeWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let language: HostLanguage

    public init(language: HostLanguage) { self.language = language }

    public func show() {
        let p = MenuBarNoticePresentation(language: language)
        let panel = self.panel ?? makeFloatingPanel(title: p.windowTitle, width: 400, height: 170)
        let host = NSHostingView(rootView: MenuBarNoticeView(p: p, close: { [weak self] in self?.close() }))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)   // 文が長くなった（点検 2f-2）ので、高さは中身に合わせる
        panel.delegate = self
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    public func close() { panel?.orderOut(nil) }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}

/// 初回の知らせの中身（書き出しでも使う）
public struct MenuBarNoticeView: View {
    let p: MenuBarNoticePresentation
    let close: () -> Void
    public init(p: MenuBarNoticePresentation, close: @escaping () -> Void) { self.p = p; self.close = close }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "menubar.rectangle").font(.system(size: 28)).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: p.title).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: p.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer()
                Button(action: close) { Text(verbatim: p.close) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
