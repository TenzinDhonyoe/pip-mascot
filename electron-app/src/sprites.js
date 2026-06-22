// ── Sprite loader & definitions (ported from MascotView.swift Sprites) ───────
// Sprites are loaded from assets/ directory as Image objects.

const spriteCache = {};

async function loadImage(name) {
  if (spriteCache[name]) return spriteCache[name];
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => { spriteCache[name] = img; resolve(img); };
    img.onerror = () => {
      console.warn(`Sprite missing: ${name}.png`);
      spriteCache[name] = null;
      resolve(null);
    };
    img.src = `../assets/${name}.png`;
  });
}

// Foot fraction: where the feet line is from the top (0=top, 1=bottom)
const FOOT_FRAC_WALK = 0.873;
const FOOT_FRAC_IDLE = 0.934;
const FOOT_FRAC_STABLE = 0.902;
const FOOT_FRAC_FALL = 0.875;

// ── Sprite arrays ────────────────────────────────────────────────────────────
export const Sprites = {
  walkRight: [],
  walkLeft: [],
  turn: [],
  pickup: [],
  air: [],
  airRight: [],
  airLeft: [],
  mad: [],
  idleRight: null,
  idleLeft: null,
  stable: [],
  pop: [],
  fall: [],

  async loadAll() {
    // Walk cycles
    for (let i = 0; i < 10; i++) {
      this.walkRight.push({ img: await loadImage(`walk-right-f${i}`), footFrac: FOOT_FRAC_WALK, directional: true });
      this.walkLeft.push({ img: await loadImage(`walk-left-f${i}`), footFrac: FOOT_FRAC_WALK, directional: true });
    }
    // Turn
    for (let i = 0; i < 6; i++) {
      this.turn.push({ img: await loadImage(`turn-${i}`), footFrac: FOOT_FRAC_WALK });
    }
    // Pickup
    for (let i = 0; i < 12; i++) {
      this.pickup.push({ img: await loadImage(`pickup-${i}`), footFrac: FOOT_FRAC_WALK });
    }
    // Air sets
    for (let i = 0; i < 12; i++) {
      this.air.push({ img: await loadImage(`air-${i}`), footFrac: FOOT_FRAC_WALK });
      this.airRight.push({ img: await loadImage(`air-r-${i}`), footFrac: FOOT_FRAC_WALK, directional: true });
      this.airLeft.push({ img: await loadImage(`air-l-${i}`), footFrac: FOOT_FRAC_WALK, directional: true });
    }
    // Mad
    for (let i = 0; i < 12; i++) {
      this.mad.push({ img: await loadImage(`mad-${i}`), footFrac: FOOT_FRAC_WALK });
    }
    // Idle
    this.idleRight = { img: await loadImage('idle-right'), footFrac: FOOT_FRAC_IDLE, directional: true };
    this.idleLeft = { img: await loadImage('idle-left'), footFrac: FOOT_FRAC_IDLE, directional: true };
    // Stable (peek)
    for (let i = 0; i < 10; i++) {
      this.stable.push({ img: await loadImage(`stable-${i}`), footFrac: FOOT_FRAC_STABLE });
    }
    // Pop
    for (let i = 0; i < 12; i++) {
      this.pop.push({ img: await loadImage(`pop-${i}`), footFrac: FOOT_FRAC_WALK });
    }
    // Fall
    for (let i = 0; i < 12; i++) {
      this.fall.push({ img: await loadImage(`fall-${i}`), footFrac: FOOT_FRAC_FALL });
    }
    return this.walkRight; // return something truthy
  },

  // Safely get a sprite at index, clamping to valid range
  safeGet(arr, idx) {
    if (!arr || arr.length === 0) return null;
    return arr[Math.max(0, Math.min(arr.length - 1, idx))];
  },

  // Select the current sprite for the pose
  select(pose) {
    const facingRight = pose.scaleX >= 0;
    const walking = pose.walkPhase >= 0;
    const turning = pose.turnPhase >= 0;
    const useFrontPose = !turning && !walking;

    // Peek frames are handled separately by the caller
    if (pose.fallFrame >= 0) {
      return this.safeGet(this.fall, pose.fallFrame);
    }
    if (pose.madFrame >= 0) {
      return this.safeGet(this.mad, pose.madFrame);
    }
    if (pose.airFrame >= 0) {
      const set = pose.airSheet === 1 ? this.airRight
                : pose.airSheet === 2 ? this.airLeft : this.air;
      return this.safeGet(set, pose.airFrame);
    }
    if (pose.pickupFrame >= 0) {
      return this.safeGet(this.pickup, pose.pickupFrame);
    }
    if (turning) {
      const p = pose.turnFromRight ? pose.turnPhase : 1 - pose.turnPhase;
      const idx = Math.max(0, Math.min(this.turn.length - 1, Math.floor(p * (this.turn.length - 1) * 6) / 6));
      return this.turn[idx] || null;
    }
    if (useFrontPose) {
      return facingRight ? this.idleRight : this.idleLeft;
    }
    // Walking: walkPhase is a quantized frame index in [0..2), 5 frames per step.
    const set = facingRight ? this.walkRight : this.walkLeft;
    const frameIdx = Math.max(0, Math.min(set.length - 1, Math.floor(pose.walkPhase * 5)));
    return set[frameIdx] || null;
  }
};
