import XCTest
@testable import ShareScaleCore
import ShareScaleHostCore
import ShareScaleProtocol

/// 見る側の値の試験（`RemoteState` を `StatusPayload` から作る・機種の記号・通信量の文言・`tr`）
final class RemoteStateTests: XCTestCase {
    func testBuildsFromStatusPayload() {
        let s = RemoteState(payload(name: "Studio", model: "Mac Studio", session: true, mode: .oneX, lastError: nil,
                                    setBy: StatusPayload.SetBy(byYou: false, at: 1_800_000_000), port: 47651, addresses: ["studio.local", "100.101.1.2"]))
        XCTAssertTrue(s.sessionActive)
        XCTAssertEqual(s.mode, .x1)
        XCTAssertEqual(s.virtualDisplay, VirtualDisplay(logical: Resolution(width: 1920, height: 997), scaling: .x1, source: "signature"))
        XCTAssertFalse(s.virtualAmbiguous)
        XCTAssertEqual(s.computerName, "Studio"); XCTAssertEqual(s.model, "Mac Studio")
        XCTAssertNil(s.lastError); XCTAssertFalse(s.paused)
        XCTAssertEqual(s.setByOther, true); XCTAssertEqual(s.setAt, 1_800_000_000)
        XCTAssertEqual(s.port, 47651); XCTAssertEqual(s.addresses, ["studio.local", "100.101.1.2"])
    }
    func testNoVirtualDisplayAndPausedAndSetByYou() {
        let s = RemoteState(payload(paused: true, session: false, mode: .twoX, vd: nil, setBy: StatusPayload.SetBy(byYou: true, at: 5)))
        XCTAssertFalse(s.sessionActive); XCTAssertEqual(s.mode, .x2); XCTAssertNil(s.virtualDisplay)
        XCTAssertTrue(s.paused); XCTAssertEqual(s.setByOther, false)
        XCTAssertNil(RemoteState(payload()).setByOther, "誰も設定していなければ nil")
    }
    func testScalingTwoXMeansRetinaAndLearnedSource() {
        let s = RemoteState(payload(vd: StatusPayload.VirtualDisplay(resolution: "1920x997", scaling: .twoX, source: .learned)))
        XCTAssertEqual(s.virtualDisplay?.scaling, .x2); XCTAssertEqual(s.virtualDisplay?.source, "learned")
    }
    // Host から来た文字列は Cc・Cf・Zl・Zp を除いてから持つ（画面は verbatim で出す）
    func testControlCharactersAreStrippedFromHostStrings() {
        let s = RemoteState(payload(name: "Stu\u{7}dio\u{202E}", model: "\u{2028}Mac mini", lastError: "apply\u{0} failed"))
        XCTAssertEqual(s.computerName, "Studio"); XCTAssertEqual(s.model, "Mac mini"); XCTAssertEqual(s.lastError, "apply failed")
        XCTAssertNil(RemoteState(payload(name: "\u{7}\u{8}", model: "")).computerName, "制御文字だけなら無し")
        XCTAssertNil(RemoteState(payload(model: "")).model)
    }
    func testDefaultsAreEmpty() {
        let s = RemoteState()
        XCTAssertFalse(s.sessionActive); XCTAssertNil(s.mode); XCTAssertNil(s.virtualDisplay); XCTAssertEqual(s.addresses, [])
    }
    func testModeConversion() {
        for (a, b) in [(DisplayMode.x1, Mode.oneX), (.x2, .twoX), (.off, .off)] {
            XCTAssertEqual(a.wire, b); XCTAssertEqual(DisplayMode(b), a)
        }
    }
}

final class ResolutionTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(Resolution(string: "2560x1080"), Resolution(width: 2560, height: 1080))
        XCTAssertNil(Resolution(string: "abc"))
        XCTAssertNil(Resolution(string: ""))
    }
    func testFramebufferDoublesForRetina() {
        let r = Resolution(width: 1920, height: 997)
        XCTAssertEqual(r.framebuffer(for: .x1), Resolution(width: 1920, height: 997))
        XCTAssertEqual(r.framebuffer(for: .x2), Resolution(width: 3840, height: 1994))
    }
    func testDescription() {
        XCTAssertEqual(Resolution(width: 1920, height: 997).description, "1920×997")
    }
}

final class RecommendationTests: XCTestCase {
    func testStandardPanelGets1x() { XCTAssertEqual(DisplayMode.recommended(forBackingScale: 1.0), .x1) }
    func testRetinaGets2x() { XCTAssertEqual(DisplayMode.recommended(forBackingScale: 2.0), .x2) }
    func testFractionalScaleTreatedAsRetina() { XCTAssertEqual(DisplayMode.recommended(forBackingScale: 1.5), .x2) }
    func testLocalDisplayPreferenceKeyAndSymbol() {
        XCTAssertEqual(lg.preferenceKey, "LG ULTRAWIDE|external"); XCTAssertEqual(builtIn.preferenceKey, "内蔵Retinaディスプレイ|builtin")
        XCTAssertEqual(LocalDisplay(id: 3, name: "X", pixels: Resolution(width: 1, height: 1), backingScale: 2, isBuiltIn: false, uuid: "U-1").preferenceKey, "U-1")
        XCTAssertEqual(lg.symbol, "display"); XCTAssertEqual(builtIn.symbol, "laptopcomputer")
        XCTAssertEqual(lg.recommended, .x1); XCTAssertEqual(builtIn.recommended, .x2)
    }
}

final class MacKindTests: XCTestCase {
    func testSymbolFollowsModel() {
        XCTAssertEqual(RemoteMacKind(model: "Mac Studio").symbol, "macstudio")
        XCTAssertEqual(RemoteMacKind(model: "Mac mini").symbol, "macmini")
        XCTAssertEqual(RemoteMacKind(model: "MacBook Pro").symbol, "laptopcomputer")
        XCTAssertEqual(RemoteMacKind(model: "MacBook Air").symbol, "laptopcomputer")
        XCTAssertEqual(RemoteMacKind(model: "Mac Pro").symbol, "macpro.gen3")
        XCTAssertEqual(RemoteMacKind(model: "iMac").symbol, "desktopcomputer")
    }
    func testUnknownModelFallsBackToGeneric() {
        XCTAssertEqual(RemoteMacKind(model: nil).symbol, "desktopcomputer")
        XCTAssertEqual(RemoteMacKind(model: "Something New").symbol, "desktopcomputer")
    }
}

final class NetworkHintTests: XCTestCase {
    // リスク3: 別の VPN が既定の経路を握っていると Tailscale の直接接続が崩れる
    func testDetectsTunnelAsDefaultRoute() {
        let vpn = "   route to: default\ndestination: default\n    gateway: 10.8.0.1\n  interface: utun6\n"
        XCTAssertTrue(NetworkHints.defaultRouteIsTunnel(routeOutput: vpn))
    }
    func testOrdinaryDefaultRoute() {
        let lan = "   route to: default\ndestination: default\n    gateway: 192.168.1.1\n  interface: en0\n"
        XCTAssertFalse(NetworkHints.defaultRouteIsTunnel(routeOutput: lan))
        XCTAssertFalse(NetworkHints.defaultRouteIsTunnel(routeOutput: ""))
    }
}

final class DataSavingTests: XCTestCase {
    override func tearDown() { AppLanguage.current = .ja }

    func testOneXShowsSavingAgainstTwoX() {
        AppLanguage.current = .ja
        let s = DataSaving.summary(chosen: .x1)!
        XCTAssertEqual(s.lead + s.emphasis + s.trail, "通信量 約50%削減（2x比）")
        AppLanguage.current = .en
        let e = DataSaving.summary(chosen: .x1)!
        XCTAssertEqual(e.lead + e.emphasis + e.trail, "~50% less data than 2x")
    }
    func testTwoXShowsWhatOneXWouldSave() {
        AppLanguage.current = .ja
        let s = DataSaving.summary(chosen: .x2)!
        XCTAssertEqual(s.lead + s.emphasis + s.trail, "1x にすると通信量 約50%削減")
        XCTAssertNil(DataSaving.summary(chosen: .off))
    }
    // 画素から計算した 75% を使わない（実測は 43〜65%）
    func testClaimStaysWithinMeasuredRange() {
        XCTAssertTrue(DataSaving.observedRange.contains(DataSaving.reductionPercent))
        AppLanguage.current = .ja
        XCTAssertTrue(DataSaving.detail.contains("43〜65%"))
        XCTAssertFalse(DataSaving.detail.contains("75%"))
    }
    // 1x/2x だけでは何のことか分からないので、見出しと同じ言葉（等倍・Retina）を併記する
    func testOptionsNameWhatTheyMean() {
        AppLanguage.current = .ja
        XCTAssertEqual(DataSaving.optionLabel(.x1), "1x 等倍")
        XCTAssertEqual(DataSaving.optionLabel(.x2), "2x Retina")
        XCTAssertTrue(DataSaving.optionHelp.contains("縦横 2 ピクセル"))
        AppLanguage.current = .en
        XCTAssertEqual(DataSaving.optionLabel(.x1), "1x Standard")
        XCTAssertTrue(DataSaving.optionHelp.contains("2×2 pixels"))
    }
}

final class LanguageAndPreferenceTests: XCTestCase {
    override func tearDown() { AppLanguage.current = .ja }
    func testTrPicksLanguage() {
        AppLanguage.current = .ja; XCTAssertEqual(tr("日本語", "English"), "日本語")
        AppLanguage.current = .en; XCTAssertEqual(tr("日本語", "English"), "English")
        XCTAssertEqual(DisplayMode.x1.label, "Standard (1x)"); XCTAssertEqual(lg.panelLabel, "Standard")
        XCTAssertEqual(AppLanguage.ja.host, .ja); XCTAssertEqual(AppLanguage.en.host, .en)
        XCTAssertTrue(HostControlClient.notRunningGuidance(.notRunning(last: nil), language: AppLanguage.current.host)?.hasPrefix("ShareScale Host isn’t running") == true, "Host 側の文言を 1 か所から使う")
        // 名前の直後の助詞（点検 2f-2）: 日本語で終われば空白を入れず、英数字で終われば入れる。名前の中の空白は残す
        XCTAssertEqual(jaName("1x 等倍", "に"), "1x 等倍に")
        XCTAssertEqual(jaName("2x Retina", "に"), "2x Retina に")
        XCTAssertEqual(jaName("内蔵Retinaディスプレイ", "の"), "内蔵Retinaディスプレイの")
        XCTAssertEqual(jaName("等倍 (1x)", "を"), "等倍 (1x) を")
        XCTAssertEqual(jaName("", "に"), "に")
    }
    func testDisplayPreferencesRememberPerDisplayAndIgnoreOff() {
        let store = MemoryStore()
        let p = DisplayPreferences(store: store)
        XCTAssertNil(p.mode(for: lg))
        p.setMode(.x2, for: lg); p.setMode(.x1, for: builtIn)
        XCTAssertEqual(p.mode(for: lg), .x2); XCTAssertEqual(p.mode(for: builtIn), .x1)
        p.setMode(.off, for: lg)
        XCTAssertNil(p.mode(for: lg), "オフは「選んでいない」と同じ")
        XCTAssertEqual(store.all.keys.sorted(), ["scale.LG ULTRAWIDE|external", "scale.内蔵Retinaディスプレイ|builtin"])
        let mem = InMemoryStringStore(); mem.set("2x", forKey: "k"); XCTAssertEqual(mem.string(forKey: "k"), "2x"); mem.set(nil, forKey: "k"); XCTAssertNil(mem.string(forKey: "k"))
    }
}

final class ClipboardClearTests: XCTestCase {
    // 貼り付けた時の changeCount と同じなら（まだそのコードのままなら）消す。中身は読まない
    func testClearOnlyWhenUnchanged() {
        XCTAssertTrue(ClipboardClear.shouldClear(changeCountAtPaste: 7, now: 7))
        XCTAssertFalse(ClipboardClear.shouldClear(changeCountAtPaste: 7, now: 8), "利用者がほかのものをコピーしていたら消さない")
        XCTAssertFalse(ClipboardClear.shouldClear(changeCountAtPaste: nil, now: 8), "貼り付けを記録していなければ消さない")
    }
}
