// swift-tools-version:5.9
import PackageDescription

// ShareScale: 画面共有の接続先の Mac の表示倍率を 1x／2x に自動で保つ（見る側 ShareScale.app と、ログイン項目の ShareScale Host.app）。
// 組み立ては scripts/build-sharescale.sh、試験は scripts/test-all.sh。リモートの依存（他人のパッケージ）は持たない。
let package = Package(
    name: "ShareScale",
    platforms: [.macOS(.v14)],
    targets: [
        // 通信の規則（純粋な関数だけ。ネットワークに触れない）
        .target(name: "ShareScaleProtocol"),
        .testTarget(name: "ShareScaleProtocolTests", dependencies: ["ShareScaleProtocol"]),
        // 暗号化された通信の窓口（TLS-PSK）と秘密の保管
        .target(name: "ShareScaleNet", dependencies: ["ShareScaleProtocol"]),
        .testTarget(name: "ShareScaleNetTests", dependencies: ["ShareScaleNet", "ShareScaleProtocol"]),
        // 表示倍率の維持（仮想ディスプレイの見分け・状態の保存・CoreGraphics と子プロセスの口）
        .target(name: "ShareScaleEngine", dependencies: ["ShareScaleNet"]),
        .testTarget(name: "ShareScaleEngineTests", dependencies: ["ShareScaleEngine"]),
        // Host の中核（画面なし）。付帯情報・ログ・ネットワークの見張り・指示への応答・同じ Mac の中の受け渡し
        .target(name: "ShareScaleHostCore", dependencies: ["ShareScaleEngine", "ShareScaleNet", "ShareScaleProtocol"]),
        .testTarget(name: "ShareScaleHostCoreTests",
                    dependencies: ["ShareScaleHostCore", "ShareScaleEngine", "ShareScaleNet", "ShareScaleProtocol"]),
        // Host の画面（メニューバー・確認のウインドウ・接続コードのウインドウ・診断のウインドウ）
        .target(name: "ShareScaleHostUI", dependencies: ["ShareScaleHostCore", "ShareScaleEngine", "ShareScaleNet", "ShareScaleProtocol"]),
        // Host の実行ファイル（引数なし＝常駐、--apply-once／--probe＝子プロセス）
        .executableTarget(name: "ShareScaleHost", dependencies: ["ShareScaleHostUI", "ShareScaleHostCore", "ShareScaleEngine", "ShareScaleProtocol"]),
        // 見る側の中核（画面なし）。接続先の帳簿・接続・ペアリング・診断・配布（~/Applications への複製・ログイン項目・完全な削除）
        .target(name: "ShareScaleCore", dependencies: ["ShareScaleHostCore", "ShareScaleEngine", "ShareScaleNet", "ShareScaleProtocol"]),
        .testTarget(name: "ShareScaleCoreTests",
                    dependencies: ["ShareScaleCore", "ShareScaleHostCore", "ShareScaleEngine", "ShareScaleNet", "ShareScaleProtocol"]),
        // 見る側の画面（SwiftUI の部品。論理は ShareScaleCore）
        .target(name: "ShareScaleUI", dependencies: ["ShareScaleCore", "ShareScaleHostCore", "ShareScaleProtocol"]),
        // 見る側の実行ファイル（アプリ本体 ShareScale.app）
        .executableTarget(name: "ShareScale", dependencies: ["ShareScaleUI", "ShareScaleCore", "ShareScaleHostCore", "ShareScaleNet", "ShareScaleProtocol"]),
        // 開発用: 偽のデータで各画面を PNG に書き出す（ImageRenderer。ウインドウは出さない）
        .executableTarget(name: "ShareScaleSnapshots", dependencies: ["ShareScaleUI", "ShareScaleCore", "ShareScaleHostUI", "ShareScaleHostCore", "ShareScaleProtocol"]),
        // 画面の部品の試験（ウインドウは出さない。設定のタブの高さと、アクセシビリティの「押す」。計画 2h）
        .testTarget(name: "ShareScaleUITests",
                    dependencies: ["ShareScaleUI", "ShareScaleHostUI", "ShareScaleCore", "ShareScaleHostCore", "ShareScaleProtocol"]),
    ]
)
