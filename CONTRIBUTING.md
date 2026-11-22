# Contributing to Wisp

Thanks for wanting to help! Bug reports, ideas and pull requests are all welcome.

## Reporting bugs and ideas

Open an [issue](https://github.com/narendraio/wispclip/issues/new/choose). For bugs, include your macOS version and steps to reproduce.

## Working on the code

```bash
git clone https://github.com/narendraio/wispclip.git
cd wispclip
./build.sh --install   # builds build/Wisp.app, copies it to /Applications and launches it
```

Requires macOS 14+ and Xcode or the Swift command line tools. `./build.sh --dmg` builds the universal app and `build/Wisp.dmg`, the same as the release workflow.

Where things live (`Sources/ClipBoard/`):

| File | What it does |
| --- | --- |
| `main.swift` | App delegate, menu bar menu |
| `ClipboardMonitor.swift` | Watches the pasteboard and captures new copies |
| `ClipStore.swift` | History, pins and snippets, saved to disk |
| `HistoryPanel.swift` | The ⌃⌘V panel UI |
| `Detector.swift`, `Highlighter.swift` | Smart detection (JSON, SQL, JWT, colors…) and syntax coloring |
| `Transforms.swift` | ⌘K transforms |
| `Paster.swift` | Pasting into the frontmost app |

## Pull requests

- For bigger changes, open an issue first so we can agree on the approach.
- Keep PRs focused on one thing.
- Make sure `./build.sh` succeeds; CI builds every PR.
- Wisp is privacy-first: please don't add network calls, analytics or telemetry.
