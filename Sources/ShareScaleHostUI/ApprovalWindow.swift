import AppKit
import ShareScaleHostCore
import SwiftUI

/// 前面に浮かぶパネル（Host は `LSUIElement` なので、ふつうの窓は前に出ない恐れがある。R1・R2 で確かめる）
@MainActor
func makeFloatingPanel(title: String, width: CGFloat, height: CGFloat) -> NSPanel {
    let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                    styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
    p.title = title
    p.level = .floating
    p.hidesOnDeactivate = false
    p.becomesKeyOnlyIfNeeded = false
    p.isReleasedWhenClosed = false
    p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    p.center()
    return p
}

/// 確認の窓（`PairingApprover` の実装）。待ち行列の論理は `ApprovalQueue`（HostCore・純粋な状態機械）にあり、ここはその指示
/// （`present`・`close`・`resume`）を 1 枚のパネルと continuation に当てるだけ。
/// - 状態の変更（待ち行列・continuation・パネル）はすべて main の同じ Task の中で行う（`requestApproval` の登録も `withdraw` も main に移してから）
/// - continuation の resume は `ApprovalQueue` が 1 つの名乗りにつき 1 回だけ出す
/// - パネルは 1 枚を使い回す。ボタンと閉じるボタンは「そのパネルに出ているもの（`presented`）」と `queue.current` の両方と照合する
/// - `requestApproval` の先頭で取り消し済みなら出さずに false。取り消しは `withTaskCancellationHandler` で `withdraw` と同じ道を通る
///   （登録より先に届いた取り消しは `ApprovalQueue.cancelledEarly` が覚える。上限 64）
public final class ApprovalWindowController: NSObject, PairingApprover, @unchecked Sendable {
    private let language: HostLanguage
    // ---- ここから下は main の中だけで触る ----
    @MainActor private var queue = ApprovalQueue()
    @MainActor private var continuations: [(ApprovalRequest, CheckedContinuation<Bool, Never>)] = []
    @MainActor private var panel: NSPanel?
    @MainActor private var presented: ApprovalRequest?

    public init(language: HostLanguage) { self.language = language }

    public func requestApproval(_ request: ApprovalRequest) async -> Bool {
        if Task.isCancelled { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                Task { @MainActor in self.enqueue(request, c) }
            }
        } onCancel: {
            Task { @MainActor in self.withdrawOnMain(request) }
        }
    }

    public func withdraw(_ request: ApprovalRequest) {
        Task { @MainActor in self.withdrawOnMain(request) }
    }

    @MainActor private func enqueue(_ r: ApprovalRequest, _ c: CheckedContinuation<Bool, Never>) {
        continuations.append((r, c))
        run(queue.enqueue(r))   // 取り消しが先に届いていれば `.resume(r, false)` だけが返る（出さない）
    }
    @MainActor private func withdrawOnMain(_ r: ApprovalRequest) {
        run(queue.withdraw(r))  // 未登録なら `ApprovalQueue` が「先に取り消された」と覚える
    }
    /// パネルの答え（「そのパネル」に出ているものと一致する時だけ。`ApprovalQueue` が `current` とも照合する）
    @MainActor private func answer(_ r: ApprovalRequest, _ ok: Bool) {
        guard presented == r else { return }
        run(queue.answer(r, ok))
    }

    @MainActor private func run(_ commands: [ApprovalQueue.Command]) {
        for c in commands {
            switch c {
            case let .resume(r, ok):
                if let i = continuations.firstIndex(where: { $0.0 == r }) {
                    let cont = continuations.remove(at: i).1
                    cont.resume(returning: ok)
                }
            case .close:
                presented = nil
                panel?.orderOut(nil)
                panel?.contentView = NSView()
            case let .present(r):
                present(r)
            }
        }
    }

    @MainActor private func present(_ r: ApprovalRequest) {
        let p = ApprovalPresentation(r, language: language)
        let panel = self.panel ?? makeFloatingPanel(title: p.windowTitle, width: 420, height: 280)
        panel.title = p.windowTitle
        let view = ApprovalView(p: p, approve: { [weak self] in self?.answer(r, true) }, decline: { [weak self] in self?.answer(r, false) })
        panel.contentView = NSHostingView(rootView: view)
        panel.delegate = self
        self.panel = panel; presented = r
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension ApprovalWindowController: NSWindowDelegate {
    /// 閉じるボタン＝「追加しない」（そのパネルに出ているものだけ）
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel, let r = presented { answer(r, false) }
        return false
    }
}

/// 確認の窓の中身（書き出しでも使う）
public struct ApprovalView: View {
    let p: ApprovalPresentation
    let approve: () -> Void
    let decline: () -> Void
    public init(p: ApprovalPresentation, approve: @escaping () -> Void, decline: @escaping () -> Void) { self.p = p; self.approve = approve; self.decline = decline }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: p.title).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if !p.source.isEmpty { Text(verbatim: p.source).font(.system(size: 12)).foregroundStyle(.secondary) }
            Text(verbatim: p.code).font(.system(size: 40, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity).accessibilityLabel(p.codeAccessibility)
            Text(verbatim: p.instruction).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: approve) { Text(verbatim: p.approve) }
                Button(action: decline) { Text(verbatim: p.decline) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
