import AppKit
import QuartzCore
import Observation

/// Everything the renderer needs to draw one frame of the mascot.
struct Pose: Equatable {
    var scaleX: CGFloat = 1          // facing (+right / −left), magnitude < 1 mid-turnaround
    var mood: Mood = .sleepy
    var walkPhase: CGFloat = -1      // stride cycle position in [0, 2): [0,1) stride A,
                                     // [1,2) stride B; -1 when not walking
    var turnPhase: CGFloat = -1      // edge-turnaround progress in [0, 1]; -1 when not turning
    var turnFromRight = false        // true: was walking right, turning to face left
    var pickupFrame = -1             // index into the pickup sheet; -1 when not grabbed/landing
    var peekFrame = -1               // index into the stable peek sheet while peeking from the edge; -1 otherwise
    var popFrame = -1                // index into the pop-out sheet while being pulled from the peek; -1 otherwise
    var fallFrame = -1               // index into the fall sheet while dropping/landing; -1 otherwise
    var airFrame = -1                // index into the selected in-air sheet; -1 otherwise
    var airSheet = 0                 // 0 base in-air set, 1 carried-right set, 2 carried-left set
    var madFrame = -1                // index into the mad sheet while fuming; -1 otherwise
    var bodySquash: CGFloat = 0      // + squashes (wider/shorter), − stretches
    var stretchY: CGFloat = 0        // peek/pop only: + stretches taller/thinner, − squashes (anchored at feet)
    var bodyLift: CGFloat = 0        // points the body rises off the ground
    var headBob: CGFloat = 0         // face offset, syncs with steps
    var phase: CGFloat = 0           // ambient clock for sway / zzz / sweat / tap
    var blink: CGFloat = 0           // 0 open .. 1 closed
    var yawn: CGFloat = 0            // 0 .. 1 mouth open
    var lookX: CGFloat = 0           // −1 .. 1 pupil shift
    var footTap: CGFloat = 0         // antsy idle foot-tap lift in points
    var sitting = false
    var weeklyPct: Double?
    var bubbleText: String?
    var showBadge = false
    var badgeStats: [UsageStat] = []
    var badgeNote: String?
    var badgeSafeMinX: CGFloat = 0     // on-screen window-x span, so the hover badge
    var badgeSafeMaxX: CGFloat = 280   // can dodge the screen edge and never clip
    var badgeDrop: CGFloat = 0         // push the badge down toward the head (peek/home)
}

@Observable
final class PoseModel {
    var pose = Pose()
}

/// CADisplayLink-driven state machine: continuous strolling along the bottom
/// edge, edge turnarounds, randomized idle pauses, drag handling, and mood
/// flavor. Movement (px/sec) and the walk-cycle pose clock are deliberately
/// decoupled — poses are quantized to ~8–11 fps so the steps read as steps.
final class WalkEngine: NSObject {

    // MARK: Tunables
    var baseSpeed: CGFloat = 34                       // points/sec at speedFactor 1.0
    var idleEvery: ClosedRange<Double> = 7...18       // seconds between idle pauses
    var idleLength: ClosedRange<Double> = 2.5...6     // seconds an idle pause lasts
    var turnDuration: Double = 0.55                   // 6 pivot frames at ~11 fps
    static let characterWidth: CGFloat = 110          // visual sprite width used for edge collision
    static let interactiveWidth: CGFloat = 180        // wider pickup/air/landing poses; keeps them on-screen near edges
    // Peeking "home": Pip is parked off the LEFT screen edge, poking his head
    // out from behind it. `peekInset` is the window-x coordinate that lands on
    // the screen's left edge — content left of it is hidden behind the edge.
    // The stable frames are pre-aligned with their flat cut at window-x ≈ 89,
    // so this tucks the cut a few points behind the edge (no visible seam).
    static let peekInset: CGFloat = 94
    // How far above the dock the home peek floats (the hole sits a bit up the
    // left edge, not down in the corner). Eased through the pop-out / tuck-in
    // so he descends to the ground as he emerges and rises back in going home.
    static let peekLift: CGFloat = 72
    static let peekBadgeDrop: CGFloat = 92   // how far to drop the hover badge toward his head at home
    static let peekRiseDuration: Double = 0.4   // after tucking in at the corner, rise up to the lifted peek
    private var peekRiseStart: TimeInterval = -1000   // far past → already risen (launch starts lifted)

    enum IdleKind { case breathe, lookAround, yawn }

    private enum State {
        case peeking                            // default: hiding off the left edge, head poked out, facing in
        case walking
        case turning(start: TimeInterval, fromFacing: CGFloat)
        case idling(kind: IdleKind, start: TimeInterval, until: TimeInterval)
        case sitting
        case dragging(start: TimeInterval)
        case falling(vy: CGFloat, bounced: Bool)
        case landing(start: TimeInterval)
        case fuming(start: TimeInterval)        // mad: planted, facing you, simmering
        case tuckingIn(start: TimeInterval)     // "go home": reverse side-pop, backing into the edge hole
    }

    /// Cartoon gravity for the released drop — gentle enough to read every
    /// frame on the way down, with one soft bounce after a hard fall.
    private static let gravity: CGFloat = 2000
    private static let terminalFall: CGFloat = 1250

    /// Pickup timing (seconds per drawn frame).
    private static let grabFrameDur = 0.08      // pickup frames 0-3: snatched off the ground
    private static let alertDur = 0.30          // in-air frame 1: startled beat after the snatch
    private static let landFrameDur = 0.11      // pickup frames 7-11: impact + brush-off
    static let landDuration = 5 * landFrameDur

    // Smoothed cursor velocity while held (window points/sec); drives which
    // in-air frame shows: calm dangle, trailing swing, or shaken-distress.
    private var dragVX: CGFloat = 0
    private var dragVY: CGFloat = 0
    private var lastDragOrigin: NSPoint?
    private var lastDragMoveAt: TimeInterval = 0
    private var dragInstVX: CGFloat = 0
    private var dragInstVY: CGFloat = 0
    private var airHeight: CGFloat = 0       // window-bottom height above the ground line
    private var tossVX: CGFloat = 0          // horizontal momentum carried into the drop

    // Pop-out-of-the-hole: grabbing him out of the side peek plays the side-pop
    // emergence over a fixed time, while he stays STUCK at the edge (the window
    // only does a tiny scripted settle, never chasing the cursor) so no frame
    // ever clips off-screen. Cursor-following only begins once he's fully out.
    private var poppingOut = false
    private var dragFromPeek = false
    static let popDuration: Double = 0.62       // seconds for the whole pull-out
    static let popPullFrac: Double = 0.42       // first part: yanked down to the corner, stretching
    static let popStretchMax: CGFloat = 0.4     // how far he stretches while stuck
    static let popSquashMax: CGFloat = 0.16     // touchdown squash at the corner
    // Window inset (window-x landing on the screen's left edge) for the fully
    // emerged frame — the widest frame sits flush here with nothing clipped.
    static let popEmergeInset: CGFloat = 84
    var isPoppingOut: Bool { poppingOut }

    // "Go home": walk back to the left edge, then play the side-pop emergence in
    // reverse to back into the hole, settling into the peek.
    private var goingHome = false
    static let tuckDuration: Double = 0.7
    static let goHomeSpeedFactor: CGFloat = 2.2   // brisk purposeful march home

    enum Pin: Int { case none, left, right }

    // MARK: Wiring
    private let store: UsageStore
    private let model: PoseModel
    var visibleFrameProvider: (() -> NSRect)?
    /// Returns the top edge (AppKit y) of a revealed auto-hide Dock so he can
    /// stand ON it like a platform; nil when there's no Dock to stand on.
    var dockGroundProvider: (() -> CGFloat?)?
    private var smoothGround: CGFloat = 0
    private var smoothGroundReady = false
    var moveWindow: ((NSPoint) -> Void)?
    var windowSize = NSSize(width: 280, height: 230)

    // MARK: State
    private var state: State = .peeking
    private(set) var facing: CGFloat = 1
    private var x: CGFloat = 0
    private var lastSentOrigin = NSPoint(x: -99999, y: -99999)
    private var lastTimestamp: TimeInterval = 0
    private var walkClock: Double = 0
    private var animClock: Double = 0
    private var nextIdleAt: TimeInterval = 0
    private var nextBlinkAt: TimeInterval = 0
    private var blinkStart: TimeInterval = -1
    private var currentMoodValue: Mood = .sleepy
    private var currentAnger: Double = 0          // 0…1, how badly the window is being wasted
    private var lastMoodCheck: TimeInterval = 0
    private var fumeUntil: TimeInterval = 0       // end of the current fuming fit
    private var madStompUntil: TimeInterval = 0   // end of the angry stomp between fits

    static let fumeDuration: ClosedRange<Double> = 2.6...4.4    // a fuming fit, planted at you
    static let madStompRange: ClosedRange<Double> = 1.0...2.0   // brief angry stomp between fits

    // Easter egg: drag a rival app icon (ChatGPT, Codex) near Pip and he loses it.
    private var provokedUntil: TimeInterval = 0
    private var rivalBubbleNextAt: TimeInterval = 0
    static let provokeHold: Double = 4.0
    static let rivalLines = [
        "ChatGPT?! not in MY house.",
        "keep that thing away from me",
        "ugh. GPT. really?",
        "we don't say that name here",
        "get that traitor away!",
        "i'm telling Claude.",
    ]

    private var bubbleUntil: TimeInterval = 0
    private var bubbleText: String?
    private var nextBubbleAt: TimeInterval = 60       // first candidate a minute in
    private var hovering = false
    private var tickCount = 0
    private var lastVisible: NSRect = .zero

    var paused = false
    var showBadgePersistent = false
    var pin: Pin = .none {
        didSet {
            if pin == .none, case .sitting = state, currentMoodValue != .sleepy {
                state = .walking
            }
        }
    }

    var currentMood: Mood { currentMoodValue }
    var isDragging: Bool { if case .dragging = state { return true } else { return false } }
    var isPeeking: Bool { if case .peeking = state { return true } else { return false } }
    /// Roaming on the open floor (so he should ride the Dock platform) — not
    /// tucked at his edge home or being carried.
    private var onOpenGround: Bool {
        switch state {
        case .peeking, .tuckingIn, .dragging: return false
        default: return true
        }
    }

    /// Easter egg: the ChatGPT app icon was dragged near him — he loses it.
    /// Forces a furious fume for a few seconds, storming out of his hole if home.
    func provokeByRival() {
        let now = CACurrentMediaTime()
        provokedUntil = now + Self.provokeHold
        currentMoodValue = .mad
        currentAnger = 1.0
        if isPeeking, !goingHome { state = .walking }   // storm out to confront the rival
        if now >= rivalBubbleNextAt {
            bubbleText = Self.rivalLines.randomElement()
            bubbleUntil = now + 3.5
            rivalBubbleNextAt = now + 5
        }
    }
    /// True while heading back to / tucking into the edge (so the menu can hide
    /// the option once he's already home or on his way).
    var isHomeOrHeading: Bool {
        if goingHome { return true }
        if case .peeking = state { return true }
        if case .tuckingIn = state { return true }
        return false
    }

    /// Send Pip back to his side-edge home: walk to the left edge, then play the
    /// pop-out emergence in reverse to back into the hole.
    func goHome() {
        guard !isHomeOrHeading else { return }
        goingHome = true
        switch state {
        case .dragging, .falling, .landing: break   // let the interaction finish; he'll head home once walking
        default: state = .walking
        }
    }

    init(store: UsageStore, model: PoseModel) {
        self.store = store
        self.model = model
        super.init()
    }

    func startPosition(in visible: NSRect) -> NSPoint {
        // Default "home": tucked behind the LEFT edge, peeking his head out and
        // facing right (into the screen). Grab + drop pulls him out to roam.
        state = .peeking
        facing = 1
        x = peekX(in: visible)
        return NSPoint(x: x, y: visible.minY + 1 + Self.peekLift)
    }

    /// Window origin x that parks Pip mostly off the left edge, with `peekInset`
    /// worth of window held at the screen's left edge (the rest hidden behind it).
    private func peekX(in visible: NSRect) -> CGFloat {
        return visible.minX - Self.peekInset
    }

    /// Window inset for a given pop/tuck frame, tied to the frame itself (no
    /// frame↔position desync). The round-bodied frames (≥4) sit FLUSH at the
    /// edge so the body is never sliced; only the flat-cut peek frames (0-3,
    /// which are drawn to meet a wall) ease the rest of the way to the edge.
    private static func popInset(forFrame f: Int) -> CGFloat {
        let t = max(0, min(1, CGFloat(4 - f) / 4))
        return popEmergeInset + (peekInset - popEmergeInset) * t
    }

    /// Vertical lift of the window above the dock: full while peeking, eased to
    /// 0 as he pops out (drops to the ground), eased back up as he tucks home.
    private func peekYLift(now: TimeInterval) -> CGFloat {
        switch state {
        case .peeking:
            // Rise up to the lifted peek AFTER tucking in at the corner.
            let p = max(0, min(1, (now - peekRiseStart) / Self.peekRiseDuration))
            return Self.peekLift * CGFloat(p * p * (3 - 2 * p))
        case .dragging(let start) where poppingOut:
            // Yanked down to the corner during the first (pull) part, then he
            // emerges from there on the ground.
            let p = min(1, (now - start) / Self.popDuration)
            guard p < Self.popPullFrac else { return 0 }
            let pp = p / Self.popPullFrac
            return Self.peekLift * CGFloat(1 - pp * pp * (3 - 2 * pp))
        default:
            // Tucking in (and everything else) stays on the ground / bottom
            // corner; the rise only happens once he's settled into the peek.
            return 0
        }
    }

    /// Stable edge-peek idle: the body never moves (the frames are pre-aligned
    /// to the edge), only the face changes. A calm timeline of (frame, seconds)
    /// — long neutral holds, a quick blink (2→3→2), the occasional smile, look
    /// and a little startled wiggle (7) — loops to keep him alive but settled.
    /// Frame map: 0/4/5/8/9 neutral · 1 smile · 2 half-blink · 3 eyes-shut ·
    /// 6 glance · 7 wiggle.
    private static let peekTimeline: [(frame: Int, dur: Double)] = [
        (0, 2.4), (2, 0.09), (3, 0.13), (2, 0.07),    // settle, blink
        (5, 1.9), (6, 1.2),                            // neutral, glance
        (1, 1.3),                                      // smile
        (8, 1.7), (2, 0.09), (3, 0.13), (2, 0.07),     // neutral, blink
        (7, 0.45), (8, 0.16), (7, 0.45),               // startled wiggle
        (9, 2.1),                                      // long neutral
    ]
    private static let peekTimelineTotal: Double = peekTimeline.reduce(0) { $0 + $1.dur }

    private func peekFramePick() -> Int {
        var t = animClock.truncatingRemainder(dividingBy: Self.peekTimelineTotal)
        for step in Self.peekTimeline {
            if t < step.dur { return step.frame }
            t -= step.dur
        }
        return 0
    }

    // MARK: - Display link tick

    @objc func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        var dt = now - lastTimestamp
        if lastTimestamp == 0 || dt < 0 || dt > 0.1 { dt = 1.0 / 60.0 }
        if lastTimestamp == 0 { scheduleNextIdle(now: now) }   // nextIdleAt starts at 0, which would idle on the very first tick
        lastTimestamp = now
        tickCount &+= 1

        animClock += dt

        if isDragging {
            // Smooth (and decay, once move events stop) the held velocity.
            if now - lastDragMoveAt > 0.08 { dragInstVX = 0; dragInstVY = 0 }
            let k = CGFloat(min(1, dt * 10))
            dragVX += (dragInstVX - dragVX) * k
            dragVY += (dragInstVY - dragVY) * k
        }

        // Mood is cheap but no need to recompute 60×/sec.
        if now - lastMoodCheck > 1.0 {
            lastMoodCheck = now
            let provoked = now < provokedUntil          // rival brought near him
            currentAnger = provoked ? 1.0 : store.angerLevel()   // drives the fuming tier
            let newMood = provoked ? .mad : store.mood()
            if newMood != currentMoodValue {
                currentMoodValue = newMood
                switch newMood {
                case .sleepy:
                    if !isDragging, !isPeeking, !goingHome { state = .sitting }
                case .mad:
                    break   // advance() keeps him fuming in fits (below)
                default:
                    if case .sitting = state, pin == .none { state = .walking }
                    if case .fuming = state { state = .walking }
                }
            }
        }

        let visible = visibleFrameProvider?() ?? .zero
        guard visible.width > 10 else { return }
        lastVisible = visible
        // Walk-cycle width drives edge turnaround + the normal resting clamp.
        let margin = (windowSize.width - Self.characterWidth) / 2
        let minX = visible.minX - margin
        let maxX = visible.maxX + margin - windowSize.width

        advance(dt: dt, now: now, minX: minX, maxX: maxX)

        // The pickup / air / landing poses are visually wider than the walk
        // cycle (out-flung arms, hands-to-face, motion lines), so they need a
        // bigger on-screen margin or they clip against a screen edge when Pip
        // is dropped there. Ease into it mid-fall so there's no sideways pop.
        let safeMargin = (windowSize.width - Self.interactiveWidth) / 2
        let sMinX = visible.minX - safeMargin
        let sMaxX = visible.maxX + safeMargin - windowSize.width
        switch state {
        case .peeking:
            // Deliberately off the left edge — don't clamp back on-screen.
            x = peekX(in: visible)
        case .tuckingIn:
            break   // advance() pins x at the edge for the reverse emergence
        case .dragging where poppingOut:
            break   // advance() pins x at the edge for the emergence
        case .falling:
            let target = min(max(x, sMinX), sMaxX)
            x += (target - x) * CGFloat(min(1, dt * 9))
        case .landing:
            x = min(max(x, sMinX), sMaxX)
        default:
            x = min(max(x, minX), maxX)
        }

        // Keep feet pinned to the bottom edge even if the Dock/screen changes
        // (airHeight > 0 only mid-drop, while gravity brings Pip down). During
        // the pop-out the engine also owns the window (he's pinned at the edge,
        // not yet following the cursor), so move it then too.
        // Ground line: normally the bottom of the screen, but ride the top of a
        // revealed (auto-hide) Dock when roaming, so he stands on it. Smoothed so
        // he rises/sinks with the Dock's reveal/hide animation.
        var groundBase = visible.minY
        if onOpenGround, let dockTop = dockGroundProvider?() { groundBase = dockTop }
        if !smoothGroundReady { smoothGround = groundBase; smoothGroundReady = true }
        smoothGround += (groundBase - smoothGround) * CGFloat(min(1, dt * 7))

        if !isDragging || poppingOut {
            let origin = NSPoint(x: x, y: smoothGround + 1 + airHeight + peekYLift(now: now))
            if abs(origin.x - lastSentOrigin.x) > 0.01 || abs(origin.y - lastSentOrigin.y) > 0.01 {
                lastSentOrigin = origin
                moveWindow?(origin)
            }
        }

        updateBlink(now: now)
        if tickCount % 15 == 0 { updateHover(visible: visible) }
        updateBubble(now: now)

        // Publish poses at a lower rate than the window moves: the window
        // translates at full display-link rate so traversal stays smooth, but
        // drawn poses are quantized (steps at ~8–11 fps, ambient motion at
        // 12 fps via the rounded phase clock), and identical poses are not
        // re-published — SwiftUI only redraws when something visibly changed.
        // That keeps CPU low, especially when idle.
        let divisor: Int
        switch state {
        case .walking, .turning, .dragging, .falling, .landing, .fuming, .peeking, .tuckingIn: divisor = 2
        case .idling, .sitting: divisor = 4
        }
        if tickCount % divisor == 0 {
            let pose = makePose(now: now)
            if pose != model.pose { model.pose = pose }
        }
    }

    // MARK: - Movement state machine

    private func advance(dt: Double, now: TimeInterval, minX: CGFloat, maxX: CGFloat) {
        if paused {
            if case .dragging = state { return }
            return // pose still renders breathing via makePose
        }

        // Mad: plant and FUME (mad sheet, trembling) in fits, with brief angry
        // stomps between them — re-asserted every tick so he's actually mad the
        // whole time, even after being dropped back down or pulled around.
        if currentMoodValue == .mad, !goingHome {
            switch state {
            case .fuming, .dragging, .falling, .landing, .peeking, .tuckingIn: break
            case .walking where now < madStompUntil: break              // mid-stomp
            default: enterFuming(now: now)
            }
        }

        switch state {
        case .peeking:
            // Rests here until the user grabs him and drops him out to roam.
            break

        case .walking:
            if goingHome {
                // March briskly straight to the left edge (no idle/turnaround),
                // then back into the hole.
                walkClock += dt * max(1.4, currentMoodValue.strideHz)
                facing = -1
                x += facing * baseSpeed * Self.goHomeSpeedFactor * dt
                if x <= minX + 2 {
                    x = minX
                    state = .tuckingIn(start: now)
                }
                return
            }
            if currentMoodValue == .sleepy { state = .sitting; return }
            let speedFactor = currentMoodValue.speedFactor
            // walkClock counts strides directly (mood cadence), independent of
            // the movement speed below.
            walkClock += dt * currentMoodValue.strideHz
            x += facing * baseSpeed * speedFactor * dt

            if let target = pinTarget(minX: minX, maxX: maxX) {
                // Walk toward the pinned corner, then settle.
                let dir: CGFloat = target > x ? 1 : -1
                if facing != dir { facing = dir }
                if abs(target - x) < 2 { x = target; state = .sitting }
                return
            }

            if (facing > 0 && x >= maxX) || (facing < 0 && x <= minX) {
                state = .turning(start: now, fromFacing: facing)
            } else if now >= nextIdleAt {
                let kind = randomIdleKind()
                var length = Double.random(in: idleLength)
                if currentMoodValue == .antsy { length *= 0.5 }   // too impatient to stand still
                state = .idling(kind: kind, start: now, until: now + length)
            }

        case .turning(let start, let fromFacing):
            let p = (now - start) / turnDuration
            if p >= 1 {
                facing = -fromFacing
                state = .walking
                scheduleNextIdle(now: now)
            }

        case .idling(_, _, let until):
            if currentMoodValue == .sleepy { state = .sitting; return }
            if now >= until {
                state = .walking
                scheduleNextIdle(now: now)
            }

        case .sitting:
            if goingHome { state = .walking; return }
            if currentMoodValue != .sleepy, pinTarget(minX: minX, maxX: maxX) == nil, pin == .none {
                state = .walking
            }

        case .dragging(let start):
            // Pop-out emergence: keep him pinned at the edge (a tiny scripted
            // settle from the peek spot to the flush-emerged spot — never the
            // cursor) so nothing clips. The controller starts cursor-following
            // only after this finishes.
            if poppingOut {
                let p = min(1, (now - start) / Self.popDuration)
                let visMinX = minX + (windowSize.width - Self.characterWidth) / 2
                if p < Self.popPullFrac {
                    x = visMinX - Self.peekInset            // stuck at the edge while he's yanked down
                } else {
                    let ep = (p - Self.popPullFrac) / (1 - Self.popPullFrac)
                    let frame = min(11, Int((ep * 11).rounded()))
                    x = visMinX - Self.popInset(forFrame: frame)
                }
                if p >= 1 { poppingOut = false }
            }

        case .falling(var vy, let bounced):
            vy = max(vy - Self.gravity * CGFloat(dt), -Self.terminalFall)
            airHeight += vy * CGFloat(dt)
            x += tossVX * CGFloat(dt)                  // a fling carries sideways momentum
            tossVX *= CGFloat(exp(-2.5 * dt))
            if airHeight <= 0 {
                airHeight = 0
                state = .landing(start: now)           // hit the ground → straight into the squash, no bounce
            } else {
                state = .falling(vy: vy, bounced: bounced)
            }

        case .landing(let start):
            if now - start >= Self.landDuration {
                state = currentMoodValue == .sleepy ? .sitting : .walking
                scheduleNextIdle(now: now)
            }

        case .tuckingIn(let start):
            // Reverse pop, pinned at the edge: a tiny scripted settle from the
            // flush-emerged spot back to the peek spot (never off-screen), so the
            // reverse frames never clip. makePose plays them 11 → 0.
            let p = min(1, (now - start) / Self.tuckDuration)
            let eased = p * p * (3 - 2 * p)
            let frame = max(0, 11 - Int((eased * 11).rounded()))
            let visMinX = minX + (windowSize.width - Self.characterWidth) / 2
            x = visMinX - Self.popInset(forFrame: frame)
            if p >= 1 {
                goingHome = false
                facing = 1
                peekRiseStart = now        // now rise up from the corner to the lifted peek
                state = .peeking
            }

        case .fuming:
            if currentMoodValue != .mad { state = .walking; return }
            // After a fit, stomp off angrily for a beat (the mad block re-fumes
            // once madStompUntil passes), turning around if he's at an edge.
            if now >= fumeUntil {
                madStompUntil = now + Double.random(in: Self.madStompRange)
                if (facing > 0 && x >= maxX - 1) || (facing < 0 && x <= minX + 1) { facing = -facing }
                state = .walking
            }
        }
    }

    private func enterFuming(now: TimeInterval) {
        fumeUntil = now + Double.random(in: Self.fumeDuration)
        state = .fuming(start: now)
    }

    private func pinTarget(minX: CGFloat, maxX: CGFloat) -> CGFloat? {
        switch pin {
        case .none: return nil
        case .left: return minX
        case .right: return maxX
        }
    }

    private func scheduleNextIdle(now: TimeInterval) {
        nextIdleAt = now + Double.random(in: idleEvery)
    }

    private func randomIdleKind() -> IdleKind {
        let r = Double.random(in: 0..<1)
        if r < 0.50 { return .breathe }
        if r < 0.85 { return .lookAround }
        return .yawn
    }

    // MARK: - Drag support (interactive mode)

    func beginDrag() {
        dragVX = 0; dragVY = 0
        dragInstVX = 0; dragInstVY = 0
        lastDragOrigin = nil
        // Grabbing him out of the side peek plays the timed pop-out emergence
        // (he stays put at the edge) instead of the off-the-ground snatch.
        dragFromPeek = isPeeking
        poppingOut = isPeeking
        state = .dragging(start: CACurrentMediaTime())
    }

    /// Called from the controller on every mouse-drag window move.
    func noteDragMove(origin: NSPoint) {
        let now = CACurrentMediaTime()
        if let prev = lastDragOrigin {
            let dt = now - lastDragMoveAt
            if dt > 0.001 {
                dragInstVX = (origin.x - prev.x) / dt
                dragInstVY = (origin.y - prev.y) / dt
            }
        }
        lastDragOrigin = origin
        lastDragMoveAt = now
    }

    /// Release: Pip keeps the throw's momentum and falls under gravity from
    /// wherever it was let go; landing frames play on touchdown.
    func endDrag(atOrigin origin: NSPoint) {
        poppingOut = false
        dragFromPeek = false
        x = origin.x
        let visible = visibleFrameProvider?() ?? .zero
        airHeight = max(0, origin.y - (visible.minY + 1))
        tossVX = max(-700, min(700, dragVX))
        let vy0 = max(-200, min(500, dragVY * 0.35))   // an upward fling arcs up first
        lastTimestamp = 0
        lastSentOrigin = NSPoint(x: -99999, y: -99999)
        if airHeight > 2 {
            state = .falling(vy: vy0, bounced: false)
        } else {
            state = .landing(start: CACurrentMediaTime())
        }
    }

    /// Pick the in-air sheet + frame from how the cursor is moving. The
    /// carried-right/left sheets share an intensity ladder: 0/1 gentle lean,
    /// 2/3 happy streaming, 5/8 distressed at speed.
    private func airFramePick(now: TimeInterval, heldSince: TimeInterval) -> (sheet: Int, frame: Int) {
        let h = abs(dragVX), v = abs(dragVY)
        let speed = max(h, v * 0.6)
        let dir = dragVX >= 0 ? 1 : 2
        if speed > 1100 {
            if h > v * 0.8 {                           // dragged hard sideways
                return (dir, [5, 8][Int(now / 0.15) % 2])
            }
            return (0, Int(now / 0.15) % 2 == 0 ? 2 : 1)   // shaken vertically
        }
        if speed > 550 {                               // brisk carry — streaming along
            return (dir, [2, 3][Int(now / 0.18) % 2])
        }
        if speed > 180 {                               // gentle carry — soft lean
            return (dir, [0, 1][Int(now / 0.22) % 2])
        }
        // Held still: slow breathing dangle, with a little leg kick every few
        // seconds (rotating through the three kick poses).
        let t = now - heldSince
        let cycle = t.truncatingRemainder(dividingBy: 3.2)
        if cycle > 2.75 {
            let kicks = [5, 9, 6]
            return (0, kicks[Int(t / 3.2) % kicks.count])
        }
        let calm = [0, 10, 11, 10]
        return (0, calm[Int(t / 0.45) % calm.count])
    }

    // MARK: - Bubbles

    func dismissBubble() {
        bubbleText = nil
        bubbleUntil = 0
    }

    private func updateBubble(now: TimeInterval) {
        if bubbleText != nil, now > bubbleUntil {
            bubbleText = nil
        }
        // While peeking, the window (and so any bubble) sits off the right
        // edge — stay quiet until he's pulled out to roam.
        guard bubbleText == nil, now >= nextBubbleAt, !paused, !isPeeking else { return }
        let line: String?
        switch currentMoodValue {
        case .mad:
            // Pointed, frequent, and quantified — name the projected waste and
            // the time left so the nudge is actionable.
            let proj = store.projectedFinalPct().map { Int($0.rounded()) }
            let left = store.snapshot.fiveHourResetsAt.map { UsageStore.countdown(to: $0, from: Date()) }
            var options = [
                "you're wasting this window. USE ME.",
                "tick tock — quota's melting and you're idle",
                "we are so behind. ship something!",
            ]
            if let p = proj { options.append("on track for only \(p)% — that's points left on the table") }
            if let l = left { options.append("\(l) left and barely touched. let's GO") }
            if let p = proj, let l = left { options.append("\(p)% projected, \(l) to fix it. move!") }
            line = options.randomElement()
        case .antsy:
            line = [
                "you've got quota to burn — use me!",
                "psst. this window resets soon and we've barely used it",
                "idle hands! ship something",
            ].randomElement()
        case .worried:
            line = "almost out for this window — maybe wrap up"
        case .happy:
            line = Double.random(in: 0..<1) < 0.3 ? "nice pace today" : nil
        default:
            line = nil
        }
        if let line {
            bubbleText = line
            bubbleUntil = now + (currentMoodValue == .mad ? 6 : 8)
        }
        // Mad nags often (it's the whole point); every other mood stays rare.
        nextBubbleAt = now + (currentMoodValue == .mad
            ? Double.random(in: 20...45)
            : Double.random(in: 600...1500))
    }

    // MARK: - Small animations

    private func updateBlink(now: TimeInterval) {
        if now >= nextBlinkAt {
            blinkStart = now
            nextBlinkAt = now + Double.random(in: 2.2...6.0)
        }
    }

    private func updateHover(visible: NSRect) {
        let charRect = NSRect(
            x: x + (windowSize.width - Self.characterWidth) / 2,
            y: visible.minY + (isPeeking ? Self.peekLift : 0),
            width: Self.characterWidth,
            height: 165)
        hovering = charRect.contains(NSEvent.mouseLocation)
    }

    // MARK: - Pose assembly

    private func makePose(now: TimeInterval) -> Pose {
        var pose = Pose()
        pose.mood = currentMoodValue
        // Quantized to 12 fps so unchanged poses can be skipped entirely.
        pose.phase = CGFloat((animClock * 12).rounded() / 12)
        pose.scaleX = facing
        pose.weeklyPct = store.snapshot.weeklyUsedPct
        pose.bubbleText = bubbleText
        pose.showBadge = hovering || showBadgePersistent
        if pose.showBadge {
            pose.badgeStats = store.usageStats()
            pose.badgeNote = store.badgeNote
        }
        // The window can sit mostly off the left edge (peeking at home), so tell
        // the renderer which window-x span is actually on screen; the badge keeps
        // itself inside that span instead of clipping at the edge.
        if lastVisible.width > 10 {
            pose.badgeSafeMinX = max(0, lastVisible.minX - x)
            pose.badgeSafeMaxX = min(windowSize.width, lastVisible.maxX - x)
        }
        // At home he peeks low in the window, so drop the badge down next to his
        // head instead of leaving it floating up at the window top.
        if isPeeking { pose.badgeDrop = Self.peekBadgeDrop }

        // Blink (suppressed while asleep — lids already shut).
        if blinkStart > 0 {
            let t = now - blinkStart
            if t < 0.14 { pose.blink = CGFloat(sin(.pi * t / 0.14)) }
        }

        // Breathing derives from the quantized phase so calm poses repeat
        // exactly between visible changes (and get skipped by the publisher).
        let breath = (sin(Double(pose.phase) * 2 * .pi / 3.2) + 1) / 2   // slow 3.2 s cycle

        func applyWalkCycle() {
            // walkClock counts footfalls; the full drawn cycle is two steps
            // (10 frames). walkPhase is held at the current frame boundary so
            // identical poses dedup and each hand-drawn frame displays
            // cleanly — no blending between frames.
            let raw = walkClock.truncatingRemainder(dividingBy: 2)
            pose.walkPhase = CGFloat((raw * 5).rounded(.down) / 5)

            // The frames carry the leg action; add only a soft bounce arc
            // per step (quantized to 1/12 stride for pose dedup).
            let f = ((raw * 12).rounded() / 12).truncatingRemainder(dividingBy: 1)
            let arc = sin(.pi * f) * sin(.pi * f)
            pose.bodyLift = CGFloat(arc) * 2.5
            pose.bodySquash = CGFloat(0.03 - 0.05 * arc)        // light squash/stretch
            pose.headBob = CGFloat(0.8 - 2 * arc)
            if currentMoodValue == .focused {                   // determined march: bigger bounce
                pose.bodyLift *= 1.4
                pose.bodySquash *= 1.3
            }
        }

        if paused {
            pose.bodySquash = CGFloat(breath) * 0.03
            return pose
        }

        switch state {
        case .peeking:
            // Hand-drawn side-pop frames carry the whole peek-a-boo; the
            // renderer draws just the frame at the left edge. Drop the ambient
            // clock so the long tucked-away rest dedups to one static pose.
            pose.peekFrame = peekFramePick()
            pose.scaleX = 1
            pose.phase = 0

        case .walking:
            applyWalkCycle()

        case .turning(let start, let fromFacing):
            let p = min(1, max(0, (now - start) / turnDuration))
            // Hand-drawn pivot frames carry the rotation; quantize progress to
            // frame boundaries so identical poses dedup. A whisper of lift
            // keeps the pivot feeling like a weight shift.
            pose.scaleX = fromFacing
            pose.turnFromRight = fromFacing > 0
            pose.turnPhase = CGFloat((p * 6).rounded(.down) / 6)
            pose.bodySquash = CGFloat(sin(.pi * p)) * 0.04
            pose.bodyLift = CGFloat(sin(.pi * p)) * 1.5

        case .idling(let kind, let start, let until):
            pose.bodySquash = CGFloat(breath) * 0.035
            pose.headBob = CGFloat(breath) * -1.5
            switch kind {
            case .breathe:
                break
            case .lookAround:
                pose.lookX = CGFloat(sin((now - start) * 1.4)) * 0.9
            case .yawn:
                let span = max(0.1, until - start)
                pose.yawn = CGFloat(sin(.pi * min(1, (now - start) / span)))
            }
            if currentMoodValue == .antsy {
                // Impatient foot tapping, ~3 taps/sec.
                pose.footTap = max(0, CGFloat(sin(animClock * 2 * .pi * 3))) * 5
            }

        case .sitting:
            pose.sitting = true
            pose.bodySquash = 0.09 + CGFloat(breath) * 0.025
            if currentMoodValue == .sleepy {
                pose.blink = 1
            }

        case .dragging(let start):
            if poppingOut {
                let p = min(1, (now - start) / Self.popDuration)
                if p < Self.popPullFrac {
                    // Stuck in the hole, yanked down to the corner: hold the peek
                    // head and stretch tall (anchored at the feet) as he's pulled.
                    let pp = p / Self.popPullFrac
                    pose.popFrame = 0
                    pose.stretchY = Self.popStretchMax * CGFloat(sin(.pi * pp))
                } else {
                    // Touched down at the corner — a quick squash, then emerge.
                    let ep = (p - Self.popPullFrac) / (1 - Self.popPullFrac)
                    pose.popFrame = min(11, Int((ep * 11).rounded()))
                    pose.stretchY = -Self.popSquashMax * CGFloat(max(0, 1 - ep / 0.22))
                }
            } else if dragFromPeek {
                // Already emerged via the pop-out — skip the off-the-ground
                // snatch and go straight to the carried frames.
                let pick = airFramePick(now: now, heldSince: start)
                pose.airSheet = pick.sheet
                pose.airFrame = pick.frame
            } else {
                // Snatch reaction (pickup frames 0-3), a startled beat, then the
                // in-air set takes over, reacting to how the cursor moves.
                let t = now - start
                let grabEnd = 4 * Self.grabFrameDur
                if t < grabEnd {
                    pose.pickupFrame = min(3, Int(t / Self.grabFrameDur))
                } else if t < grabEnd + Self.alertDur {
                    pose.airFrame = 1
                } else {
                    let pick = airFramePick(now: now, heldSince: start + grabEnd)
                    pose.airSheet = pick.sheet
                    pose.airFrame = pick.frame
                }
            }

        case .falling(let vy, _):
            // Drop frames driven by downward speed: calm at the apex (0), more
            // flail + speed-lines as he accelerates toward terminal (→7).
            let speed = max(0, -vy)
            pose.fallFrame = min(7, Int((speed / Self.terminalFall * 7).rounded()))

        case .fuming:
            // Anger tier picks the row, looping its 4 frames as a seething bob.
            // Row 0 of the sheet is near-neutral (almost smiling), so "mad"
            // uses row 1 (cross) and row 2 (red-faced furious — most of the time).
            let rage = max(0, min(1, (currentAnger - 0.40) / 0.45))   // 0…1 across the mad range
            let tier = currentAnger < 0.55 ? 1 : 2
            let frameInRow = Int(animClock / 0.12) % 4                // quick agitated cycle
            pose.madFrame = tier * 4 + frameInRow
            pose.scaleX = facing                       // sprite is front-facing; keep sign stable
            // The madder he is, the harder he trembles and jiggles at you.
            pose.bodyLift = CGFloat(max(0, sin(animClock * 2 * .pi * 5.5))) * CGFloat(2.2 + 4 * rage)
            pose.footTap = CGFloat(0.9 + rage)         // drives the renderer's angry jiggle + anger mark

        case .landing(let start):
            // Touchdown: squash down (8 → 9 → 10 max) then spring back up to a
            // stand (11) before walking off — so the drop resolves smoothly.
            let p = min(1, (now - start) / Self.landDuration)
            let frame: Int
            if p < 0.16 { frame = 8 }
            else if p < 0.34 { frame = 9 }
            else if p < 0.60 { frame = 10 }
            else { frame = 11 }
            pose.fallFrame = frame

        case .tuckingIn(let start):
            // Reverse side-pop: full body (11) → tucked head-peek (0), backing
            // into the hole. Same eased curve the window slide uses.
            let p = min(1, (now - start) / Self.tuckDuration)
            let eased = p * p * (3 - 2 * p)
            pose.popFrame = max(0, 11 - Int((eased * 11).rounded()))
            pose.phase = 0
        }

        return pose
    }
}
