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

// MARK: - Accessibility helpers (read other apps' menu bar items)

final class MenuBarItemRef {
    let element: AXUIElement
    let title: String
    let appIcon: NSImage?
    init(element: AXUIElement, title: String, appIcon: NSImage?) {
        self.element = element
        self.title = title
        self.appIcon = appIcon
    }
}

enum AXScanner {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// All other apps' menu bar extras whose x-position satisfies `filter`.
    static func scan(filter: (CGPoint) -> Bool) -> [MenuBarItemRef] {
        guard trusted else { return [] }
        var result: [MenuBarItemRef] = []
        let myPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            if app.processIdentifier == myPID { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.3) // skip unresponsive apps
            var extrasRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
                  let extras = extrasRef else { continue }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(extras as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }
            for (idx, child) in children.enumerated() {
                var posRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success else { continue }
                var point = CGPoint.zero
                AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
                guard filter(point) else { continue }
                var name = app.localizedName ?? "메뉴 아이템"
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let t = titleRef as? String, !t.isEmpty, t != name {
                    name = "\(name) — \(t)"
                } else if children.count > 1 {
                    name = "\(name) \(idx + 1)"
                }
                result.append(MenuBarItemRef(element: child, title: name, appIcon: app.icon))
            }
        }
        return result.sorted { $0.title < $1.title }
    }

    /// Items currently pushed off-screen (used when restoring a saved eaten state).
    static func offscreenItems() -> [MenuBarItemRef] {
        let minX = NSScreen.screens.map { $0.frame.minX }.min() ?? 0
        return scan { $0.x < minX }
    }

    /// X-position of our own separator item, in the same AX coordinate space
    /// used by `scan` (more reliable than window frames on multi-display setups).
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

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pacItem: NSStatusItem!
    var separatorItem: NSStatusItem!
    var hidden = false
    var belly: [MenuBarItemRef] = []   // cached at eat time
    var animTimer: Timer?
    var autoEatTimer: Timer?
    var autoEatActivity: NSObjectProtocol?
    let collapsedLength: CGFloat = 14
    let expandedLength: CGFloat = 10_000

    let defaults = UserDefaults.standard
    let eatenKey = "isEaten"
    let rememberKey = "rememberEaten"

    var rememberEaten: Bool {
        get { defaults.object(forKey: rememberKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: rememberKey) }
    }
    /// seconds until pacman eats again after spitting; 0 = off
    var autoEatSeconds: Int {
        get { defaults.object(forKey: "autoEatSeconds") as? Int ?? 60 }
        set { defaults.set(newValue, forKey: "autoEatSeconds") }
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
            sep.title = "⋮"
            sep.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            sep.alphaValue = 0.4
            sep.toolTip = "이 점 왼쪽의 아이콘들이 먹혀요 (⌘+드래그로 옮기세요)"
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
        separatorItem.button?.title = "⋮"
        scheduleAutoEat()
    }

    func scheduleAutoEat() {
        cancelAutoEat()
        guard autoEatSeconds > 0 else { return }
        // keep App Nap from deferring the timer while the countdown runs
        autoEatActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "auto-eat countdown")
        autoEatTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(autoEatSeconds),
                                            repeats: false) { [weak self] _ in
            self?.eat()
        }
        autoEatTimer?.tolerance = 2
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
                if let icon = ref.appIcon {
                    let small = NSImage(size: NSSize(width: 18, height: 18))
                    small.lockFocus()
                    icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
                    small.unlockFocus()
                    mi.image = small
                }
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
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

        let autoEatMenu = NSMenu()
        for (label, secs) in [("끄기", 0), ("30초", 30), ("1분", 60), ("2분", 120), ("5분", 300)] {
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
        // items are off-screen while hidden: spit first, then press
        spit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            AXUIElementPerformAction(ref.element, kAXPressAction as CFString)
        }
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
        let items = hidden ? bellyItems() : AXScanner.scan { $0.x < sepX }
        lines.append("items(\(items.count)):")
        lines += items.map { "  - \($0.title)" }
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
