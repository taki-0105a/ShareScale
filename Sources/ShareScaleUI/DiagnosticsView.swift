import ShareScaleCore
import ShareScaleHostCore
import SwiftUI

/// 診断の窓（`ViewerDiagnostics`）。主の窓の案内の「診断…」とメニューの「診断…」から開く
public struct DiagnosticsWindow: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var targets: ViewerTargets
    /// 引き渡し・ログイン項目の行（計画 2e-1。末尾に足す）
    @ObservedObject var distribution: DistributionStatus
    let version: String

    public init(model: ViewerModel, targets: ViewerTargets, distribution: DistributionStatus, version: String) {
        self.model = model; self.targets = targets; self.distribution = distribution; self.version = version
    }

    public var body: some View {
        let target = targets.selectedEntry
        let lines = ViewerDiagnostics.lines(target: target, state: model.state, failure: model.failure,
                                            chosen: model.displays.first.map { model.chosenMode(for: $0) }, readProblems: targets.loaded.problems.count)
            + distribution.lines
        DiagnosticsContent(targetName: target?.displayName, lines: lines, report: ViewerDiagnostics.report(lines, target: target, version: version),
                           busy: model.busy, canRecheck: model.hasTarget,
                           onRecheck: { Task { await model.refresh(force: true) } },
                           onAction: { openSystemSettings($0) })
    }
}

/// 診断の行の読み上げ（Host の診断の窓の `RowAccessibility` と同じ）
struct DiagnosticRowAccessibility: ViewModifier {
    let hasAction: Bool
    let label: String
    @ViewBuilder func body(content: Content) -> some View {
        if hasAction { content.accessibilityElement(children: .contain) }
        else { content.accessibilityElement(children: .combine).accessibilityLabel(label) }
    }
}

/// 診断の窓の中身（DESIGN.md「診断の窓」: ✓／✗／? は記号の形と文字で示し、色だけに頼らない）
public struct DiagnosticsContent: View {
    let targetName: String?
    let lines: [ViewerDiagnostics.Line]
    let report: String
    let busy: Bool
    let canRecheck: Bool
    let onRecheck: () -> Void
    /// ✗ と ? の行の「〜の設定を開く…」（計画 2f-1 案 5）
    let onAction: (DiagnosticAction) -> Void

    public init(targetName: String?, lines: [ViewerDiagnostics.Line], report: String, busy: Bool, canRecheck: Bool, onRecheck: @escaping () -> Void,
                onAction: @escaping (DiagnosticAction) -> Void = { _ in }) {
        self.targetName = targetName; self.lines = lines; self.report = report; self.busy = busy; self.canRecheck = canRecheck; self.onRecheck = onRecheck
        self.onAction = onAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: tr("診断", "Diagnostics")).font(.system(size: 15, weight: .medium))
                Text(verbatim: targetName.map { tr("接続先: \($0)", "Target: \($0)") } ?? tr("接続先: なし", "Target: none"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    if i > 0 { Divider().padding(.leading, 40) }
                    lineView(line)
                }
            }
            .cardStyle()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(action: onRecheck) { Label(tr("もう一度確認", "Check Again"), systemImage: "arrow.clockwise") }
                    .disabled(busy || !canRecheck)
                CopyButton(title: tr("結果をコピー", "Copy Results"), symbol: "doc.on.doc", text: report)
            }
            .font(.system(size: 13))
        }
        .padding(20)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func lineView(_ l: ViewerDiagnostics.Line) -> some View {
        let label = Self.markWord(l.mark) + tr("、", ", ") + l.text + (l.advice.map { tr("。", ". ") + $0 } ?? "")
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(l.mark)).foregroundStyle(Self.color(l.mark)).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: l.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Self.markWord(l.mark) + tr("、", ", ") + l.text)
                if let a = l.advice { Text(verbatim: a).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let action = l.action {
                    Button { onAction(action) } label: { Text(verbatim: action.title(AppLanguage.current.host)) }
                        .buttonStyle(.link).font(.system(size: 12)).padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // ボタンの無い行は 1 つの読みにまとめる。ボタンのある行は子を残し（押せるように）、記号の読みは文に付ける（読みを二重にしない。点検 2f-1）
        .modifier(DiagnosticRowAccessibility(hasAction: l.action != nil, label: label))
    }

    static func symbol(_ m: ViewerDiagnostics.Mark) -> String {
        switch m { case .ok: return "checkmark.circle"; case .bad: return "xmark.circle"; case .unknown: return "questionmark.circle" }
    }
    static func color(_ m: ViewerDiagnostics.Mark) -> Color {
        switch m { case .ok: return .green; case .bad: return .orange; case .unknown: return .secondary }
    }
    static func markWord(_ m: ViewerDiagnostics.Mark) -> String {
        switch m { case .ok: return tr("問題なし", "OK"); case .bad: return tr("問題あり", "Problem"); case .unknown: return tr("不明", "Unknown") }
    }
}
