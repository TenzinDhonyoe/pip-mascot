// ── UsageStore (ported from UsageStore.swift) ────────────────────────────────
import { Mood } from './mood.js';

export class UsageStore {
  constructor() {
    this.snapshot = {
      fiveHourUsedPct: null,
      fiveHourResetsAt: null,
      weeklyUsedPct: null,
      weeklyResetsAt: null,
      lastUpdated: 0  // epoch ms
    };
    this.tokenAvailable = false;
    this.lastSource = 'none';
    this.lastError = null;
  }

  static STALE_AFTER = 3 * 3600 * 1000; // 3 hours in ms

  ingest(incoming, source) {
    if (incoming.lastUpdated < this.snapshot.lastUpdated) return;
    const s = this.snapshot;
    if (incoming.fiveHourUsedPct != null) s.fiveHourUsedPct = incoming.fiveHourUsedPct;
    if (incoming.fiveHourResetsAt != null) s.fiveHourResetsAt = incoming.fiveHourResetsAt;
    if (incoming.weeklyUsedPct != null) s.weeklyUsedPct = incoming.weeklyUsedPct;
    if (incoming.weeklyResetsAt != null) s.weeklyResetsAt = incoming.weeklyResetsAt;
    s.lastUpdated = incoming.lastUpdated;
    this.lastSource = source;
    this.lastError = null;
  }

  get hasFreshData() {
    return this.snapshot.fiveHourUsedPct != null
      && (Date.now() - this.snapshot.lastUpdated) < UsageStore.STALE_AFTER;
  }

  paceDelta(now = Date.now()) {
    const s = this.snapshot;
    if (!this.hasFreshData || s.fiveHourUsedPct == null || s.fiveHourResetsAt == null) return null;
    const windowLen = 5 * 3600 * 1000;
    const start = s.fiveHourResetsAt - windowLen;
    const elapsedFrac = Math.max(0, Math.min(1, (now - start) / windowLen));
    return s.fiveHourUsedPct / 100 - elapsedFrac;
  }

  elapsedFrac(now) {
    const s = this.snapshot;
    if (s.fiveHourResetsAt == null) return null;
    const windowLen = 5 * 3600 * 1000;
    const start = s.fiveHourResetsAt - windowLen;
    return Math.max(0, Math.min(1, (now - start) / windowLen));
  }

  projectedFinalPct(now = Date.now()) {
    const s = this.snapshot;
    if (!this.hasFreshData || s.fiveHourUsedPct == null) return null;
    const e = this.elapsedFrac(now);
    if (e == null || e <= 0.02) return null;
    return Math.min(200, s.fiveHourUsedPct / e);
  }

  angerLevel(now = Date.now()) {
    const s = this.snapshot;
    if (s.fiveHourUsedPct == null || s.fiveHourUsedPct >= 90) return 0;
    const e = this.elapsedFrac(now);
    if (e == null) return 0;
    const projected = this.projectedFinalPct(now);
    if (projected == null) return 0;

    const confidence = smoothstep(e, 0.30, 0.55);
    const waste = clamp((90 - projected) / 60, 0, 1);
    return confidence * waste;
  }

  mood(now = Date.now()) {
    const s = this.snapshot;
    if (!this.hasFreshData || s.fiveHourUsedPct == null) return Mood.SLEEPY;
    const delta = this.paceDelta(now);
    if (delta == null) return Mood.SLEEPY;
    if (s.fiveHourUsedPct >= 90) return Mood.WORRIED;
    if (this.angerLevel(now) >= 0.40) return Mood.MAD;
    if (delta <= -0.25) return Mood.ANTSY;
    if (delta >= 0.10) return Mood.FOCUSED;
    return Mood.HAPPY;
  }

  usageStats(now = Date.now()) {
    const out = [];
    const s = this.snapshot;
    if (s.fiveHourUsedPct != null) {
      out.push({
        label: '5h',
        pct: s.fiveHourUsedPct,
        resets: s.fiveHourResetsAt ? countdown(s.fiveHourResetsAt, now) : '—'
      });
    }
    if (s.weeklyUsedPct != null) {
      out.push({
        label: '7d',
        pct: s.weeklyUsedPct,
        resets: s.weeklyResetsAt ? countdown(s.weeklyResetsAt, now) : '—'
      });
    }
    return out;
  }
}

// ── Utility functions ─────────────────────────────────────────────────────────
function clamp(x, lo, hi) { return Math.max(lo, Math.min(hi, x)); }
function smoothstep(x, a, b) {
  if (b <= a) return x < a ? 0 : 1;
  const t = clamp((x - a) / (b - a), 0, 1);
  return t * t * (3 - 2 * t);
}

export function countdown(toMs, fromMs) {
  const s = Math.max(0, Math.floor((toMs - fromMs) / 1000));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

export function ago(dateMs, fromMs) {
  const s = Math.max(0, Math.floor((fromMs - dateMs) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  return `${Math.floor(s / 3600)}h ago`;
}
