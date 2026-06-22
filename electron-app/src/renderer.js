// ── Canvas renderer (ported from MascotView.swift drawMascot) ────────────────
import { Mood, Palette } from './mood.js';
import { Sprites } from './sprites.js';

const SPRITE_SIDE = 200;

export class Renderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
  }

  draw(pose) {
    const ctx = this.ctx;
    const w = this.canvas.width;
    const h = this.canvas.height;
    const cx = w / 2;
    const ground = h - 5;

    ctx.clearRect(0, 0, w, h);

    let sprite = null;

    // Peek / pop frames
    if (pose.peekFrame >= 0 || pose.popFrame >= 0) {
      if (pose.popFrame >= 0) {
        sprite = Sprites.safeGet(Sprites.pop, pose.popFrame);
      } else {
        sprite = Sprites.safeGet(Sprites.stable, pose.peekFrame);
      }
      if (sprite && sprite.img) {
        this.drawSprite(sprite, cx, ground, pose.scaleX, pose);
      }
      return;
    }

    sprite = Sprites.select(pose);
    if (!sprite || !sprite.img) {
      this.drawPlaceholder(cx, ground, pose);
      return;
    }

    this.drawSprite(sprite, cx, ground, pose.scaleX, pose);
  }

  drawSprite(sprite, cx, ground, scaleX, pose) {
    const ctx = this.ctx;
    const side = SPRITE_SIDE;
    const x = cx - side / 2;
    const lift = (pose.bodyLift || 0) + (pose.footTap || 0) * 0.5;
    const y = ground - lift - (sprite.footFrac || 0.9) * side;

    // Directional sprites (walk/idle/air left+right) already face the correct way,
    // so they must NOT be mirrored again — only single-direction sets use scaleX to flip.
    const flip = sprite.directional ? 1 : scaleX;

    ctx.save();
    ctx.translate(cx, ground);
    ctx.scale(flip, 1);
    ctx.translate(-cx, -ground);
    ctx.drawImage(sprite.img, x, y, side, side);
    ctx.restore();
  }

  drawPlaceholder(cx, ground, pose) {
    const ctx = this.ctx;
    const lift = (pose.bodyLift || 0) + (pose.footTap || 0) * 0.5;
    const y = ground - lift - 90;

    ctx.save();
    ctx.translate(cx, ground);
    ctx.scale(pose.scaleX >= 0 ? 1 : -1, 1);
    ctx.translate(-cx, -ground);

    // Body
    ctx.fillStyle = 'rgba(204, 120, 92, 0.9)';
    ctx.beginPath();
    ctx.ellipse(cx, y + 80, 45, 55, 0, 0, Math.PI * 2);
    ctx.fill();

    // Eyes
    ctx.fillStyle = 'rgb(51, 48, 43)';
    ctx.beginPath();
    ctx.arc(cx - 15, y + 60, 5, 0, Math.PI * 2);
    ctx.arc(cx + 15, y + 60, 5, 0, Math.PI * 2);
    ctx.fill();

    ctx.restore();
  }
}
