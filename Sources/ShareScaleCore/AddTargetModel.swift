import Combine
import Foundation
import ShareScaleProtocol

/// 見る側のクリップボードの口（中身は読まない。`changeCount` と消去だけ）。本物は ShareScaleUI の `SystemPasteboard`（`NSPasteboard.general`）、
/// 試験は偽物（試験で `NSPasteboard.general` に触れないため）
public protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    func clearContents()
}

/// 接続先の追加の窓の中身（`AddTargetFlow` を持ち、`PairingFlow.run` を画面に結び付かない Task で動かす。SwiftUI/AppKit に依存しない）。
/// - 入力の欄は `setTab`・`setCode`・`setAddress`・`setKey` でだけ変える（入力中だけ効く。`flow` を丸ごと書き換えさせない）
/// - 貼り付けは利用者の操作だけ（「貼り付け」ボタンの `paste`、または ⌘V で欄が書き換わった `setCode`）。その時の `changeCount` を控える
/// - 成功（確定・未確定）と保存の後にやめた時は、接続コードの欄で始めた時だけ、クリップボードがまだ控えた時のままなら消す（`ClipboardClear.shouldClear`）
/// - 進み具合（`onPhase`）は主スレッドに移して `AddTargetFlow.receive` に渡す（順が入れ替わっても戻らない）
/// - 終わったら（やめた時も）`onFinish` を呼ぶ（帳簿を読み直す。保存の後にやめた接続先は未確定のまま残るため）
@MainActor
public final class AddTargetModel: ObservableObject, Identifiable {
    public typealias Runner = @Sendable (PairingFlow.Entry, _ onPhase: @escaping @Sendable (PairingFlow.Phase) -> Void) async
        -> Result<PairingFlow.Outcome, PairingFlow.Failure>

    @Published public private(set) var flow = AddTargetFlow()
    /// 貼り付けた時の `changeCount`（貼り付けていなければ nil）
    public private(set) var changeCountAtPaste: Int?

    private let runner: Runner
    private let pasteboard: PasteboardAccess
    private let names: (PairingID) -> String?
    private let clock: () -> Int64
    private let onFinish: (Result<PairingFlow.Outcome, PairingFlow.Failure>) -> Void
    private var task: Task<Void, Never>?

    /// - `names`: 追加した接続先の表示名（帳簿から。結果の文言に使う）
    /// - `clock`: 壁時計（UNIX 秒。期限の注意に使う）
    public init(runner: @escaping Runner, pasteboard: PasteboardAccess, names: @escaping (PairingID) -> String? = { _ in nil },
                clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
                onFinish: @escaping (Result<PairingFlow.Outcome, PairingFlow.Failure>) -> Void = { _ in }) {
        self.runner = runner; self.pasteboard = pasteboard; self.names = names; self.clock = clock; self.onFinish = onFinish
    }

    /// 製品の走らせ方（`PairingFlow.run`。名乗る名前は `computerName`）
    public nonisolated static func runner(book: TargetBook, computerName: @escaping @Sendable () -> String?,
                                          settings: PairingFlow.Settings = .standard) -> Runner {
        { entry, onPhase in await PairingFlow.run(entry, book: book, computerName: computerName, onPhase: onPhase, settings: settings) }
    }

    /// 「貼り付け」ボタンで受け取った文字列（`PasteButton`。中身をこちらから読まない）。その時の `changeCount` を控える
    public func paste(_ text: String) {
        guard flow.step == .input else { return }
        flow.tab = .code
        flow.code = text
        changeCountAtPaste = pasteboard.changeCount
    }

    /// 入力の欄（入力中だけ効く。段階・試行の番号は `start`・`receive`・`finish` だけが動かす）
    public func setTab(_ tab: AddTargetFlow.Tab) { if flow.step == .input { flow.tab = tab } }
    public func setAddress(_ text: String) { if flow.step == .input { flow.address = text } }
    public func setKey(_ text: String) { if flow.step == .input { flow.key = text } }

    /// 接続コードの欄が書き換わった（⌘V を含む）。貼り付けとみなせる変更（`AddTargetFlow.looksPasted`）なら `changeCount` を控える
    /// （1 文字ずつ打った変更では控えない。クリップボードにコードが無いのに消さないため）。欄が空になれば控えを捨てる
    public func setCode(_ text: String) {
        guard flow.step == .input else { return }
        let old = flow.code
        flow.code = text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { changeCountAtPaste = nil; return }
        if AddTargetFlow.looksPasted(old: old, new: text) { changeCountAtPaste = pasteboard.changeCount }
    }

    /// 期限の注意（接続コードの `x` を自分の時計で 10 分以上過ぎている時）
    public var expiryWarning: String? { flow.expiryWarning(now: clock()) }

    /// 「追加する」
    public func start() {
        guard let (run, entry) = flow.start() else { return }
        let mark = flow.usedTab == .code ? changeCountAtPaste : nil
        let id = entry.id
        // 始めから帳簿にある id（使用済みのコードや同じキーをもう一度入れた）は、やめた時に「保存の後にやめた」と見ない
        let existed = names(id) != nil
        let runner = self.runner
        // 名乗りが終わるまで、この中身を持ち続ける（窓を閉じても `PairingFlow.run` の結末を受け取り、帳簿を読み直させるため）
        task = Task {
            let result = await runner(entry) { phase in
                Task { @MainActor in self.flow.receive(phase, run: run) }
            }
            self.finish(result, run: run, id: id, existed: existed, clipboardMark: mark)
        }
    }

    /// 「やめる」: 進行中なら取り消す（`PairingFlow.run` が戻ると `.finished(.cancelled)` になる）。入力中・終わった後は何もしない（窓を閉じるのは画面）
    public func cancel() {
        if flow.cancel() { task?.cancel() }
    }

    /// 「やり直す」
    public func retry() { flow.retry() }

    /// 進行中の名乗りが終わるまで待つ（試験・窓を閉じる前）
    public func waitUntilFinished() async { await task?.value }

    private func finish(_ result: Result<PairingFlow.Outcome, PairingFlow.Failure>, run: Int, id: PairingID, existed: Bool, clipboardMark: Int?) {
        task = nil
        var name: String?
        var saved: PairingID?
        if case let .success(o) = result { name = names(o.id) }
        // やめた時: 帳簿にその接続先が残っていれば、保存の後にやめた（承認待ちの間に押しても、取り消しが届く前に保存まで進むことがある）。
        // 始めから帳簿にあった id は、この試行で保存したものではないので除く（「追加をキャンセルしました」のまま。クリップボードも消さない）
        if case .failure(.cancelled) = result, !existed, let n = names(id) { name = n; saved = id }
        // 保存まで済んだ（成功・保存の後にやめた）なら、コードは使用済み。クリップボードがそのコードのままなら消す
        let stored: Bool = { if case .success = result { return true }; return saved != nil }()
        if stored, ClipboardClear.shouldClear(changeCountAtPaste: clipboardMark, now: pasteboard.changeCount) {
            pasteboard.clearContents()
            changeCountAtPaste = nil
        }
        flow.finish(result, run: run, name: name, saved: saved)
        onFinish(result)
    }
}
