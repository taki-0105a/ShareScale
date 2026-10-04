# ShareScale

[English](README.md)

ShareScale は、画面共有で操作する相手の Mac の表示倍率を、見ているディスプレイに合わせて **1x** か **2x** に自動で保つアプリです。

macOS の画面共有を高パフォーマンスのモードで使うと、操作される側の Mac は画面を仮想ディスプレイに描きます。ShareScale を使うと、その仮想ディスプレイを 1x（1 点を 1 画素。通信量は約半分。実測で、画面の中身によって変わります）で描くか 2x（Retina の細かさ）で描くかを、自分のディスプレイごとに選べ、画面共有を始めるたびにその表示倍率に保ちます。

**ShareScale は無料で、現状のまま提供します。利用は自己責任でお願いします。問い合わせへの対応は約束しません。** ライセンスは [LICENSE](LICENSE)（MIT）です。

<!--
スクリーンショット: 日本語の画面を実際に撮った画像を docs/images/ に置き、次の行のコメントを外す。
個人の名前・アドレス・接続コードが写っていないこと。docs/ はリリースの tarball に入らない。
![主のウインドウ](docs/images/main-ja.png)
![メニューバー](docs/images/menu-ja.png)
![ペアリング（確認番号）](docs/images/pairing-ja.png)
![はじめに](docs/images/getting-started-ja.png)
-->

## しくみ

- ShareScale を **2 台の Mac の両方**に入れます。手元で使っている Mac（接続元の Mac）と、操作される側の Mac（接続先）です。このページでは、操作される側の Mac をいつも「接続先」と呼びます。
- 接続先では、ShareScale がメニューバーの小さなアプリ **ShareScale Host** をログイン項目として動かします。ShareScale Host は選ばれた表示倍率を保ち、画面共有の仮想ディスプレイが現れるたびにそれを当てます。
- 接続元の Mac では、ShareScale が自分のディスプレイごとにカードを出します。カードをクリックするか、メニューバーから、**1x 等倍**か **2x Retina** を選びます。
- 2 台は、接続コードと 6 桁の確認番号で一度だけペアリングします。その後は、同じネットワークか Tailscale の上で、暗号化された接続で通信します。SSH・ターミナル・管理者の権限は要りません（Homebrew での導入を除く）。

## 必要なもの

- Apple シリコンの Mac 2 台（macOS 14 Sonoma 以降）。**動作を確かめているのは macOS 27 だけです**（下の「制限と既知のこと」）
- macOS の画面共有の高パフォーマンスのモード（ShareScale が表示倍率を変える仮想ディスプレイは、このモードで作られます）
- [Homebrew](https://brew.sh) と、最新の Command Line Tools for Xcode（または Xcode）。ShareScale はお使いの Mac の上でソースから組み立てます
- 2 台が同じネットワークか [Tailscale](https://tailscale.com) で互いに届くこと

## 入れ方

それぞれの Mac で:

```sh
brew install taki-0105a/tap/sharescale
open "$(brew --prefix)/opt/sharescale/ShareScale.app"
```

初めて開いた時、ShareScale は自分を `~/Applications/ShareScale.app` にコピーし、そのコピーを開きます。以後はこのコピーを使ってください（ShareScale Host を登録するのも、アップデートで置き換わるのもこのコピーです）。

## はじめ方

ShareScale を初めて開くと、**はじめに**のガイドが、したいことを尋ねて順に案内します。設定 › 一般の「**はじめに…**」からもう一度開けます。手順は次のとおりです。

1. **操作される側の Mac（接続先）で:** 画面共有をオンにします（システム設定 › 一般 › 共有 › 画面共有）。ShareScale の設定 › この Mac の接続先で「**この Mac を接続先にする**」をオンにします。ShareScale Host がログイン項目に登録され、動き始めます。
2. **接続先で:** 「**接続元の Mac を追加…**」を選びます（ShareScale のメニューバーのメニューか、設定 › この Mac の接続先）。「**接続コード**」ウインドウが出ます。コードの有効期限は 10 分で、1 回だけ使えます。
3. **接続元の Mac で:** 「**接続先を追加…**」をクリックし、接続コードを貼り付けます。画面共有のクリップボードの共有かユニバーサルクリップボードで届きます。「接続コード」ウインドウに出るアドレスとキーを手で入力することもできます。
4. 2 台に同じ **6 桁の確認番号**が出ます。同じなら接続先で「**追加する**」をクリックします。違えば「**追加しない**」をクリックします。

あとは、いつもどおり画面共有を始めてください。ShareScale が、見ているディスプレイに選んだ表示倍率へ仮想ディスプレイを切り替えます。

## ふだんの使い方

- **主のウインドウ:** ディスプレイごとにカードが出ます。カードには、今当たっているもの（「適用中」）と選んだもの（「選択中」）が出ます。ディスプレイごとに 1x か 2x を選ぶと、ShareScale が覚えます。
- **メニューバー:** ShareScale はメニューバーに残ります。そこから、ディスプレイごとの 1x 等倍と 2x Retina の切り替え・更新・接続先の切り替えができ、ShareScale や設定を開けます。主のウインドウを閉じても ShareScale は終了しません。終了は「**ShareScale を終了**」です。
- **メニューバーのアイコンは 1 つ:** ShareScale が開いている間は、ShareScale Host は自分のアイコンを出さず、ShareScale のメニューに「**この Mac の接続先**」の節が出ます。ShareScale を終了すると ShareScale Host のアイコンが戻ります。両方を常に出すには、設定 › 一般の「**ShareScale Host のアイコンを常にメニューバーに表示する**」をオンにします。
- **設定 › 一般:** 「**Dock に表示する**」（既定はオン）、「**ログイン時に ShareScale を開く**」（既定はオフ。`~/Applications` のコピーだけがオンにできます）、表示倍率や接続の変化の通知（任意。オンにすると、ShareScale が前面にない間は 1 分ごとに接続先を確認します。失敗の後と低電力モードの間は 5 分ごと）、「**ShareScale を完全に削除…**」。
- 「**診断…**」は、各段階（ローカルネットワークの許可・届くか・ペアリング・接続先・画面共有・仮想ディスプレイ・表示倍率）を確認し、関係するシステム設定を開けます。

## アップデート

```sh
brew upgrade sharescale
```

その後、**ShareScale を終了して開き直してください**（メニューバー › ShareScale を終了）。ShareScale が `~/Applications` のコピーを新しいバージョンに置き換え、新しい ShareScale Host を登録します。開き直すまでは前のバージョンが動き続けます。ShareScale が開いている間も、「新しいバージョンがあります」と「**ShareScale を終了して開き直す…**」を出します。

## 削除

1. ShareScale の設定 › 一般 › 「**ShareScale を完全に削除…**」を選びます。ShareScale Host を止めて登録を解除し、接続先それぞれにこの Mac の登録の解除を頼み、ペアリングの秘密を削除し、設定・ログ・`~/Applications/ShareScale.app` をゴミ箱に入れ、「ログイン時に ShareScale を開く」を外します。
2. その後、次を実行します。

   ```sh
   brew uninstall sharescale
   ```

先に `brew uninstall` をした場合は、`~/Applications/ShareScale.app` を開くと、この Mac からも完全に削除するかを尋ねます。

手で削除する場合: 「この Mac を接続先にする」をオフにし（またはシステム設定 › 一般 › ログイン項目で ShareScale を削除し）、ShareScale と ShareScale Host を終了してから、`~/Library/Application Support/ShareScale/pairings/` を削除し（ペアリングの秘密が入っているので、ゴミ箱に残さないでください）、`~/Library/Application Support/ShareScale/`・`~/Library/Logs/ShareScale/`・`~/Library/Preferences/io.github.taki-0105a.ShareScale.plist`・`~/Library/Preferences/io.github.taki-0105a.ShareScale.Host.plist`・`~/Library/Saved Application State/io.github.taki-0105a.ShareScale.savedState`・`~/Applications/ShareScale.app` を取り除きます。接続先では、設定 › この Mac の接続先からこの Mac の登録を解除します。

## ソースから組み立てる（予備の手順）

```sh
git clone https://github.com/taki-0105a/ShareScale.git
cd ShareScale
scripts/build-sharescale.sh --install
open ~/Applications/ShareScale.app
```

`--install` は、アプリを `~/Applications/ShareScale.app` にコピーした後、`build/ShareScale.app` を削除します（Spotlight や Launchpad で名前から開いた時に、インストールした方が開くようにするためです）。`--install` を付けない `scripts/build-sharescale.sh` は `build/ShareScale.app` を作るだけです。そちらを開くと、`~/Applications` の ShareScale を開くよう案内します（`~/Applications` にあれば、開くボタンも出ます）。試験は `scripts/test-all.sh` で流します（XCTest には Xcode が要ります）。試験はループバックのアドレスだけを使い、ホームフォルダの実際の場所には書きません。画面の部品の試験（`ShareScaleUITests`）はアクセシビリティの木を読むもので、macOS 27 で確かめています。木を読めない環境では飛ばします（`SHARESCALE_REQUIRE_AX_TESTS=1` を付けると、飛ばさずに失敗にします）。

## 安全の設計

ShareScale Host にできることは、あえて少なくしています。ペアリングの手続き（`hello`・`reveal`）と、接続元の Mac が自分のペアリングの登録を解除すること（`unpair`）を除けば、受け付けるのは表示倍率の変更（`set`）と、状態（`status`）と短いログ（`log`）の報告だけです。任意のコマンドを実行したり、任意のファイルを読み書きしたりはせず、画面共有をオンにすることもできません。

- **暗号化された相互認証の接続:** TLS 1.2 の ECDHE-PSK（`TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`。前方秘匿性あり）で、ペアリングごとに乱数の 256 ビットの秘密を使います。指示は TLS のセッションにも結び付けます。
- **ペアリング:** 接続先が、1 回限りで 10 分間有効な接続コードを出します。2 台はそれぞれ TLS のセッションから 6 桁の確認番号を作って表示し、番号が同じ時だけ、利用者が接続先でペアリングを承認します。間に入って中継されると、2 台の番号が違います。
- **秘密は 2 台の中だけ:** ペアリングごとの秘密は接続先（ShareScale Host）で作り、暗号化されたペアリングの接続の中で接続元の Mac に 1 回だけ届けます。それ以外には送りません（その後は TLS の鍵として使うだけです）。接続コードの中の秘密は 1 回限りで、ペアリングが終わるまでしか使えず、その後は取り替えます。秘密は `~/Library/Application Support/ShareScale/pairings/`（フォルダ 700・ファイル 600）に置き、バックアップの対象から外します。FileVault をオンにすることをお勧めします。
- **接続を受け付ける相手:** 既定では、ShareScale Host は次からの接続を受け付けます。この Mac（ループバック）、プライベートとリンクローカルのアドレス（`10.0.0.0/8`・`172.16.0.0/12`・`192.168.0.0/16`・`169.254.0.0/16`・`fe80::/10`。どのネットワークから届いたかは問いません）、`100.64.0.0/10` と `fc00::/7`（Tailscale が使う範囲。ほかのネットワークも使います）、接続先の Wi‑Fi か有線と同じサブネットのグローバルなアドレス。それ以外のグローバルなアドレスからの接続は、「インターネットからの接続も受け付ける」をオンにしない限り、TLS の前に断ります。「Tailscale からの接続だけを受け付ける」も選べます。3 つのうちどれが有効かは、ShareScale Host のメニューと、設定 › この Mac の接続先に出ます（既定は「ローカルネットワークと Tailscale からの接続を受け付けています」。ほかは「インターネットを含むすべてのネットワークからの接続を受け付けています」「Tailscale からの接続だけを受け付けています」）。
- **上限:** 同時の接続の数・各段階の時間に上限があり、失敗を繰り返すアドレスは一時的に締め出します。

設計（脅威モデル・通信・保管・配布・診断）は [docs/design.md](docs/design.md) にあります。脆弱性の知らせ方は [SECURITY.md](SECURITY.md) を見てください。

## 制限と既知のこと

- ShareScale は簡易署名（ad-hoc）で、公証を受けていません（お使いの Mac の上で組み立てるので、Gatekeeper には止められません）。そのため、アップデートや組み立て直しの後に、macOS がローカルネットワークへのアクセスや、ShareScale Host への外部からの接続の許可（ファイアウォール）をもう一度尋ねることがあります。
- アップデートの直後に ShareScale を開くと、ShareScale Host が動き出すまで 10 秒ほどかかることがあり、macOS が ShareScale Host の最初の起動を止めた記録（「Launch Constraint Violation」）が「コンソール」の「クラッシュレポート」に 1 つ（まれに 2 つ以上）残り、「予期しない理由で終了しました」の窓が出ることがあります。ShareScale が自動で登録し直すので、そのままで構いません（macOS 27 で確認）。
- macOS のファイアウォールがオンなら、ShareScale Host への外部からの接続を許可してください（システム設定 › ネットワーク › ファイアウォール › オプション）。「外部からの接続をすべてブロック」がオンだと ShareScale Host に届きません。診断で分かります。ShareScale Host がまだファイアウォールの一覧に無い時は、初めて接続を受けた時に、macOS が許可を求めることがあります（macOS 27 で確認）。接続先の Mac で「許可」をクリックするまで、接続元の Mac には「接続先に接続できません」と表示されます。
- ShareScale Host は TCP のポート 47651 で待ち受けます。
- Apple シリコンだけです。macOS 14 Sonoma 以降を対象に作っていますが、開発と動作の確認は macOS 27 だけで行っています。それより古いバージョンでは動かない場合があります。その時は、バージョンを添えて Issue で知らせてください（ほかと同じく、修正は約束できません）。
- ShareScale が変えるのは、画面共有の仮想ディスプレイの表示倍率だけです。画面共有を始めたり、止めたり、設定したりはしません。
- 「Retina」は 2x の設定の説明にだけ使っています。ShareScale は Apple と関係がなく、Apple の承認を受けたものでもありません。

## ライセンス

MIT。[LICENSE](LICENSE) を見てください。
