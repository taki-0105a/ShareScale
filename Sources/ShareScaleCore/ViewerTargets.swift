import Combine
import Foundation
import ShareScaleHostCore
import ShareScaleProtocol

/// 接続先の帳簿と、使う接続先（`ViewerModel` の相手）の切り替え（アプリ本体の組み立ての中で、試せる部分）。
/// - `reload` で帳簿を読み直し、使う接続先（`TargetBook.selected(in:)`）が変わった時だけ `TargetSession` を作り直して
///   `ViewerModel.updateClient` を呼び、`onSwitch`（既定は画面に結び付かない `Task { await model.refresh() }`）を呼ぶ
/// - 接続先の追加（`PairingFlow.run` が「選んだ接続先」を書く）・削除・候補の手直しの後も `reload` する
/// - 帳簿が使えない（この Mac の識別子を読めない）時は接続先なしで動き、`storeNotice` で案内する（終了しない）
@MainActor
public final class ViewerTargets: ObservableObject {
    @Published public private(set) var loaded = TargetBook.Loaded()
    /// 使っている接続先の id（無ければ nil）
    @Published public private(set) var selectedID: PairingID?
    /// 上限（32 件）に達しているか。帳簿が使えない時は偽（追加できないのは `canAdd` で分ける）
    @Published public private(set) var isFull = false

    public let book: TargetBook?
    public let model: ViewerModel
    private let connector: Connector.Settings
    private let onSwitch: (ViewerModel) -> Void
    private var session: TargetSession?
    /// 取り除いた後（帳簿を読み直さない。`pairings/viewer/` を作り直さないため。計画 2e-1 の点検 N）
    public private(set) var frozen = false

    /// - `onSwitch`: 接続先を切り替えた時に呼ぶ。nil（既定）なら画面に結び付かない `Task { await model.refresh() }` で取り直す
    ///   （2d-1「2d-2 への注記」: `.task {}` から呼ばない）。試験は取り直しを自分で呼ぶために差し替える
    public init(book: TargetBook?, model: ViewerModel, connector: Connector.Settings = .standard, onSwitch: ((ViewerModel) -> Void)? = nil) {
        self.book = book; self.model = model; self.connector = connector
        self.onSwitch = onSwitch ?? { m in Task { await m.refresh() } }
    }

    /// 使っている接続先（応答で更新された付帯情報を含む。診断・一覧に使う）
    public var selectedEntry: TargetEntry? { session?.entry }
    /// 一覧（表示名の順）
    public var rows: [TargetRow] { TargetRow.rows(loaded, selectedID: selectedID) }
    /// 「接続先を追加」を押せるか（帳簿があり、かつ上限でない）
    public var canAdd: Bool { book != nil && !isFull }
    /// 追加についての注記（押せない時はその理由。帳簿が使えない時と上限の時で文言を分ける）
    public var addNote: String {
        if book == nil {
            // 理由は上の案内（`storeNotice`）が書くので、ここでは重ねない（仕上げ 2026-09-30）
            return tr("接続先を保存できないため、今は追加できません。", "Targets can’t be added right now because they can’t be stored.")
        }
        if isFull {
            return tr("接続先が上限の \(Limits.maxPairings) 台に達しているため、追加できません。使わない接続先を削除してください。",
                      "You’ve reached the limit of \(Limits.maxPairings) targets. Delete one you don’t use to add another.")
        }
        return tr("接続先は \(Limits.maxPairings) 台まで登録できます。", "You can add up to \(Limits.maxPairings) targets.")
    }

    /// 取り除いた後: 相手を外し、以後は帳簿を読み直さない（読むと秘密のフォルダを作り直すため）
    public func freeze() {
        frozen = true
        loaded = TargetBook.Loaded(); isFull = false
        switchTo(nil)
    }

    /// 帳簿を読み直す。使う接続先が変わった時だけ相手を切り替える
    public func reload() {
        guard !frozen else { return }
        guard let book else {
            loaded = TargetBook.Loaded(); isFull = false
            if session != nil || model.hasTarget { switchTo(nil) }
            return
        }
        loaded = book.load()
        isFull = book.isFull
        let entry = book.selected(in: loaded)
        if entry?.id != session?.id || (entry == nil && model.hasTarget) { switchTo(entry) }
    }

    /// 接続先を選ぶ（主の窓の見出しのメニュー）
    public func select(_ id: PairingID) {
        guard let book, book.load().entry(id) != nil else { return }
        book.selectedID = id
        reload()
    }

    /// 接続先の追加の窓が終わった（やめた時も。保存の後にやめた接続先は未確定のまま帳簿に残る）
    public func pairingFinished(_ result: Result<PairingFlow.Outcome, PairingFlow.Failure>) { reload() }

    /// 追加した接続先の表示名（結果の文言に使う）
    public func name(of id: PairingID) -> String? { book?.load().entry(id)?.displayName }

    public enum SaveError: Error, Equatable, Sendable {
        case unavailable    // 帳簿が使えない
        case notFound       // 窓を開いている間に削除された
        case invalid        // 今の付帯情報に当てると規則に合わない
    }

    /// 候補を手で直した（`ManualCandidatesEditor.Candidates`）。帳簿の今の付帯情報を読み直し、候補・通信口・手で直した印の 3 つだけを差し替えて書く
    /// （窓を開いている間に確定・名前・前回の候補が変わっても、古い写しで上書きしない）。
    /// 使っている接続先なら相手を作り直す（`TargetSession` は候補の写しを持つため）
    public func saveCandidates(_ id: PairingID, _ candidates: ManualCandidatesEditor.Candidates) throws {
        guard let book else { throw SaveError.unavailable }
        var found = false
        try book.modify(id) { loaded in
            guard let current = loaded.entry(id)?.meta else { return nil }
            found = true
            guard let meta = candidates.applied(to: current) else { throw SaveError.invalid }
            return meta
        }
        guard found else { reload(); throw SaveError.notFound }
        loaded = book.load()
        if session?.id == id { switchTo(book.selected(in: loaded)) } else { reload() }
    }

    /// 名前を付け直した（`TargetAlias.validate` を通した値。nil なら接続先の名前に戻す）。帳簿の今の付帯情報を読み直し、名前だけを差し替えて書く。
    /// 使っている接続先なら、相手を作り直さずに見出しの名前だけを変える（状態を取り直さない。計画 2f-1 案 6）
    public func rename(_ id: PairingID, alias: String?) throws {
        guard let book else { throw SaveError.unavailable }
        var found = false
        try book.modify(id) { loaded in
            guard let current = loaded.entry(id)?.meta else { return nil }
            found = true
            guard let meta = current.withAlias(alias) else { throw SaveError.invalid }
            return meta != current ? meta : nil
        }
        guard found else { reload(); throw SaveError.notFound }
        loaded = book.load()
        if let s = session, s.id == id, let e = loaded.entry(id) {
            s.adoptAlias(alias)
            model.rename(targetLabel: e.displayName, aliased: alias != nil)
        }
    }

    /// 候補を保存できなかった時の本文（「何が起きたか＋何をすればよいか」）と、コピーできる生の理由
    public static func saveProblem(_ error: Error) -> (text: String, detail: String?) {
        switch error as? SaveError {
        case .notFound?:
            return (tr("この接続先はすでに削除されています。", "This target was already deleted."), nil)
        case .unavailable?:
            return (tr("この Mac の識別子を読み取れないため、保存できません。詳しくは「診断」で確認できます。", "Can’t save because this Mac’s identifier can’t be read. See Diagnostics for details."), nil)
        case .invalid?:
            return (ManualCandidatesEditor.message(.invalid), nil)
        case nil:
            return (tr("保存できませんでした。~/Library/Application Support/ShareScale/pairings/viewer/ のアクセス権を確認してください。",
                       "Couldn’t save. Check the permissions of ~/Library/Application Support/ShareScale/pairings/viewer/."), "\(error)")
        }
    }

    /// 削除（`unpair` を送ってから消す。届かなければこの Mac だけで消す）
    public func remove(_ id: PairingID) async -> TargetRemoval {
        guard let book else { return .failed(name: loaded.entry(id)?.displayName ?? "", reason: "the viewer book is unavailable") }
        guard let e = book.load().entry(id) else { reload(); return .alreadyRemoved }
        let s = (session?.id == id ? session : nil) ?? TargetSession(book: book, entry: e, settings: connector)
        let name = e.displayName
        do {
            let r = try await s.remove()
            reload()
            return r == .removed ? .removed(name: name) : .removedLocally(name: name)
        } catch {
            reload()
            return .failed(name: name, reason: "\(error)")
        }
    }

    /// 帳簿の問題の案内（使えない・読めないファイルがある）。主の窓で `ViewerModel.notice` が無い時に出す
    public var storeNotice: ViewerNotice.Text? {
        if book == nil {
            return ViewerNotice.Text(tr("接続先を保存できません", "Can’t store targets"),
                                     tr("この Mac の識別子を読み取れないため、接続先を保存・読み込みできません。Mac を再起動しても直らない場合は「診断」の結果を控えてください。",
                                        "This Mac’s identifier can’t be read, so targets can’t be saved or loaded. If restarting doesn’t help, save the results of Diagnostics."))
        }
        guard !loaded.problems.isEmpty else { return nil }
        let n = loaded.problems.count
        return ViewerNotice.Text(tr("読み込めない接続先のファイルがあります", "Some target files can’t be read"),
                                 tr("\(n) 件のファイルを読み込めませんでした。ペアリングし直すか、~/Library/Application Support/ShareScale/pairings/viewer/ のアクセス権を直してください（フォルダ 700・ファイル 600）。",
                                    "\(HostLanguage.count(n, "file", "files")) couldn’t be read. Pair again, or fix the permissions of ~/Library/Application Support/ShareScale/pairings/viewer/ (folder 700, files 600)."))
    }

    private func switchTo(_ e: TargetEntry?) {
        selectedID = e?.id
        if let e, let book {
            let s = TargetSession(book: book, entry: e, settings: connector)
            session = s
            model.updateClient(s, targetLabel: e.displayName, unconfirmed: !e.meta.confirmed, aliased: e.meta.alias != nil)
            onSwitch(model)
        } else {
            session = nil
            model.updateClient(nil, targetLabel: "")
        }
    }
}
