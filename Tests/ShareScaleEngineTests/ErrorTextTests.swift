import XCTest
@testable import ShareScaleEngine

/// 記録に載せるエラーの文: 読める文が主で、後ろに種類と番号（計画 2h の点検）。
/// 読める文は macOS の言語で変わるので、試験は種類と番号の部分（言語に依らない）だけを見る
final class ErrorTextTests: XCTestCase {
    func testCodeHasOnlyDomainAndCode() {
        XCTAssertEqual(ErrorText.code(CocoaError(.fileWriteNoPermission)), "NSCocoaErrorDomain 513")
        XCTAssertEqual(ErrorText.code(POSIXError(.EACCES)), "NSPOSIXErrorDomain 13")
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 2),
                                                                             NSFilePathErrorKey: "/Users/taro/secret",
                                                                             NSLocalizedDescriptionKey: "ファイルが見つかりません"])
        XCTAssertEqual(ErrorText.code(wrapped), "NSCocoaErrorDomain 4, NSPOSIXErrorDomain 2", "パスなどの付帯の情報は入れない")
    }

    func testReadableTextComesFirstAndTheCodeFollowsInParentheses() {
        // 読める文を決めてあるエラー: 文が主で、種類と番号を括弧で添える
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 2),
                                                                             NSFilePathErrorKey: "/Users/taro/secret",
                                                                             NSLocalizedDescriptionKey: "ファイルが見つかりません"])
        XCTAssertEqual(ErrorText.readable(wrapped), "ファイルが見つかりません (NSCocoaErrorDomain 4, NSPOSIXErrorDomain 2)")
        // macOS が文を作るエラー: 文は言語で変わるので、種類と番号の部分と、文があることだけを見る
        for (error, code) in [(CocoaError(.fileWriteNoPermission) as Error, "(NSCocoaErrorDomain 513)"), (POSIXError(.EACCES), "(NSPOSIXErrorDomain 13)")] {
            let text = ErrorText.readable(error)
            XCTAssertTrue(text.hasSuffix(" " + code), text)
            XCTAssertGreaterThan(text.count, code.count + 1, "読める文が前にある: \(text)")
        }
        // 改行は空白 1 つに（続いていても 1 つ。語がつながらない）、ほかの制御文字は除く（1 行に載せる）
        let noisy = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: " line1\nline2\u{7}\u{1B}[31m\u{2028}end\r\n\nlast "])
        XCTAssertEqual(ErrorText.readable(noisy), "line1 line2[31m end last (Test 7)")
        // 文が空なら、種類と番号だけ
        XCTAssertEqual(ErrorText.readable(NSError(domain: "Test", code: 8, userInfo: [NSLocalizedDescriptionKey: "\n"])), "Test 8")
    }

    // 子プロセスを起動できなかった時の理由にも、種類と番号が付く
    func testLaunchErrorCarriesTheCode() throws {
        let r = ChildProcess.run(URL(fileURLWithPath: "/nonexistent/sharescale-test-no-such-tool"), [], timeout: 5)
        let e = try XCTUnwrap(r.launchError)
        XCTAssertNotNil(e.range(of: #" \(NSCocoaErrorDomain \d+(, NSPOSIXErrorDomain \d+)?\)$"#, options: .regularExpression), e)
        XCTAssertFalse(e.contains("\n"))
    }
}
