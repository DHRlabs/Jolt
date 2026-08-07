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
    private var energy: [CGFloat] = []   // per-dot brightness, decays each tick (comet trail)

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

    // Tool-agnostic prompt the user pastes into any agent to wire it up to Jolt.
    static let trackingPrompt = """
    Set up live "agent running" tracking for THIS agent so the Jolt macOS menu-bar app can count it.

    HEARTBEAT CONTRACT (how Jolt counts agents):
    - Directory: ~/.jolt/agents  (create if missing: mkdir -p ~/.jolt/agents)
    - While a session is active, it keeps one uniquely-named file in that directory, e.g. <tool>-<pid>. An empty file is fine; optional one-line JSON contents: {"agent":"<tool>","pid":<pid>}
    - When the session ends, that file is deleted.
    - Jolt counts the files = number of live agents, and deletes files older than 12h to recover from crashes. Re-touching the file periodically is welcome but optional.

    DO THIS NOW:
    1. Work out which agent/CLI you are and where your own config lives. Examples: Claude Code -> ~/.claude/settings.json hooks; Codex -> its config/hooks; Aider, Cursor, Hermes, OpenCode, Goose, Gemini CLI, etc. -> their own mechanisms.
    2. If this tool supports session lifecycle hooks (start / stop / exit, or per-turn events), add hooks — merged into existing config, backed up first, without clobbering anything — that do:
         on start:  mkdir -p ~/.jolt/agents && : > ~/.jolt/agents/<tool>-$PPID
         on end:    rm -f ~/.jolt/agents/<tool>-$PPID
       Use whatever stable per-session id your tool exposes ($PPID or the tool's own session id are both fine).
    3. If this tool has NO hook system, achieve the same create-on-start / delete-on-exit another safe way (a shell function plus an exit trap in the user's shell rc, or the tool's startup script) and explain what you did.
    4. Either way, create the heartbeat file for the CURRENT session right now so it shows up in Jolt immediately.
    5. Print a short summary: which agent you detected, exactly what you changed, and how to undo it.

    RULES: be idempotent (safe to run more than once), never write secrets, and only touch the detected tool's own config. If you cannot tell which tool you are, just do step 4 and say so.
    """

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

        let trackItem = NSMenuItem(title: "Set Up Precise Agent Tracking…", action: #selector(copyTrackingPrompt), keyEquivalent: "")
        trackItem.target = self
        menu.addItem(trackItem)

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

    @objc private func copyTrackingPrompt() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.trackingPrompt, forType: .string)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Setup prompt copied to your clipboard"
        alert.informativeText = """
        Paste it into any AI coding agent — Claude Code, Codex, Cursor, Aider, Hermes, whatever you use.

        It detects which tool it's running in and wires that tool up to report live to Jolt — no manual config. Do it once per agent system you want tracked.

        Until then, Jolt automatically falls back to counting agent processes, so Agent Mode still works with zero setup.
        """
        alert.alertStyle = .informational
        alert.runModal()
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
        energy = Array(repeating: 0, count: scanDots)
        scanHead = 0; scanDir = 1
        agentCount = countAgents()
        updateCountLabels()
        tickScanner()
        scheduleScanner()
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshAgentCount()
        }
    }

    private func stopAgentAnimation() {
        scannerTimer?.invalidate(); scannerTimer = nil
        countTimer?.invalidate(); countTimer = nil
    }

    // Slower by default, quicker as more agents come online
    private func scannerInterval() -> TimeInterval {
        return max(0.05, 0.18 - 0.022 * Double(agentCount))
    }

    private func scheduleScanner() {
        scannerTimer?.invalidate()
        scannerTimer = Timer.scheduledTimer(withTimeInterval: scannerInterval(), repeats: true) { [weak self] _ in
            self?.tickScanner()
        }
    }

    private func tickScanner() {
        scanHead += scanDir
        if scanHead >= scanDots - 1 { scanHead = scanDots - 1; scanDir = -1 }
        else if scanHead <= 0 { scanHead = 0; scanDir = 1 }
        for j in 0..<energy.count { energy[j] *= 0.58 }   // fade the trail
        energy[scanHead] = 1.0                            // light the head
        statusItem.button?.image = scannerImage()
    }

    private func refreshAgentCount() {
        let n = countAgents()
        if n != agentCount { agentCount = n; scheduleScanner() }   // re-tempo the sweep
        updateCountLabels()
    }

    private func updateCountLabels() {
        guard mode == .agent else { return }
        statusItem.button?.title = " \(agentCount)"
        statusLine.title = agentCount == 1
            ? "Agent Mode — 1 agent running"
            : "Agent Mode — \(agentCount) agents running"
    }

    private func scannerImage() -> NSImage {
        let dot: CGFloat = 4.6
        let gap: CGFloat = 2.2
        let step = dot + gap
        let w = CGFloat(scanDots) * step
        let h: CGFloat = 18
        let e = energy
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            for i in 0..<e.count {
                let v = e[i]
                let color: NSColor
                if v > 0.99 {
                    color = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)       // white head
                } else {
                    let a = max(0.06, v)                                                   // green tail → unlit
                    color = NSColor(srgbRed: 0.15, green: 1.0, blue: 0.30, alpha: a)
                }
                color.setFill()
                let x = CGFloat(i) * step
                let y = (h - dot) / 2
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    // Live agent count: exact heartbeat count once any agent has been instrumented,
    // otherwise a best-effort process scan so Agent Mode works with zero setup.
    private func countAgents() -> Int {
        if let hb = heartbeatCount(), hb > 0 { return hb }
        return processScanCount()
    }

    private var heartbeatDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jolt/agents", isDirectory: true)
    }

    // nil = precise tracking not in use (directory absent). Otherwise the number of
    // fresh heartbeat files; stale ones (>12h, presumed crashed) are cleaned up.
    private func heartbeatCount() -> Int? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: heartbeatDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        var n = 0
        for f in files {
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime < cutoff { try? fm.removeItem(at: f); continue }
            n += 1
        }
        return n
    }

    // Best-effort: count agent CLI sessions (terminal or IDE-launched), skipping
    // background servers. Match is by the executable's lowercase name, so capitalized
    // desktop apps (Claude.app, ChatGPT.app) don't get counted — only CLI binaries.
    private func processScanCount() -> Int {
        let out = shellOutput("/bin/ps", ["-axo", "command="])
        let servers = ["bg-pty-host", "bg-spare", "daemon", "mcp-server", "--bg-", "app-server"]
        let binaries: Set<String> = [
            "claude", "codex", "hermes", "opencode", "aider", "goose", "cline", "gemini", "crush"
        ]
        var n = 0
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let first = String(line.split(separator: " ").first ?? "")
            let base = (first as NSString).lastPathComponent
            guard binaries.contains(base) else { continue }
            if servers.contains(where: { line.contains($0) }) { continue }
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
