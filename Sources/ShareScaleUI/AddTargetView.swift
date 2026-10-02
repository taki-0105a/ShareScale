import AppKit
import ShareScaleCore
import SwiftUI

/// 「接続先を追加」を押した時の答え（アプリ本体の `makeAddTarget` が返す）
public enum AddTargetOpening {
    case open(AddTargetModel)      // 新しく開く
    case shownExisting             // 開いている追加の窓を前面に出した（同時に 1 つだけ）
    case alreadyOpen               // 開いている・進めている窓があるが、前面に出せなかった（「追加の窓はすでに開いています」）
    case unavailable               // 帳簿が使えない（ボタンは押せないはず）
}

/// 開いている追加の窓（シートの窓）の控え。2 つ目を開こうとした時に前面に出す
@MainActor
public enum AddTargetWindows {
    private final class Weak { weak var window: NSWindow?; init(_ w: NSWindow?) { window = w } }
    private static var windows: [ObjectIdentifier: Weak] = [:]

    static func register(_ model: AddTargetModel, _ window: NSWindow?) {
        windows = windows.filter { $0.value.window != nil }
        windows[ObjectIdentifier(model)] = window.map { Weak($0) }
    }

    /// その中身の窓が見えていれば、親の窓ごと前面に出して true
    public static func bringToFront(_ model: AddTargetModel) -> Bool {
        guard let w = windows[ObjectIdentifier(model)]?.window, w.isVisible else { return false }
        NSApp.activate()
        (w.sheetParent ?? w).makeKeyAndOrderFront(nil)
        w.makeKeyAndOrderFront(nil)
        return true
    }
}

/// 自分が載っている窓を知らせる（`ImageRenderer` では描けない部品なので、書き出しに使う `AddTargetForm` には入れない）
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> ReaderView { let v = ReaderView(); v.onWindow = onWindow; return v }
    func updateNSView(_ nsView: ReaderView, context: Context) {}
    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) }
    }
}

/// 接続先の追加の窓（シート）。中身は `AddTargetForm`（値と操作だけを受け取る。書き出しの試験でも使う）。
/// 入力の欄は `AddTargetModel` の setter を通す（`flow` を丸ごと書き換えない）。窓が閉じられたら（進行中でも）名乗りを取り消す
public struct AddTargetSheet: View {
    @ObservedObject var model: AddTargetModel
    @Environment(\.dismiss) private var dismiss

    public init(model: AddTargetModel) { self.model = model }

    public var body: some View {
        AddTargetForm(flow: model.flow,
                      tab: Binding(get: { model.flow.tab }, set: { model.setTab($0) }),
                      code: Binding(get: { model.flow.code }, set: { model.setCode($0) }),
                      address: Binding(get: { model.flow.address }, set: { model.setAddress($0) }),
                      key: Binding(get: { model.flow.key }, set: { model.setKey($0) }),
                      expiryWarning: model.expiryWarning,
                      onPaste: { model.paste($0) },
                      onStart: { model.start() },
                      onCancel: { model.cancel() },
                      onRetry: { model.retry() },
                      onClose: { model.cancel(); dismiss() })
            .background(WindowReader { AddTargetWindows.register(model, $0) })
            .onDisappear { model.cancel() }
    }
}

/// 接続先の追加の窓の中身（DESIGN.md「接続先の追加の窓」「確認番号の表示」）。
/// タブ「接続コード」（貼り付け欄＋「貼り付け」ボタン。自動では読まない。⌘V 可）／「手入力」（アドレス・キー。キーは 4 文字ずつの表示補助）→
/// 名乗り中 → 確認番号（大きく等幅。VoiceOver は数字を 1 つずつ）→ 確定中（n/3）→ 結果。「やめる」はいつでも
public struct AddTargetForm: View {
    let flow: AddTargetFlow
    @Binding var tab: AddTargetFlow.Tab
    @Binding var code: String
    @Binding var address: String
    @Binding var key: String
    let expiryWarning: String?
    let onPaste: (String) -> Void
    let onStart: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void

    public init(flow: AddTargetFlow, tab: Binding<AddTargetFlow.Tab>, code: Binding<String>, address: Binding<String>, key: Binding<String>,
                expiryWarning: String?, onPaste: @escaping (String) -> Void,
                onStart: @escaping () -> Void, onCancel: @escaping () -> Void, onRetry: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.flow = flow; _tab = tab; _code = code; _address = address; _key = key
        self.expiryWarning = expiryWarning; self.onPaste = onPaste
        self.onStart = onStart; self.onCancel = onCancel; self.onRetry = onRetry; self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: tr("接続先を追加", "Add Target")).font(.system(size: 15, weight: .medium))
            switch flow.step {
            case .input: input
            case let .awaitingApproval(code): approval(code)
            case .connecting, .confirming, .cancelling: progress
            case let .finished(f): result(f)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 入力

    private var input: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(tr("入力方法", "Input Method"), selection: $tab) {
                Text(verbatim: tr("接続コード", "Pairing Code")).tag(AddTargetFlow.Tab.code)
                Text(verbatim: tr("手動で入力", "Enter Manually")).tag(AddTargetFlow.Tab.manual)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if flow.tab == .code { codeInput } else { manualInput }
            if case let .invalid(reason) = flow.check {
                StatusLabel(symbol: "exclamationmark.triangle", text: reason, color: .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let w = expiryWarning {
                StatusLabel(symbol: "clock", text: w, color: .secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(action: onClose) { Text(verbatim: tr("キャンセル", "Cancel")) }.keyboardShortcut(.cancelAction)
                Button(action: onStart) { Text(verbatim: tr("追加する", "Add")) }
                    .keyboardShortcut(.defaultAction).disabled(!flow.canStart)
            }
        }
    }

    private var codeInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: tr("接続先の Mac で ShareScale Host のメニューから「接続元の Mac を追加…」を選び、表示された接続コードをここに貼り付けてください。",
                              "On the Host, choose Add a Mac to Connect From… in the ShareScale Host menu, then paste the pairing code here."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(text: $code, prompt: Text(verbatim: "sharescale1:…"), axis: .vertical) { Text(verbatim: tr("接続コード", "Pairing code")) }
                .lineLimit(3...5)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    guard let s = strings.first else { return }
                    Task { @MainActor in onPaste(s) }
                }
                .labelStyle(.titleAndIcon)
                Text(verbatim: tr("⌘V でも貼り付けられます。クリップボードの内容を自動で読み取ることはありません。", "You can also press ⌘V. The clipboard is never read automatically."))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    private var manualInput: some View {
        let preview = AddTargetText.keyPreview(flow.key)
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: tr("接続先の「接続コード」ウインドウに表示されている「アドレス」と「キー」を入力してください（キーの空白とハイフンは無視されます）。",
                              "Enter the Address and Key shown in the Pairing Code window on the Host (spaces and hyphens in the key are ignored)."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text(verbatim: tr("アドレス", "Address")).font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField(text: $address, prompt: Text(verbatim: "studio.local")) { Text(verbatim: tr("アドレス", "Address")) }
                        .font(.system(size: 13, design: .monospaced)).textFieldStyle(.roundedBorder)
                }
                GridRow(alignment: .top) {
                    Text(verbatim: tr("キー", "Key")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(text: $key, prompt: Text(verbatim: "ABCD EFGH …"), axis: .vertical) { Text(verbatim: tr("キー", "Key")) }
                            .lineLimit(2...4)
                            .font(.system(size: 13, design: .monospaced)).textFieldStyle(.roundedBorder)
                        keyPreview(preview)
                    }
                }
            }
        }
    }

    /// キーの表示補助（4 文字ずつ。VoiceOver はまとまりごとに、文字を 1 つずつ読む）
    private func keyPreview(_ p: AddTargetText.KeyPreview) -> some View {
        let rows = stride(from: 0, to: p.groups.count, by: 5).map { Array(p.groups.indices[$0..<min($0 + 5, p.groups.count)]) }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { i in
                        Text(verbatim: p.groups[i]).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                            .accessibilityLabel(p.accessibility[i])
                    }
                }
            }
            Text(verbatim: tr("\(p.count)/\(AddTargetText.keyLength) 文字", "\(p.count)/\(AddTargetText.keyLength) characters"))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    // MARK: 進行中

    private var progress: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let t = AddTargetText.progress(flow.step) {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: t.title).font(.system(size: 13, weight: .medium))
                        Text(verbatim: t.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer()
                Button(action: onCancel) { Text(verbatim: tr("キャンセル", "Cancel")) }
                    .keyboardShortcut(.cancelAction).disabled(flow.step == .cancelling)
            }
        }
    }

    /// 確認番号（DESIGN.md「確認番号の表示」: 34pt・medium・等幅、カードの中央。VoiceOver は数字を 1 つずつ）
    private func approval(_ code: Int) -> some View {
        let t = AddTargetText.progress(.awaitingApproval(code: code))
        return VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                Text(verbatim: t?.title ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(verbatim: AddTargetText.code(code))
                    .font(.system(size: 34, weight: .medium, design: .monospaced))
            }
            // VoiceOver は題名と番号を 1 つの読みにする（「確認番号 0 1 2 3 4 5」）
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AddTargetText.codeAccessibility(code))
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .cardStyle()
            HStack(alignment: .top, spacing: 10) {
                ProgressView().controlSize(.small)
                Text(verbatim: t?.detail ?? "").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(action: onCancel) { Text(verbatim: tr("キャンセル", "Cancel")) }.keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: 結果

    private func result(_ f: AddTargetFlow.Finish) -> some View {
        let r = AddTargetText.result(f)
        let ok: Bool = { if case .confirmed = f { return true }; return false }()
        let failed: Bool = { if case .failed = f { return true }; return false }()
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: ok ? "checkmark.circle" : (r.isError ? "exclamationmark.triangle" : "info.circle"))
                    .font(.system(size: 20))
                    .foregroundStyle(ok ? Color.green : (r.isError ? Color.orange : .secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: r.text.title).font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: r.text.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let d = r.copyable {
                        CopyButton(title: tr("詳細をコピー", "Copy Details"), text: d)
                            .buttonStyle(.link).font(.system(size: 12)).padding(.top, 2)
                    }
                }
                .accessibilityElement(children: .contain)
            }
            HStack {
                Spacer()
                if failed || f == .cancelled {
                    Button(action: onRetry) { Text(verbatim: tr("やり直す", "Try Again")) }
                }
                Button(action: onClose) { Text(verbatim: tr("閉じる", "Close")) }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
