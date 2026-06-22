// ── WalkEngine (ported from WalkEngine.swift) ────────────────────────────────
// CADisplayLink-driven state machine: walk/turn/idle/sit/drag + pose generation.
// Runs on requestAnimationFrame at ~60fps.

import { Mood, moodSpeedFactor, moodStrideHz } from './mood.js';

// ── Pose model ────────────────────────────────────────────────────────────────
export class Pose {
  constructor() {
    this.scaleX = 1;
    this.mood = Mood.SLEEPY;
    this.walkPhase = -1;
    this.turnPhase = -1;
    this.turnFromRight = false;
    this.pickupFrame = -1;
    this.peekFrame = -1;
    this.popFrame = -1;
    this.fallFrame = -1;
    this.airFrame = -1;
    this.airSheet = 0;
    this.madFrame = -1;
    this.bodySquash = 0;
    this.stretchY = 0;
    this.bodyLift = 0;
    this.headBob = 0;
    this.phase = 0;
    this.blink = 0;
    this.yawn = 0;
    this.lookX = 0;
    this.footTap = 0;
    this.sitting = false;
    this.weeklyPct = null;
    this.bubbleText = null;
    this.showBadge = false;
    this.badgeStats = [];
    this.badgeNote = null;
    this.badgeDrop = 0;
    this.badgeSafeMinX = 0;
    this.badgeSafeMaxX = 280;
  }

  clone() {
    const p = new Pose();
    Object.assign(p, this);
    return p;
  }
}

// ── State machine ─────────────────────────────────────────────────────────────
const State = {
  PEEKING:  'peeking',
  WALKING:  'walking',
  TURNING:  'turning',
  IDLING:   'idling',
  SITTING:  'sitting',
  DRAGGING: 'dragging',
  FALLING:  'falling',
  LANDING:  'landing',
  FUMING:   'fuming',
  TUCKING:  'tuckingIn'
};

const Pin = { NONE: 0, LEFT: 1, RIGHT: 2 };

export class WalkEngine {
  constructor(store) {
    this.store = store;

    // Tunables
    this.baseSpeed = 34;
    this.turnDuration = 0.55;
    this.CHAR_WIDTH = 110;
    this.INTERACTIVE_WIDTH = 180;
    this.PEEK_INSET = 94;
    this.PEEK_LIFT = 72;
    this.PEEK_BADGE_DROP = 92;
    this.PEEK_RISE_DURATION = 0.4;
    this.GRAVITY = 2000;
    this.TERMINAL_FALL = 1250;
    this.POP_DURATION = 0.62;
    this.POP_PULL_FRAC = 0.42;
    this.POP_STRETCH_MAX = 0.4;
    this.POP_SQUASH_MAX = 0.16;
    this.POP_EMERGE_INSET = 84;
    this.TUCK_DURATION = 0.7;
    this.GO_HOME_SPEED = 2.2;
    this.FUME_DURATION_MIN = 2.6;
    this.FUME_DURATION_MAX = 4.4;
    this.MAD_STOMP_MIN = 1.0;
    this.MAD_STOMP_MAX = 2.0;
    this.PROVOKE_HOLD = 4.0;

    this.RIVAL_LINES = [
      "ChatGPT?! not in MY house.",
      "keep that thing away from me",
      "ugh. GPT. really?",
      "we don't say that name here",
      "get that traitor away!",
      "i'm telling Claude."
    ];

    this.PEEK_TIMELINE = [
      { frame: 0, dur: 2.4 }, { frame: 2, dur: 0.09 }, { frame: 3, dur: 0.13 }, { frame: 2, dur: 0.07 },
      { frame: 5, dur: 1.9 }, { frame: 6, dur: 1.2 },
      { frame: 1, dur: 1.3 },
      { frame: 8, dur: 1.7 }, { frame: 2, dur: 0.09 }, { frame: 3, dur: 0.13 }, { frame: 2, dur: 0.07 },
      { frame: 7, dur: 0.45 }, { frame: 8, dur: 0.16 }, { frame: 7, dur: 0.45 },
      { frame: 9, dur: 2.1 }
    ];
    this.PEEK_TIMELINE_TOTAL = this.PEEK_TIMELINE.reduce((s, x) => s + x.dur, 0);

    // State
    this.state = State.PEEKING;
    this.facing = 1;
    this.x = 0;
    this.lastTimestamp = 0;
    this.walkClock = 0;
    this.animClock = 0;
    this.nextIdleAt = 0;
    this.currentMood = Mood.SLEEPY;
    this.currentAnger = 0;
    this.lastMoodCheck = 0;
    this.fumeUntil = 0;
    this.madStompUntil = 0;
    this.goingHome = false;
    this.paused = false;
    this.showBadgePersistent = false;
    this.pin = Pin.NONE;
    this.tickCount = 0;
    this.lastPose = new Pose();

    // Peek/tuck
    this.peekRiseStart = -1000;

    // Drag
    this.dragVX = 0;  this.dragVY = 0;
    this.dragInstVX = 0;  this.dragInstVY = 0;
    this.lastDragOrigin = null;
    this.lastDragMoveAt = 0;
    this.airHeight = 0;
    this.tossVX = 0;
    this.poppingOut = false;
    this.dragFromPeek = false;

    // Turn state
    this._turnStart = 0;
    this._turnFromFacing = 0;

    // Idle state
    this._idleUntil = 0;
    this._idleKind = 'breathe';

    // Tuck state
    this._tuckStart = 0;

    // Idle scheduling
    this.scheduleNextIdle();

    // Bubble
    this.bubbleUntil = 0;
    this.bubbleText = null;
    this.nextBubbleAt = 60;

    // Rival
    this.provokedUntil = 0;
    this.rivalBubbleNextAt = 0;

    // Pose callback
    this._onPoseUpdate = () => {};
  }

  scheduleNextIdle(now) {
    this.nextIdleAt = (now || performance.now() / 1000) + 7 + Math.random() * 11;
  }

  // ── Public API ────────────────────────────────────────────────────────────
  get isPoppingOut() { return this.poppingOut; }
  get isDragging() { return this.state === State.DRAGGING; }
  get isPeeking() { return this.state === State.PEEKING; }
  get isHomeOrHeading() {
    return this.goingHome || this.state === State.PEEKING || this.state === State.TUCKING;
  }

  goHome() {
    if (this.isHomeOrHeading) return;
    this.goingHome = true;
    if (this.state !== State.DRAGGING && this.state !== State.FALLING && this.state !== State.LANDING) {
      this.state = State.WALKING;
    }
  }

  provokeByRival() {
    const now = performance.now() / 1000;
    this.provokedUntil = now + this.PROVOKE_HOLD;
    this.currentMood = Mood.MAD;
    this.currentAnger = 1.0;
    if (this.state === State.PEEKING && !this.goingHome) {
      this.state = State.WALKING;
    }
    if (now >= this.rivalBubbleNextAt) {
      this.bubbleText = this.RIVAL_LINES[Math.floor(Math.random() * this.RIVAL_LINES.length)];
      this.bubbleUntil = now + 3.5;
      this.rivalBubbleNextAt = now + 5;
    }
  }

  // Drag state
  beginDrag() {
    this.dragFromPeek = this.state === State.PEEKING;
    this.poppingOut = this.dragFromPeek;
    this._dragStart = performance.now() / 1000;
    this.state = State.DRAGGING;
  }

  endDrag() {
    this.poppingOut = false;
    this.dragFromPeek = false;
    this._landStart = performance.now() / 1000;
    this.state = State.LANDING;
  }

  noteDragMove(dx, dy, dt) {
    if (dt > 0.001) {
      this.dragInstVX = dx / dt;
      this.dragInstVY = dy / dt;
      this.lastDragMoveAt = performance.now() / 1000;
    }
  }

  dismissBubble() {
    this.bubbleText = null;
    this.bubbleUntil = 0;
  }

  // ── Start position ───────────────────────────────────────────────────────
  startPosition(visibleRect, testMode = false) {
    if (testMode) {
      // Start in the middle, walking right for easy visual verification
      this.state = State.WALKING;
      this.facing = 1;
      this.x = visibleRect.x + visibleRect.width / 2 - 140;
      this.currentMood = Mood.HAPPY;
      return { x: this.x, y: visibleRect.y + visibleRect.height - 230 + 1 };
    }

    /** Normal home start: parked off the left edge peeking in. */
    this.state = State.PEEKING;
    this.facing = 1;
    this.x = visibleRect.x - this.PEEK_INSET;
    return { x: this.x, y: visibleRect.y + 1 + this.PEEK_LIFT };
  }

  // ── Main tick ────────────────────────────────────────────────────────────
  tick(timestamp) {
    const now = timestamp / 1000;
    let dt = now - this.lastTimestamp;
    if (this.lastTimestamp === 0 || dt <= 0 || dt > 0.1) dt = 1 / 60;
    this.lastTimestamp = now;
    this.tickCount++;
    this.animClock += dt;

    // Drag velocity smoothing
    if (this.isDragging && now - this.lastDragMoveAt > 0.08) {
      this.dragInstVX = 0;
      this.dragInstVY = 0;
    }
    if (this.isDragging) {
      const k = Math.min(1, dt * 10);
      this.dragVX += (this.dragInstVX - this.dragVX) * k;
      this.dragVY += (this.dragInstVY - this.dragVY) * k;
    }

    // Mood polling (once per second)
    if (now - this.lastMoodCheck > 1.0) {
      this.lastMoodCheck = now;
      const provoked = now < this.provokedUntil;
      this.currentAnger = provoked ? 1.0 : this.store.angerLevel();
      const newMood = provoked ? Mood.MAD : this.store.mood();
      if (newMood !== this.currentMood) {
        this.currentMood = newMood;
        switch (newMood) {
          case Mood.SLEEPY:
            if (!this.isDragging && !this.isPeeking && !this.goingHome) this.state = State.SITTING;
            break;
          case Mood.MAD:
            break;
          default:
            if (this.state === State.SITTING && this.pin === Pin.NONE) this.state = State.WALKING;
            if (this.state === State.FUMING) this.state = State.WALKING;
        }
      }
    }

    // Advance state machine
    this.advance(dt, now);

    // Publish pose (throttled)
    const moveStates = [State.WALKING, State.TURNING, State.DRAGGING, State.FALLING,
      State.LANDING, State.FUMING, State.PEEKING, State.TUCKING];
    const divisor = moveStates.includes(this.state) ? 2 : 4;

    if (this.tickCount % divisor === 0) {
      const pose = this.makePose(now);
      if (!posesEqual(pose, this.lastPose)) {
        this.lastPose = pose;
        this._onPoseUpdate(pose);
      }
    }
  }

  onPoseUpdate(cb) { this._onPoseUpdate = cb || (() => {}); }

  // ── State machine advancement ─────────────────────────────────────────────
  advance(dt, now) {
    if (this.paused && this.state !== State.DRAGGING) return;

    // Mad: plant and fume in fits
    if (this.currentMood === Mood.MAD && !this.goingHome) {
      switch (this.state) {
        case State.FUMING: case State.DRAGGING: case State.FALLING:
        case State.LANDING: case State.PEEKING: case State.TUCKING: break;
        case State.WALKING:
          if (now >= this.madStompUntil) this.enterFuming(now);
          break;
        default:
          this.enterFuming(now);
      }
      // Don't advance further while fuming
      if (this.state === State.FUMING) {
        if (now >= this.fumeUntil) {
          this.madStompUntil = now + this.MAD_STOMP_MIN + Math.random() * (this.MAD_STOMP_MAX - this.MAD_STOMP_MIN);
          this.state = State.WALKING;
        }
        return;
      }
    }

    switch (this.state) {
      case State.PEEKING:
        // Rest here until grabbed
        break;

      case State.WALKING:
        this.advanceWalking(dt, now);
        break;

      case State.TURNING:
        this.advanceTurning(dt, now);
        break;

      case State.IDLING:
        this.advanceIdling(dt, now);
        break;

      case State.TUCKING:
        this.advanceTucking(dt, now);
        break;

      default:
        // SITTING, DRAGGING, FALLING, LANDING, FUMING — no per-frame advance needed
        break;
    }
  }

  advanceWalking(dt, now) {
    if (this.goingHome) {
      this.walkClock += dt * Math.max(1.4, moodStrideHz(this.currentMood));
      this.facing = -1;
      this.x += -1 * this.baseSpeed * this.GO_HOME_SPEED * dt;
      if (this.x <= 2) {
        this.x = 0;
        this.state = State.TUCKING;
        this._tuckStart = now;
      }
      return;
    }

    if (this.currentMood === Mood.SLEEPY) { this.state = State.SITTING; return; }
    const speed = moodSpeedFactor(this.currentMood);
    this.walkClock += dt * moodStrideHz(this.currentMood);
    this.x += this.facing * this.baseSpeed * speed * dt;

    // Edge turnaround — check if we've walked off the visible area
    // We need the visible rect from outside; if we don't have it, we still
    // trigger based on accumulated x position (caller should provide bounds)
    // For now, edge detection is handled by the caller clamping x.

    // Idle pauses
    if (now >= this.nextIdleAt) {
      const len = (2.5 + Math.random() * 3.5) * (this.currentMood === Mood.ANTSY ? 0.5 : 1);
      this.state = State.IDLING;
      this._idleUntil = now + len;
      this._idleKind = Math.random() < 0.3 ? 'yawn' : (Math.random() < 0.5 ? 'lookAround' : 'breathe');
    }
  }

  advanceTurning(dt, now) {
    const p = (now - this._turnStart) / this.turnDuration;
    if (p >= 1) {
      this.facing = -this._turnFromFacing;
      this.state = State.WALKING;
      this.scheduleNextIdle(now);
    }
  }

  advanceIdling(dt, now) {
    if (now >= this._idleUntil) {
      this.state = State.WALKING;
      this.scheduleNextIdle(now);
    }
  }

  advanceTucking(dt, now) {
    const p = (now - this._tuckStart) / this.TUCK_DURATION;
    if (p >= 1) {
      this.state = State.PEEKING;
      this.goingHome = false;
      this.peekRiseStart = now;
    }
  }

  enterFuming(now) {
    this.state = State.FUMING;
    this.fumeUntil = now + this.FUME_DURATION_MIN + Math.random() * (this.FUME_DURATION_MAX - this.FUME_DURATION_MIN);
  }

  // Called externally when Pip hits a screen edge
  beginTurn() {
    this.state = State.TURNING;
    this._turnStart = performance.now() / 1000;
    this._turnFromFacing = this.facing;
  }

  // ── Pose generation ──────────────────────────────────────────────────────
  makePose(now) {
    const pose = new Pose();
    pose.phase = Math.round(this.animClock * 12) / 12;
    pose.mood = this.currentMood;
    pose.scaleX = this.facing;

    // Weekly aura
    if (this.store.snapshot.weeklyUsedPct != null) {
      pose.weeklyPct = this.store.snapshot.weeklyUsedPct;
    }

    // Badge
    pose.showBadge = this.showBadgePersistent;
    pose.badgeStats = this.store.usageStats();
    pose.badgeNote = this.store.snapshot.fiveHourUsedPct != null ? null
      : (this.store.tokenAvailable ? 'no usage data yet' : 'log into Claude Code to wake me up');

    // Bubble
    if (now < this.bubbleUntil && this.bubbleText) {
      pose.bubbleText = this.bubbleText;
    }

    const breath = (Math.sin(pose.phase * 2 * Math.PI / 3.2) + 1) / 2;

    switch (this.state) {
      case State.PEEKING:
        pose.peekFrame = this.peekFramePick();
        pose.scaleX = 1;
        pose.phase = 0;
        pose.badgeDrop = this.PEEK_BADGE_DROP;
        break;

      case State.TUCKING:
        {
          const p = Math.min(1, (now - this._tuckStart) / this.TUCK_DURATION);
          const eased = p * p * (3 - 2 * p);
          pose.popFrame = Math.max(0, 11 - Math.round(eased * 11));
          pose.scaleX = 1;
          pose.phase = 0;
          pose.badgeDrop = this.PEEK_BADGE_DROP * Math.min(1, p);
        }
        break;

      case State.WALKING:
        {
          const raw = this.walkClock % 2;
          pose.walkPhase = Math.floor(raw * 5) / 5;
          const f = (Math.round(raw * 12) / 12) % 1;
          const arc = Math.sin(Math.PI * f) * Math.sin(Math.PI * f);
          pose.bodyLift = arc * 2.5;
          pose.bodySquash = 0.03 - 0.05 * arc;
          if (this.currentMood === Mood.FOCUSED) {
            pose.bodyLift *= 1.4;
            pose.bodySquash *= 1.3;
          }
        }
        break;

      case State.TURNING:
        {
          const p = Math.min(1, Math.max(0, (now - this._turnStart) / this.turnDuration));
          pose.scaleX = this._turnFromFacing;
          pose.turnFromRight = this._turnFromFacing > 0;
          pose.turnPhase = Math.floor(p * 6) / 6;
          pose.bodySquash = Math.sin(Math.PI * p) * 0.04;
          pose.bodyLift = Math.sin(Math.PI * p) * 1.5;
        }
        break;

      case State.IDLING:
      case State.SITTING:
        pose.sitting = this.state === State.SITTING || this.currentMood === Mood.SLEEPY;
        pose.bodySquash = breath * 0.035;
        if (this.currentMood === Mood.ANTSY) {
          pose.footTap = Math.max(0, Math.sin(this.animClock * 2 * Math.PI * 3)) * 5;
        }
        break;

      case State.DRAGGING:
        {
          const start = this._dragStart || now;
          const p = Math.min(1, (now - start) / this.POP_DURATION);
          if (this.poppingOut) {
            if (p < this.POP_PULL_FRAC) {
              pose.popFrame = 0;
              const pp = p / this.POP_PULL_FRAC;
              pose.stretchY = this.POP_STRETCH_MAX * Math.sin(Math.PI * pp);
            } else {
              const ep = (p - this.POP_PULL_FRAC) / (1 - this.POP_PULL_FRAC);
              pose.popFrame = Math.min(11, Math.round(ep * 11));
              pose.stretchY = -this.POP_SQUASH_MAX * Math.max(0, 1 - ep / 0.22);
            }
          } else if (this.dragFromPeek) {
            const pick = this.airFramePick(now, start);
            pose.airSheet = pick.sheet;
            pose.airFrame = pick.frame;
          } else {
            const t = now - start;
            const grabEnd = 4 * 0.08;
            if (t < grabEnd) {
              pose.pickupFrame = Math.min(3, Math.floor(t / 0.08));
            } else if (t < grabEnd + 0.30) {
              pose.airFrame = 1;
            } else {
              const pick = this.airFramePick(now, start + grabEnd);
              pose.airSheet = pick.sheet;
              pose.airFrame = pick.frame;
            }
          }
        }
        break;

      case State.FALLING:
        {
          const vy = Math.max(-this.TERMINAL_FALL, this.dragVY - this.GRAVITY * 0.016);
          const speed = Math.max(0, -vy);
          pose.fallFrame = Math.min(7, Math.round(speed / this.TERMINAL_FALL * 7));
        }
        break;

      case State.LANDING:
        {
          const p = Math.min(1, (now - this._landStart) / (5 * 0.11));
          let frame = 11;
          if (p < 0.16) frame = 8;
          else if (p < 0.34) frame = 9;
          else if (p < 0.60) frame = 10;
          pose.fallFrame = frame;
        }
        break;

      case State.FUMING:
        {
          const tier = this.currentAnger < 0.55 ? 1 : 2;
          const frameInRow = Math.floor(this.animClock / 0.12) % 4;
          pose.madFrame = tier * 4 + frameInRow;
          pose.scaleX = this.facing;
          const rage = Math.max(0, Math.min(1, (this.currentAnger - 0.40) / 0.45));
          pose.bodyLift = Math.max(0, Math.sin(this.animClock * 2 * Math.PI * 5.5)) * (2.2 + 4 * rage);
          pose.footTap = 0.9 + rage;
        }
        break;
    }

    return pose;
  }

  airFramePick(now, heldSince) {
    const h = Math.abs(this.dragVX), v = Math.abs(this.dragVY);
    const speed = Math.max(h, v * 0.6);
    const dir = this.dragVX >= 0 ? 1 : 2;
    if (speed > 1100) {
      if (h > v * 0.8) {
        return { sheet: dir, frame: [5, 8][Math.floor(now / 0.15) % 2] };
      }
      return { sheet: 0, frame: (Math.floor(now / 0.15) % 2 === 0) ? 2 : 1 };
    }
    if (speed > 550) {
      return { sheet: dir, frame: [2, 3][Math.floor(now / 0.18) % 2] };
    }
    if (speed > 180) {
      return { sheet: dir, frame: [0, 1][Math.floor(now / 0.22) % 2] };
    }
    const t = now - heldSince;
    const cycle = t % 3.2;
    if (cycle > 2.75) {
      const kicks = [5, 9, 6];
      return { sheet: 0, frame: kicks[Math.floor(t / 3.2) % kicks.length] };
    }
    const calm = [0, 10, 11, 10];
    return { sheet: 0, frame: calm[Math.floor(t / 0.45) % calm.length] };
  }

  peekFramePick() {
    let t = this.animClock % this.PEEK_TIMELINE_TOTAL;
    for (const step of this.PEEK_TIMELINE) {
      if (t < step.dur) return step.frame;
      t -= step.dur;
    }
    return 0;
  }

  popFrameForTuck(now) {
    const p = Math.min(1, (now - this._tuckStart) / this.TUCK_DURATION);
    return Math.max(0, Math.floor((1 - p) * 12));
  }
}

// ── Pose equality ─────────────────────────────────────────────────────────────
function posesEqual(a, b) {
  const keys = ['walkPhase', 'turnPhase', 'pickupFrame', 'peekFrame', 'popFrame',
    'fallFrame', 'airFrame', 'madFrame', 'bodyLift', 'bodySquash', 'footTap', 'sitting',
    'mood', 'bubbleText', 'showBadge', 'weeklyPct', 'scaleX', 'stretchY'];
  for (const k of keys) {
    if (a[k] !== b[k]) return false;
  }
  return a.badgeNote === b.badgeNote
    && JSON.stringify(a.badgeStats) === JSON.stringify(b.badgeStats);
}
