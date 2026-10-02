import XCTest
@testable import ShareScaleHostCore

/// 開いた URL を記録する偽の口（実物のシステム設定を開かない）。`accepts` に入っている URL だけ開けたことにする
final class FakeSettingsOpener: SystemSettingsOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var _tried: [URL] = []
    private var _loginItems = 0
    let accepts: @Sendable (URL) -> Bool
    init(accepts: @escaping @Sendable (URL) -> Bool = { _ in true }) { self.accepts = accepts }
    var tried: [URL] { lock.withLock { _tried } }
    var loginItems: Int { lock.withLock { _loginItems } }
    func open(_ url: URL) -> Bool { lock.withLock { _tried.append(url) }; return accepts(url) }
    func openLoginItems() { lock.withLock { _loginItems += 1 } }
}

/// システム設定の URL の表と開き方（計画 2f-1 案 5）
final class SystemSettingsLinkTests: XCTestCase {
    func testCandidatesAreInOrderAndUseTheSystemPreferencesScheme() {
        XCTAssertEqual(SystemSettingsLink.candidates(.openLocalNetworkSettings).map(\.absoluteString), [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ])
        XCTAssertEqual(SystemSettingsLink.candidates(.openFirewallSettings).first?.absoluteString, "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")
        XCTAssertEqual(SystemSettingsLink.candidates(.openFileVaultSettings).first?.absoluteString, "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault")
        XCTAssertEqual(SystemSettingsLink.candidates(.openNotificationSettings).first?.absoluteString,
                       "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.github.taki-0105a.ShareScale")
        for a in DiagnosticAction.allCases {
            let c = SystemSettingsLink.candidates(a)
            XCTAssertFalse(c.isEmpty, "\(a)")
            XCTAssertTrue(c.allSatisfy { $0.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.") }, "\(a)")
            XCTAssertFalse(a.title(.ja).isEmpty); XCTAssertTrue(a.title(.en).hasSuffix("…"), "ウインドウが開くので「…」")
        }
    }

    func testOpenTriesCandidatesInOrderThenFallsBackToTheSettingsApp() {
        let first = FakeSettingsOpener()
        XCTAssertEqual(SystemSettingsLink.open(.openFirewallSettings, using: first), SystemSettingsLink.candidates(.openFirewallSettings).first)
        XCTAssertEqual(first.tried.count, 1, "開けたらそこで止める")
        let second = FakeSettingsOpener(accepts: { !$0.absoluteString.contains("Network-Settings.extension?") })
        XCTAssertEqual(SystemSettingsLink.open(.openFirewallSettings, using: second), SystemSettingsLink.candidates(.openFirewallSettings).dropFirst().first)
        let none = FakeSettingsOpener(accepts: { $0 == SystemSettingsLink.settingsApp })
        XCTAssertEqual(SystemSettingsLink.open(.openFileVaultSettings, using: none), SystemSettingsLink.settingsApp)
        XCTAssertEqual(none.tried, SystemSettingsLink.candidates(.openFileVaultSettings) + [SystemSettingsLink.settingsApp], "候補を順に試し、どれも開けなければシステム設定そのもの")
        XCTAssertNil(SystemSettingsLink.open(.openLocalNetworkSettings, using: FakeSettingsOpener(accepts: { _ in false })))
        let login = FakeSettingsOpener()
        XCTAssertNil(SystemSettingsLink.open(.openLoginItemsSettings, using: login))
        XCTAssertEqual(login.loginItems, 1); XCTAssertEqual(login.tried, [], "ログイン項目は SMAppService の口で開く（URL は使わない）")
    }

    func testReportItemsCarryActionsOnlyOnProblemLines() {
        var s = SystemDiagnostics(); s.firewall = .on(.blocked); s.fileVault = false; s.loginItem = .requiresApproval
        var d = HostDiagnostics(); d.listener = .listening(port: 47651)
        let now = Date()
        let items = DiagnosticsReport.items(host: d, system: s, pairings: [:], version: "1", now: now, language: .ja)
        XCTAssertEqual(items.map(\.line), DiagnosticsReport.lines(host: d, system: s, pairings: [:], version: "1", now: now, language: .ja), "コピーの行は今までと同じ")
        func action(_ prefix: String) -> DiagnosticAction? { items.first { $0.text.hasPrefix(prefix) }?.action }
        XCTAssertEqual(action("ファイアウォールが"), .openFirewallSettings)
        XCTAssertEqual(action("ログイン項目で"), .openLoginItemsSettings)
        XCTAssertEqual(action("FileVault がオフ"), .openFileVaultSettings)
        XCTAssertNil(items.first?.mark, "版の行には記号を付けない")
        XCTAssertEqual(items.first?.section, .header)
        XCTAssertTrue(items.filter { $0.mark != nil }.allSatisfy { $0.section == .check }, "記号の付く行は確認の行")
        XCTAssertEqual(items.last?.section, .viewers, "接続元の Mac の見出しは一覧の区画")
        XCTAssertTrue(items.filter { $0.mark == .ok }.allSatisfy { $0.action == nil }, "✓ の行には付けない")
        s.firewall = .off; s.fileVault = true; s.loginItem = .enabled
        XCTAssertTrue(DiagnosticsReport.items(host: d, system: s, pairings: [:], version: "1", now: now, language: .en).allSatisfy { $0.action == nil })
        s.firewall = .unknown("x"); s.fileVault = nil; s.loginItem = .unknown
        let unknown = DiagnosticsReport.items(host: d, system: s, pairings: [:], version: "1", now: now, language: .en)
        XCTAssertEqual(Set(unknown.compactMap(\.action)), [.openFirewallSettings, .openFileVaultSettings, .openLoginItemsSettings], "? の行にも付ける")
        s.loginItem = .notRegistered
        XCTAssertFalse(DiagnosticsReport.items(host: d, system: s, pairings: [:], version: "1", now: now, language: .en).contains { $0.action == .openLoginItemsSettings },
                       "未登録は ShareScale の「この Mac を接続先にする」で直す（システム設定ではない）")
    }
}
