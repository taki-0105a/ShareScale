import Darwin
import XCTest
@testable import ShareScaleCore

/// 引き渡しの記録（`app-state.json`。一時フォルダ）
final class AppStateTests: TempDirTestCase {
    func testRoundTripStrictDecodingAndFileProtection() throws {
        let s = AppState(source: "/opt/homebrew/opt/sharescale/ShareScale.app", registeredCDHash: "a4ba26929e720934b0b2833d1c5b96778238f4cb",
                         attemptedHandoff: AppState.Attempt(build: 10200, cdhash: "00ff"))
        XCTAssertEqual(String(decoding: s.encoded(), as: UTF8.self),
                       #"{"format":1,"source":"/opt/homebrew/opt/sharescale/ShareScale.app","registered_cdhash":"a4ba26929e720934b0b2833d1c5b96778238f4cb","attempted_handoff":{"build":10200,"cdhash":"00ff"}}"# + "\n")
        XCTAssertEqual(AppState.decode(s.encoded()), s)
        XCTAssertEqual(String(decoding: AppState().encoded(), as: UTF8.self),
                       #"{"format":1,"source":null,"registered_cdhash":null,"attempted_handoff":null}"# + "\n")
        XCTAssertEqual(AppState.decode(AppState().encoded()), AppState())
        for bad in [#"{"format":2,"source":null,"registered_cdhash":null,"attempted_handoff":null}"#,
                    #"{"format":1,"source":null,"registered_cdhash":null}"#,                                              // 足りない
                    #"{"format":1,"source":null,"registered_cdhash":null,"attempted_handoff":null,"x":1}"#,              // 知らないキー
                    #"{"format":1,"source":"/tmp/ShareScale.app","registered_cdhash":null,"attempted_handoff":null}"#,   // 複製元の形でない
                    #"{"format":1,"source":null,"registered_cdhash":"ABCD","attempted_handoff":null}"#,                  // 大文字
                    #"{"format":1,"source":null,"registered_cdhash":null,"attempted_handoff":{"build":"1","cdhash":"00"}}"#,
                    #"{"format":1,"source":null,"registered_cdhash":null,"attempted_handoff":{"build":1}}"#,
                    #"{"format":1,"source":null,"registered_cdhash":null,"attempted_handoff":true}"#] {
            XCTAssertNil(AppState.decode(Data(bad.utf8)), bad)
        }
        // 「ログイン時に開く」を登録した時の CDHash（点検 2f-2）: 登録した時だけキーを書き、無くても読める
        var withApp = s; withApp.registeredAppCDHash = "0a0b"
        XCTAssertTrue(String(decoding: withApp.encoded(), as: UTF8.self).hasSuffix(#","registered_app_cdhash":"0a0b"}"# + "\n"))
        XCTAssertEqual(AppState.decode(withApp.encoded()), withApp)
        XCTAssertNil(AppState.decode(Data(#"{"format":1,"source":null,"registered_cdhash":null,"attempted_handoff":null,"registered_app_cdhash":"XY"}"#.utf8)))
        XCTAssertNil(AppState.decode(Data(#"{"format":1,"source":null,"registered_cdhash":null,"attempted_handoff":null,"registered_app_cdhash":null}"#.utf8)),
                     "書くのは登録した時だけ（null は書かない形）")
        XCTAssertTrue(AppState.isSourcePath("/usr/local/opt/sharescale/ShareScale.app"))
        XCTAssertFalse(AppState.isSourcePath("/opt/homebrew/Cellar/sharescale/1.2.0/ShareScale.app"), "記録するのは版に依らない場所")

        let file = AppStateFile(url: support.appendingPathComponent("app-state.json"))
        XCTAssertEqual(file.load().state, AppState()); XCTAssertNil(file.load().problem, "無ければ既定値で、問題ではない")
        try file.save(s)
        var st = stat()
        XCTAssertEqual(lstat(file.url.path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(support.path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o700, "フォルダは 700 で作る")
        XCTAssertEqual(file.load().state, s)
        try file.update { $0.source = nil }
        XCTAssertNil(file.load().state.source); XCTAssertEqual(file.load().state.registeredCDHash, s.registeredCDHash, "ほかの項目は残る")
        // 壊れている・緩い・リンク → 既定値で動き、理由を診断に出す
        try Data("{".utf8).write(to: file.url)
        XCTAssertEqual(file.load().state, AppState()); XCTAssertEqual(file.load().problem, "app-state.json: badFormat")
        try file.save(s)
        chmod(file.url.path, 0o644)
        XCTAssertEqual(file.load().problem, "app-state.json: loosePermissions")
        // 権限が緩いだけで中身が正しければ、書き換えの時に複製元を引き継ぐ（書き直すと 600 に戻る。点検 P）
        try file.update { $0.registeredCDHash = "0e" }
        XCTAssertEqual(file.load().state, AppState(source: s.source, registeredCDHash: "0e"), "引き継ぐのは source だけ")
        XCTAssertEqual(lstat(file.url.path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o600)
        // 同じプロセスの中で同時に書き換えても、互いの変更を失わない（読むのと書くのを 1 つの鍵の中で行う）
        try file.save(AppState())
        DispatchQueue.concurrentPerform(iterations: 20) { i in
            try? file.update { $0.source = i % 2 == 0 ? "/opt/homebrew/opt/sharescale/ShareScale.app" : "/usr/local/opt/sharescale/ShareScale.app" }
            try? file.update { $0.registeredCDHash = "0f" }
        }
        XCTAssertEqual(file.load().state.registeredCDHash, "0f"); XCTAssertNotNil(file.load().state.source)
        try file.save(s)
        chmod(file.url.path, 0o644)
        unlink(file.url.path)
        symlink(dir.appendingPathComponent("elsewhere.json").path, file.url.path)
        XCTAssertEqual(file.load().problem, "app-state.json: notRegularFile")
        // 落ちたプロセスの一時ファイルは次の書き込みで消す（生きている pid のものは残す）
        unlink(file.url.path)
        FileManager.default.createFile(atPath: support.appendingPathComponent(".app-state.999999.1.tmp").path, contents: Data())
        FileManager.default.createFile(atPath: support.appendingPathComponent(".app-state.\(getpid()).2.tmp").path, contents: Data())
        try file.save(AppState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent(".app-state.999999.1.tmp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent(".app-state.\(getpid()).2.tmp").path))
    }
}
