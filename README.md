<div align="center">

![Jolt icon](https://raw.githubusercontent.com/DHRlabs/Jolt/main/art/icon-master.png)

# Jolt

**A native, one-click menu-bar app that keeps your Mac awake.**

Native, tiny, no dependencies. Lives in your menu bar as a coffee cup.

[**⬇ Download the latest version**](https://github.com/DHRlabs/Jolt/releases/latest/download/Jolt.dmg)

</div>

---

## What it does

Click the coffee cup in your menu bar to stop your Mac from sleeping. Click again to let it sleep.

- **Keep Awake** — stay awake indefinitely.
- **Keep Awake For…** — 15 min, 30 min, 1 hour, 2 hours, or 5 hours, then auto-off.
- **Keep Awake With Lid Closed** (and a timed **… For…** variant) — keep running with the lid shut. Requires your admin password; the timed version auto-reverts.
- **Launch at Login** — start Jolt automatically.

The icon fills in when it's keeping your Mac awake, and the top of the menu shows the current state.

## Install

1. Download **[Jolt.dmg](https://github.com/DHRlabs/Jolt/releases/latest/download/Jolt.dmg)**.
2. Open it and drag **Jolt** into **Applications**.
3. Launch it. A coffee cup appears in your menu bar (there's no Dock icon).

### First launch: "Apple cannot check it for malicious software"

Jolt is open-source and only ad-hoc signed (not paid Apple notarization), so Gatekeeper warns on first launch. Either right-click Jolt → **Open** → **Open**, or run once in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Jolt.app
```

## About "Keep Awake With Lid Closed"

`caffeinate` alone can't keep a MacBook awake with the lid closed — closing the lid triggers a hardware sleep. The only way around it is disabling system sleep at the OS level (`pmset disablesleep`), which needs admin rights.

When you enable it, Jolt shows the standard macOS password prompt and runs `pmset -a disablesleep 1` for you. Note:

- Your Mac will not sleep (lid open or closed) until you turn it off; the timed version auto-reverts.
- With the lid closed there's no active cooling, so avoid heavy sustained loads for long stretches.
- If you quit Jolt while it's on (untimed), it stays on. Turn it off in the menu, or run `sudo pmset -a disablesleep 0`.

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/DHRlabs/Jolt.git
cd Jolt
bash Scripts/build.sh      # → build/Jolt.app
bash Scripts/make-dmg.sh   # → build/Jolt.dmg
```

- `Sources/main.swift` — the whole app (AppKit `NSStatusItem`, wraps `/usr/bin/caffeinate`).
- `art/icon-master.png` + `Scripts/make-icon.sh` — rebuild platform icons from the selected source artwork.

## License

MIT — see [LICENSE](LICENSE).
