import CryptoKit
import XCTest
@testable import ShareScaleProtocol

/// 期待値は Python の標準ライブラリ（hmac・hashlib）で独立に計算したもの
final class CryptoTests: XCTestCase {
    let secret = Bytes32.counting
    let id = PairingID.sample
    let ekm = Bytes32(Data(32..<64))!

    func testHKDFMatchesRFC5869TestCase3() {
        // RFC 5869 A.3（salt なし・info なし）: CryptoKit の「salt なし」が RFC の空の salt と同じであることを確かめる
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(repeating: 0x0b, count: 22)), info: Data(), outputByteCount: 42)
        XCTAssertEqual(okm.withUnsafeBytes { Data($0) }.hex, "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
    }
    func testBindKeyKnownAnswer() {
        XCTAssertEqual(Binding.bindKey(secret: secret).withUnsafeBytes { Data($0) }.hex,
                       "dbd96318236330560fd7d80e54feda473ff0f3b993f17eb90b4037a731e9fc98")
    }
    func testProofKnownAnswerAndVerify() {
        let proof = Binding.proof(secret: secret, id: id, ekm: ekm)
        XCTAssertEqual(proof.base64URL, "FzzXy52gEZFAS2vg01YXIchBS-Ixrx-c8nbSQHdOaHg")
        XCTAssertTrue(Binding.verify(proof: proof, secret: secret, id: id, ekm: ekm))
    }
    func testProofRejectsEveryVariation() {
        let proof = Binding.proof(secret: secret, id: id, ekm: ekm)
        func flip(_ b: Bytes32, at i: Int, _ mask: UInt8 = 1) -> Bytes32 { var d = b.data; d[i] ^= mask; return Bytes32(d)! }
        let otherSecret = flip(secret, at: 0), otherEkm = flip(ekm, at: 31), flipped = flip(proof, at: 5, 0x80)
        XCTAssertFalse(Binding.verify(proof: proof, secret: otherSecret, id: id, ekm: ekm), "別の秘密")
        XCTAssertFalse(Binding.verify(proof: proof, secret: secret, id: PairingID(hex: "ffeeddccbbaa99887766554433221100")!, ekm: ekm), "他人の id")
        XCTAssertFalse(Binding.verify(proof: proof, secret: secret, id: id, ekm: otherEkm), "前の接続の proof の使い回し")
        XCTAssertFalse(Binding.verify(proof: flipped, secret: secret, id: id, ekm: ekm))
        XCTAssertNil(Bytes32(proof.data.prefix(31)), "短い proof・ekm は型で作れない")
    }
    func testCommitment() {
        let rv = Bytes32.filled(1)
        let c = Commitment.make(rv)
        XCTAssertEqual(c.base64URL, "cs1uhCLEB_ttCYaQ8RMLfe1-wvf14dML2dUh8BU2N5M")
        XCTAssertTrue(Commitment.matches(commitment: c, reveal: rv))
        XCTAssertFalse(Commitment.matches(commitment: c, reveal: .filled(2)))
        XCTAssertFalse(Commitment.matches(commitment: rv, reveal: rv))
    }
    func testConfirmationCodeKnownAnswer() {
        let rv = Bytes32.filled(1), rh = Bytes32.filled(2)
        XCTAssertEqual(ConfirmationCode.derive(ekm: ekm, viewerRandom: rv, hostRandom: rh), 712462)
        XCTAssertNotEqual(ConfirmationCode.derive(ekm: ekm, viewerRandom: rh, hostRandom: rv), 712462, "乱数の順が効く")
        XCTAssertEqual(ConfirmationCode.format(712462), "712 462")
        XCTAssertEqual(ConfirmationCode.format(12345), "012 345")
        XCTAssertEqual(ConfirmationCode.format(0), "000 000")
    }
    func testConstantTimeEqual() {
        XCTAssertTrue(constantTimeEqual(Data([1, 2, 3])[1...], Data([2, 3])), "切り出した Data でも中身で比べる")
        XCTAssertTrue(constantTimeEqual(Data([1, 2]), Data([1, 2])))
        XCTAssertFalse(constantTimeEqual(Data([1, 2]), Data([1, 3])))
        XCTAssertFalse(constantTimeEqual(Data([1]), Data([1, 2])))
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
