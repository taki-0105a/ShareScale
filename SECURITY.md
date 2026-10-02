# Security Policy

[日本語は下にあります](#日本語)

## Supported versions

Only the latest release of ShareScale receives security fixes.

| Version | Supported |
|---|---|
| 1.0.x (latest) | Yes |
| Older | No |

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's **Private vulnerability reporting**: open the repository's **Security** tab and choose **Report a vulnerability** (<https://github.com/taki-0105a/ShareScale/security/advisories/new>). Do not open a public issue for a vulnerability.

Please include the version (Settings › General in ShareScale), your macOS version, and the steps to reproduce. Do not include your pairing codes, keys, or the files in `~/Library/Application Support/ShareScale/pairings/`.

ShareScale is maintained by one person in their spare time. Reports are welcome, but there is no promise of a response time or a fix.

The design and threat model are in [docs/design.md](docs/design.md) (in Japanese) and summarized in the Security section of [README.md](README.md).

## 日本語

### 対象のバージョン

安全の修正は、ShareScale の最新のリリースにだけ行います（今は 1.0.x）。

### 脆弱性の知らせ方

GitHub の **Private vulnerability reporting** で、公開せずに知らせてください。リポジトリの **Security** のタブから **Report a vulnerability** を選びます（<https://github.com/taki-0105a/ShareScale/security/advisories/new>）。脆弱性を公開の issue に書かないでください。

バージョン（ShareScale の設定 › 一般）・macOS のバージョン・再現の手順を書いてください。接続コード・キー・`~/Library/Application Support/ShareScale/pairings/` のファイルは含めないでください。

ShareScale は 1 人が空いた時間に保守しています。知らせは歓迎しますが、返事や修正の時期は約束しません。

設計と脅威モデルは [docs/design.md](docs/design.md) にあります。
