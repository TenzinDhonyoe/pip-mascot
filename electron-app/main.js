const { app, BrowserWindow, Tray, Menu, ipcMain, nativeImage, screen } = require('electron');

// Force X11 backend on Linux/Wayland to avoid scale/position weirdness
if (process.platform === 'linux') {
  process.env.GDK_BACKEND = 'x11';
  process.env.QT_QPA_PLATFORM = 'x11';
  app.commandLine.appendSwitch('disable-features', 'UseOzonePlatform');
  app.commandLine.appendSwitch('ozone-platform', 'x11');
}
app.commandLine.appendSwitch('force-device-scale-factor', '1');

const path = require('path');
const fs = require('fs');
const { execFile } = require('child_process');
const os = require('os');

// ── Constants ────────────────────────────────────────────────────────────────
const WINDOW_W = 280;
const WINDOW_H = 230;
const MASCOT_NAME = 'Pip';

let mainWindow = null;
let tray = null;
let credentialsCache = null;

// ── Token extraction (cross-platform) ────────────────────────────────────────
async function loadAccessToken() {
  const home = os.homedir();
  if (process.platform === 'darwin') {
    try {
      const { stdout } = await execPromise('security', [
        'find-generic-password', '-s', 'Claude Code-credentials', '-w'
      ]);
      if (stdout) {
        const obj = JSON.parse(stdout.trim());
        const token = probeToken(obj);
        if (token) return token;
      }
    } catch (_) {}
  }
  const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(home, '.claude');
  const credsPath = path.join(configDir, '.credentials.json');
  try {
    const raw = fs.readFileSync(credsPath, 'utf8');
    const obj = JSON.parse(raw);
    const token = probeToken(obj);
    if (token) return token;
  } catch (_) {}
  return null;
}

function probeToken(obj) {
  const candidates = [];
  for (const key of Object.keys(obj)) {
    const v = obj[key];
    if (typeof v === 'object' && v !== null) {
      if (v.accessToken) candidates.push(v.accessToken);
      if (v.access_token) candidates.push(v.access_token);
      if (v.token) candidates.push(v.token);
      for (const k2 of Object.keys(v)) {
        const v2 = v[k2];
        if (typeof v2 === 'object' && v2 !== null) {
          if (v2.accessToken) candidates.push(v2.accessToken);
          if (v2.access_token) candidates.push(v2.access_token);
        }
      }
    }
    if (key === 'accessToken' || key === 'access_token') candidates.push(v);
  }
  return candidates.find(t => typeof t === 'string' && t.length > 20) || null;
}

function execPromise(cmd, args) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { timeout: 5000 }, (err, stdout, stderr) => {
      if (err) reject(err);
      else resolve({ stdout, stderr });
    });
  });
}

// ── Window creation ───────────────────────────────────────────────────────────
function createWindow() {
  const display = screen.getPrimaryDisplay();
  const workArea = display.workArea;
  const scaleFactor = display.scaleFactor || 1;

  console.log(`Screen: ${workArea.width}x${workArea.height}, scale: ${scaleFactor}x`);

  mainWindow = new BrowserWindow({
    width: WINDOW_W,
    height: WINDOW_H,
    x: 100,
    y: 100,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: false,
    hasShadow: false,
    useContentSize: true,
    // 'panel' floats above full-screen apps on macOS, 'toolbar' suits Linux; Windows
    // has no equivalent type, so leave it unset there.
    type: process.platform === 'darwin' ? 'panel'
        : process.platform === 'linux' ? 'toolbar'
        : undefined,
    // Windows draws a resize border on transparent frameless windows unless this is off.
    thickFrame: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      zoomFactor: 1.0
    }
  });

  // Force exact logical size (work around Linux/Wayland HiDPI scaling)
  mainWindow.setBounds({ x: 100, y: 100, width: WINDOW_W, height: WINDOW_H });
  mainWindow.setResizable(false);

  if (process.platform === 'linux') {
    mainWindow.setAlwaysOnTop(true, 'screen-saver');
    mainWindow.setVisibleOnAllWorkspaces(true);
  }

  mainWindow.loadFile(path.join(__dirname, 'src', 'index.html'));
  mainWindow.setFocusable(false);

  // Open devtools briefly on first load so we can see console output
  // (comment out for production)
  // mainWindow.webContents.openDevTools({ mode: 'detach' });

  mainWindow.on('closed', () => { mainWindow = null; });
}

// ── Tray ──────────────────────────────────────────────────────────────────────
function createTray() {
  const size = 16;
  const buf = Buffer.alloc(size * size * 4);
  const cx = size / 2, cy = size / 2, r = 5;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const i = (y * size + x) * 4;
      const dx = x - cx, dy = y - cy;
      if (dx * dx + dy * dy <= r * r) {
        buf[i] = 0xCC; buf[i+1] = 0x78; buf[i+2] = 0x5C; buf[i+3] = 0xFF;
      } else {
        buf[i+3] = 0;
      }
    }
  }
  const icon = nativeImage.createFromBuffer(buf, { width: size, height: size });
  tray = new Tray(icon);
  tray.setToolTip(MASCOT_NAME);
  refreshTrayMenu();
}

// Build the menu shown both from the tray icon and from right-clicking Pip.
function buildMenu() {
  const sizeOption = (label, value) => ({
    label, type: 'radio',
    checked: Math.abs(pipScale - value) < 0.001,
    click: () => setScale(value)
  });
  return Menu.buildFromTemplate([
    { label: `${MASCOT_NAME} 🐾`, enabled: false },
    { type: 'separator' },
    { label: 'Toggle Pause', click: togglePause },
    { label: 'Toggle Click-Through', click: toggleClickThrough },
    { label: 'Size', submenu: [
      sizeOption('Small', 0.8),
      sizeOption('Normal', 1.0),
      sizeOption('Large', 1.3),
      sizeOption('Huge', 1.6),
    ] },
    { type: 'separator' },
    { label: 'Refresh Usage Now', click: refreshUsage },
    { label: 'Show Usage Details', click: toggleBadge },
    { type: 'separator' },
    { label: `Quit ${MASCOT_NAME}`, click: () => { app.quit(); } }
  ]);
}

// Rebuilt whenever state changes (e.g. size) so radio checkmarks stay in sync.
function refreshTrayMenu() {
  if (!tray) return;
  tray.setContextMenu(buildMenu());
}

let paused = false;
let clickThroughEnabled = false;
let badgeVisible = false;
let pipScale = 1;

// Resize Pip: scale the window and zoom the page together; the renderer scales its
// edge/ground math to match. Default 1.0 means startup is unaffected.
function setScale(s) {
  pipScale = s;
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.setSize(Math.round(WINDOW_W * s), Math.round(WINDOW_H * s));
    mainWindow.webContents.setZoomFactor(s);
    mainWindow.webContents.send('set-scale', s);
  }
  refreshTrayMenu();
}

function togglePause() {
  paused = !paused;
  mainWindow?.webContents.send('toggle-pause');
}
function toggleClickThrough() {
  clickThroughEnabled = !clickThroughEnabled;
  mainWindow?.webContents.send('toggle-click-through');
}
function refreshUsage() {
  mainWindow?.webContents.send('refresh-usage');
}
function toggleBadge() {
  badgeVisible = !badgeVisible;
  mainWindow?.webContents.send('toggle-badge');
}

// ── IPC handlers ──────────────────────────────────────────────────────────────
ipcMain.handle('get-token', async () => {
  credentialsCache = await loadAccessToken();
  return credentialsCache;
});

ipcMain.handle('get-platform', () => process.platform);

ipcMain.on('set-ignore-mouse-events', (event, ignore, options) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (win) win.setIgnoreMouseEvents(ignore, options || { forward: true });
});

ipcMain.on('move-window', (event, x, y) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (win && !win.isDestroyed()) {
    win.setPosition(Math.round(x), Math.round(y));
  }
});

// Right-clicking Pip opens the same menu as the tray — handy when the desktop
// hides the tray icon (e.g. GNOME without an AppIndicator extension).
ipcMain.on('show-context-menu', () => {
  buildMenu().popup(mainWindow ? { window: mainWindow } : undefined);
});

ipcMain.handle('get-screen-info', () => {
  const display = screen.getPrimaryDisplay();
  const sa = display.workArea;
  return {
    x: sa.x,
    y: sa.y,
    width: sa.width,
    height: sa.height,
    scaleFactor: display.scaleFactor || 1
  };
});

ipcMain.handle('poll-usage', async () => {
  const token = credentialsCache || await loadAccessToken();
  if (!token) return { error: 'no-token' };

  // The /api/oauth/usage endpoint returns persistent HTTP 429 (a known Anthropic
  // server-side bug), so we read the same numbers from the anthropic-ratelimit-unified-*
  // response headers of a minimal Messages call instead — this is the source Claude
  // Code's own statusline uses, and it doesn't depend on the broken usage endpoint.
  try {
    const https = require('https');
    const payload = JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 1,
      messages: [{ role: 'user', content: 'hi' }]
    });
    const result = await new Promise((resolve, reject) => {
      const req = https.request('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'anthropic-beta': 'oauth-2025-04-20',
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
          'content-length': Buffer.byteLength(payload)
        },
        timeout: 15000
      }, (res) => {
        res.on('data', () => {});
        res.on('end', () => {
          const h = res.headers;
          const num = (v) => (v == null ? null : Number(v));
          const u5 = num(h['anthropic-ratelimit-unified-5h-utilization']);
          const r5 = num(h['anthropic-ratelimit-unified-5h-reset']);
          const u7 = num(h['anthropic-ratelimit-unified-7d-utilization']);
          const r7 = num(h['anthropic-ratelimit-unified-7d-reset']);
          const body = { rate_limits: {} };
          if (u5 != null) body.rate_limits.five_hour = { used_percentage: u5 * 100, resets_at: r5 };
          if (u7 != null) body.rate_limits.seven_day = { used_percentage: u7 * 100, resets_at: r7 };
          // Headers are present on 2xx and 429 alike; surface 200 so the renderer ingests them.
          const ok = body.rate_limits.five_hour || body.rate_limits.seven_day;
          resolve({ status: ok ? 200 : res.statusCode, body });
        });
      });
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
      req.write(payload);
      req.end();
    });
    return result;
  } catch (e) {
    return { error: e.message };
  }
});

// ── App lifecycle ─────────────────────────────────────────────────────────────
// Only allow one Pip at a time — a second launch just exits, so you never end up
// with several mascots you can't all quit.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => { /* already running; keep the existing one */ });
  app.whenReady().then(() => {
    createTray();
    createWindow();
  });
}

app.on('window-all-closed', () => {
  // Don't quit on window close; stay in tray
});

app.on('before-quit', () => {
  if (tray) tray.destroy();
});
