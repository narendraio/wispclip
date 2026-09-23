# Wisp

**A clipboard with a memory.** — [wispclip.com](https://wispclip.com)

Wisp is a lightweight clipboard manager for macOS. It sits in the menu bar, quietly remembers everything you copy (text, rich text, images, files), and hands it back the moment you press **⌃⌘V**. Free and open source.

## Build & install

```bash
git clone https://github.com/narendraio/wispclip.git
cd wispclip
./build.sh             # builds build/Wisp.app
./build.sh --install   # also copies it to /Applications and launches it
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

## Contributing

Issues and pull requests are welcome at [github.com/narendraio/wispclip](https://github.com/narendraio/wispclip). For bigger changes, please open an issue first to talk it through.

## License

[MIT](LICENSE)
