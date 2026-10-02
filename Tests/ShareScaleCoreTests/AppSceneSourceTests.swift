import XCTest
@testable import ShareScaleCore

/// アプリの場面の並び（`Sources/ShareScale/ShareScaleApp.swift`）の形。実際のメニューは実機でしか見られないので、ソースの形を縛る（計画 2h。実機確認 A）
final class AppSceneSourceTests: XCTestCase {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `start` で始まる場面の 1 かたまり（次の空行まで）
    func scene(_ source: String, startingWith start: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let from = source.range(of: start) else { XCTFail("場面が見つかりません: \(start)", file: file, line: line); return "" }
        let rest = source[from.lowerBound...]
        return String(rest[..<(rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex)])
    }

    // ShareScale と Host の画面の言語は、同じ 1 つの関数（`HostLanguage.detect`）で決める（再点検 2h。標準のメニューの言語と同じ決まり）
    func testAppAndHostUseTheSameLanguageRule() throws {
        func text(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        XCTAssertTrue(try text("Sources/ShareScaleCore/L10n.swift")
            .contains("private static var value: AppLanguage = HostLanguage.detect(Locale.preferredLanguages) == .ja ? .ja : .en\n"), "ShareScale.app")
        XCTAssertTrue(try text("Sources/ShareScaleHostUI/HostAppController.swift").contains("    public let language = HostLanguage.detect(Locale.preferredLanguages)\n"), "Host")
        // 並びを読むのは、この 2 か所だけ（先頭だけを見る書き方を、どこにも残さない）
        var readers: [String] = []
        for folder in ["ShareScale", "ShareScaleCore", "ShareScaleEngine", "ShareScaleHost", "ShareScaleHostCore", "ShareScaleHostUI", "ShareScaleNet",
                       "ShareScaleProtocol", "ShareScaleUI"] {
            let dir = root.appendingPathComponent("Sources/\(folder)")
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where name.hasSuffix(".swift") {
                let s = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                XCTAssertFalse(s.contains("preferredLanguages.first"), "先頭だけで決めない: \(folder)/\(name)")
                // 説明の中の言及（バッククォートで囲んだもの）は数えない
                let uses = s.components(separatedBy: "Locale.preferredLanguages").count - 1 - (s.components(separatedBy: "`Locale.preferredLanguages`").count - 1)
                if uses > 0 { readers.append("\(folder)/\(name): \(uses)") }
            }
        }
        XCTAssertEqual(readers, ["ShareScaleCore/L10n.swift: 1", "ShareScaleHostUI/HostAppController.swift: 1"])
        // 組み立てのスクリプトの説明も、今の決まり
        for script in ["scripts/build-sharescale.sh", "scripts/build-host-app.sh"] {
            let s = try text(script)
            XCTAssertFalse(s.contains("preferredLanguages の先頭"), script)
            XCTAssertTrue(s.contains("アプリ自身の文言の言語も、同じ決まりで選ぶ"), script)
        }
    }

    // 接着の所（アプリの本体・画面の部品・メニュー）は、Host が断った時（一時停止中・処理中）を「接続できない」と読まない（計画 2i）。
    // 接続の状態の判断は `ViewerModel`（`connection`・`connectionFailure`・`targetModel`・`hostPaused`）の 1 か所で、ここではその形を縛る
    func testGlueReadsTheConnectionStateFromTheModel() throws {
        func text(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let app = try text("Sources/ShareScale/ViewerApp.swift")
        XCTAssertTrue(app.contains("lastFailed: self.model.connectionFailure != nil)"), "裏での取り直し: 断られた後は、間隔を 5 分に延ばさない（接続はできている）")
        let main = try text("Sources/ShareScaleUI/MainView.swift")
        XCTAssertTrue(main.contains("        switch model.connection {\n"), "見出しのバッジ")
        XCTAssertTrue(main.contains("RemoteMacKind(model: model.targetModel).symbol"), "見出しの機種の記号")
        // 失敗（`failure`）をじかに見て決める所を残さない（診断の窓は、行の判断 `ViewerDiagnostics.lines` に渡すだけ）
        for path in ["Sources/ShareScale/ViewerApp.swift", "Sources/ShareScale/ShareScaleApp.swift", "Sources/ShareScaleUI/MainView.swift",
                     "Sources/ShareScaleUI/MenuBarView.swift", "Sources/ShareScaleUI/DisplayCard.swift", "Sources/ShareScaleCore/ViewerMenu.swift"] {
            XCTAssertFalse(try text(path).contains("model.failure"), path)
        }
        let diagnostics = try text("Sources/ShareScaleUI/DiagnosticsView.swift")
        XCTAssertEqual(diagnostics.components(separatedBy: "model.failure").count - 1, 1)
        XCTAssertTrue(diagnostics.contains("ViewerDiagnostics.lines(target: target, state: model.state, failure: model.failure,"))
    }

    func testAuxiliaryWindowsStayOutOfTheWindowMenuAndHelpOpensTheRepository() throws {
        let s = try String(contentsOf: root.appendingPathComponent("Sources/ShareScale/ShareScaleApp.swift"), encoding: .utf8)
        // 診断と完全な削除のウインドウは、「ウインドウ」のメニューに開く項目を出さない（`.commandsRemoved()`）
        let diagnostics = scene(s, startingWith: "        Window(tr(\"診断\", \"Diagnostics\"), id: WindowID.diagnostics) {")
        let uninstall = scene(s, startingWith: "        Window(tr(\"ShareScale を完全に削除\", \"Remove ShareScale Completely\"), id: WindowID.uninstall) {")
        for (name, block) in [("診断", diagnostics), ("完全な削除", uninstall)] {
            XCTAssertTrue(block.hasSuffix("        .windowResizability(.contentSize)\n        .commandsRemoved()"), "\(name): \(block)")
        }
        // 主の窓は外さない（「ウインドウ › ShareScale」で開き直せる。「診断…」と「ヘルプ」の項目もこの場面が持つ）
        let main = scene(s, startingWith: "        Window(\"ShareScale\", id: WindowID.main) {")
        XCTAssertFalse(main.contains(".commandsRemoved()"), main)
        XCTAssertTrue(main.contains("CommandGroup(after: .appInfo) { DiagnosticsMenuItem() }"), "「ShareScale › 診断…」は今までどおり")
        // 「ヘルプ」は、選んでも何も出ない標準の項目を、公開のリポジトリを開く項目に置き換える
        XCTAssertTrue(main.contains("CommandGroup(replacing: .help) { HelpMenuItem() }"), main)
        XCTAssertTrue(s.contains("Button { NSWorkspace.shared.open(AppLinks.repository) } label: { Text(verbatim: AppLinks.helpTitle) }"),
                      "開くのは `AppLinks.repository` だけ")
        XCTAssertEqual(s.components(separatedBy: "NSWorkspace.shared.open(").count - 1, 1, "アプリの場面から外を開くのは 1 か所だけ")
        // 診断を開く道（⇧⌘D）は残っている
        XCTAssertTrue(s.contains("Button { openWindow(id: WindowID.diagnostics) } label: { Text(verbatim: tr(\"診断…\", \"Diagnostics…\")) }\n            .keyboardShortcut(\"d\", modifiers: [.command, .shift])"))
    }
}
