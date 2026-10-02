import ShareScaleCore
import ShareScaleHostCore
import SwiftUI

/// 初回のガイド（計画 2f-2 案 3）。主の窓の中にページとして出す（シートにしない。「接続先を追加」のシートへ続けて移れるように）。
/// 中身は `OnboardingContent`（値と操作だけ。書き出しでも使う）
struct OnboardingPanel: View {
    @ObservedObject var guide: OnboardingGuide
    @ObservedObject var host: HostPanelStore
    @ObservedObject var loginItems: LoginItemController
    let flow: OnboardingFlow
    let canAddTarget: Bool
    /// 最後の段の「接続先を追加…」（ガイドを閉じてから、主の窓が追加の窓を開く）
    let onAddTarget: () -> Void

    var body: some View {
        let running = host.panel.hostIsRunning
        OnboardingContent(page: OnboardingPage.make(flow, hostRunning: running, canAddTarget: canAddTarget,
                                                    issueCode: (host.panel.issueCodeTitle, host.panel.canIssueCode)),
                          hostSwitch: loginItems.model,
                          onChoose: { guide.choose($0) },
                          onPrimary: {
                              let atAddTarget = flow.step == .addTarget
                              if guide.next(hostRunning: running) == .finished, atAddTarget { onAddTarget() }
                          },
                          onAction: { host.perform(.issueCode) },
                          onBack: { guide.back() },
                          onLater: { guide.close() },
                          onToggleHost: { on in
                              // 画面に結び付かない Task（ページを閉じても登録の待ちを途中で捨てない）。終わったら Host の様子を読み直す（「次へ」を押せるように）
                              Task { await loginItems.setEnabled(on); host.reload() }
                          },
                          onOpenLoginItems: { loginItems.openLoginItems() })
            .onAppear { loginItems.refresh(); host.reload() }
            // 「この Mac を接続先にする」の段の間は Host の様子を読み直し続ける（Host が動いたら「次へ」を押せるように。点検 2f-2）
            .onChange(of: flow.step, initial: true) { _, step in
                if step == .hostSwitch { host.startPolling(owner: "onboarding") } else { host.stopPolling(owner: "onboarding") }
            }
            .onDisappear { host.stopPolling(owner: "onboarding") }
    }
}

/// ガイドの 1 画面（DESIGN.md「初回のガイド」）
public struct OnboardingContent: View {
    let page: OnboardingPage
    let hostSwitch: HostSwitchModel
    let onChoose: (OnboardingFlow.Goal) -> Void
    let onPrimary: () -> Void
    let onAction: () -> Void
    let onBack: () -> Void
    let onLater: () -> Void
    let onToggleHost: (Bool) -> Void
    let onOpenLoginItems: () -> Void

    public init(page: OnboardingPage, hostSwitch: HostSwitchModel, onChoose: @escaping (OnboardingFlow.Goal) -> Void, onPrimary: @escaping () -> Void,
                onAction: @escaping () -> Void, onBack: @escaping () -> Void, onLater: @escaping () -> Void, onToggleHost: @escaping (Bool) -> Void,
                onOpenLoginItems: @escaping () -> Void) {
        self.page = page; self.hostSwitch = hostSwitch; self.onChoose = onChoose; self.onPrimary = onPrimary; self.onAction = onAction
        self.onBack = onBack; self.onLater = onLater; self.onToggleHost = onToggleHost; self.onOpenLoginItems = onOpenLoginItems
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: page.title).font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let p = page.progress { Text(verbatim: p).font(.system(size: 12)).foregroundStyle(.tertiary) }
            }
            .accessibilityElement(children: .combine)
            if let l = page.lead {
                Text(verbatim: l).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !page.options.isEmpty {
                VStack(spacing: 10) { ForEach(page.options, id: \.goal) { option($0) } }
            }
            if !page.steps.isEmpty { steps }
            if page.showsHostSwitch { hostSwitchView }
            if let a = page.action {
                Button(action: onAction) { Label(a.title, systemImage: "plus.circle") }
                    .controlSize(.large)
                    .disabled(!a.enabled)
            }
            footer
        }
        .padding(20)
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 1 画面目の選択肢（図: この Mac（アクセント）と別の Mac と矢印。全体が 1 つのボタン）。
    /// VoiceOver は題名と説明を 1 つの読みにする（`Button` に読みを付けるだけ。`accessibilityElement(children: .ignore)` を重ねると、
    /// ボタンの「押す」まで消えて、VoiceOver やアクセシビリティの操作で選べなくなる。計画 2h・実機確認 A）
    private func option(_ o: OnboardingPage.Option) -> some View {
        Button { onChoose(o.goal) } label: {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    mac(o.left, OnboardingPage.thisMac, accent: true)
                    Image(systemName: o.arrow).font(.system(size: 13)).foregroundStyle(.secondary)
                    mac(o.right, OnboardingPage.otherMac, accent: false)
                }
                .frame(width: 128)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: o.title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: o.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .cardStyle()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: o.title + tr("。", ". ") + o.detail))
    }

    private func mac(_ symbol: String, _ label: String, accent: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(accent ? Color.accentColor : Color.secondary)
            Text(verbatim: label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .accessibilityHidden(true)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(page.steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(i + 1).").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                    Text(verbatim: s).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// 「この Mac を接続先にする」（設定 › この Mac の接続先 と同じスイッチ。オフにする時の確かめは設定のタブで行うので、ここではオンにするだけ）
    private var hostSwitchView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { hostSwitch.isOn }, set: { if $0 { onToggleHost(true) } })) {
                    Text(verbatim: tr("この Mac を接続先にする", "Use This Mac as a Target")).font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.switch)
                .disabled(!hostSwitch.canToggle || hostSwitch.isOn)
                if hostSwitch.busy { ProgressView().controlSize(.small) }
            }
            Text(verbatim: hostSwitch.note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if hostSwitch.needsApproval {
                Button(action: onOpenLoginItems) { Text(verbatim: tr("ログイン項目を開く…", "Open Login Items…")) }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            if let r = hostSwitch.result {
                StatusLabel(symbol: hostSwitch.resultIsError ? "exclamationmark.triangle" : "checkmark.circle", text: r,
                            color: hostSwitch.resultIsError ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let s = page.hostStatus, hostSwitch.result == nil {
                StatusLabel(symbol: "checkmark.circle", text: s, color: .green)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var footer: some View {
        HStack {
            if let b = page.back { Button(action: onBack) { Text(verbatim: b) } }
            Spacer()
            Button(action: onLater) { Text(verbatim: page.later) }.keyboardShortcut(.cancelAction)
            if let p = page.primary {
                Button(action: onPrimary) { Text(verbatim: p.title) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!p.enabled)
            }
        }
        .padding(.top, 4)
    }
}
