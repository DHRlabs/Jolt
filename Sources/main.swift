import Cocoa
import ServiceManagement

enum Mode { case off, awake, agent }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: State
    private var statusItem: NSStatusItem!
    private var caffeinateProcess: Process?
    private var mode: Mode = .off
    private var endDate: Date?          // non-nil only for timed "awake" sessions
    private var lidEndDate: Date?       // non-nil only for timed lid-closed sessions
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
    private var agentsParent: NSMenuItem!
    private var agentsMenu: NSMenu!
    private var indefiniteItem: NSMenuItem!
    private var agentItem: NSMenuItem!
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

    // Tool-agnostic prompt the user pastes into any agent to wire it up to Jolt.
    static let trackingPrompt = """
    Set up live "agent running" tracking for THIS agent so the Jolt macOS menu-bar app can count it.

    Source, optional to review, not required: https://github.com/DHRlabs/Jolt . Do not fetch and run remote code; everything you need is below.

    HOW IT WORKS (applies to any tool):
    Jolt counts live agents by watching a folder: one file = one running session. Make a file appear when a session starts and disappear when it ends, using whatever mechanism your tool has (a lifecycle hook, a plugin, a startup/shutdown script, a shell wrapper, an alias). If you are a tool not named below, apply the same "start = create a file, end = remove it" idea however you best can, and say what you chose.

    HEARTBEAT CONTRACT:
    - Directory: ~/.jolt/agents  (create if missing: mkdir -p ~/.jolt/agents)
    - Each running session keeps ONE file there while it is active, deleted when it ends.
    - CRITICAL: the filename must be UNIQUE PER CONCURRENT SESSION. Use the session's process id (PID) or a per-session id. Do NOT use one fixed or shared name -- if you do, 5 sessions collapse into 1 file and Jolt shows 1. Name it <tool>-<pid> or <tool>-<sessionid>.
    - Jolt counts the files, and deletes files older than 12h to recover from crashes.

    DO THIS NOW:
    1. Identify which agent/CLI you are and where your config lives. Examples: Claude Code -> ~/.claude/settings.json hooks; Codex -> its config/hooks; Aider, Cursor, Hermes, OpenCode, Goose, Gemini CLI -> their own.
    2. If this tool has session lifecycle hooks (start / end / exit), add them -- merged into existing config, backed up first, not clobbering anything -- doing:
         on start:  mkdir -p ~/.jolt/agents && : > ~/.jolt/agents/<tool>-$PPID
         on end:    rm -f ~/.jolt/agents/<tool>-$PPID
    3. If it has NO hooks, do the same create-on-start / delete-on-exit another safe way (a shell function + exit trap in the shell rc, or a wrapper around the launch command).
    4. If this tool is a single long-running app that genuinely cannot tell its concurrent chats/sessions apart (many desktop apps are like this), then one file for the whole app is the best possible -- do that and SAY SO, so the user knows this tool can only ever contribute 1 to the count.
    5. Create the file for the CURRENT session now so it shows immediately, then print a short summary: which tool, what you changed, whether it is per-session or one-per-app, and how to undo it.

    RULES: be idempotent, never write secrets, only touch this tool's own config.
    """

    // Mirror of the setup prompt: pasted into an agent to REMOVE its Jolt integration.
    static let cleanupPrompt = """
    Remove the "Jolt agent tracking" integration that was previously added to THIS tool. Jolt is a macOS menu-bar app being uninstalled. It cleans up its own files, but it cannot undo the per-tool integration you (or a past setup prompt) added, so undo yours.

    Source, optional to review: https://github.com/DHRlabs/Jolt . Do not fetch and run remote code; everything you need is below.

    WHAT WAS ADDED (the thing to remove):
    Earlier this tool was set up to write a heartbeat file into ~/.jolt/agents when a session starts and remove it when the session ends. That was done with whatever mechanism this tool has: a lifecycle hook, a plugin, a shell function/alias/trap in a shell rc file, a launch wrapper, a background watcher, or similar. Your job is to find and fully remove that, restoring config to how it was.

    DO THIS NOW:
    1. Work out which agent/CLI you are and where your own config lives.
    2. Search your config and the user's shell rc files (~/.zshrc, ~/.bashrc, ~/.bash_profile, ~/.profile) for anything referencing "jolt", "~/.jolt", "jolt-track", or a "heartbeat" script, hook entries, shell functions, aliases, traps, wrapper scripts, plugin entries, launchd/cron jobs.
    3. Remove ONLY those Jolt-related entries. If a backup was saved when they were added (for example a file ending in a "jolt" backup suffix), you may restore from it. Leave all unrelated config untouched.
    4. Do NOT delete ~/.jolt or ~/.local/bin/jolt-track yourself; the Jolt app removes those. (If the app is already gone and they remain, removing them is fine.)
    5. Print a short summary of exactly what you removed and anything you looked for but could not find.

    RULES: be conservative (only Jolt-related entries, nothing else), never touch secrets, and back up any file before you edit it.
    """

    // MARK: Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateUI()
        restoreState()
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

        // ── Keep Awake ──
        indefiniteItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleIndefinite), keyEquivalent: "")
        indefiniteItem.target = self
        menu.addItem(indefiniteItem)

        let durationParent = NSMenuItem(title: "Keep Awake For…", action: nil, keyEquivalent: "")
        durationParent.submenu = makeDurations(#selector(startTimed(_:)), store: &durationItems)
        menu.addItem(durationParent)

        lidItem = NSMenuItem(title: "Keep Awake With Lid Closed", action: #selector(toggleLidClosed), keyEquivalent: "")
        lidItem.target = self
        menu.addItem(lidItem)

        let lidDurationParent = NSMenuItem(title: "Keep Awake With Lid Closed For…", action: nil, keyEquivalent: "")
        lidDurationParent.submenu = makeDurations(#selector(startLidTimed(_:)), store: &lidDurationItems)
        menu.addItem(lidDurationParent)

        menu.addItem(.separator())

        // ── Agents ──
        agentItem = NSMenuItem(title: "Agent Mode", action: #selector(toggleAgentMode), keyEquivalent: "")
        agentItem.target = self
        menu.addItem(agentItem)

        agentsParent = NSMenuItem(title: "Connected Agents", action: nil, keyEquivalent: "")
        agentsMenu = NSMenu()
        agentsParent.submenu = agentsMenu
        menu.addItem(agentsParent)

        let trackItem = NSMenuItem(title: "Set Up Precise Agent Tracking…", action: #selector(copyTrackingPrompt), keyEquivalent: "")
        trackItem.target = self
        menu.addItem(trackItem)

        menu.addItem(.separator())

        // ── App ──
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let about = NSMenuItem(title: "About Jolt", action: #selector(about), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let uninstallItem = NSMenuItem(title: "Uninstall Jolt…", action: #selector(uninstallData), keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)

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

    // MARK: Mode control
    private func setOff() {
        stopCaffeinate()
        stopAgentAnimation()
        mode = .off
        persistState()
        updateUI()
    }

    private func setAwake(seconds: Int?) {
        stopAgentAnimation()
        startCaffeinate(seconds: seconds)
        mode = .awake
        persistState()
        updateUI()
    }

    private func setAgent() {
        startCaffeinate(seconds: nil)
        mode = .agent
        startAgentAnimation()
        persistState()
        updateUI()
    }

    // Remember the chosen mode so it resumes on next launch (e.g. Launch at Login).
    private func persistState() {
        let d = UserDefaults.standard
        d.set(mode == .agent ? "agent" : (mode == .awake ? "awake" : "off"), forKey: "jolt.mode")
        d.set(endDate?.timeIntervalSinceReferenceDate ?? 0, forKey: "jolt.endDate")
    }

    private func restoreState() {
        switch UserDefaults.standard.string(forKey: "jolt.mode") {
        case "agent":
            setAgent()
        case "awake":
            let ts = UserDefaults.standard.double(forKey: "jolt.endDate")
            if ts > 0 {
                let remaining = Int(Date(timeIntervalSinceReferenceDate: ts).timeIntervalSinceNow)
                if remaining > 5 { setAwake(seconds: remaining); return }
                setOff(); return   // timer already elapsed while quit
            }
            setAwake(seconds: nil)
        default:
            break
        }
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
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Copy the agent setup prompt?"
        alert.informativeText = """
        This copies a short prompt to your clipboard. Paste it into any AI agent (Claude Code, Codex, Aider, and so on) and it sets that agent up to report to Jolt, so the count is exact.

        Do it once per agent. Nothing changes until you paste it.
        """
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.trackingPrompt, forType: .string)
    }

    @objc private func toggleLidClosed() {
        if lidCloseAwakeEnabled() { disableLidClosed() }
        else if confirmLidClosed(nil) { enableLidClosed(seconds: nil) }
    }

    @objc private func startLidTimed(_ sender: NSMenuItem) {
        let label = durations.first { $0.1 == sender.tag }?.0 ?? "a while"
        if confirmLidClosed(label) { enableLidClosed(seconds: sender.tag) }
    }

    private func confirmLidClosed(_ durationLabel: String?) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = durationLabel == nil
            ? "Keep Awake With Lid Closed?"
            : "Keep Awake With Lid Closed for \(durationLabel!)?"
        var body = """
        This disables system sleep so your Mac keeps running with the lid shut — handy for letting agents keep working.

        • Requires your admin password.
        • With the lid closed there is no active cooling, so avoid heavy sustained loads for long stretches.
        """
        body += durationLabel == nil
            ? "\n• Stays on (lid open or closed) until you turn it off; persists even if you quit Jolt."
            : "\n• Auto-reverts after \(durationLabel!)."
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // One admin prompt: enables disablesleep now and, if timed, schedules a root
    // background revert (JOLT_LID_REVERT tag lets a later action cancel a pending one).
    private func enableLidClosed(seconds: Int?) {
        var cmd = "pkill -f JOLT_LID_REVERT 2>/dev/null; pmset -a disablesleep 1"
        if let s = seconds {
            cmd += "; nohup sh -c 'sleep \(s); pmset -a disablesleep 0' JOLT_LID_REVERT >/dev/null 2>&1 &"
        }
        if runPrivileged(cmd) {
            lidEndDate = seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
            if mode == .off { setAwake(seconds: nil) }   // fill icon / keep display assertions
        }
        updateUI()
    }

    private func disableLidClosed() {
        _ = runPrivileged("pkill -f JOLT_LID_REVERT 2>/dev/null; pmset -a disablesleep 0")
        lidEndDate = nil
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

    @objc private func uninstallData() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove Jolt's data and integrations?"
        alert.informativeText = """
        This will:
        • turn off "Keep Awake With Lid Closed" if it's on,
        • remove Jolt's hooks from Claude Code's settings.json (a backup is kept),
        • delete the ~/.jolt folder,
        • remove ~/.local/bin/jolt-track.

        It will NOT delete Jolt.app itself — drag that to the Trash afterward. Any OTHER agents you wired up with the setup prompt must be undone in those tools.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var report: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        if lidCloseAwakeEnabled(), runPrivileged("pmset -a disablesleep 0") {
            report.append("• Re-enabled system sleep (lid-closed off).")
        }
        report.append("• " + removeClaudeHooks())

        let jolt = home.appendingPathComponent(".jolt")
        if FileManager.default.fileExists(atPath: jolt.path) {
            try? FileManager.default.removeItem(at: jolt)
            report.append("• Deleted ~/.jolt.")
        } else {
            report.append("• ~/.jolt was not present.")
        }

        let track = home.appendingPathComponent(".local/bin/jolt-track")
        if FileManager.default.fileExists(atPath: track.path) {
            try? FileManager.default.removeItem(at: track)
            report.append("• Removed ~/.local/bin/jolt-track.")
        }

        setOff()

        let done = NSAlert()
        done.messageText = "Jolt data removed"
        done.informativeText = report.joined(separator: "\n") + "\n\nWired up other agents (Codex, Hermes, …) with the setup prompt? Copy a cleanup prompt to paste into each one so it removes its own Jolt integration too."
        done.addButton(withTitle: "Copy Cleanup Prompt")
        done.addButton(withTitle: "No Thanks")
        if done.runModal() == .alertFirstButtonReturn {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(Self.cleanupPrompt, forType: .string)
            let copied = NSAlert()
            copied.messageText = "Cleanup prompt copied"
            copied.informativeText = "Paste it into any agent you set up for Jolt. It will find and remove that tool's Jolt integration and report what it changed."
            copied.runModal()
        }

        let bye = NSAlert()
        bye.messageText = "Finish uninstalling"
        bye.informativeText = "Drag Jolt.app to the Trash to finish removing Jolt. Quit Jolt now?"
        bye.addButton(withTitle: "Quit Jolt")
        bye.addButton(withTitle: "Keep Running")
        if bye.runModal() == .alertFirstButtonReturn { NSApplication.shared.terminate(nil) }
    }

    // Remove only Jolt's own hooks from Claude Code's settings.json, leaving other
    // hooks untouched. Uses Foundation JSON (no jq dependency on the user's machine).
    private func removeClaudeHooks() -> String {
        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settings),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "Claude Code settings.json not found or unreadable — skipped (remove hooks manually if needed)."
        }
        guard var hooks = root["hooks"] as? [String: Any] else {
            return "No hooks block in Claude Code settings — nothing to remove."
        }
        let marker = "jolt/hooks/claude-heartbeat"
        var removed = 0
        for event in ["SessionStart", "SessionEnd"] {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            let before = groups.count
            groups = groups.filter { group in
                let cmds = (group["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
                return !cmds.contains { $0.contains(marker) }
            }
            removed += before - groups.count
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        guard removed > 0 else { return "No Jolt hooks found in Claude Code settings." }
        let bak = settings.deletingLastPathComponent().appendingPathComponent("settings.json.jolt-uninstall-bak")
        try? data.write(to: bak)
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? out.write(to: settings)
            return "Removed \(removed) Jolt hook(s) from Claude Code (backup: \(bak.lastPathComponent))."
        }
        return "Found \(removed) Jolt hook(s) but could not rewrite settings.json — remove them manually."
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: caffeinate control
    private func startCaffeinate(seconds: Int?) {
        stopCaffeinate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        var args = ["-d", "-i", "-s", "-u"]   // display, idle, system(AC), declare user active
        if let s = seconds {
            args += ["-t", String(s)]         // timed: caffeinate self-exits at timeout
        } else {
            // indefinite: tie lifetime to Jolt's PID so it can't outlive us even on a hard kill
            args += ["-w", String(ProcessInfo.processInfo.processIdentifier)]
        }
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

    private var heartbeatDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jolt/agents", isDirectory: true)
    }

    private let agentBinaries: Set<String> = [
        "claude", "codex", "hermes", "opencode", "aider", "goose", "cline", "gemini", "crush"
    ]
    private let agentServerMarkers = ["bg-pty-host", "bg-spare", "daemon", "mcp-server", "--bg-", "app-server"]

    // What's running now, as display strings. Exact heartbeat list once any agent has
    // been instrumented, otherwise a best-effort process scan (zero-setup default).
    private func agentDescriptors() -> [String] {
        // Heartbeats are exact; for any tool NOT reporting heartbeats, fall back to the
        // process scan so instrumented and un-instrumented agents both count.
        let hb = heartbeatDescriptors() ?? []
        let hbTools = Set(hb.map { toolName(of: $0) })
        let scan = processScanDescriptors().filter { !hbTools.contains(toolName(of: $0)) }
        return (hb + scan).sorted()
    }

    private func toolName(of descriptor: String) -> String {
        String(descriptor.split(separator: " ").first ?? "")
    }

    private func countAgents() -> Int { agentDescriptors().count }

    // nil = precise tracking not in use (directory absent). Otherwise one entry per
    // fresh heartbeat file; stale ones (>12h, presumed crashed) are cleaned up.
    private func heartbeatDescriptors() -> [String]? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: heartbeatDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        var items: [String] = []
        for f in files {
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime < cutoff { try? fm.removeItem(at: f); continue }
            let name = f.lastPathComponent
            let parts = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let tool = String(parts.first ?? "agent")
            var id = parts.count > 1 ? String(parts[1]) : ""
            if id.count > 8 { id = String(id.prefix(8)) + "…" }
            items.append(id.isEmpty ? tool : "\(tool)  ·  \(id)")
        }
        return items.sorted()
    }

    // Best-effort: agent CLI sessions (terminal or IDE-launched), skipping background
    // servers. Match is by the executable's lowercase name, so capitalized desktop apps
    // (Claude.app, ChatGPT.app) don't get counted — only CLI binaries.
    private func processScanDescriptors() -> [String] {
        let out = shellOutput("/bin/ps", ["-axo", "pid=,command="])
        var items: [String] = []
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let sp = line.firstIndex(of: " ") else { continue }
            let pid = String(line[..<sp])
            let cmd = line[line.index(after: sp)...].trimmingCharacters(in: .whitespaces)
            let first = String(cmd.split(separator: " ").first ?? "")
            let base = (first as NSString).lastPathComponent
            guard agentBinaries.contains(base) else { continue }
            if agentServerMarkers.contains(where: { cmd.contains($0) }) { continue }
            items.append("\(base)  ·  pid \(pid)")
        }
        return items.sorted()
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
        if !lidClosed { lidEndDate = nil }   // reflect an auto-revert that already fired

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
            if let end = lidEndDate {
                let fmt = DateFormatter(); fmt.timeStyle = .short
                statusLine.title = "Awake, lid closed, until \(fmt.string(from: end))"
            } else {
                statusLine.title = "Awake — even with lid closed"
            }
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
        lidItem.state = (lidClosed && lidEndDate == nil) ? .on : .off
        for it in lidDurationItems {
            it.state = (lidClosed && lidEndDate != nil && it.tag == currentLidSeconds) ? .on : .off
        }
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        // Connected-agents list (refreshed whenever the menu opens)
        let descs = agentDescriptors()
        agentsMenu.removeAllItems()
        if descs.isEmpty {
            let none = NSMenuItem(title: "None detected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            agentsMenu.addItem(none)
        } else {
            for d in descs {
                let it = NSMenuItem(title: d, action: nil, keyEquivalent: "")
                it.isEnabled = false
                agentsMenu.addItem(it)
            }
        }
        agentsParent.title = "Connected Agents (\(descs.count))"
    }

    private var currentTimedSeconds: Int {
        guard let end = endDate else { return -1 }
        let remaining = end.timeIntervalSinceNow
        return durations.map { $0.1 }.min(by: { abs(Double($0) - remaining) < abs(Double($1) - remaining) }) ?? -1
    }

    private var currentLidSeconds: Int {
        guard let end = lidEndDate else { return -1 }
        let remaining = end.timeIntervalSinceNow
        return durations.map { $0.1 }.min(by: { abs(Double($0) - remaining) < abs(Double($1) - remaining) }) ?? -1
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
