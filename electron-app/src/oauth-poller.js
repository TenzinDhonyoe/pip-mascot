// ── OAuth Usage Poller (ported from OAuthUsagePoller.swift) ──────────────────

export class OAuthPoller {
  constructor(store) {
    this.store = store;
    this.pollInterval = 30_000; // 30 seconds
    this._timer = null;
    this._polling = false;
  }

  start() {
    if (this._polling) return;
    this._polling = true;
    this.pollNow();
    this._timer = setInterval(() => this.pollNow(), this.pollInterval);
  }

  stop() {
    this._polling = false;
    if (this._timer) {
      clearInterval(this._timer);
      this._timer = null;
    }
  }

  async pollNow() {
    if (!window.pip) return;

    const result = await window.pip.pollUsage();
    if (!result || result.error) {
      if (result?.error === 'no-token') {
        this.store.tokenAvailable = false;
        this.store.lastError = 'no claude code token found';
      } else {
        this.store.lastError = result?.error || 'poll failed';
      }
      return;
    }

    this.store.tokenAvailable = true;

    if (result.status < 200 || result.status >= 300) {
      this.store.lastError = `http ${result.status} from usage endpoint`;
      return;
    }

    const body = result.body;
    if (!body) {
      this.store.lastError = 'malformed usage response';
      return;
    }

    const snap = extractUsage(body);
    if (!snap) {
      this.store.lastError = 'usage schema not recognized';
      return;
    }

    snap.lastUpdated = Date.now();
    this.store.ingest(snap, 'oauth');
  }
}

// ── JSON Probing (ported from JSONProbe.swift) ──────────────────────────────
function extractUsage(json) {
  if (!json || typeof json !== 'object') return null;

  const snap = {};

  // Probe several key names for the five-hour used percentage
  const fiveHourKeys = ['five_hour', 'fiveHour', '5h', 'usage_5h'];
  const weeklyKeys = ['seven_day', 'sevenDay', '7d', 'weekly', 'usage_7d'];
  const usedPctKeys = ['used_percentage', 'usedPercentage', 'used', 'pct'];
  const resetsAtKeys = ['resets_at', 'resetsAt', 'reset', 'next_reset'];

  // Try top-level objects
  for (const container of [json, json.usage, json.rate_limits, json.limits]) {
    if (!container) continue;

    // 5-hour
    let fiveHour = null;
    for (const fk of fiveHourKeys) {
      fiveHour = container[fk];
      if (fiveHour) break;
    }
    if (typeof fiveHour === 'object' && fiveHour !== null) {
      for (const uk of usedPctKeys) {
        if (typeof fiveHour[uk] === 'number') { snap.fiveHourUsedPct = fiveHour[uk]; break; }
      }
      for (const rk of resetsAtKeys) {
        const r = fiveHour[rk];
        if (typeof r === 'number') { snap.fiveHourResetsAt = r * 1000; break; } // epoch seconds → ms
        if (typeof r === 'string') { snap.fiveHourResetsAt = new Date(r).getTime(); break; }
      }
    }

    // Weekly / 7-day
    let weekly = null;
    for (const wk of weeklyKeys) {
      weekly = container[wk];
      if (weekly) break;
    }
    if (typeof weekly === 'object' && weekly !== null) {
      for (const uk of usedPctKeys) {
        if (typeof weekly[uk] === 'number') { snap.weeklyUsedPct = weekly[uk]; break; }
      }
      for (const rk of resetsAtKeys) {
        const r = weekly[rk];
        if (typeof r === 'number') { snap.weeklyResetsAt = r * 1000; break; }
        if (typeof r === 'string') { snap.weeklyResetsAt = new Date(r).getTime(); break; }
      }
    }

    // Also try flat structure
    if (snap.fiveHourUsedPct == null && typeof container.used_percentage === 'number') {
      snap.fiveHourUsedPct = container.used_percentage;
    }
    if (snap.weeklyUsedPct == null && typeof container.weekly_used === 'number') {
      snap.weeklyUsedPct = container.weekly_used;
    }
  }

  // If we found nothing, return null
  if (snap.fiveHourUsedPct == null && snap.weeklyUsedPct == null) return null;

  // Clamp values defensively
  if (snap.fiveHourUsedPct != null) snap.fiveHourUsedPct = Math.max(0, Math.min(100, snap.fiveHourUsedPct));
  if (snap.weeklyUsedPct != null) snap.weeklyUsedPct = Math.max(0, Math.min(100, snap.weeklyUsedPct));

  return snap;
}
