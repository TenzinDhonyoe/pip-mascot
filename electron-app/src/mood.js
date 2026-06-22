// ── Mood enum and Palette (ported from Mood.swift) ───────────────────────────
export const MASCOT_NAME = 'Pip';

export const Mood = {
  MAD:     'mad',
  ANTSY:   'antsy',
  HAPPY:   'happy',
  FOCUSED: 'focused',
  WORRIED: 'worried',
  SLEEPY:  'sleepy',
};

export function moodSpeedFactor(mood) {
  switch (mood) {
    case Mood.MAD:     return 1.5;
    case Mood.ANTSY:   return 1.35;
    case Mood.HAPPY:   return 1.0;
    case Mood.FOCUSED: return 1.15;
    case Mood.WORRIED: return 0.75;
    case Mood.SLEEPY:  return 0;
    default:           return 1.0;
  }
}

export function moodStrideHz(mood) {
  switch (mood) {
    case Mood.WORRIED: return 3.0;
    case Mood.MAD:     return 3.2;
    case Mood.ANTSY:   return 2.4;
    case Mood.FOCUSED: return 2.1;
    case Mood.HAPPY:   return 1.8;
    case Mood.SLEEPY:  return 0;
    default:           return 1.8;
  }
}

// CSS-compatible color strings
export const Palette = {
  body:      'rgb(255, 161, 140)',
  bodyEdge:  'rgb(224, 117, 102)',
  belly:     'rgb(255, 237, 217)',
  feet:      'rgb(219, 112, 97)',
  eye:       'rgb(66, 43, 43)',
  blush:     'rgb(255, 115, 128)',
  leaf:      'rgb(115, 184, 115)',
  stem:      'rgb(97, 153, 97)',
  sweat:     'rgb(115, 179, 242)',
  shadow:    'rgba(0, 0, 0)',
  claudeClay:  'rgb(204, 120, 92)',
  claudeCream: 'rgb(248, 246, 241)',
  claudeInk:   'rgb(51, 48, 43)',
  claudeAmber: 'rgb(222, 140, 69)',
  claudeAlert: 'rgb(199, 74, 64)',

  usageFill(pct) {
    if (pct >= 90) return this.claudeAlert;
    if (pct >= 70) return this.claudeAmber;
    return this.claudeClay;
  },

  scarf(weeklyPct) {
    const p = Math.max(0, Math.min(100, weeklyPct));
    if (p < 50) return 'rgb(115, 191, 184)';
    if (p < 80) {
      const t = (p - 50) / 30;
      const r = Math.round(115 + 128 * t);
      const g = Math.round(191 - 13 * t);
      const b = Math.round(184 - 107 * t);
      return `rgb(${r}, ${g}, ${b})`;
    }
    const t = Math.min(1, (p - 80) / 20);
    const r = Math.round(242);
    const g = Math.round(179 - 102 * t);
    const b = Math.round(77 - 13 * t);
    return `rgb(${r}, ${g}, ${b})`;
  }
};
