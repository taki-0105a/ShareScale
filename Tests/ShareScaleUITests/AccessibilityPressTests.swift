import AppKit
import SwiftUI
import XCTest
import ShareScaleCore
import ShareScaleHostCore
import ShareScaleHostUI
import ShareScaleProtocol
@testable import ShareScaleUI

/// アクセシビリティの木の 1 つの要素
struct AXItem {
    let role: String
    let label: String
    let enabled: Bool
    /// 「押す」（AXPress）ができるか
    let canPress: Bool
    /// 「押す」を行う（できたら真）
    let press: @MainActor () -> Bool
}

/// 画面の部品のアクセシビリティの木を読む。**ウインドウは出さない**（画面の外の、表示しないウインドウに載せるだけ）
@MainActor
enum AXTree {
    /// 押せる部品の役割（ボタン・スイッチとチェックボックス・切り替えのセグメント・メニューのボタン・リンク）
    static let pressableRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink", "AXDisclosureTriangle"]
    private static let pressSelector = #selector(NSAccessibilityElement.accessibilityPerformPress)

    /// 木を読めない環境でも落とすことを求める環境変数（開発機の `scripts/test-all.sh` が付ける。公開用の test-all は付けない）
    nonisolated static let requireVariable = "SHARESCALE_REQUIRE_AX_TESTS"

    /// SwiftUI は、支援技術（VoiceOver など）がつながるまでアクセシビリティの木を作らない。
    /// この試験のプロセスの中だけで、つながった時と同じ印（`AXEnhancedUserInterface`）を付ける（利用者の設定は変えない）。試験の終わりに `reset` で戻す
    static func enable() { setEnhancedUserInterface(true) }
    private static func setEnhancedUserInterface(_ on: Bool) {
        _ = NSApplication.shared
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: on), with: "AXEnhancedUserInterface" as NSString)
    }

    /// 試験の後片付け: 生かしておいたウインドウ（と、その中の部品・タイマー）を手放し、付けた印を外す
    static func reset() {
        keep = []
        setEnhancedUserInterface(false)
    }

    /// この環境で木を読めて、「押す」のある・なしを見分けられるか（ふつうのボタンが 1 つ見つかって押せ、`.ignore` を重ねたボタンは押せない）。
    /// macOS の版によって、SwiftUI が木を作らない・この読み方が通らないことがありうる（確かめているのは macOS 27）
    static func canTellPressFromNoPress() -> Bool {
        var pressed = 0
        let good = items(Button { pressed += 1 } label: { Text(verbatim: "a") }.buttonStyle(.plain).accessibilityLabel(Text(verbatim: "probe")))
            .filter { $0.role == "AXButton" }
        guard good.count == 1, good[0].label == "probe", good[0].canPress, good[0].press(), pressed == 1 else { return false }
        let bad = items(Button {} label: { Text(verbatim: "a") }.buttonStyle(.plain)
            .accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: "probe")).accessibilityAddTraits(.isButton)).filter { $0.role == "AXButton" }
        return bad.count == 1 && !bad[0].canPress
    }

    /// 木を読めない環境での扱い（純粋な判断）: 求められていれば落とす、そうでなければ飛ばす
    enum Unreadable: Equatable { case fail, skip }
    static func whenUnreadable(environment: [String: String]) -> Unreadable {
        environment[requireVariable] == "1" ? .fail : .skip
    }

    static func items(_ view: some View, width: CGFloat = 560) -> [AXItem] {
        enable()
        let host = NSHostingView(rootView: view.frame(width: width))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var out: [AXItem] = []
        collect(host, &out, depth: 0)
        keep.append(window)   // 押す操作の間、部品を生かしておく
        return out
    }
    private static var keep: [NSWindow] = []

    /// 要素とその子をたどる。SwiftUI の要素（`AccessibilityNode`）は `NSObject` で、アクセシビリティの決まりの関数を宣言なしで持つので、
    /// 応える関数だけを `NSAccessibilityElement` の形で呼ぶ
    private static func collect(_ any: Any, _ out: inout [AXItem], depth: Int) {
        guard depth < 60, let o = any as? NSObject else { return }
        let names = ["accessibilityRole", "accessibilityLabel", "accessibilityChildren", "isAccessibilityEnabled", "isAccessibilitySelectorAllowed:", "accessibilityPerformPress"]
        guard names.allSatisfy({ o.responds(to: NSSelectorFromString($0)) }) else { return }
        // 型は違うが、上の関数に応えることを確かめてあるので、同じ形で呼べる（`unsafeDowncast` は型を確かめて止まるので使えない）
        let e = Unmanaged<NSAccessibilityElement>.fromOpaque(Unmanaged.passUnretained(o).toOpaque()).takeUnretainedValue()
        let role = e.accessibilityRole()?.rawValue ?? ""
        let title = text(o, "accessibilityTitle"), label = text(o, "accessibilityLabel")
        out.append(AXItem(role: role, label: label.isEmpty ? title : label, enabled: e.isAccessibilityEnabled(),
                          canPress: e.isAccessibilitySelectorAllowed(pressSelector), press: { e.accessibilityPerformPress() }))
        for child in e.accessibilityChildren() ?? [] { collect(child, &out, depth: depth + 1) }
    }

    /// 読み・題名（文字列か、飾り付きの文字列で返る。応えなければ空）
    private static func text(_ o: NSObject, _ name: String) -> String {
        let selector = NSSelectorFromString(name)
        guard o.responds(to: selector), let v = o.perform(selector)?.takeUnretainedValue() else { return "" }
        if let s = v as? String { return s }
        return (v as? NSAttributedString)?.string ?? ""
    }

    /// 使えるのに「押す」ができない、押せる役割の要素（「役割: 読み」）
    static func unpressable(_ items: [AXItem]) -> [String] {
        items.filter { pressableRoles.contains($0.role) && $0.enabled && !$0.canPress }.map { "\($0.role): \($0.label)" }
    }
}

/// 木を読めない環境で、落とすことを求められている時の失敗
struct AccessibilityTreeUnreadable: Error, CustomStringConvertible {
    var description: String { "アクセシビリティの木を読めません（\(AXTree.requireVariable)=1 のため、飛ばさずに失敗にします）" }
}

/// 押せる部品は、VoiceOver やアクセシビリティの操作の「押す」（AXPress）でも押せる（計画 2h。実機確認 A:
/// 「はじめに」の 3 枚のカードは `Button` に `accessibilityElement(children: .ignore)` を重ねていて、マウスでは動くのに「押す」が無かった）。
/// **木を読めない環境では、木を読む試験を飛ばす**（`XCTSkip`。理由を出力する）。確かめているのは macOS 27。
/// 環境変数 `SHARESCALE_REQUIRE_AX_TESTS=1` の時は、飛ばさずに失敗にする（開発機の `scripts/test-all.sh` が付ける。点検 2h）
@MainActor
final class AccessibilityPressTests: XCTestCase {
    /// 主の窓の中身（偽の接続先に 1 回問い合わせた後）と、設定 › 一般 の中身。待つ処理は `setUp` で済ませる。
    /// アクセシビリティの木を読むのは、待ちの無い試験の関数の中だけにする（作っている途中、`async` の試験の関数の中で読んだ時に、試験のプロセスが
    /// `freed pointer was not the last allocation` で落ちたことがある。原因は未確定で、後から同じ形で再現しようとしても再現しなかった。今の形で安定している）
    var models: [(String, ViewerModel)] = []
    var general: GeneralSettings?
    private var languageBefore = AppLanguage.current

    override func setUp() async throws {
        languageBefore = AppLanguage.current
        AppLanguage.current = .ja
        models = [("主の窓・接続中", await viewerModel(.success(remoteState()))), ("主の窓・接続できない", await viewerModel(.failure(.unreachable))),
                  ("主の窓・ローカルネットワーク", await viewerModel(.failure(.localNetworkDenied)))]
        general = await generalContent(.denied, notificationsOn: true)
    }

    // 後片付け: 表示しないウインドウ（その中の部品とタイマー）・付けた印・言語を戻す
    override func tearDown() async throws {
        AXTree.reset()
        models = []; general = nil
        AppLanguage.current = languageBefore
    }

    /// 木を読めない環境なら、この試験を飛ばす（求められていれば失敗にする）
    func requireReadableTree() throws {
        if AXTree.canTellPressFromNoPress() { return }
        let reason = "アクセシビリティの木を読めないため、木を読む試験を飛ばします（SwiftUI がこの環境で木を作らないか、読み方が合わない。確かめているのは macOS 27。"
            + "落とすには \(AXTree.requireVariable)=1）: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        print(reason)
        switch AXTree.whenUnreadable(environment: ProcessInfo.processInfo.environment) {
        case .fail: throw AccessibilityTreeUnreadable()
        case .skip: throw XCTSkip(reason)
        }
    }

    // 木を読めない環境での扱い: 環境変数が 1 の時だけ落とし、そうでなければ飛ばす
    func testUnreadableTreeSkipsUnlessRequired() {
        XCTAssertEqual(AXTree.whenUnreadable(environment: [:]), .skip)
        XCTAssertEqual(AXTree.whenUnreadable(environment: ["SHARESCALE_REQUIRE_AX_TESTS": "1"]), .fail)
        XCTAssertEqual(AXTree.whenUnreadable(environment: ["SHARESCALE_REQUIRE_AX_TESTS": "0"]), .skip)
        XCTAssertEqual(AXTree.whenUnreadable(environment: ["SHARESCALE_REQUIRE_AX_TESTS": ""]), .skip)
        XCTAssertEqual(AXTree.requireVariable, "SHARESCALE_REQUIRE_AX_TESTS")
    }

    // この試験の見方が、直す前の形（「押す」が無い）と正しい形を見分けられること
    func testTheCheckTellsAButtonWithoutPressFromOneWithPress() throws {
        try requireReadableTree()
        var pressed = 0
        let good = AXTree.items(Button { pressed += 1 } label: { Text(verbatim: "題名") }.buttonStyle(.plain).accessibilityLabel(Text(verbatim: "題名。説明")))
        let goodButtons = good.filter { $0.role == "AXButton" }
        guard goodButtons.count == 1, let g = goodButtons.first else {
            return XCTFail("アクセシビリティの木を読めません: \(good.map { "\($0.role): \($0.label)" })")
        }
        XCTAssertEqual(g.label, "題名。説明"); XCTAssertTrue(g.canPress)
        XCTAssertTrue(g.press()); XCTAssertEqual(pressed, 1, "「押す」でボタンの処理が動く")
        XCTAssertEqual(AXTree.unpressable(good), [])
        // 直す前の形: 読みは同じでも「押す」が無い
        let bad = AXTree.items(Button { pressed += 1 } label: { Text(verbatim: "題名") }.buttonStyle(.plain)
            .accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: "題名。説明")).accessibilityAddTraits(.isButton))
        XCTAssertEqual(AXTree.unpressable(bad), ["AXButton: 題名。説明"])
        XCTAssertEqual(bad.first { $0.role == "AXButton" }?.press(), false)
        XCTAssertEqual(pressed, 1, "押せない")
        // 使えないボタンは数えない（押せなくてよい）
        XCTAssertEqual(AXTree.unpressable(AXTree.items(Button {} label: { Text(verbatim: "x") }.disabled(true))), [])
    }

    // 「はじめに」の 3 枚のカード: 読みは題名と説明の 1 つ、「押す」でその選択肢が選ばれる
    func testOnboardingOptionCardsCanBePressed() throws {
        try requireReadableTree()
        for language in [AppLanguage.ja, .en] {
            AppLanguage.current = language
            let page = OnboardingPage.make(OnboardingFlow(), hostRunning: false, canAddTarget: true, issueCode: ("x", true))
            XCTAssertEqual(page.options.count, 3)
            var chosen: [OnboardingFlow.Goal] = []
            let items = AXTree.items(OnboardingContent(page: page, hostSwitch: hostSwitch(.notRegistered), onChoose: { chosen.append($0) }, onPrimary: {}, onAction: {},
                                                       onBack: {}, onLater: {}, onToggleHost: { _ in }, onOpenLoginItems: {}), width: 480)
            XCTAssertEqual(AXTree.unpressable(items), [], "\(language)")
            for o in page.options {
                let label = o.title + (language == .ja ? "。" : ". ") + o.detail
                let cards = items.filter { $0.label == label }
                XCTAssertEqual(cards.count, 1, "読みは題名と説明の 1 つ: \(label)")
                XCTAssertEqual(cards.first?.role, "AXButton", label)
                XCTAssertEqual(cards.first?.canPress, true, label)
                XCTAssertEqual(cards.first?.press(), true, label)
                XCTAssertEqual(chosen.last, o.goal, "「押す」でその選択肢が選ばれる: \(label)")
            }
            XCTAssertEqual(chosen, page.options.map(\.goal))
            // 図の呼び名（「この Mac」「別の Mac」）は読みに出さない（題名と説明だけ）
            XCTAssertFalse(items.contains { $0.label == OnboardingPage.thisMac || $0.label == OnboardingPage.otherMac })
        }
    }

    // ShareScale と ShareScale Host の画面を見て回り、使えるのに「押す」ができない押せる部品が無いこと（同じ形の洗い出し）
    func testEveryEnabledControlOnTheScreensCanBePressed() throws {
        try requireReadableTree()
        let general = try XCTUnwrap(self.general)
        XCTAssertEqual(models.count, 3)
        let seen = Screens()
        func add(_ name: String, _ view: some View, width: CGFloat = 560) { seen.add(name, view, width: width) }
        // 主の窓（ディスプレイのカードは、全体が 1 つのボタン）
        let rows = targetRows(3)
        for (name, vm) in models {
            add(name, MainContent(model: vm, targets: rows, storeNotice: nil, canAddTarget: true, addNote: "", version: "1.1.0",
                                  onSelectTarget: { _ in }, onAddTarget: {}, onDiagnostics: {}, update: UpdateWatcher.noticeText), width: 480)
        }
        add("主の窓・接続先なし", MainContent(model: ViewerModel(client: nil, displays: { [display(1, builtIn: false)] }), targets: [], storeNotice: nil, canAddTarget: true,
                                     addNote: "", hostRunningHere: true, version: "1.1.0", onSelectTarget: { _ in }, onAddTarget: {}, onDiagnostics: {}), width: 480)
        // 初回のガイドの各段
        for (name, flow) in [("ガイド・選ぶ", guide(nil)), ("ガイド・接続先を追加", guide(.connectFrom)), ("ガイド・接続先にする", guide(.both)),
                             ("ガイド・接続元を追加", guide(.both, steps: 1)), ("ガイド・最後", guide(.both, steps: 2))] {
            add(name, OnboardingContent(page: OnboardingPage.make(flow, hostRunning: true, canAddTarget: true, issueCode: (tr("接続元の Mac を追加…", "Add a Mac to Connect From…"), true)),
                                        hostSwitch: hostSwitch(.enabled), onChoose: { _ in }, onPrimary: {}, onAction: {}, onBack: {}, onLater: {}, onToggleHost: { _ in },
                                        onOpenLoginItems: {}), width: 480)
        }
        // 設定の 3 つのタブ
        add("設定・接続先", targetsContent(3))
        add("設定・この Mac の接続先", hostContent(viewers: 3))
        add("設定・この Mac の接続先（停止）", HostSettingsContent(panel: HostPanelModel.make(.notRunning(last: nil), now: 1_800_000_000), hostSwitch: hostSwitch(.requiresApproval),
                                                    actionMessage: "x", actionFailed: true, actionDetail: "detail", onAction: { _ in }, onToggleHost: { _ in },
                                                    onOpenLoginItems: {}, onOpenSettings: { _ in }))
        add("設定・一般", general)
        add("名前を変更", RenameTargetSheet(row: rows[0], onSave: { _ in }), width: 420)
        // 接続先の追加（入力・確認番号・結果）
        add("追加・入力", addForm(AddTargetFlow()), width: 460)
        add("追加・確認番号", addForm(addFlow { let r = $0.start()!.run; $0.receive(.awaitingApproval(code: 12_345), run: r) }), width: 460)
        add("追加・失敗", addForm(addFlow { let r = $0.start()!.run; $0.finish(.failure(.pairing(.notPaired)), run: r, name: nil) }), width: 460)
        // 診断・完全な削除
        let lines = [ViewerDiagnostics.Line(.ok, "ok"), ViewerDiagnostics.Line(.bad, "bad", advice: "advice", action: .openLoginItemsSettings)]
        add("診断", DiagnosticsContent(targetName: "Target 1", lines: lines, report: "report", busy: false, canRecheck: true, onRecheck: {}), width: 520)
        let items = Uninstaller.plannedItems(paths: AppPaths(home: URL(fileURLWithPath: "/Users/taro")), targetNames: ["Target 1"], homebrewRemoved: false)
        add("完全な削除・確認", UninstallContent(stage: .confirming, items: items, phase: nil, report: nil, onCancel: {}, onConfirm: {}, onClose: {}, onQuit: {}), width: 520)
        var report = UninstallReport(); report.appTrashed = true; report.brewCommand = "brew uninstall sharescale"
        add("完全な削除・結果", UninstallContent(stage: .finished, items: items, phase: .finished, report: report, onCancel: {}, onConfirm: {}, onClose: {}, onQuit: {}), width: 520)
        // ShareScale Host のウインドウ
        let L = HostLanguage.ja
        let code = PairingCode(id: pid(7), secret: Bytes32(Data(repeating: 7, count: 32))!, port: 47651, addresses: ["target1.local"], expiresAt: 1_800_000_421)!
        add("Host・接続コード", CodeView(p: CodePresentation(code, language: L), language: L, now: Date(timeIntervalSince1970: 1_800_000_000), copy: { _ in }, revoke: {}), width: 520)
        let request = ApprovalRequest(codeID: pid(7), name: "Mac 1", confirmationCode: 12_345, source: "100.101.1.3", sourceClass: .sharedCGNAT)
        add("Host・確認", ApprovalView(p: ApprovalPresentation(request, language: L), approve: {}, decline: {}), width: 420)
        add("Host・初回の知らせ", MenuBarNoticeView(p: MenuBarNoticePresentation(language: L), close: {}), width: 400)
        var hd = HostDiagnostics(); hd.listener = .listening(port: 47651)
        var sys = SystemDiagnostics(); sys.firewall = .on(.blocked); sys.fileVault = false; sys.loginItem = .requiresApproval
        let hostItems = DiagnosticsReport.items(host: hd, system: sys, pairings: [:], version: "1.1.0 (10100)", now: Date(timeIntervalSince1970: 1_800_000_000), language: L)
        add("Host・診断", HostDiagnosticsView(content: HostDiagnosticsContent(items: hostItems), language: L, onAction: { _ in }, onReload: {}, copy: { _ in }, scrolls: false))

        let screens = seen.all
        var total = 0
        for (name, items) in screens {
            let controls = items.filter { AXTree.pressableRoles.contains($0.role) && $0.enabled }
            XCTAssertFalse(controls.isEmpty, "押せる部品が 1 つも見つからない（木を読めていない）: \(name)")
            XCTAssertEqual(AXTree.unpressable(items), [], "使えるのに「押す」ができない部品: \(name)")
            total += controls.count
        }
        print("見て回った押せる部品: \(total) 個（\(screens.count) 画面）")
        // 数は 110 前後（追加の窓の「ペースト」は、クリップボードに文字がある時だけ使えるので、その時は 1 つ増える）
        XCTAssertGreaterThan(total, 100, "見て回った押せる部品の数（\(total)）")
        // ディスプレイのカード（全体が 1 つのボタン）も「押す」で適用できる
        let cards = screens[0].1.filter { $0.role == "AXButton" && $0.label.contains("Display 1") }
        XCTAssertEqual(cards.count, 1, "\(screens[0].1.map { "\($0.role): \($0.label)" })")
        XCTAssertEqual(cards.first?.canPress, true)
    }

    // 同じ形（押せる部品に `accessibilityElement(children: .ignore)`）を、画面のソースに戻さない。
    // 残っている `.ignore` は、文字だけのまとまり（押す部品を含まない）の 3 か所だけ
    func testIgnoreIsOnlyOnTextGroups() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var found: [String: Int] = [:]
        for folder in ["Sources/ShareScaleUI", "Sources/ShareScaleHostUI", "Sources/ShareScale", "Sources/ShareScaleHost"] {
            let dir = root.appendingPathComponent(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where name.hasSuffix(".swift") {
                let s = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                // 先頭の「.」まで含めて数える（説明の中の引用は「`accessibilityElement(…)`」と書くので、数に入らない）
                let n = s.components(separatedBy: ".accessibilityElement(children: .ignore)").count - 1
                if n > 0 { found[folder + "/" + name] = n }
                XCTAssertFalse(s.contains(".onTapGesture"), "押す操作は Button で作る（タップだけの部品は「押す」を持たない）: \(name)")
            }
        }
        XCTAssertEqual(found, ["Sources/ShareScaleUI/SettingsView.swift": 2, "Sources/ShareScaleUI/AddTargetView.swift": 1],
                       "増えた時は、その部品が押す操作を含まないことを確かめてから、この数を直す")
    }
}

/// 偽の接続先に 1 回問い合わせた後の主の窓の中身
@MainActor func viewerModel(_ result: Result<RemoteState, ViewerFailure>) async -> ViewerModel {
    let vm = ViewerModel(client: FixedTarget(result), displays: { [display(1, builtIn: false), display(2, builtIn: true)] }, targetLabel: "Target 1")
    await vm.refresh()
    return vm
}

/// 見て回った画面（名前と、アクセシビリティの木の要素）
@MainActor
final class Screens {
    private(set) var all: [(String, [AXItem])] = []
    func add(_ name: String, _ view: some View, width: CGFloat) { all.append((name, AXTree.items(view, width: width))) }
}

// ---- この試験だけの偽のデータ ----

/// 結果を固定した接続先
final class FixedTarget: TargetControlling, @unchecked Sendable {
    let result: Result<RemoteState, ViewerFailure>
    init(_ result: Result<RemoteState, ViewerFailure>) { self.result = result }
    func status() async -> Result<RemoteState, ViewerFailure> { result }
    func set(_ mode: DisplayMode) async -> Result<RemoteState, ViewerFailure> { result }
}

func display(_ id: UInt32, builtIn: Bool) -> LocalDisplay {
    LocalDisplay(id: id, name: "Display \(id)", pixels: Resolution(width: builtIn ? 3024 : 2560, height: builtIn ? 1964 : 1080), backingScale: builtIn ? 2 : 1, isBuiltIn: builtIn)
}

func remoteState() -> RemoteState {
    RemoteState(StatusPayload(name: "Target 1", model: "Mac Studio", paused: false, session: true, mode: .oneX,
                              virtualDisplay: StatusPayload.VirtualDisplay(resolution: "1920x997", scaling: .oneX, source: .signature),
                              ambiguous: false, lastError: nil, setBy: nil, port: 47651, addresses: ["target1.local"])!)
}

/// 初回のガイドの各段（`goal` を選び、`steps` 回「次へ」を押した姿）
func guide(_ goal: OnboardingFlow.Goal?, steps: Int = 0) -> OnboardingFlow {
    var f = OnboardingFlow()
    if let goal { f.choose(goal) }
    for _ in 0..<steps { _ = f.next(hostRunning: true) }
    return f
}

/// 接続先の追加の窓の各段（接続コードを入れた姿から）
func addFlow(_ build: (inout AddTargetFlow) -> Void) -> AddTargetFlow {
    var f = AddTargetFlow()
    f.code = PairingCode(id: pid(7), secret: Bytes32(Data(repeating: 7, count: 32))!, port: 47651, addresses: ["target1.local"], expiresAt: 4_000_000_000)!.encoded()
    build(&f)
    return f
}

@MainActor func addForm(_ flow: AddTargetFlow) -> AddTargetForm {
    AddTargetForm(flow: flow, tab: .constant(flow.tab), code: .constant(flow.code), address: .constant(flow.address), key: .constant(flow.key),
                  expiryWarning: nil, onPaste: { _ in }, onStart: {}, onCancel: {}, onRetry: {}, onClose: {})
}
