#!/bin/bash
# Remove everything Jolt created outside its own .app bundle.
# (The in-app "Uninstall Jolt…" menu item does the same thing with no dependencies.)
set -uo pipefail

echo "Uninstalling Jolt's data and integrations…"

# 1. Turn off lid-closed keep-awake if it's on (needs admin).
if pmset -g | grep -qiE "sleepdisabled +1"; then
    echo "• Re-enabling system sleep (needs your password)…"
    sudo pmset -a disablesleep 0 || echo "  (skipped — run 'sudo pmset -a disablesleep 0' yourself)"
fi

# 2. Remove Jolt's hooks from Claude Code settings.json (keeps other hooks).
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" <<'PY'
import json, sys, os, shutil
p = sys.argv[1]
try:
    data = json.load(open(p))
except Exception:
    print("• Could not parse settings.json — remove Jolt hooks manually."); raise SystemExit(0)
hooks = data.get("hooks")
if not isinstance(hooks, dict):
    print("• No hooks block in settings.json."); raise SystemExit(0)
marker = "jolt/hooks/claude-heartbeat"
removed = 0
for ev in ("SessionStart", "SessionEnd"):
    groups = hooks.get(ev)
    if not isinstance(groups, list):
        continue
    keep = [g for g in groups if not any(marker in h.get("command", "") for h in g.get("hooks", []))]
    removed += len(groups) - len(keep)
    if keep: hooks[ev] = keep
    else: hooks.pop(ev, None)
data.pop("hooks", None) if not hooks else data.__setitem__("hooks", hooks)
if removed:
    shutil.copy(p, p + ".jolt-uninstall-bak")
    json.dump(data, open(p, "w"), indent=2)
    print(f"• Removed {removed} Jolt hook(s) from Claude Code (backup kept).")
else:
    print("• No Jolt hooks found in Claude Code settings.")
PY
else
    echo "• Skipped Claude Code hooks (no settings.json or no python3) — remove manually if needed."
fi

# 3. Remove the heartbeat folder and helper scripts.
rm -rf "$HOME/.jolt" && echo "• Deleted ~/.jolt."
rm -f "$HOME/.local/bin/jolt-track" && echo "• Removed ~/.local/bin/jolt-track (if present)."

echo
echo "Done. Now drag Jolt.app to the Trash to finish."
echo "Any OTHER agents you wired up with the setup prompt must be undone in those tools."
