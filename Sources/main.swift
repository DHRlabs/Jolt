import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var caffeinateProcess: Process?
    private var endDate: Date?        // non-nil only for timed keep-awake
    private var lidEndDate: Date?     // non-nil only for timed lid-closed
    private var tickTimer: Timer?
    private var pulseTimer: Timer?    // sweeps a comet through the lid-closed status text while the menu is open
    private var charEnergy: [CGFloat] = []
    private var sHead = 0
    private var pulseLastT: CFAbsoluteTime = 0
    private var pulseAcc = 0.0

    private let menu = NSMenu()
    private var statusLine: NSMenuItem!
    private var awakeItem: NSMenuItem!
    private var durationItems: [NSMenuItem] = []
    private var lidItem: NSMenuItem!
    private var lidDurationItems: [NSMenuItem] = []
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

    func applicationWillTerminate(_ notification: Notification) { stopCaffeinate() }

    func menuWillOpen(_ menu: NSMenu) {
        updateUI()
        if lidOn() { startPulse() }
    }
    func menuDidClose(_ menu: NSMenu) { stopPulse() }

    // Breathing purple on the lid-closed status line (runs only while the menu is open).
    private func startPulse() {
        stopPulse()
        pulseLastT = CFAbsoluteTimeGetCurrent()
        pulseTick()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.pulseTick() }
        RunLoop.main.add(t, forMode: .common)
        pulseTimer = t
    }
    private func stopPulse() { pulseTimer?.invalidate(); pulseTimer = nil }

    // Sweep a white comet head through the (purple) status letters. Each letter fades on
    // its own real-time clock, independent of how fast the head advances.
    private func pulseTick() {
        let n = (statusLine.title as NSString).length
        guard n > 0 else { return }
        if charEnergy.count != n { charEnergy = Array(repeating: 0, count: n); sHead = 0; pulseAcc = 0 }

        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(0.1, now - pulseLastT); pulseLastT = now
        let f = CGFloat(exp(-dt / 0.45))
        for i in 0..<n { charEnergy[i] *= f }

        pulseAcc += dt
        let step = 0.07
        var steps = 0
        while pulseAcc >= step && steps < 64 {
            sHead = (sHead + 1) % n
            pulseAcc -= step
            steps += 1
        }
        charEnergy[sHead] = 1.0   // head letter stays lit; only the trail fades

        let attr = NSMutableAttributedString(string: statusLine.title)
        let purple = NSColor(srgbRed: 0.60, green: 0.35, blue: 1.0, alpha: 1)
        for i in 0..<n {
            let v = min(1, charEnergy[i])
            let color = purple.blended(withFraction: v, of: .white) ?? purple   // white head → purple trail
            attr.addAttribute(.foregroundColor, value: color, range: NSRange(location: i, length: 1))
        }
        statusLine.attributedTitle = attr
    }

    // MARK: Menu
    private func buildMenu() {
        statusLine = NSMenuItem(title: "Off", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        awakeItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleAwake), keyEquivalent: "")
        awakeItem.target = self
        menu.addItem(awakeItem)

        let durationParent = NSMenuItem(title: "Keep Awake For…", action: nil, keyEquivalent: "")
        durationParent.submenu = makeDurations(#selector(startTimed(_:)), store: &durationItems)
        menu.addItem(durationParent)

        lidItem = NSMenuItem(title: "Keep Awake With Lid Closed", action: #selector(toggleLid), keyEquivalent: "")
        lidItem.target = self
        menu.addItem(lidItem)

        let lidDurationParent = NSMenuItem(title: "Keep Awake With Lid Closed For…", action: nil, keyEquivalent: "")
        lidDurationParent.submenu = makeDurations(#selector(startLidTimed(_:)), store: &lidDurationItems)
        menu.addItem(lidDurationParent)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let quit = NSMenuItem(title: "Quit Jolt", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func makeDurations(_ action: Selector, store: inout [NSMenuItem]) -> NSMenu {
        let m = NSMenu()
        for (label, seconds) in durations {
            let it = NSMenuItem(title: label, action: action, keyEquivalent: "")
            it.target = self
            it.tag = seconds
            m.addItem(it)
            store.append(it)
        }
        return m
    }

    // MARK: Actions
    @objc private func toggleAwake() {
        if lidOn() {
            // Switch from lid-closed to plain keep-awake (turning lid-closed off needs admin).
            _ = runPrivileged("pkill -f JOLT_LID_REVERT 2>/dev/null; pmset -a disablesleep 0")
            lidEndDate = nil
            if !isActive { startCaffeinate(seconds: nil) }
        } else if isActive && endDate == nil {
            stopCaffeinate()
        } else {
            startCaffeinate(seconds: nil)
        }
        updateUI()
    }

    @objc private func startTimed(_ sender: NSMenuItem) {
        startCaffeinate(seconds: sender.tag)
        updateUI()
    }

    @objc private func toggleLid() {
        if lidOn() { disableLid() } else if confirmLid(nil) { enableLid(seconds: nil) }
    }

    @objc private func startLidTimed(_ sender: NSMenuItem) {
        let label = durations.first { $0.1 == sender.tag }?.0 ?? "a while"
        if confirmLid(label) { enableLid(seconds: sender.tag) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Jolt: launch-at-login change failed: \(error)")
        }
        updateUI()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: caffeinate
    private var isActive: Bool { caffeinateProcess?.isRunning ?? false }

    private func startCaffeinate(seconds: Int?) {
        stopCaffeinate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        var args = ["-d", "-i", "-s", "-u"]           // display, idle, system(AC), user-active
        if let s = seconds {
            args += ["-t", String(s)]                 // timed: self-exits at timeout
        } else {
            args += ["-w", String(ProcessInfo.processInfo.processIdentifier)]  // dies with Jolt
        }
        p.arguments = args
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.caffeinateProcess = nil
                self?.endDate = nil
                self?.updateUI()
            }
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

    private func startTicking() {
        tickTimer?.invalidate()
        guard endDate != nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateUI()
        }
    }

    // MARK: Lid-closed (pmset disablesleep)
    private func lidOn() -> Bool {
        for line in shellOut("/usr/bin/pmset", ["-g"]).split(separator: "\n") {
            let l = line.lowercased()
            if l.contains("sleepdisabled") { return l.contains("1") }
        }
        return false
    }

    private func confirmLid(_ label: String?) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = label == nil
            ? "Keep Awake With Lid Closed?"
            : "Keep Awake With Lid Closed for \(label!)?"
        var body = """
        Disables system sleep so your Mac keeps running with the lid shut.

        • Requires your admin password.
        • With the lid closed there is no active cooling, so avoid heavy sustained loads for long stretches.
        """
        body += label == nil
            ? "\n• Stays on until you turn it off; persists even if you quit Jolt."
            : "\n• Auto-reverts after \(label!)."
        a.informativeText = body
        a.alertStyle = .warning
        a.addButton(withTitle: "Enable")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    // One admin prompt: enables now and, if timed, schedules a root background revert.
    private func enableLid(seconds: Int?) {
        var cmd = "pkill -f JOLT_LID_REVERT 2>/dev/null; pmset -a disablesleep 1"
        if let s = seconds {
            cmd += "; nohup sh -c 'sleep \(s); pmset -a disablesleep 0' JOLT_LID_REVERT >/dev/null 2>&1 &"
        }
        if runPrivileged(cmd) {
            lidEndDate = seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
            if !isActive { startCaffeinate(seconds: nil) }
        }
        updateUI()
    }

    private func disableLid() {
        _ = runPrivileged("pkill -f JOLT_LID_REVERT 2>/dev/null; pmset -a disablesleep 0")
        lidEndDate = nil
        if isActive && endDate == nil { stopCaffeinate() }
        updateUI()
    }

    @discardableResult
    private func runPrivileged(_ cmd: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges")?
            .executeAndReturnError(&err)
        if let err { NSLog("Jolt: privileged command failed: \(err)"); return false }
        return true
    }

    private func shellOut(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    // MARK: UI
    private func updateUI() {
        let lid = lidOn()
        if !lid { lidEndDate = nil }
        // Lid-closed disables system sleep, but display-sleep prevention is a separate
        // caffeinate process. If it's not running (died, or the flag was set outside
        // this launch of Jolt), restart it so the screen doesn't sleep/lock.
        if lid && !isActive { startCaffeinate(seconds: nil) }

        let awake = isActive || lid
        let symbol = awake ? "cup.and.saucer.fill" : "cup.and.saucer"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jolt") {
            img.isTemplate = true
            statusItem.button?.image = img
        }

        let fmt = DateFormatter(); fmt.timeStyle = .short
        if lid {
            statusLine.title = lidEndDate.map { "Awake, lid closed, until \(fmt.string(from: $0))" }
                ?? "Awake — even with lid closed"
        } else if isActive {
            statusLine.title = endDate.map { "Awake until \(fmt.string(from: $0))" }
                ?? "Awake — indefinitely"
        } else {
            statusLine.title = "Off — Mac can sleep"
        }

        if !lid { statusLine.attributedTitle = nil }   // purple letter-comet (driven by the pulse) only while lid-closed

        let plainAwake = isActive && endDate == nil && !lid
        awakeItem.state = plainAwake ? .on : .off
        awakeItem.title = plainAwake ? "Stop Keeping Awake" : "Keep Awake"
        for it in durationItems {
            it.state = (isActive && endDate != nil && !lid && it.tag == nearest(endDate)) ? .on : .off
        }
        lidItem.state = (lid && lidEndDate == nil) ? .on : .off
        for it in lidDurationItems {
            it.state = (lid && lidEndDate != nil && it.tag == nearest(lidEndDate)) ? .on : .off
        }
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    private func nearest(_ end: Date?) -> Int {
        guard let end else { return -1 }
        let r = end.timeIntervalSinceNow
        return durations.map { $0.1 }.min(by: { abs(Double($0) - r) < abs(Double($1) - r) }) ?? -1
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
