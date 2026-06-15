import AppKit
import SwiftUI
import QuartzCore
import ServiceManagement
import ApplicationServices

/// Apps that make Pip jealous. Matched by bundle id (preferred) or, as a
/// fallback, a substring of the file / Dock-tile name. Add a rival here and
/// both trigger paths (Finder-drag onto Pip, cursor-over-Dock-icon) pick it up.
enum Rival {
    static let bundleIDs: Set<String> = ["com.openai.chat", "com.openai.codex"]
    static let nameNeedles = ["chatgpt", "codex"]

    static func matches(bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return bundleIDs.contains(id)
    }
    static func matches(name: String) -> Bool {
        let n = name.lowercased()
        return nameNeedles.contains { n.contains($0) }
    }
}

/// Borderless, transparent, non-activating panel — floats above other windows
/// without ever stealing focus.
final class MascotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Catches all mouse events itself (so SwiftUI content stays inert) and
/// forwards them to the controller. Only relevant when click-through is off.
final class MascotContainerView: NSView {
    weak var controller: MascotController?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(with: event, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.dragBegan(event)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.dragMoved(event)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.dragEnded(event)
    }

    // MARK: - Drag destination (easter egg)
    // Dragging a rival app icon (ChatGPT, Codex) over Pip makes him lose it. We never accept
    // the drop (operation stays empty, so the cursor shows the "no" badge — fitting),
    // we only use the hover to provoke him. Works without Accessibility permission,
    // independent of the Dock-hover rival path.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.draggingIsRival(sender) { controller?.rivalDraggedNear() }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.draggingIsRival(sender) { controller?.rivalDraggedNear() }
        return []
    }

    /// True when the dragged item is a rival app (by bundle id, falling back to
    /// the file name) — matched against the pasteboard's file URLs.
    static func draggingIsRival(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: opts) as? [URL] else { return false }
        return urls.contains { url in
            if Rival.matches(bundleID: Bundle(url: url)?.bundleIdentifier) { return true }
            return Rival.matches(name: url.lastPathComponent)
        }
    }
}

final class MascotController: NSObject {

    static let windowSize = NSSize(width: 280, height: 230)

    private let store: UsageStore
    private let poller: OAuthUsagePoller
    private let bridge: StatuslineBridge
    private let panel: MascotPanel
    private let engine: WalkEngine
    private let model = PoseModel()
    private var statusItem: NSStatusItem?
    private var displayLink: CADisplayLink?
    private var containerView: MascotContainerView!
    private var tooltipTimer: Timer?
    private var rivalTimer: Timer?

    private var dragGrabOffset = NSPoint.zero
    private var popHandoffPending = false       // re-anchor the grab offset once the pop-out finishes
    private var dragActive = false

    // Auto-hide Dock "platform": no API exposes its geometry, so estimate the
    // top edge above the bottom (≈ tilesize 57 + padding) and detect the reveal
    // from the cursor pressing the bottom edge. Tunable if his feet float/sink.
    static let dockTopFromBottom: CGFloat = 80
    private var dockRevealed = false

    init(store: UsageStore, poller: OAuthUsagePoller, bridge: StatuslineBridge) {
        self.store = store
        self.poller = poller
        self.bridge = bridge

        panel = MascotPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false  // interactive by default so Pip can be picked up; toggle click-through in the menu
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false           // dragging is handled manually
        panel.isReleasedWhenClosed = false
        // Set the level LAST — isFloatingPanel resets it to .floating, which is
        // below the Dock. Sit just above the Dock so Pip walks ON it, but below
        // the menu bar (24).
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

        engine = WalkEngine(store: store, model: model)
        engine.windowSize = Self.windowSize

        super.init()

        let container = MascotContainerView(frame: NSRect(origin: .zero, size: Self.windowSize))
        container.controller = self
        container.registerForDraggedTypes([.fileURL])   // ChatGPT-icon-dragged-near easter egg
        let hosting = NSHostingView(rootView: MascotRootView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        containerView = container

        engine.visibleFrameProvider = { [weak self] in
            guard let self else { return .zero }
            let screen = self.panel.screen ?? NSScreen.main ?? NSScreen.screens.first
            return screen?.visibleFrame ?? .zero
        }
        engine.dockGroundProvider = { [weak self] in self?.revealedDockTopY() }
        engine.moveWindow = { [weak self] origin in
            self?.panel.setFrameOrigin(origin)
        }

        setUpStatusItem()
    }

    func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(engine.startPosition(in: visible))
        panel.orderFrontRegardless()
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)  // above the Dock

        let link = panel.displayLink(target: engine, selector: #selector(WalkEngine.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshTooltip()
        }
        RunLoop.main.add(t, forMode: .common)
        tooltipTimer = t
        refreshTooltip()

        // Fume whenever the cursor hovers the ChatGPT icon in the Dock. This
        // reads the Dock's Accessibility tree, so prompt for permission once.
        let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(axOpts)
        let rt = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.pollRivalHover()
        }
        RunLoop.main.add(rt, forMode: .common)
        rivalTimer = rt
        Self.dlog("=== Pip launched; rival hover poll started; accessibilityTrusted=\(trusted) ===")
    }

    private func refreshTooltip() {
        containerView.toolTip = store.hasFreshData
            ? nil
            : "log into Claude Code to wake me up"
    }

    // MARK: - Status bar item (always reachable, even with click-through on)

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐾"
        item.button?.toolTip = mascotName
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func showContextMenu(with event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        populateMenu(menu)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        menu.addItem(headerItem())
        menu.addItem(.separator())

        let goHome = actionItem("Go Home", action: #selector(goHome), symbol: "house.fill")
        goHome.isEnabled = !engine.isHomeOrHeading
        menu.addItem(goHome)

        menu.addItem(actionItem(
            engine.paused ? "Resume Walking" : "Pause Walking",
            action: #selector(togglePause),
            symbol: engine.paused ? "figure.walk" : "pause.fill"))

        let clickThrough = actionItem("Click-Through", action: #selector(toggleClickThrough),
                                      symbol: "cursorarrow.rays")
        clickThrough.state = panel.ignoresMouseEvents ? .on : .off
        menu.addItem(clickThrough)

        let pinMenu = NSMenu()
        pinMenu.autoenablesItems = false
        for (title, pin) in [("Bottom Left", WalkEngine.Pin.left),
                             ("Bottom Right", WalkEngine.Pin.right),
                             ("Unpinned (roam)", WalkEngine.Pin.none)] {
            let item = actionItem(title, action: #selector(setPin(_:)))
            item.tag = pin.rawValue
            item.state = engine.pin == pin ? .on : .off
            pinMenu.addItem(item)
        }
        let pinItem = actionItem("Pin to a Corner", action: nil, symbol: "pin.fill")
        pinItem.submenu = pinMenu
        menu.addItem(pinItem)

        let badge = actionItem("Show Usage Details", action: #selector(toggleBadge),
                               symbol: "chart.bar.fill")
        badge.state = engine.showBadgePersistent ? .on : .off
        menu.addItem(badge)

        menu.addItem(.separator())
        menu.addItem(actionItem("Refresh Usage Now", action: #selector(refreshNow),
                                symbol: "arrow.clockwise"))

        let install = actionItem(
            bridge.isInstalled ? "Reinstall Statusline Bridge…" : "Install Statusline Bridge…",
            action: #selector(installBridge), symbol: "terminal.fill")
        menu.addItem(install)

        menu.addItem(.separator())
        let login = actionItem("Launch at Login", action: #selector(toggleLaunchAtLogin),
                               symbol: "power")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(actionItem("Quit \(mascotName)", action: #selector(quit), symbol: "xmark"))
    }

    /// Claude-themed status banner pinned to the top of the menu.
    private func headerItem() -> NSMenuItem {
        let updated = store.snapshot.lastUpdated > .distantPast
            ? "updated \(UsageStore.ago(store.snapshot.lastUpdated, from: Date())) · \(store.lastSource)"
            : ""
        let header = MenuHeaderView(mood: store.mood().rawValue,
                                    stats: store.usageStats(),
                                    note: store.badgeNote,
                                    updated: updated)
        let host = NSHostingView(rootView: header)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let item = NSMenuItem()
        item.view = host
        return item
    }

    private func actionItem(_ title: String, action: Selector?, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        }
        return item
    }

    // MARK: - Menu actions

    @objc private func togglePause() {
        engine.paused.toggle()
    }

    @objc private func goHome() {
        engine.goHome()
    }

    // MARK: - Rival detection (cursor over the ChatGPT Dock icon → Pip gets mad)
    //
    // We locate the ChatGPT tile in the Dock via the Accessibility API, cache
    // its on-screen frame, and fume whenever the cursor is over it. Needs
    // Accessibility permission (prompted at launch); without it AX queries fail
    // and Pip simply never finds the icon.

    private var rivalIconFrame: CGRect?                       // ChatGPT Dock tile, AppKit (bottom-left) coords
    private var rivalFrameRefreshedAt: TimeInterval = 0
    private var rivalIconLogged = false

    /// Easter egg entry point: a rival app icon was dragged over Pip's window.
    /// Provoke him. Throttled-logged so the drag stream stays quiet.
    private var rivalDragLogged = false
    func rivalDraggedNear() {
        if !rivalDragLogged { rivalDragLogged = true; Self.dlog("rival icon dragged near Pip → fuming") }
        engine.provokeByRival()
    }

    private func pollRivalHover() {
        let now = CACurrentMediaTime()
        // The tile only moves when the Dock changes (app opens/closes, resize),
        // so relocating once every ~1.5s is plenty; the hover test is cheap.
        if rivalIconFrame == nil || now - rivalFrameRefreshedAt > 1.5 {
            rivalFrameRefreshedAt = now
            rivalIconFrame = locateRivalDockIcon()
            if let f = rivalIconFrame, !rivalIconLogged {
                rivalIconLogged = true
                Self.dlog("ChatGPT Dock icon located at \(f)")
            }
        }
        guard let frame = rivalIconFrame else { return }
        if frame.contains(NSEvent.mouseLocation) { engine.provokeByRival() }
    }

    /// Walks the Dock's Accessibility tree for a rival tile (ChatGPT, Codex) and
    /// returns its frame in AppKit (bottom-left origin) screen coordinates, or nil.
    private func locateRivalDockIcon() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        guard let dock = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let el = findRivalElement(in: app, depth: 0), let cg = axFrame(of: el) else { return nil }
        // AX positions are top-left origin (Quartz global); flip to AppKit's
        // bottom-left using the primary screen's height.
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?
            .frame.height ?? cg.maxY
        return CGRect(x: cg.minX, y: primaryH - cg.maxY, width: cg.width, height: cg.height)
    }

    private func findRivalElement(in el: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 4 { return nil }
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String, Rival.matches(name: title) {
            return el
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findRivalElement(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func axFrame(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    static func dlog(_ s: String) {
        let line = "\(Date()) \(s)\n"
        let url = URL(fileURLWithPath: "/tmp/pip_drag.log")
        if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Top edge (AppKit y) of the revealed bottom Dock to stand on, or nil.
    private func revealedDockTopY() -> CGFloat? {
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        let f = screen.frame, vf = screen.visibleFrame
        // A persistent bottom Dock already reserves space (visibleFrame excludes
        // it), so he stands on it for free — nothing to add here.
        guard vf.minY <= f.minY + 1 else { return nil }
        // Auto-hide: reveal when the cursor presses the very bottom edge; hide
        // once it climbs back above the Dock band. (Hysteresis so it's stable.)
        let m = NSEvent.mouseLocation
        let inX = m.x >= f.minX && m.x <= f.maxX
        if inX, m.y <= f.minY + 2 {
            dockRevealed = true
        } else if !inX || m.y > f.minY + Self.dockTopFromBottom + 16 {
            dockRevealed = false
        }
        return dockRevealed ? f.minY + Self.dockTopFromBottom : nil
    }

    @objc private func toggleClickThrough() {
        panel.ignoresMouseEvents.toggle()
    }

    @objc private func setPin(_ sender: NSMenuItem) {
        engine.pin = WalkEngine.Pin(rawValue: sender.tag) ?? .none
    }

    @objc private func toggleBadge() {
        engine.showBadgePersistent.toggle()
    }

    @objc private func refreshNow() {
        poller.pollNow()
    }

    @objc private func installBridge() {
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.messageText = "Install the statusline bridge?"
        confirm.informativeText = """
        This writes \(bridge.scriptPath) and points the statusLine setting in \
        ~/.claude/settings.json at it (your current settings.json is backed up \
        first; an existing statusline command keeps working via chaining). \
        While Claude Code runs, it will then feed \(mascotName) official usage numbers.
        """
        confirm.addButton(withTitle: "Install")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let result = NSAlert()
        do {
            result.messageText = "Statusline bridge installed"
            result.informativeText = try bridge.install()
        } catch {
            result.messageText = "Install failed"
            result.informativeText = error.localizedDescription
            result.alertStyle = .warning
        }
        result.runModal()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Manual dragging (only reachable when click-through is off)

    func dragBegan(_ event: NSEvent) {
        if model.pose.bubbleText != nil {
            engine.dismissBubble()
            return
        }
        dragActive = true
        dragGrabOffset = NSPoint(
            x: NSEvent.mouseLocation.x - panel.frame.origin.x,
            y: NSEvent.mouseLocation.y - panel.frame.origin.y)
        engine.beginDrag()
        popHandoffPending = engine.isPoppingOut
    }

    func dragMoved(_ event: NSEvent) {
        guard dragActive else { return }
        // While popping out of the side hole, Pip stays pinned at the edge and
        // the engine owns his window — ignore the cursor entirely until he's out.
        if engine.isPoppingOut { return }

        let loc = NSEvent.mouseLocation
        let target = NSPoint(x: loc.x - dragGrabOffset.x, y: loc.y - dragGrabOffset.y)
        // Just popped free at the edge: ease over to the cursor (rather than
        // snapping) so he smoothly "comes to hand," then follow 1:1.
        if popHandoffPending {
            let cur = panel.frame.origin
            let dx = target.x - cur.x, dy = target.y - cur.y
            if dx * dx + dy * dy < 9 {
                popHandoffPending = false
            } else {
                let eased = NSPoint(x: cur.x + dx * 0.35, y: cur.y + dy * 0.35)
                panel.setFrameOrigin(eased)
                engine.noteDragMove(origin: eased)
                return
            }
        }
        panel.setFrameOrigin(target)
        engine.noteDragMove(origin: target)
    }

    func dragEnded(_ event: NSEvent) {
        guard dragActive else { return }
        dragActive = false
        // No snap: the engine takes over from here and drops Pip under
        // gravity onto the bottom edge of whatever screen we're on now
        // (this is also how you move Pip to another monitor).
        engine.endDrag(atOrigin: panel.frame.origin)
    }
}

extension MascotController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }
}
