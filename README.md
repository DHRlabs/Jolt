<div align="center">

<img src="art/icon-master.png" width="128" alt="Jolt icon">

# Jolt

**A one-click menu-bar toggle to keep your Mac awake.**

Native, tiny, no dependencies. Lives in your menu bar as a coffee cup.

[**⬇ Download the latest DMG**](https://github.com/DHRlabs/Jolt/releases/latest/download/Jolt.dmg)

</div>

---

## What it does

Click the coffee cup in your menu bar to stop your Mac from sleeping. Click again to let it sleep.

- **Keep Awake** — stay awake indefinitely.
- **Keep Awake For…** — 15 min, 30 min, 1 hour, 2 hours, or 5 hours, then auto-off.
- **Agent Mode** — turns the menu bar into a green Knight Rider scanner with a live count of running AI coding agents; the sweep speeds up as more agents come online.
- **Keep Awake With Lid Closed** — disables system sleep entirely so your Mac keeps running with the lid shut (great for letting background jobs or agents keep working). Requires your admin password.
- **Launch at Login** — start Jolt automatically.

The icon fills in when awake mode is on, and the top of the menu always tells you the current state.

## Agent Mode

Turn it on and the coffee cup becomes a green scanner (white head, fading green comet trail) with a number next to it: how many AI coding agents are running. The sweep gets faster as the count climbs.

**How the count works, with zero setup:** Jolt scans running processes for known agent CLIs (`claude`, `codex`, `hermes`, `opencode`, `aider`, `goose`, `cline`, `gemini`, `crush`) and skips their background servers. This catches agents launched from a terminal *or* from an IDE's integrated terminal / extension. It can't see an IDE's built-in assistant (Cursor Composer, Copilot) because those talk to the cloud without a local agent process.

**Precise tracking (optional, one click):** the process scan is a good-enough heuristic. For an exact count across any tool, choose **Set Up Precise Agent Tracking…**. It copies a tool-agnostic prompt to your clipboard; paste it into any agent (Claude Code, Codex, Hermes, Aider, …) and that agent wires up its own lifecycle hook to report to Jolt. Do it once per tool. Under the hood:

- Each live session keeps a file in `~/.jolt/agents/`; it's deleted when the session ends.
- Jolt counts those files (and auto-removes any older than 12h in case of a crash).
- If no agent has been instrumented yet, Jolt automatically falls back to the process scan, so Agent Mode always works out of the box.

## Install

1. Download **[Jolt.dmg](https://github.com/DHRlabs/Jolt/releases/latest/download/Jolt.dmg)**.
2. Open it and drag **Jolt** into **Applications**.
3. Launch it. A coffee cup appears in your menu bar (there's no Dock icon).

### First launch: "Apple cannot check it for malicious software"

Jolt is open-source and only **ad-hoc signed** (not paid Apple notarization), so Gatekeeper warns on first launch. Either:

- **Right-click** Jolt in Applications → **Open** → **Open**, or
- run this once in Terminal:

  ```bash
  xattr -dr com.apple.quarantine /Applications/Jolt.app
  ```

## About "Keep Awake With Lid Closed"

Regular caffeination **cannot** keep a MacBook awake with the lid closed — closing the lid triggers a hardware sleep. The only way around it is to disable system sleep at the OS level (`pmset disablesleep`), which needs admin rights.

When you enable this, Jolt shows the standard macOS password prompt and runs `sudo pmset -a disablesleep 1` for you. Keep in mind:

- Your Mac will **not sleep at all** (lid open or closed) until you turn it back off.
- With the lid closed there's **no active cooling**, so avoid heavy sustained loads for long stretches.
- The setting **persists even if you quit Jolt.** Turn it off in the menu, or run `sudo pmset -a disablesleep 0`.

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/DHRlabs/Jolt.git
cd Jolt
bash Scripts/build.sh      # → build/Jolt.app
bash Scripts/make-dmg.sh   # → build/Jolt.dmg
```

- `Sources/main.swift` — the whole app (AppKit `NSStatusItem`, wraps `/usr/bin/caffeinate`).
- `Scripts/render-icon.swift` + `Scripts/make-icon.sh` — generate the icon from code.

## License

MIT — see [LICENSE](LICENSE).
