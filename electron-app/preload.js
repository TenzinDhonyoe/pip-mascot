const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pip', {
  getToken: () => ipcRenderer.invoke('get-token'),
  pollUsage: () => ipcRenderer.invoke('poll-usage'),
  getPlatform: () => ipcRenderer.invoke('get-platform'),
  getScreenInfo: () => ipcRenderer.invoke('get-screen-info'),
  moveWindow: (x, y) => ipcRenderer.send('move-window', x, y),
  showContextMenu: () => ipcRenderer.send('show-context-menu'),
  quitApp: () => ipcRenderer.send('quit-app'),
  onTogglePause: (cb) => ipcRenderer.on('toggle-pause', (e) => cb()),
  onToggleClickThrough: (cb) => ipcRenderer.on('toggle-click-through', (e) => cb()),
  onRefreshUsage: (cb) => ipcRenderer.on('refresh-usage', (e) => cb()),
  onToggleBadge: (cb) => ipcRenderer.on('toggle-badge', (e) => cb()),
  onSetScale: (cb) => ipcRenderer.on('set-scale', (e, scale) => cb(scale)),
  setIgnoreMouseEvents: (ignore, options) => {
    ipcRenderer.send('set-ignore-mouse-events', ignore, options);
  }
});
