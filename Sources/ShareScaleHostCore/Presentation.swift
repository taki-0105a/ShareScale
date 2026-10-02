import Foundation
import ShareScaleProtocol

/// 確認の窓に出す値（`ApprovalRequest` から。純粋な関数）。
/// 「追加しない」を既定のボタンにし、接続元の Mac に同じ番号が出ていなければ「追加しない」を選ぶよう書く（仕様「名乗りと確認番号」）
public struct ApprovalPresentation: Equatable, Sendable {
    public var windowTitle: String  // 窓の題名「接続元の Mac を追加」
    public var title: String        // 『「<name>」（<分類>）を追加しますか？』（分類は「この Mac」「同じネットワーク」「Tailscale 経由」「インターネット経由」。
                                    // ウインドウの題名が「接続元の Mac を追加」なので「接続元の Mac として」は繰り返さない。計画 2f-1）
    public var name: String         // 制御文字を除いた名前
    public var source: String       // 「アドレス: 192.168.1.9」。送り元がこの Mac（ループバック）なら空（題名の「この Mac」と重ねない。実機確認 2026-09-30）
    public var code: String         // 「012 345」
    public var instruction: String  // 接続元の Mac の番号と比べる案内
    public var approve: String      // 「追加する」
    public var decline: String      // 「追加しない」（既定）
    public var codeAccessibility: String   // VoiceOver 用（「確認番号 0 1 2 3 4 5」。数字を 1 つずつ）

    public init(_ r: ApprovalRequest, language L: HostLanguage) {
        let name = L.displayName(r.name)
        let cls = Self.describe(r.sourceClass, L)
        self.name = name
        windowTitle = L.t("接続元の Mac を追加", "Add a Mac to Connect From")
        // 題名は名前と分類、下の行はアドレスだけ（同じアドレスを 2 回出さない）。この Mac からの名乗りは題名の「この Mac」だけで足りるので下の行を出さない
        source = r.sourceClass == .loopback ? "" : L.t("アドレス: \(r.source)", "Address: \(r.source)")
        title = L.t("「\(name)」（\(cls)）を追加しますか？", "Add “\(name)” (\(cls))?")
        code = r.formattedCode
        instruction = L.t("接続元の Mac に同じ確認番号が表示されている場合だけ、「追加する」をクリックしてください。違う番号が表示されている場合は「追加しない」をクリックしてください。",
                          "Click Add only if the Mac you’re connecting from shows the same confirmation number. If the number is different, click Don’t Add.")
        approve = L.t("追加する", "Add")
        decline = L.t("追加しない", "Don’t Add")
        codeAccessibility = L.t("確認番号 ", "Confirmation number ") + code.filter(\.isNumber).map(String.init).joined(separator: " ")
    }

    /// 題名の括弧の中に入れる分類（括弧を重ねないよう、IPv6 かどうかは下の行のアドレスで分かるので書かない）
    static func describe(_ c: SourceClass, _ L: HostLanguage) -> String {
        switch c {
        case .loopback: return L.t("この Mac", "this Mac")
        case .privateV4, .linkLocal, .sameNetworkGlobal: return L.t("同じネットワーク", "on the same network")
        case .sharedCGNAT, .uniqueLocal: return L.t("Tailscale 経由", "via Tailscale")
        case .otherGlobal: return L.t("インターネット経由", "via the internet")
        }
    }
}

/// コードの窓に出す値（`HostRuntime.issueCode()` の結果から。純粋な関数）
public struct CodePresentation: Equatable, Sendable {
    public var code: String                 // 貼り付け用の文字列（`sharescale1:…`）
    public var address: String              // 手入力用のアドレス（1 件。`[IPv6]`、ポートが既定でなければ `:port`）
    public var key: String                  // 手入力用のキー（4 文字ずつ区切り）
    public var keyRaw: String               // 区切りを除いたキー（78 文字。「キーをコピー」。`ManualEntry.decodeKey` が読める形）
    public var keyGroups: [String]          // VoiceOver 用（4 文字ずつ）
    public var expires: Date
    public var copy: String, copyKey: String, copyAddress: String, copied: String
    /// 「コピー」（接続コード）に重ねた時の説明（キーは ⇧⌘C。⌘C は選択した文字のコピーに使う。計画 2f-1）
    public var copyHelp: String
    public var revoke: String, addressLabel: String, keyLabel: String, title: String, hint: String

    public init(_ c: PairingCode, language L: HostLanguage) {
        code = c.encoded()
        address = Self.manualAddress(c.addresses.first ?? "", port: c.port)
        keyRaw = ManualEntry.encodeKey(id: c.id, secret: c.secret)
        key = ManualEntry.grouped(keyRaw)
        keyGroups = key.split(separator: " ").map(String.init)
        expires = Date(timeIntervalSince1970: TimeInterval(c.expiresAt))
        title = L.t("接続コード", "Pairing Code")
        hint = L.t("接続元の Mac で ShareScale を開き、「接続先を追加」にこのコードを貼り付けてください。コードの代わりに、下のアドレスとキーを入力することもできます。コードは 10 分間、1 回だけ使えます。",
                   "On the Mac you’ll connect from, open ShareScale and paste this code into Add Target. You can also enter the address and key below instead. The code can be used once within 10 minutes.")
        copy = L.t("コピー", "Copy"); copyKey = L.t("キーをコピー", "Copy Key"); copyAddress = L.t("アドレスをコピー", "Copy Address")
        copyHelp = L.t("接続コードをコピーします（⇧⌘C）", "Copy the pairing code (⇧⌘C)")
        copied = L.t("コピーしました", "Copied")
        revoke = L.t("コードを取り消す", "Revoke Code")
        addressLabel = L.t("アドレス", "Address"); keyLabel = L.t("キー", "Key")
    }

    /// コピーするもの（「コピー」＝接続コード・「キーをコピー」・「アドレスをコピー」）
    public enum Item: Equatable, Sendable { case code, key, address }
    /// コピーする文字列と、クリップボードに「秘密（`org.nspasteboard.ConcealedType`）・一時的（`TransientType`）」の印を付けるか。
    /// 接続コードとキーは秘密（名乗りに使える）なので印を付ける。アドレスは秘密ではないので付けない
    public func clipboard(_ item: Item) -> (text: String, concealed: Bool) {
        switch item {
        case .code: return (code, true)
        case .key: return (keyRaw, true)
        case .address: return (address, false)
        }
    }

    /// 手入力の形（仕様「手入力」）: `<ホスト名>`・`<IPv4>`・`[<IPv6>]` の後に、既定でなければ `:<ポート>`
    public static func manualAddress(_ a: String, port: Int) -> String {
        let host = a.contains(":") ? "[\(a)]" : a
        return port == Limits.defaultPort ? host : "\(host):\(port)"
    }

    /// 残り時間の表示（1 秒ごとに呼ぶ）
    public func remaining(now: Date, language L: HostLanguage) -> String {
        let s = Int(expires.timeIntervalSince(now).rounded(.down))
        return L.t("残り \(HostLanguage.clock(s))", "\(HostLanguage.clock(s)) left")
    }
}

/// Host の編集のメニュー（メニューバーには出ない。`LSUIElement` の Host で ⌘C・⌘A を選択した文字に届けるためだけに置く。計画 2f-1）。
/// 項目の文言・動作（`NSText` の選択子の名前）・キー
public enum EditMenuModel {
    public struct Item: Equatable, Sendable {
        public let title: String
        public let action: String
        public let key: String
    }
    public static func items(_ L: HostLanguage) -> [Item] {
        [Item(title: L.t("コピー", "Copy"), action: "copy:", key: "c"),
         Item(title: L.t("すべてを選択", "Select All"), action: "selectAll:", key: "a")]
    }
    public static func title(_ L: HostLanguage) -> String { L.t("編集", "Edit") }
}

/// 初回の起動で出す「メニューバーで動いています」の知らせ（実機確認 2026-09-30: メニューバーの記号が画面上部の切り欠きに隠れ、見つからなかった）。
/// 出すのは `HostPreferences.menuBarNoticeShown` が偽の時の 1 回だけ
public struct MenuBarNoticePresentation: Equatable, Sendable {
    public var windowTitle: String
    public var title: String
    public var message: String
    public var close: String

    public init(language L: HostLanguage) {
        windowTitle = "ShareScale Host"
        title = L.t("ShareScale Host はメニューバーで動作しています", "ShareScale Host runs in the menu bar")
        // アイコンが見当たらない時の道を 3 つ（システム設定で表示が許可されているか・隠れている時は ShareScale の設定・ShareScale を開いている間は ShareScale のメニュー。点検 2f-2）
        message = L.t("メニューバーにアイコンが見当たらない場合は、システム設定 › メニューバーで ShareScale Host の表示が許可されているかを確認してください。画面上部のカメラ部分に隠れている場合は、ShareScale の設定 › この Mac の接続先から操作できます。ShareScale を開いている間は、このアイコンの代わりに ShareScale のメニューに「この Mac の接続先」が表示されます。",
                      "If you can’t see its icon in the menu bar, check that ShareScale Host is allowed in System Settings › Menu Bar. If the icon is hidden behind the camera housing at the top of the screen, you can use ShareScale Settings › This Mac as a Target instead. While ShareScale is open, This Mac as a Target appears in the ShareScale menu instead of this icon.")
        close = L.t("閉じる", "Close")
    }
}
