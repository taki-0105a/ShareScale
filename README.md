# ShareScale

[日本語](README.ja.md)

ShareScale keeps the display scale of the Mac you control with Screen Sharing at **1x** or **2x**, matched to the display you are looking at.

When you use macOS Screen Sharing in High Performance mode, the Mac you control draws its screen on a virtual display. ShareScale lets you choose, for each of your displays, whether that virtual display is drawn at 1x (one point per pixel, about half the data (measured; depends on what’s on screen)) or 2x (Retina-sharp), and keeps it that way every time Screen Sharing starts.

**ShareScale is free software provided as is, at your own risk. There is no promise of support or answers to questions.** See [LICENSE](LICENSE) (MIT).

<!--
Screenshots: put real captures of the English UI in docs/images/ and uncomment these lines.
No personal names, addresses, or pairing codes may be visible. docs/ is not included in the release tarball.
![The main window](docs/images/main-en.png)
![The menu bar](docs/images/menu-en.png)
![Pairing: the confirmation number](docs/images/pairing-en.png)
![Getting Started](docs/images/getting-started-en.png)
-->

## How it works

- Install ShareScale on **both** Macs: the Mac you sit at (the Mac you connect from) and the Mac you control (the Host). This page always calls the Mac you control “the Host”; the app’s buttons and settings call it a target, as in **Add Target…**.
- On the Host, ShareScale runs a small menu bar app, **ShareScale Host**, as a login item. It keeps the scale you chose and applies it whenever Screen Sharing’s virtual display appears.
- On the Mac you connect from, ShareScale shows a card for each of your displays. Click a card, or use the menu bar, to pick **1x Standard** or **2x Retina**.
- The two Macs are paired once with a pairing code and a 6-digit confirmation number. After that they talk over an encrypted connection on your local network or Tailscale. No SSH, Terminal, or administrator rights are needed (except for installing with Homebrew).

## Requirements

- Two Macs with Apple silicon, running macOS 14 Sonoma or later. **ShareScale has only been tested on macOS 27** (see [Limitations and known issues](#limitations-and-known-issues))
- macOS Screen Sharing in High Performance mode (it creates the virtual display ShareScale adjusts)
- [Homebrew](https://brew.sh) and the latest Command Line Tools for Xcode (or Xcode). ShareScale is built from source on your Mac
- The Macs can reach each other on the same network or through [Tailscale](https://tailscale.com)

## Install

On each Mac:

```sh
brew install taki-0105a/tap/sharescale
open "$(brew --prefix)/opt/sharescale/ShareScale.app"
```

The first time it opens, ShareScale copies itself to `~/Applications/ShareScale.app` and opens that copy. Use the copy from then on (it is the copy that registers ShareScale Host, and the copy that an update replaces).

## Getting started

When you open ShareScale for the first time, **Getting Started** asks what you want to do and walks you through it. You can open it again from Settings › General › **Getting Started…**. The steps are:

1. **On the Mac you want to control (the Host):** turn on Screen Sharing (System Settings › General › Sharing › Screen Sharing). In ShareScale, open Settings › This Mac as a Target and turn on **Use This Mac as a Target**. ShareScale Host is registered as a login item and starts.
2. **On the Host:** choose **Add a Mac to Connect From…** (in ShareScale’s menu bar menu or in Settings › This Mac as a Target). A **Pairing Code** window appears. The code is valid for 10 minutes and can be used once.
3. **On the Mac you connect from:** click **Add Target…** and paste the pairing code. Screen Sharing’s shared clipboard or Universal Clipboard carries it; you can also type the address and key shown in the Pairing Code window.
4. Both Macs show the same **6-digit confirmation number**. If they match, click **Add** on the Host. If they don’t, click **Don’t Add**.

Then start Screen Sharing as usual. ShareScale switches the virtual display to the scale you chose for the display you are looking at.

## Everyday use

- **Main window:** one card per display. The card shows what is applied now (“Applied”) and what you chose (“Selected”). Choose 1x or 2x for each display; ShareScale remembers it.
- **Menu bar:** ShareScale stays in the menu bar. From there you can switch each display between 1x Standard and 2x Retina, refresh, switch between Hosts, and open ShareScale or Settings. Closing the main window does not quit ShareScale; choose **Quit ShareScale** to quit.
- **One menu bar icon:** while ShareScale is open, ShareScale Host hides its own icon and ShareScale’s menu shows a **This Mac as a Target** section instead. When ShareScale quits, ShareScale Host’s icon comes back. To always show both, turn on Settings › General › **Always Show ShareScale Host’s Icon in the Menu Bar**.
- **Settings › General:** **Show in Dock** (on by default), **Open ShareScale at Login** (off by default; only the copy in `~/Applications` can turn it on), optional notifications about scale and connection changes (while ShareScale is in the background, it then checks the Host every minute, or every 5 minutes after a failure or in Low Power Mode), and **Remove ShareScale Completely…**.
- **Diagnostics…** checks each step (Local Network permission, reachability, pairing, the Host, Screen Sharing, the virtual display, the scale) and can open the related System Settings pane.

## Update

```sh
brew upgrade sharescale
```

Then **quit ShareScale** (menu bar › Quit ShareScale) **and open it again**. ShareScale replaces the copy in `~/Applications` with the new version and registers the new ShareScale Host. Until you do, the previous version keeps running. While ShareScale is open, it also shows “A new version is available” with **Quit and Reopen ShareScale…**.

## Uninstall

1. In ShareScale, choose Settings › General › **Remove ShareScale Completely…**. It stops and unregisters ShareScale Host, asks each Host to remove this Mac, deletes the pairing secrets, moves the settings, logs, and `~/Applications/ShareScale.app` to the Trash, and turns off Open ShareScale at Login.
2. Then run:

   ```sh
   brew uninstall sharescale
   ```

If you ran `brew uninstall` first, open `~/Applications/ShareScale.app`: it asks whether to remove ShareScale completely from this Mac too.

To remove it by hand instead: turn off **Use This Mac as a Target** (or remove ShareScale in System Settings › General › Login Items), quit ShareScale and ShareScale Host, then delete `~/Library/Application Support/ShareScale/pairings/` (do not keep it in the Trash: it contains the pairing secrets) and remove `~/Library/Application Support/ShareScale/`, `~/Library/Logs/ShareScale/`, `~/Library/Preferences/io.github.taki-0105a.ShareScale.plist`, `~/Library/Preferences/io.github.taki-0105a.ShareScale.Host.plist`, `~/Library/Saved Application State/io.github.taki-0105a.ShareScale.savedState`, and `~/Applications/ShareScale.app`. On each Host, remove this Mac from Settings › This Mac as a Target.

## Build from source (alternative)

```sh
git clone https://github.com/taki-0105a/ShareScale.git
cd ShareScale
scripts/build-sharescale.sh --install
open ~/Applications/ShareScale.app
```

`--install` copies the app to `~/Applications/ShareScale.app` and then removes `build/ShareScale.app`, so that opening ShareScale by name (Spotlight, Launchpad) opens the installed copy. `scripts/build-sharescale.sh` without `--install` only builds `build/ShareScale.app`; if you open that one, it tells you to open the copy in `~/Applications` (and offers a button for it when the copy exists). Run the tests with `scripts/test-all.sh` (XCTest needs Xcode). The tests use only the loopback address and never write to the real locations in your home folder. The UI tests (`ShareScaleUITests`) read the accessibility tree and have been checked on macOS 27; where the tree can’t be read they are skipped (set `SHARESCALE_REQUIRE_AX_TESTS=1` to make that a failure).

## Security

ShareScale Host can do very little on purpose. Apart from pairing (`hello`, `reveal`) and letting a Mac remove its own pairing (`unpair`), the only requests it accepts are changing the display scale (`set`) and reporting its status (`status`) and a short log (`log`). It does not run arbitrary commands, does not read or write arbitrary files, and cannot turn on Screen Sharing.

- **Encrypted, mutually authenticated connection:** TLS 1.2 ECDHE-PSK (`TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`, forward secrecy) with a random 256-bit secret per pairing. Each request is also bound to the TLS session.
- **Pairing:** the Host issues a one-time pairing code that is valid for 10 minutes. Both Macs then show a 6-digit confirmation number that each derives from the TLS session, and you approve the pairing on the Host only if the numbers match. If someone relays the connection in the middle, the two Macs show different numbers.
- **Secrets stay on the Macs:** each pairing secret is created on the Host and delivered once to the Mac you connect from, inside the encrypted pairing connection; it is not sent anywhere else (afterwards it is only used as the TLS key). The secret in a pairing code works only once and only until the pairing completes, and is then replaced. Secrets are stored in `~/Library/Application Support/ShareScale/pairings/` (folder 700, files 600), excluded from backups. Turning on FileVault is recommended.
- **Who can connect:** by default ShareScale Host accepts connections from this Mac (loopback); from any private or link-local address (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `fe80::/10`), whichever network it arrives on; from `100.64.0.0/10` and `fc00::/7` (the ranges Tailscale uses, which other networks use too); and from global addresses on the same subnet as the Host’s Wi‑Fi or Ethernet. Connections from other global addresses are refused before TLS starts unless you turn on “Also accept connections from the internet”. You can also choose “Accept connections from Tailscale only”. The ShareScale Host menu and Settings › This Mac as a Target show which of the three is in effect: “Accepting connections from local networks and Tailscale” (the default), “Accepting connections from all networks, including the internet”, or “Accepting connections from Tailscale only”.
- **Limits:** a few connections at a time, time limits on every step, and a temporary block for addresses that fail repeatedly.

The design (threat model, protocol, storage, distribution, diagnostics) is described in [docs/design.md](docs/design.md) (in Japanese). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Limitations and known issues

- ShareScale is ad-hoc signed and not notarized (it is built on your Mac, so Gatekeeper does not block it). Because of this, after an update or a rebuild macOS may ask again for Local Network access, or for the firewall to allow incoming connections to ShareScale Host.
- If the macOS firewall is on, allow incoming connections for ShareScale Host (System Settings › Network › Firewall › Options). “Block all incoming connections” stops ShareScale Host from being reached. Diagnostics shows this. If ShareScale Host isn’t in the firewall’s list yet, macOS may ask the first time ShareScale Host receives a connection (confirmed on macOS 27); until you click Allow on the Host, the Mac you sit at shows “Can’t connect to the Host”.
- ShareScale Host listens on TCP port 47651.
- Apple silicon only. ShareScale is built for macOS 14 Sonoma or later, but it has been developed and tested only on macOS 27. It may not work on older versions. If it doesn’t, please open an issue and say which version; as with everything here, there is no promise of a fix.
- ShareScale changes only the scale of Screen Sharing’s virtual display. It does not start, stop, or configure Screen Sharing.
- “Retina” is used only to describe the 2x setting. ShareScale is not affiliated with or endorsed by Apple.

## License

MIT. See [LICENSE](LICENSE).
