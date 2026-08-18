import AppKit
import ApplicationServices
import ServiceManagement

// MARK: - Pac-Man icon drawing

enum PacFrame {
    /// Pixel-art pacman on a 12×12 dot grid, facing left. Rendered as a
    /// template image so the system tints it like native menu bar icons
    /// (white on dark menu bars, black on light ones).
    static func image(mouthAngle: CGFloat) -> NSImage {
        let grid = 12
        let pt: CGFloat = 18
        let cell = pt / CGFloat(grid)
        let c = CGFloat(grid - 1) / 2
        let img = NSImage(size: NSSize(width: pt, height: pt))
        img.lockFocus()
        NSColor.black.setFill()
        for rowTop in 0..<grid {
            for col in 0..<grid {
                let dx = CGFloat(col) - c
                let dy = c - CGFloat(rowTop)
                guard sqrt(dx * dx + dy * dy) <= 6.0 else { continue }          // circle body
                if rowTop == 3 && (col == 3 || col == 4) { continue }           // eye
                if mouthAngle >= 1 {                                            // mouth wedge (left)
                    let ang = atan2(dy, dx) * 180 / .pi
                    if abs(180 - abs(ang)) < mouthAngle { continue }
                }
                NSRect(x: CGFloat(col) * cell, y: pt - CGFloat(rowTop + 1) * cell,
                       width: cell, height: cell).fill()
            }
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    static let idle = image(mouthAngle: 35)          // hungry, mouth open
    static let full = image(mouthAngle: 0)           // ate everything, closed
    static let chompFrames: [NSImage] = [35, 20, 6, 20, 35, 20, 6].map { image(mouthAngle: $0) }
    static let spitFrames: [NSImage] = [0, 15, 45, 55, 45, 35].map { image(mouthAngle: $0) }
}

// MARK: - Notch geometry

enum Notch {
    /// The screen our status items actually live on. With separate Spaces the
    /// menu bar follows the active display, so "the notch" is only relevant
    /// when the icons are on the built-in screen — an external monitor has none.
    static var hostScreen: NSScreen? {
        if let app = NSApp.delegate as? AppDelegate,
           let screen = app.pacItem?.button?.window?.screen {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// X where the camera housing ends. A status item that does not fit to the
    /// right of this line gets drawn under the notch — invisible and
    /// unclickable. nil when the icons sit on a screen without a notch.
    static func edgeX(on screen: NSScreen? = hostScreen) -> CGFloat? {
        // test hook: pretend the notch ends here (see CLAUDE.md)
        if let fake = UserDefaults.standard.object(forKey: "debugNotchEdgeX") as? Double {
            return CGFloat(fake)
        }
        guard let screen, screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        return right.minX
    }

    /// Left edge of every screen combined. Kept global on purpose: a status item
    /// sitting on another display must not be mistaken for one pacman ate.
    static var screenMinX: CGFloat { NSScreen.screens.map { $0.frame.minX }.min() ?? 0 }
}

// MARK: - Accessibility helpers (read other apps' menu bar items)

/// Where a menu bar extra currently lives.
enum ItemZone {
    case visible      // right of the notch, clickable
    case notch        // swallowed by the camera housing — the thing we rescue
    case offscreen    // pushed off the left edge, i.e. eaten by pacman
}

final class MenuBarItemRef {
    let element: AXUIElement
    let title: String
    let appIcon: NSImage?
    let frame: CGRect
    let zone: ItemZone
    init(element: AXUIElement, title: String, appIcon: NSImage?, frame: CGRect, zone: ItemZone) {
        self.element = element
        self.title = title
        self.appIcon = appIcon
        self.frame = frame
        self.zone = zone
    }
}

enum AXScanner {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// Apps that owned a menu bar extra last time we looked. Asking all ~180
    /// running processes costs ~500ms; asking these ten costs almost nothing.
    /// Scans run on several queues (timer, post-spit, menu), hence the lock.
    private static var _extrasPIDs: Set<pid_t> = []
    private static let cacheLock = NSLock()
    static var extrasPIDs: Set<pid_t> {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return _extrasPIDs
    }

    /// Every other app's menu bar extra, with its frame and zone.
    /// `limitTo` restricts the sweep to known owners for a fast refresh.
    static func snapshot(limitTo pids: Set<pid_t>? = nil) -> [MenuBarItemRef] {
        guard trusted else { return [] }
        let minX = Notch.screenMinX
        let notchX = Notch.edgeX()
        var result: [MenuBarItemRef] = []
        var owners: Set<pid_t> = []
        let myPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            if app.processIdentifier == myPID { continue }
            if let pids, !pids.contains(app.processIdentifier) { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.3) // skip unresponsive apps
            var extrasRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
                  let extras = extrasRef else { continue }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(extras as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }
            owners.insert(app.processIdentifier)
            for (idx, child) in children.enumerated() {
                var posRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success else { continue }
                var point = CGPoint.zero
                AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
                var size = CGSize(width: 24, height: 22)
                var sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success {
                    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                }
                // stale/torn-down items report a degenerate frame; ignore them
                guard size.width >= 4, size.height >= 10 else { continue }
                let frame = CGRect(origin: point, size: size)
                let zone: ItemZone
                if frame.minX < minX {
                    zone = .offscreen
                } else if let notchX, frame.minX < notchX {
                    zone = .notch
                } else {
                    zone = .visible
                }
                var name = app.localizedName ?? "메뉴 아이템"
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let t = titleRef as? String, !t.isEmpty, t != name {
                    name = "\(name) — \(t)"
                } else if children.count > 1 {
                    name = "\(name) \(idx + 1)"
                }
                result.append(MenuBarItemRef(element: child, title: name, appIcon: app.icon, frame: frame, zone: zone))
            }
        }
        // a full sweep replaces the cache; a narrow one can only add to it
        cacheLock.lock()
        _extrasPIDs = pids == nil ? owners : _extrasPIDs.union(owners)
        cacheLock.unlock()
        return result.sorted { $0.title < $1.title }
    }

    /// Items currently pushed off-screen (used when restoring a saved eaten state).
    static func offscreenItems() -> [MenuBarItemRef] {
        snapshot(limitTo: extrasPIDs.isEmpty ? nil : extrasPIDs).filter { $0.zone == .offscreen }
    }

    /// One full sweep so the first spit already has the owner list.
    static func warmCache() {
        guard extrasPIDs.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { _ = snapshot() }
    }

    /// X-position of our own separator item, in the same AX coordinate space
    /// used by `snapshot` (more reliable than window frames on multi-display setups).
    static func mySeparatorX() -> CGFloat? {
        let axApp = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var extrasRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
              let extras = extrasRef else { return nil }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extras as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        var xs: [CGFloat] = []
        for child in children {
            var posRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success else { continue }
            var point = CGPoint.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
            xs.append(point.x)
        }
        return xs.min() // separator sits left of pacman
    }
}

// MARK: - Pac-Me Bar (our own strip, so the notch can't eat anything)

/// Icon button with a menu-like hover highlight.
final class BarButton: NSButton {
    var onClick: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.85).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    @objc func fire() { onClick?() }
}

/// A floating strip drawn just below the menu bar. Because we draw it ourselves
/// it is free of the menu bar's layout rules — it can sit left of the notch,
/// which `NSStatusItem` never can.
final class PacBar {
    private let panel: NSPanel
    private let container: NSView
    private let side: CGFloat = 26
    private let gap: CGFloat = 2
    private let pad: CGFloat = 5

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = NSVisualEffectView()
        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 9
        blur.layer?.masksToBounds = true
        container = blur
        panel.contentView = blur
    }

    /// `rightEdge` is where the strip ends; it grows leftward from there, so the
    /// hidden icons read as a continuation of the visible row.
    func show(items: [MenuBarItemRef], rightEdge: CGFloat, on screen: NSScreen,
              pick: @escaping (MenuBarItemRef) -> Void) {
        guard !items.isEmpty else { hide(); return }
        container.subviews.forEach { $0.removeFromSuperview() }

        var x = pad
        for ref in items {
            let b = BarButton(frame: NSRect(x: x, y: pad, width: side, height: side))
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.image = ref.appIcon
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = ref.title
            b.onClick = { pick(ref) }
            b.target = b
            b.action = #selector(BarButton.fire)
            container.addSubview(b)
            x += side + gap
        }

        let w = x - gap + pad
        let h = side + pad * 2
        // hang it right under the menu bar; the notch is above us, so we can
        // extend as far left as we like
        let menuBarBottom = screen.frame.maxY - max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        var origin = NSPoint(x: rightEdge - w, y: menuBarBottom - h - 3)
        origin.x = min(max(origin.x, screen.frame.minX + 8), screen.frame.maxX - w - 8)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pacItem: NSStatusItem!
    var separatorItem: NSStatusItem!
    var hidden = false
    var belly: [MenuBarItemRef] = []   // cached at eat time
    var animTimer: Timer?
    var autoEatTimer: Timer?
    var autoEatActivity: NSObjectProtocol?
    var notchTimer: Timer?
    let pacBar = PacBar()
    var barWatch: Timer?
    var barClickMonitor: Any?
    /// Present the bar once a scan that *started* after this instant lands.
    /// A scan kicked off earlier still sees the icons mid-flight and would
    /// report "nothing hidden", silently eating the request.
    var barPendingAfter: Date?
    /// Left edge of the leftmost still-visible menu bar icon — the point where
    /// the row gets cut off by the notch. The bar hangs from here.
    var barAnchorX: CGFloat?
    var barShownTitles: [String] = []
    var spitAt: Date?
    var lastBarLatencyMs = 0.0
    var lastScanMs = 0.0
    var lastScanApps = 0
    var notchVictims: [MenuBarItemRef] = []   // items the notch is covering right now
    var rescueGraceUntil = Date.distantPast   // don't re-eat right after a manual spit
    let collapsedLength: CGFloat = 10
    let expandedLength: CGFloat = 10_000

    let defaults = UserDefaults.standard
    let eatenKey = "isEaten"
    let rememberKey = "rememberEaten"

    var rememberEaten: Bool {
        get { defaults.object(forKey: rememberKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: rememberKey) }
    }
    /// seconds until pacman eats again after spitting; always on, cannot be disabled
    var autoEatSeconds: Int {
        get {
            let stored = defaults.object(forKey: "autoEatSeconds") as? Int ?? 10
            return stored > 0 ? stored : 10  // migrate old "off" (0) setting
        }
        set { defaults.set(newValue, forKey: "autoEatSeconds") }
    }
    /// eat automatically as soon as the notch starts swallowing icons
    var autoRescue: Bool {
        get { defaults.object(forKey: "autoRescueNotch") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoRescueNotch") }
    }
    /// pop the pac bar open when pacman opens his mouth (spits everything out),
    /// so whatever the notch is still covering is right there
    var barOnSpit: Bool {
        get { defaults.object(forKey: "barOnSpit") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "barOnSpit") }
    }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // first launch: place the separator immediately left of pacman so that
        // everything further left is in the "eatable" zone
        let pacKey = "NSStatusItem Preferred Position pacmenu.pacman"
        let sepKey = "NSStatusItem Preferred Position pacmenu.separator"
        if defaults.object(forKey: sepKey) == nil {
            defaults.set(340, forKey: pacKey)
            defaults.set(362, forKey: sepKey)
        }

        // created first → rightmost; separator lands to its left
        pacItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        pacItem.autosaveName = "pacmenu.pacman"
        separatorItem = NSStatusBar.system.statusItem(withLength: collapsedLength)
        separatorItem.autosaveName = "pacmenu.separator"

        if let btn = pacItem.button {
            btn.image = PacFrame.idle
            btn.target = self
            btn.action = #selector(pacClicked)
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.toolTip = "PAC-MEN-U: 클릭=먹기/뱉기, 우클릭=뱃속 보기"
        }
        if let sep = separatorItem.button {
            sep.title = "‹"
            sep.font = NSFont.systemFont(ofSize: 13, weight: .heavy)
            sep.alphaValue = 0.4
            sep.toolTip = "이 표시 왼쪽의 아이콘들이 먹혀요 (⌘+드래그로 옮기세요)"
        }
        AXScanner.requestPermission()

        // restore last eaten state
        if rememberEaten && defaults.bool(forKey: eatenKey) {
            hidden = true
            separatorItem.length = expandedLength
            separatorItem.button?.title = ""
            pacItem.button?.image = PacFrame.full
        }

        // debug hooks (command line)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(toggleClicked),
                        name: NSNotification.Name("com.zzanggi.pacmenu.toggle"), object: nil)
        dnc.addObserver(self, selector: #selector(debugDump),
                        name: NSNotification.Name("com.zzanggi.pacmenu.dump"), object: nil)
        dnc.addObserver(self, selector: #selector(showBar),
                        name: NSNotification.Name("com.zzanggi.pacmenu.bar"), object: nil)

        startNotchWatch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard self?.hidden == true else { return }   // spat out: checkNotch fills it
            AXScanner.warmCache()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // a new app may bring a new icon, so this one has to be a full sweep
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.checkNotch() }
        }
    }

    // MARK: notch rescue

    /// Poll for icons the camera housing is hiding. Only runs while pacman is
    /// hungry — once everything is eaten there is nothing left to rescue.
    func startNotchWatch() {
        notchTimer?.invalidate()
        // full sweeps are ~500ms of AX chatter, so only every 8th tick (~32s);
        // in between we just re-ask the apps we already know own icons
        var tick = 0
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            tick += 1
            self?.checkNotch(fast: tick % 8 != 0)
        }
        timer.tolerance = 1.5
        // .common so this keeps firing on schedule while a menu we opened is being
        // tracked, instead of pausing and then firing all at once the moment it closes
        RunLoop.main.add(timer, forMode: .common)
        notchTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkNotch() }
    }

    /// `fast` asks only the apps known to own menu bar icons — used right after
    /// spitting, where a full ~500ms sweep is felt as lag.
    func checkNotch(fast: Bool = false) {
        guard !hidden, AXScanner.trusted, Notch.edgeX() != nil else { return }
        let limit = fast && !AXScanner.extrasPIDs.isEmpty ? AXScanner.extrasPIDs : nil
        DispatchQueue.global(qos: fast ? .userInitiated : .utility).async { [weak self] in
            let scanStart = Date()
            let t0 = ProcessInfo.processInfo.systemUptime
            let items = AXScanner.snapshot(limitTo: limit)
            let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            let apps = limit?.count ?? NSWorkspace.shared.runningApplications.count
            let sepX = AXScanner.mySeparatorX() ?? .greatestFiniteMagnitude
            DispatchQueue.main.async {
                guard let self, !self.hidden else { return }
                self.lastScanMs = ms
                self.lastScanApps = apps
                self.notchVictims = items.filter { $0.zone == .notch }
                self.barAnchorX = items.filter { $0.zone == .visible }.map { $0.frame.minX }.min()
                self.updateBadge()
                let shown = self.notchVictims.map(\.title)
                if let due = self.barPendingAfter, scanStart >= due {
                    self.barPendingAfter = nil
                    if let t = self.spitAt {
                        self.lastBarLatencyMs = Date().timeIntervalSince(t) * 1000
                        self.spitAt = nil
                    }
                    self.presentBar(sticky: true)   // empty list just closes it
                } else if self.pacBar.isVisible, shown != self.barShownTitles {
                    self.presentBar(sticky: true)   // full sweep found more/fewer
                }
                self.barShownTitles = shown
                // something is hidden, and pacman actually has food to swallow
                let eatable = items.contains { $0.zone != .offscreen && $0.frame.minX < sepX }
                if !self.notchVictims.isEmpty, self.autoRescue, eatable,
                   Date() >= self.rescueGraceUntil {
                    self.eat()
                }
            }
        }
    }

    // MARK: pac bar

    /// What the bar shows: the belly when everything is eaten, otherwise
    /// whatever the notch is currently covering.
    func barItems() -> [MenuBarItemRef] {
        hidden ? bellyItems() : notchVictims
    }


    /// Opened deliberately (menu item / CLI): stays put until something is clicked.
    @objc func showBar() { presentBar(sticky: true) }

    func presentBar(sticky: Bool) {
        guard let btn = pacItem.button, let win = btn.window,
              let screen = win.screen ?? Notch.hostScreen else { return }
        let items = barItems()
        guard !items.isEmpty else { hideBar(); return }
        hideBar()
        // continue the row where the notch cut it off; with nothing scanned
        // (e.g. the belly bar while eaten) hang it off the pacman instead
        let rightEdge = barAnchorX ?? win.frame.minX
        pacBar.show(items: items, rightEdge: rightEdge, on: screen) { [weak self] ref in
            self?.press(ref)
        }
        if sticky {
            barClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hideBar() }
        } else {
            startBarWatch()
        }
    }

    func hideBar() {
        pacBar.hide()
        barWatch?.invalidate()
        barWatch = nil
        if let monitor = barClickMonitor {
            NSEvent.removeMonitor(monitor)
            barClickMonitor = nil
        }
    }

    /// Hover mode: close the bar once the pointer leaves both the bar and the
    /// pacman. The grace period covers the trip down from the menu bar.
    func startBarWatch() {
        barWatch?.invalidate()
        let opened = Date()
        barWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.pacBar.isVisible else { return }
            guard Date().timeIntervalSince(opened) > 0.8 else { return }
            var hot = self.pacBar.frame.insetBy(dx: -10, dy: -10)
            if let f = self.pacItem.button?.window?.frame { hot = hot.union(f.insetBy(dx: -8, dy: -8)) }
            if !hot.contains(NSEvent.mouseLocation) { self.hideBar() }
        }
    }

    /// Open a hidden item's own menu. Items pacman swallowed are off-screen, so
    /// they get spat back out first; notch-covered ones respond where they are.
    func press(_ ref: MenuBarItemRef) {
        hideBar()
        guard ref.zone == .offscreen else {
            // this icon has been sitting there since whenever the bar first
            // opened — interacting with it now should buy it a fresh grace
            // period, not inherit however much of the old one is left
            scheduleAutoEat()
            AXUIElementPerformAction(ref.element, kAXPressAction as CFString)
            return
        }
        spit()
        // we're about to open the item's own menu, not the pac bar again —
        // cancel the "reopen bar after spit" that spit() just scheduled, or
        // it pops back up a moment later and covers the menu we just opened
        barPendingAfter = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            AXUIElementPerformAction(ref.element, kAXPressAction as CFString)
        }
    }

    /// Notch count lives in the tooltip only — a title next to the icon widens
    /// the status item and shoves the whole menu bar sideways.
    func updateBadge() {
        guard let btn = pacItem.button else { return }
        let n = hidden ? 0 : notchVictims.count
        btn.toolTip = n > 0
            ? "노치에 가려진 아이콘 \(n)개 — 클릭=먹어서 구출, 우클릭=목록"
            : "PAC-MEN-U: 클릭=먹기/뱉기, 우클릭=뱃속 보기"
    }

    // MARK: actions

    @objc func pacClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showBellyMenu()
            return
        }
        hidden ? spit() : eat()
    }

    func eat() {
        guard !hidden else { return }
        cancelAutoEat()
        hidden = true
        defaults.set(true, forKey: eatenKey)
        notchVictims = []
        barPendingAfter = nil
        barAnchorX = nil
        updateBadge()
        hideBar()
        animate(frames: PacFrame.chompFrames, final: PacFrame.full)
        separatorItem.length = expandedLength
        separatorItem.button?.title = ""
        // snapshot the belly in the background (items are off-screen now)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = AXScanner.offscreenItems()
            DispatchQueue.main.async {
                guard let self, self.hidden else { return }
                self.belly = items
            }
        }
    }

    func spit() {
        guard hidden else { return }
        hidden = false
        belly = []
        defaults.set(false, forKey: eatenKey)
        animate(frames: PacFrame.spitFrames, final: PacFrame.idle)
        separatorItem.length = collapsedLength
        separatorItem.button?.title = "‹"
        scheduleAutoEat()
        barPendingAfter = barOnSpit ? Date().addingTimeInterval(0.2) : nil
        spitAt = Date()
        // status item positions settle as soon as the separator collapses
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.checkNotch(fast: true)
        }
    }

    func scheduleAutoEat() {
        cancelAutoEat()
        // the notch rescue waits out the same countdown, so the two never race
        rescueGraceUntil = Date().addingTimeInterval(TimeInterval(autoEatSeconds))
        // keep App Nap from deferring the timer while the countdown runs
        autoEatActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "auto-eat countdown")
        let timer = Timer(timeInterval: TimeInterval(autoEatSeconds), repeats: false) { [weak self] _ in
            self?.eat()
        }
        timer.tolerance = 2
        // .common so a native menu we opened from the notch bar (which runs the
        // run loop in .eventTracking mode) doesn't pause this and then fire it
        // immediately, all at once, the instant that menu closes
        RunLoop.main.add(timer, forMode: .common)
        autoEatTimer = timer
    }

    func cancelAutoEat() {
        autoEatTimer?.invalidate()
        autoEatTimer = nil
        if let token = autoEatActivity {
            ProcessInfo.processInfo.endActivity(token)
            autoEatActivity = nil
        }
    }

    func animate(frames: [NSImage], final: NSImage) {
        animTimer?.invalidate()
        var i = 0
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if i < frames.count {
                self.pacItem.button?.image = frames[i]
                i += 1
            } else {
                timer.invalidate()
                self.pacItem.button?.image = final
            }
        }
    }

    /// Belly contents: prefer the snapshot taken at eat time; fall back to an
    /// off-screen scan (e.g. state restored after relaunch).
    func bellyItems() -> [MenuBarItemRef] {
        guard hidden else { return [] }
        if belly.isEmpty { belly = AXScanner.offscreenItems() }
        return belly
    }

    // MARK: menus

    func showBellyMenu() {
        let menu = NSMenu()
        let items = bellyItems()

        let header = NSMenuItem(title: hidden ? "팩미의 뱃속 (\(items.count))" : "팩미가 배고파요",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // icons the camera housing is currently covering
        if !hidden && !notchVictims.isEmpty {
            let notchHeader = NSMenuItem(title: "🕳️ 노치에 가려짐 (\(notchVictims.count))",
                                         action: nil, keyEquivalent: "")
            notchHeader.isEnabled = false
            menu.addItem(notchHeader)
            for ref in notchVictims {
                let mi = NSMenuItem(title: ref.title, action: #selector(notchItemClicked(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = ref
                mi.image = menuIcon(ref.appIcon)
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }

        if !AXScanner.trusted {
            let perm = NSMenuItem(title: "🔒 손쉬운 사용 권한이 필요해요 — 클릭해서 열기",
                                  action: #selector(openAccessibilitySettings), keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
        } else if hidden && items.isEmpty {
            let empty = NSMenuItem(title: "(뱃속이 비었어요)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for ref in items {
                let mi = NSMenuItem(title: ref.title, action: #selector(hiddenItemClicked(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = ref
                mi.image = menuIcon(ref.appIcon)
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        if !barItems().isEmpty {
            let showBarItem = NSMenuItem(title: "🍽️ 팩미 바 열기", action: #selector(showBar), keyEquivalent: "")
            showBarItem.target = self
            menu.addItem(showBarItem)
        }
        let toggle = NSMenuItem(title: hidden ? "👻 모두 뱉기" : "😋 먹기",
                                action: #selector(toggleClicked), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // settings
        let settingsMenu = NSMenu()
        let loginItem = NSMenuItem(title: "로그인 시 자동 실행",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = launchAtLogin ? .on : .off
        settingsMenu.addItem(loginItem)
        let rememberItem = NSMenuItem(title: "먹은 상태 기억하기",
                                      action: #selector(toggleRemember), keyEquivalent: "")
        rememberItem.target = self
        rememberItem.state = rememberEaten ? .on : .off
        settingsMenu.addItem(rememberItem)

        let barItem = NSMenuItem(title: "뱉을 때 팩미 바 열기",
                                 action: #selector(toggleBarOnSpit), keyEquivalent: "")
        barItem.target = self
        barItem.state = barOnSpit ? .on : .off
        settingsMenu.addItem(barItem)

        let rescueItem = NSMenuItem(title: "노치에 가리면 자동으로 먹기",
                                    action: #selector(toggleAutoRescue), keyEquivalent: "")
        rescueItem.target = self
        rescueItem.state = autoRescue ? .on : .off
        settingsMenu.addItem(rescueItem)

        let autoEatMenu = NSMenu()
        for (label, secs) in [("10초", 10), ("30초", 30), ("1분", 60)] {
            let mi = NSMenuItem(title: label, action: #selector(autoEatChanged(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = secs
            mi.state = autoEatSeconds == secs ? .on : .off
            autoEatMenu.addItem(mi)
        }
        let autoEatRoot = NSMenuItem(title: "뱉은 뒤 자동으로 다시 먹기", action: nil, keyEquivalent: "")
        autoEatRoot.submenu = autoEatMenu
        settingsMenu.addItem(autoEatRoot)
        let settingsRoot = NSMenuItem(title: "⚙️ 설정", action: nil, keyEquivalent: "")
        settingsRoot.submenu = settingsMenu
        menu.addItem(settingsRoot)

        let quit = NSMenuItem(title: "PAC-MEN-U 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        popUp(menu)
    }

    func popUp(_ menu: NSMenu) {
        pacItem.menu = menu
        pacItem.button?.performClick(nil)
        pacItem.menu = nil // keep button clicks going to our action afterwards
    }

    @objc func toggleClicked() { hidden ? spit() : eat() }

    @objc func toggleRemember() { rememberEaten.toggle() }

    @objc func toggleBarOnSpit() { barOnSpit.toggle() }

    @objc func toggleAutoRescue() {
        autoRescue.toggle()
        if autoRescue { rescueGraceUntil = .distantPast; checkNotch() }
    }

    /// A notch-covered item is still a live AX element, so we can open its menu
    /// even though the mouse can't reach it.
    @objc func notchItemClicked(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? MenuBarItemRef else { return }
        press(ref)
    }

    func menuIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon else { return nil }
        let small = NSImage(size: NSSize(width: 18, height: 18))
        small.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        small.unlockFocus()
        return small
    }

    @objc func autoEatChanged(_ sender: NSMenuItem) {
        autoEatSeconds = sender.tag
        if hidden {
            cancelAutoEat()
        } else {
            scheduleAutoEat() // apply immediately while spat out
        }
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("PAC-MEN-U: launch-at-login failed: \(error)")
        }
    }

    @objc func hiddenItemClicked(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? MenuBarItemRef else { return }
        press(ref)
    }

    @objc func openAccessibilitySettings() {
        AXScanner.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func debugDump() {
        var lines = ["trusted=\(AXScanner.trusted)", "hidden=\(hidden)",
                     "remember=\(rememberEaten)", "launchAtLogin=\(launchAtLogin)"]
        let sepX = AXScanner.mySeparatorX() ?? separatorItem.button?.window?.frame.origin.x ?? -1
        lines.append("sepX=\(sepX) (windowX=\(separatorItem.button?.window?.frame.origin.x ?? -1))")
        lines.append("pacFrame=\(pacItem.button?.window?.frame ?? .zero) barVisible=\(pacBar.isVisible)")
        lines.append("spitToBar=\(Int(lastBarLatencyMs))ms")
        lines.append("lastScan=\(Int(lastScanMs))ms over \(lastScanApps) apps")
        lines.append("barFrame=\(pacBar.frame) anchorX=\(barAnchorX.map(String.init(describing:)) ?? "nil")")
        lines.append("notchEdgeX=\(Notch.edgeX().map(String.init(describing:)) ?? "none") "
                     + "screenMinX=\(Notch.screenMinX) autoRescue=\(autoRescue)")
        let all = AXScanner.snapshot()
        lines.append("allItems(\(all.count)):")
        lines += all.map { "  [\($0.zone)] x=\(Int($0.frame.minX))..\(Int($0.frame.maxX)) \($0.title)" }
        try? lines.joined(separator: "\n")
            .write(toFile: "/tmp/pacmenu-dump.txt", atomically: true, encoding: .utf8)
    }
}

// MARK: - main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
