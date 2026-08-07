import Cocoa
import ServiceManagement

enum Mode { case off, awake, agent }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: State
    private var statusItem: NSStatusItem!
    private var caffeinateProcess: Process?
    private var mode: Mode = .off
    private var endDate: Date?          // non-nil only for timed "awake" sessions
    private var tickTimer: Timer?       // refreshes the timed countdown label

    // Agent-mode animation
    private var scannerTimer: Timer?
    private var countTimer: Timer?
    private var scanHead = 0
    private var scanDir = 1
    private var agentCount = 0
    private let scanDots = 8

    // MARK: Menu items we update
    private let menu = NSMenu()
    private var statusLine: NSMenuItem!
    private var indefiniteItem: NSMenuItem!
    private var agentItem: NSMenuItem!
    private var durationItems: [NSMenuItem] = []
    private var lidItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private let durations: [(String, Int)] = [
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("1 hour",     60 * 60),
        ("2 hours",  2 * 60 * 60),
        ("5 hours",  5 * 60 * 60),
    ]

    // MARK: Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopCaffeinate()
        stopAgentAnimation()
    }

    func menuWillOpen(_ menu: NSMenu) { updateUI() }

    // MARK: Menu
    private func buildMenu() {
        statusLine = NSMenuItem(title: "Off", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        indefiniteItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleIndefinite), keyEquivalent: "")
        indefiniteItem.target = self
        menu.addItem(indefiniteItem)

        let durationParent = NSMenuItem(title: "Keep Awake For…", action: nil, keyEquivalent: "")
        let durationMenu = NSMenu()
        for (label, seconds) in durations {
            let it = NSMenuItem(title: label, action: #selector(startTimed(_:)), keyEquivalent: "")
            it.target = self
            it.tag = seconds
            durationMenu.addItem(it)
            durationItems.append(it)
        }
        durationParent.submenu = durationMenu
        menu.addItem(durationParent)

        agentItem = NSMenuItem(title: "Agent Mode", action: #selector(toggleAgentMode), keyEquivalent: "")
        agentItem.target = self
        menu.addItem(agentItem)

        lidItem = NSMenuItem(title: "Keep Awake With Lid Closed", action: #selector(toggleLidClosed), keyEquivalent: "")
        lidItem.target = self
        menu.addItem(lidItem)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Jolt", action: #selector(about), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Jolt", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Mode control
    private func setOff() {
        stopCaffeinate()
        stopAgentAnimation()
        mode = .off
        updateUI()
    }

    private func setAwake(seconds: Int?) {
        stopAgentAnimation()
        startCaffeinate(seconds: seconds)
        mode = .awake
        updateUI()
    }

    private func setAgent() {
        startCaffeinate(seconds: nil)
        mode = .agent
        startAgentAnimation()
        updateUI()
    }

    // MARK: Actions
    @objc private func toggleIndefinite() {
        if mode == .awake && endDate == nil { setOff() } else { setAwake(seconds: nil) }
    }

    @objc private func startTimed(_ sender: NSMenuItem) {
        setAwake(seconds: sender.tag)
    }

    @objc private func toggleAgentMode() {
        if mode == .agent { setOff() } else { setAgent() }
    }

    @objc private func toggleLidClosed() {
        if lidCloseAwakeEnabled() {
            _ = runPrivileged("pmset -a disablesleep 0")
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Keep Awake With Lid Closed?"
            alert.informativeText = """
            This disables sleep entirely, so your Mac keeps running with the lid shut — handy for letting agents keep working.

            • Requires your admin password.
            • Your Mac will NOT sleep (lid open or closed) until you turn this off.
            • With the lid closed there is no active cooling, so avoid heavy sustained loads for long stretches.
            • The setting persists even if you quit Jolt (turn it off here, or run: sudo pmset -a disablesleep 0).
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if runPrivileged("pmset -a disablesleep 1"), mode == .off {
                setAwake(seconds: nil)   // keep display/idle assertions consistent
                return
            }
        }
        updateUI()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Jolt: launch-at-login change failed: \(error)")
        }
        updateUI()
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Jolt"
        alert.informativeText = """
        A one-click menu-bar toggle to keep your Mac awake.

        • Keep Awake — normal caffeination.
        • Agent Mode — a Knight Rider scanner in the menu bar plus a live count of running Claude Code / Codex sessions.
        • Keep Awake With Lid Closed — disables system sleep so agents keep working with the lid shut (admin password required).
        """
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: caffeinate control
    private func startCaffeinate(seconds: Int?) {
        stopCaffeinate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        var args = ["-d", "-i", "-s", "-u"]   // display, idle, system(AC), declare user active
        if let s = seconds { args += ["-t", String(s)] }
        p.arguments = args
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleCaffeinateExit() }
        }
        do {
            try p.run()
            caffeinateProcess = p
            endDate = seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
            startTicking()
        } catch {
            NSLog("Jolt: failed to launch caffeinate: \(error)")
            caffeinateProcess = nil
            endDate = nil
        }
    }

    private func stopCaffeinate() {
        tickTimer?.invalidate(); tickTimer = nil
        if let p = caffeinateProcess, p.isRunning {
            p.terminationHandler = nil
            p.terminate()
        }
        caffeinateProcess = nil
        endDate = nil
    }

    // caffeinate exited on its own (timer elapsed or killed) — fall back to Off
    private func handleCaffeinateExit() {
        caffeinateProcess = nil
        endDate = nil
        stopAgentAnimation()
        mode = .off
        updateUI()
    }

    private func startTicking() {
        tickTimer?.invalidate()
        guard endDate != nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateUI()
        }
    }

    // MARK: Agent mode — scanner + count
    private func startAgentAnimation() {
        scanHead = 0; scanDir = 1
        updateAgentCount()
        tickScanner()
        scannerTimer?.invalidate()
        scannerTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            self?.tickScanner()
        }
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateAgentCount()
        }
    }

    private func stopAgentAnimation() {
        scannerTimer?.invalidate(); scannerTimer = nil
        countTimer?.invalidate(); countTimer = nil
    }

    private func tickScanner() {
        scanHead += scanDir
        if scanHead >= scanDots - 1 { scanHead = scanDots - 1; scanDir = -1 }
        else if scanHead <= 0 { scanHead = 0; scanDir = 1 }
        statusItem.button?.image = scannerImage(head: scanHead)
    }

    private func updateAgentCount() {
        agentCount = countAgents()
        if mode == .agent {
            statusItem.button?.title = " \(agentCount)"
            statusLine.title = agentCount == 1
                ? "Agent Mode — 1 agent running"
                : "Agent Mode — \(agentCount) agents running"
        }
    }

    private func scannerImage(head: Int) -> NSImage {
        let dot: CGFloat = 3.4
        let gap: CGFloat = 2.0
        let step = dot + gap
        let w = CGFloat(scanDots) * step
        let h: CGFloat = 16
        let dots = scanDots
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            for i in 0..<dots {
                let dist = abs(i - head)
                let level: CGFloat
                switch dist {
                case 0: level = 1.0
                case 1: level = 0.55
                case 2: level = 0.22
                default: level = 0.08
                }
                // White head fading to green along the tail
                let t = min(1.0, CGFloat(dist) / 2.0)
                let r = 1.0 - t * 0.85   // 1.00 → 0.15
                let b = 1.0 - t * 0.70   // 1.00 → 0.30
                NSColor(srgbRed: r, green: 1.0, blue: b, alpha: level).setFill()
                let x = CGFloat(i) * step
                let y = (h - dot) / 2
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    // Count top-level Claude Code / Codex CLI sessions (skip the background helpers)
    private func countAgents() -> Int {
        let out = shellOutput("/bin/ps", ["-axo", "command="])
        let helpers = ["bg-pty-host", "bg-spare", "daemon", "mcp-server", "--bg-"]
        let binaries: Set<String> = ["claude", "codex"]
        var n = 0
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let first = String(line.split(separator: " ").first ?? "")
            let base = (first as NSString).lastPathComponent
            guard binaries.contains(base) else { continue }
            if helpers.contains(where: { line.contains($0) }) { continue }
            n += 1
        }
        return n
    }

    // MARK: Lid-closed / system sleep (pmset)
    private func lidCloseAwakeEnabled() -> Bool {
        let out = shellOutput("/usr/bin/pmset", ["-g"])
        for line in out.split(separator: "\n") {
            let l = line.lowercased()
            if l.contains("sleepdisabled") { return l.contains("1") }
        }
        return false
    }

    @discardableResult
    private func runPrivileged(_ command: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let src = "do shell script \"\(command)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { NSLog("Jolt: privileged command failed: \(err)"); return false }
        return true
    }

    private func shellOutput(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: UI
    private func updateUI() {
        let lidClosed = lidCloseAwakeEnabled()

        // Icon + title
        if mode == .agent {
            statusItem.button?.imagePosition = .imageLeft
            statusItem.button?.title = " \(agentCount)"
            // image is driven by the scanner timer
        } else {
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.title = ""
            let awake = (mode == .awake) || lidClosed
            let symbol = awake ? "cup.and.saucer.fill" : "cup.and.saucer"
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jolt") {
                img.isTemplate = true
                statusItem.button?.image = img
            }
        }

        // Status line
        if mode == .agent {
            statusLine.title = agentCount == 1
                ? "Agent Mode — 1 agent running"
                : "Agent Mode — \(agentCount) agents running"
        } else if lidClosed {
            statusLine.title = "Awake — even with lid closed"
        } else if mode == .awake {
            if let end = endDate {
                let fmt = DateFormatter(); fmt.timeStyle = .short
                statusLine.title = "Awake until \(fmt.string(from: end))"
            } else {
                statusLine.title = "Awake — indefinitely"
            }
        } else {
            statusLine.title = "Off — Mac can sleep"
        }

        // Checkmarks / titles
        indefiniteItem.state = (mode == .awake && endDate == nil) ? .on : .off
        indefiniteItem.title = (mode == .awake && endDate == nil) ? "Stop Keeping Awake" : "Keep Awake"
        agentItem.state = (mode == .agent) ? .on : .off
        for it in durationItems {
            it.state = (mode == .awake && endDate != nil && it.tag == currentTimedSeconds) ? .on : .off
        }
        lidItem.state = lidClosed ? .on : .off
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    private var currentTimedSeconds: Int {
        guard let end = endDate else { return -1 }
        let remaining = end.timeIntervalSinceNow
        return durations.map { $0.1 }.min(by: { abs(Double($0) - remaining) < abs(Double($1) - remaining) }) ?? -1
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
