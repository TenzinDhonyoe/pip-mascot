# Pip 🐾 — Electron port (Windows / macOS / Linux)

A cross-platform [Electron](https://www.electronjs.org/) port of [Pip](https://github.com/TenzinDhonyoe/pip-mascot),
the Claude-usage-aware desktop mascot (the original is a macOS-only Swift app).

Pip is a small, transparent, always-on-top character that walks along the bottom edge of
your screen and changes mood based on your **live Claude Code usage**. Everything runs
locally — it reads your existing Claude Code login, no API key or cloud account required.

![Pip walking](../mascot/front.png)

---

## Run it

```bash
cd electron-app
npm install
npm start
```

That's it on **macOS** and **Windows**. On **Linux/Wayland** the app forces itself onto
XWayland automatically (see [Platform notes](#platform-notes)).

For console logging while developing:

```bash
npm run start:dev
```

## Build installers

```bash
npm run build:win     # NSIS installer (.exe)
npm run build:mac     # .dmg
npm run build:linux   # AppImage + .deb
```

Output lands in `dist/`. Builds are produced with
[electron-builder](https://www.electron.build/).

---

## Install on Linux

**Prerequisites:** [Node.js](https://nodejs.org/) 18 or newer (LTS recommended) and `git`.
You also need to be logged into Claude Code so Pip has usage data to read
(`~/.claude/.credentials.json` must exist).

### Option A — run from source (quickest)

```bash
git clone https://github.com/avisre/pip-mascot.git
cd pip-mascot/electron-app
npm install
npm start
```

Pip starts walking along the bottom of your screen, with a 🐾 in your system tray.

### Add Pip to your app menu (launcher)

To launch Pip from your applications menu instead of a terminal:

```bash
cd pip-mascot/electron-app
./linux/install-launcher.sh
```

This installs a desktop entry to `~/.local/share/applications/pip-mascot.desktop`
pointing at this checkout — then just search for **Pip** in your app grid. (Packaged
`.deb`/AppImage builds create their own launcher automatically; this is for run-from-source
setups.)

### Option B — build and install a package

```bash
cd pip-mascot/electron-app
npm install
npm run build:linux        # produces dist/*.AppImage and dist/*.deb
```

**AppImage** (portable, no install):

```bash
chmod +x dist/Pip-*.AppImage
./dist/Pip-*.AppImage
```

> If you see `dlopen(): error loading libfuse.so.2`, AppImages need FUSE 2:
> `sudo apt install libfuse2` (Ubuntu 22.04) or `sudo apt install libfuse2t64`
> (Ubuntu 24.04+). Alternatively run it extracted:
> `./dist/Pip-*.AppImage --appimage-extract-and-run`.

**`.deb`** (Debian/Ubuntu):

```bash
sudo apt install ./dist/Pip_*.deb      # installs to /opt and adds a desktop entry
```

Then launch **Pip** from your app menu.

### Wayland

No setup needed — `main.js` forces the app onto X11/XWayland automatically, because
transparent always-on-top windows misbehave on some Wayland compositors. If your tray
icon doesn't appear on GNOME, install a tray extension such as
[AppIndicator Support](https://extensions.gnome.org/extension/615/appindicator-support/).

---

## How it works

Pip is two processes that talk over IPC:

| Process | File | Responsibility |
|---|---|---|
| **Main** (Node) | [`main.js`](main.js) | Owns the OS window + tray, reads your token, polls usage, moves the window |
| **Renderer** (web page) | [`src/`](src/) | Draws and animates Pip on a `<canvas>` |
| **Bridge** | [`preload.js`](preload.js) | Exposes a safe `window.pip` API to the page |

**The window is the character.** It's a 280×230 frameless, transparent, always-on-top
window. To "walk," the app moves the whole window across the screen (`win.setPosition`)
rather than moving the sprite inside it.

**Usage drives the mood.** Every 30 s the poller fetches your usage and feeds a
`UsageStore`, which maps the numbers to a mood:

| Your 5-hour usage | Mood | Behavior |
|---|---|---|
| no data | `sleepy` | sits still |
| on/under pace | `happy` / `focused` | normal walk |
| way under pace near reset | `antsy` / `mad` | hurries (you're wasting quota) |
| ≥ 90 % | `worried` | slows down |

The [`WalkEngine`](src/walk-engine.js) is a per-frame state machine (walk / turn / idle /
sit / peek / drag) that picks a sprite frame from [`assets/`](assets) and a facing
direction; [`renderer.js`](src/renderer.js) draws it.

### Where the usage numbers come from

Claude Code's official usage endpoint (`/api/oauth/usage`) currently returns persistent
HTTP 429 for many accounts — a known server-side issue
([#31021](https://github.com/anthropics/claude-code/issues/31021),
[#30930](https://github.com/anthropics/claude-code/issues/30930),
[#31637](https://github.com/anthropics/claude-code/issues/31637)). So instead, the poller
reads the same numbers Claude Code's own status line uses: the
`anthropic-ratelimit-unified-*` **response headers** returned by a minimal Messages API
call. This is local-token, no extra account, and not affected by the broken endpoint.

> Trade-off: each poll makes a tiny (~1 output token) Messages call. To poll less often,
> raise `pollInterval` in [`src/oauth-poller.js`](src/oauth-poller.js).

The OAuth token is read from your existing Claude Code login:

- **macOS** — the `Claude Code-credentials` Keychain item
- **Windows / Linux** — `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`)

---

## Interacting with Pip

- **Pick him up** — click and drag Pip anywhere on screen; let go and he drops back to the
  ground and carries on walking. (Disabled while Click-Through is on.)
- **Right-click Pip** — opens the menu (Quit, Size, …) right at the cursor. Handy on GNOME,
  where the tray icon may be hidden without an AppIndicator extension.
- **Double-click Pip to quit** — a guaranteed way to close him, even when the tray icon and
  the right-click menu aren't available on your desktop.
- Only **one** Pip runs at a time — launching again just exits, so you never end up with
  several you can't quit.

## Tray menu

Right-click Pip, or click the 🐾 tray icon, for:

- **Toggle Pause** / **Toggle Click-Through** (let clicks pass through Pip)
- **Size** — resize Pip: Small (0.8×), Normal (1×), Large (1.3×), Huge (1.6×)
- **Refresh Usage Now** / **Show Usage Details**
- **Quit**

---

## Platform notes

- **Windows** — frameless transparent window uses `thickFrame: false` to avoid the resize
  border. Token is read from `%USERPROFILE%\.claude\.credentials.json`.
- **macOS** — the window uses the `panel` level so it floats above full-screen apps, and
  the app hides from the Dock.
- **Linux** — Electron is forced onto **X11/XWayland** (`ozone-platform=x11`) from inside
  `main.js`, because transparent always-on-top windows misbehave on some Wayland
  compositors. No environment variables needed.

---

## Relationship to the original

This is the Electron port. The original macOS/Swift app lives at the repo root
(`Pip.xcodeproj`, `Pip/`) and on GitHub at
[TenzinDhonyoe/pip-mascot](https://github.com/TenzinDhonyoe/pip-mascot). Shared art lives
in [`../mascot`](../mascot); this port also ships its own frame-by-frame sprites in
[`assets/`](assets).

---

## Credits & thanks

🐾 **Pip was created by [Tenzin Dhonyoe](https://github.com/TenzinDhonyoe)** —
[`TenzinDhonyoe/pip-mascot`](https://github.com/TenzinDhonyoe/pip-mascot).

Huge thanks to Tenzin for the original macOS app: the concept, the adorable mascot art,
the walk-cycle animation, and the whole "your usage as a little creature" idea. This
cross-platform Electron port simply stands on that work so the rest of us — on Windows and
Linux — can have Pip walking along our screens too. All the charm is theirs; please go
star the [original repo](https://github.com/TenzinDhonyoe/pip-mascot). 💛

Licensed under [MIT](../LICENSE), same as the original.
