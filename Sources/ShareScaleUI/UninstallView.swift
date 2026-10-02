import AppKit
import ShareScaleCore
import SwiftUI

/// 完全な削除のウインドウ（`Window(id: "uninstall")`。設定の「一般」の「ShareScale を完全に削除…」と、起動時の「Homebrew から削除されています…」の問いかけから開く）
public struct UninstallWindow: View {
    @ObservedObject var flow: UninstallFlow
    @Environment(\.dismissWindow) private var dismissWindow

    public init(flow: UninstallFlow) { self.flow = flow }

    public var body: some View {
        UninstallRunning(flow: flow, dismiss: { dismissWindow(id: WindowID.uninstall) })
            // 窓の復元などで、始めていないのに開いた時は閉じる（「取り除く」を押せる形で出さない）
            .onAppear { if flow.stage == .idle { dismissWindow(id: WindowID.uninstall) } }
            // 閉じたら: 確かめの途中は取りやめ、中止の結果は始め直せる状態に（点検 O）
            .onDisappear { flow.windowClosed() }
    }
}

/// 進み具合を読むために `Uninstaller` も見る
struct UninstallRunning: View {
    @ObservedObject var flow: UninstallFlow
    let dismiss: () -> Void

    var body: some View {
        if let u = flow.uninstaller {
            UninstallProgress(flow: flow, uninstaller: u, dismiss: dismiss)
        } else {
            UninstallContent(stage: flow.stage, items: flow.plannedItems, phase: nil, report: nil,
                             onCancel: { flow.cancel(); dismiss() }, onConfirm: { flow.confirm() }, onClose: { dismiss() }, onQuit: Self.quit)
        }
    }

    /// 取り除いた後の終了（窓の状態を残さないよう、復元の印を外してから）
    static func quit() {
        NSApp.windows.forEach { $0.isRestorable = false }
        NSApp.terminate(nil)
    }
}

struct UninstallProgress: View {
    @ObservedObject var flow: UninstallFlow
    @ObservedObject var uninstaller: Uninstaller
    let dismiss: () -> Void
    var body: some View {
        UninstallContent(stage: flow.stage, items: flow.plannedItems, phase: uninstaller.phase, report: uninstaller.report,
                         onCancel: { flow.cancel(); dismiss() }, onConfirm: { flow.confirm() },
                         onClose: { dismiss() }, onQuit: UninstallRunning.quit)
    }
}

/// 取り除きの窓の中身（値と操作だけ。書き出しでも使う。DESIGN.md「取り除きの窓」）
public struct UninstallContent: View {
    let stage: UninstallFlow.Stage
    let items: [String]
    let phase: Uninstaller.Phase?
    let report: UninstallReport?
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onClose: () -> Void
    let onQuit: () -> Void

    public init(stage: UninstallFlow.Stage, items: [String], phase: Uninstaller.Phase?, report: UninstallReport?,
                onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void, onClose: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.stage = stage; self.items = items; self.phase = phase; self.report = report
        self.onCancel = onCancel; self.onConfirm = onConfirm; self.onClose = onClose; self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch stage {
            case .idle, .confirming: confirming
            case .running: running
            case .finished: finished
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var confirming: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: tr("ShareScale を完全に削除しますか？", "Remove ShareScale Completely?")).font(.system(size: 15, weight: .medium))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(verbatim: "•").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(verbatim: item).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            Text(verbatim: tr("削除した後は、この Mac からもほかの Mac からも ShareScale を使えなくなります。もう一度使うには、インストールし直してペアリングし直してください。",
                              "After removal, ShareScale can’t be used from this Mac or others until you reinstall and pair again."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: onCancel) { Text(verbatim: tr("やめる", "Cancel")) }.keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: onConfirm) { Text(verbatim: tr("完全に削除", "Remove Completely")) }
            }
        }
    }

    private var running: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: tr("削除しています…", "Removing…")).font(.system(size: 13, weight: .medium))
                Text(verbatim: Self.phaseText(phase)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func phaseText(_ p: Uninstaller.Phase?) -> String {
        switch p {
        case .stoppingHost?: return tr("ShareScale Host を停止しています", "Stopping ShareScale Host")
        case .unpairing?: return tr("接続先に登録の解除を伝えています", "Asking targets to remove this Mac")
        case .deletingSecrets?: return tr("ペアリングの鍵を削除しています", "Deleting pairing keys")
        case .trashing?, .finished?: return tr("ゴミ箱に入れています", "Moving items to the Trash")
        case nil: return ""
        }
    }

    @ViewBuilder private var finished: some View {
        if let r = report {
            let text = r.summary
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: r.completed ? "checkmark.circle" : "exclamationmark.triangle").font(.system(size: 20))
                    .foregroundStyle(r.completed ? Color.green : Color.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: text.title).font(.system(size: 15, weight: .medium))
                    Text(verbatim: text.detail).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if let b = r.brewCommand {
                HStack {
                    Text(verbatim: b).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    CopyButton(title: tr("コピー", "Copy"), symbol: "doc.on.doc", text: b)
                }
                .padding(12)
                .cardStyle()
            }
            if let d = r.abortDetail {
                CopyButton(title: tr("詳細をコピー", "Copy Details"), text: d).buttonStyle(.link).font(.system(size: 12))
            }
            HStack {
                Spacer()
                if r.aborted != nil {
                    Button(action: onClose) { Text(verbatim: tr("閉じる", "Close")) }.keyboardShortcut(.defaultAction)
                } else {
                    Button(action: onQuit) { Text(verbatim: tr("ShareScale を終了", "Quit ShareScale")) }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
