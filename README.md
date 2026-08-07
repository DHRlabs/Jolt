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
- **Keep Awake With Lid Closed** — disables system sleep entirely so your Mac keeps running with the lid shut (great for letting background jobs or agents keep working). Requires your admin password.
- **Launch at Login** — start Jolt automatically.

The icon fills in when awake mode is on, and the top of the menu always tells you the current state.

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
