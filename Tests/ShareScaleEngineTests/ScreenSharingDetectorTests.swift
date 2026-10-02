import XCTest
@testable import ShareScaleEngine

final class ScreenSharingDetectorTests: XCTestCase {
    let header = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
    """
    func testIncomingSessionIsDetected() {                 // 自分の 5900 番に相手がつないでいる
        let out = header + "\ntcp4       0      0  100.101.77.7.5900     100.101.88.8.56162    ESTABLISHED\n"
        XCTAssertTrue(ScreenSharingDetector.hasIncomingSession(netstatOutput: out))
    }
    func testOutgoingSessionIsIgnored() {                   // 自分が別の Mac の 5900 番を見ている
        let out = header + "\ntcp4       0      0  100.101.1.2.52311      100.101.1.9.5900       ESTABLISHED\n"
        XCTAssertFalse(ScreenSharingDetector.hasIncomingSession(netstatOutput: out))
    }
    func testListeningIsNotASession() {
        let out = header + "\ntcp4       0      0  *.5900                 *.*                    LISTEN\n"
        XCTAssertFalse(ScreenSharingDetector.hasIncomingSession(netstatOutput: out))
    }
    func testIPv6Incoming() {
        let out = header + "\ntcp6       0      0  fd7a:115c:a1e0::1.5900  fd7a:115c:a1e0::2.60000  ESTABLISHED\n"
        XCTAssertTrue(ScreenSharingDetector.hasIncomingSession(netstatOutput: out))
    }
    func testOtherPortsAndClosingStates() {
        let out = header + """

        tcp4       0      0  192.168.1.57.59000    192.168.1.60.5900     ESTABLISHED
        tcp4       0      0  192.168.1.57.15900    192.168.1.60.60000    ESTABLISHED
        tcp4       0      0  192.168.1.57.5900     192.168.1.60.60001    TIME_WAIT
        """
        XCTAssertFalse(ScreenSharingDetector.hasIncomingSession(netstatOutput: out))
    }
    func testEmptyAndGarbage() {
        XCTAssertFalse(ScreenSharingDetector.hasIncomingSession(netstatOutput: ""))
        XCTAssertFalse(ScreenSharingDetector.hasIncomingSession(netstatOutput: "garbage .5900 ESTABLISHED"))
    }
}
