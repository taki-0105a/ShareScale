import XCTest
@testable import ShareScaleEngine

/// probe の出力（1行1台: uuid\t製造元\t製品\tシリアル\t幅x高\t実画素幅x実画素高）を読み戻す
final class ProbeOutputTests: XCTestCase {
    func testParsesTwoDisplays() {
        let text = "\(VIRT)\t6161706c\t00001234\t6d767300\t1920x997\t3840x1994\n\(PHYS)\t00001e6d\t00005b11\t00000001\t1920x1080\t3840x2160\n"
        XCTAssertEqual(ProbeOutput.parse(text), [virtual(factor: 2), physical()])
    }
    func testHexFields() {
        let d = ProbeOutput.parse("V1\t6161706c\t00001234\t6d767300\t1512x896\t3024x1792\n")?.first
        XCTAssertEqual(d?.vendor, 0x6161706c); XCTAssertEqual(d?.model, 0x1234); XCTAssertEqual(d?.serial, 0x6d767300)
        XCTAssertEqual(d?.isScreenSharingVirtual, true)
        XCTAssertEqual(d?.width, 1512); XCTAssertEqual(d?.height, 896); XCTAssertEqual(d?.pixelWidth, 3024); XCTAssertEqual(d?.pixelHeight, 1792)
    }
    func testEmptyOutputIsNoDisplaysNotFailure() {             // ディスプレイが無いのは失敗ではない
        XCTAssertEqual(ProbeOutput.parse(""), [])
        XCTAssertEqual(ProbeOutput.parse("\n\n"), [])
    }
    func testMalformedLineFailsWhole() {                        // 1行でも読めなければ nil（呼び出し側が別の方法に切り替える）
        let good = "V1\t6161706c\t00001234\t6d767300\t1920x997\t3840x1994"
        XCTAssertNil(ProbeOutput.parse(good + "\nerror=usage\n"))
        XCTAssertNil(ProbeOutput.parse("V1\tzzzz\t00001234\t6d767300\t1920x997\t3840x1994"), "16進でない")
        XCTAssertNil(ProbeOutput.parse("V1\t6161706c\t00001234\t6d767300\t1920x997"), "欄が足りない")
        XCTAssertNil(ProbeOutput.parse("V1\t6161706c\t00001234\t6d767300\t1920-997\t3840x1994"), "大きさの形が違う")
        XCTAssertNil(ProbeOutput.parse("V1\t6161706c\t00001234\t6d767300\t1920x997\t3840x1994\textra"), "欄が多い")
    }
    func testToleratesOddWhitespace() {                          // CRLF・前後の空白・空行・連続した区切り
        let text = "\r\n  V1 \t6161706c\t\t00001234\t6d767300\t1920x997\t3840x1994  \r\n\n"
        XCTAssertEqual(ProbeOutput.parse(text)?.map(\.uuid), ["V1"])
    }
    func testFormatRoundTrips() {                                // `--probe` が書き出した形を読み戻せる
        let ds = [virtual(factor: 2), physical(), placeholder()]
        XCTAssertEqual(ProbeOutput.parse(ProbeOutput.format(ds)), ds)
        XCTAssertEqual(ProbeOutput.format([]), "")
    }
}
