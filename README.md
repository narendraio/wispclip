# Wisp

**A clipboard with a memory.** — [wispclip.com](https://wispclip.com)

[![Latest release](https://img.shields.io/github/v/release/narendraio/wispclip)](https://github.com/narendraio/wispclip/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/narendraio/wispclip/total)](https://github.com/narendraio/wispclip/releases)
[![Build](https://github.com/narendraio/wispclip/actions/workflows/build.yml/badge.svg)](https://github.com/narendraio/wispclip/actions/workflows/build.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Wisp is a lightweight clipboard manager for macOS. It sits in the menu bar, quietly remembers everything you copy (text, rich text, images, files), and hands it back the moment you press **⌃⌘V**. Free and open source.

<!-- Add a screenshot or demo GIF here, e.g. ![Wisp](docs/screenshot.png) -->

## Why Wisp

- **Fast and native.** A tiny native Swift app (a ~1 MB download), no Electron, lives in the menu bar.
- **Private by design.** Your history stays on your Mac. Wisp makes no network requests, has no accounts, no analytics, and skips copies that password managers mark as concealed.
- **Built for developers.** Recognizes JSON, SQL, JWTs, UUIDs and colors, and ⌘K transforms format, decode, convert case and more without leaving the keyboard.
- **Free forever.** MIT licensed, no subscription.

## Download

**[⬇ Download Wisp.dmg](https://github.com/narendraio/wispclip/releases/latest/download/Wisp.dmg)** (universal: Apple silicon and Intel, macOS 14+)

Open the DMG and drag Wisp into Applications. Wisp isn't notarized yet, so on first launch go to **System Settings → Privacy & Security** and click **Open Anyway**. Or, in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Wisp.app
```

## Build from source

```bash
git clone https://github.com/narendraio/wispclip.git
cd wispclip
./build.sh             # builds build/Wisp.app
./build.sh --install   # also copies it to /Applications and launches it
./build.sh --dmg       # universal app plus build/Wisp.dmg
```

Requires macOS 14+ and Xcode / Swift command line tools.

## Use

| Action | How |
| --- | --- |
| Open history | **⌃⌘V** (Control + Command + V) anywhere, or click the menu bar icon |
| Paste an item | click it, or ↑/↓ then **Return** |
| Paste as plain text (no formatting) | **⌥Return** or ⌥-click |
| Actions menu (transforms, pin, delete…) | **⌘K** |
| Switch type filter (All / Text / Links / Images / Files / Snippets) | **Tab** / **⇧Tab** |
| Save selected item as a snippet | **⌘S** |
| New snippet / edit snippet | **⌘N** / **⌘E** (Esc when done; saves as you type) |
| Open a copied link | **⌘O** |
| Quick paste | **⌘1 … ⌘9** |
| Search | just start typing |
| Pin (keep forever, always on top) | **⌘P** or right-click → Pin |
| Delete item (it turns to dust) | **⌘⌫**, the trash button, or right-click → Delete |
| Close | **Esc** |

The menu bar menu also has: the 10 most recent items, New Snippet, Pause Recording, Clear History (keeps pinned items and snippets), Copy Sound, Sound While Browsing, Open at Login, and a link to wispclip.com.

**Smart detection:** JSON, SQL, UUIDs, JWTs, links, emails and colors are recognized. JSON and SQL get syntax coloring in the preview, JWTs are decoded (with expiry), colors show a swatch.

**⌘K transforms:** Format / Minify JSON, Decode JWT, Format SQL, Make SQL `IN (...)` list, UPPER / lower / Title / camel / snake / kebab case, Trim, Join / Sort / Dedupe lines, URL and Base64 encode/decode, plus Generate UUID / timestamp. The result is pasted and saved to history.

**Sounds:** pick the copy sound under **Copy Sound** (Soft Tap by default, or None). Soft ticks while moving through or scrolling the list can be turned off with **Sound While Browsing**.

**Auto-paste:** to have a picked item pasted straight into the app you were using, allow Wisp in
System Settings → Privacy & Security → Accessibility. Without it, picking an item just copies it and you press ⌘V yourself.

## Details

- Keeps the last 300 items, plus any number of pinned items and snippets.
- History is stored in `~/Library/Application Support/ClipBoard/` (images as PNG files). The folder keeps the app's original name so history survives the rename to Wisp.
- Ignores copies that password managers mark as concealed/transient.
- No network access, no telemetry. The only link out is the wispclip.com item in the menu.

## FAQ

**Is it really free?** Yes. Wisp is MIT licensed with no paid tier.

**Does it sync between Macs?** No. History never leaves your Mac.

**How do I uninstall it?** Quit Wisp from the menu bar, delete `/Applications/Wisp.app`, and optionally delete `~/Library/Application Support/ClipBoard/` to remove your history.

**Why does macOS say it can't verify the developer?** Wisp isn't notarized yet. See [Download](#download) for how to open it.

## Contributing

Issues and pull requests are welcome at [github.com/narendraio/wispclip](https://github.com/narendraio/wispclip). For bigger changes, please open an issue first to talk it through. See [CONTRIBUTING.md](CONTRIBUTING.md) to get started.

If you like Wisp, a ⭐ on GitHub helps other people find it.

## License

[MIT](LICENSE)
