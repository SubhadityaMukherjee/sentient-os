#!/usr/bin/env bash
# Reset Sentient OS's local state so the next run is fresh.
#
# Default (light) reset:
#   - quits the running app (the SwiftData store can't be wiped while it's open)
#   - deletes IterativeCycle.store + sidecar files  → next run re-summarizes every bucket
#   - clears proactive.lastCycleAt / latestActionItems / latestReady / realtime.lastRunAt
#     in UserDefaults                                   → deck empties, next Analyze restamps
#
# The knowledge base vault (~/Sentient OS - Knowledge Base) is NOT touched by default —
# the next cycle updates it incrementally with the fresh summaries. Pass --deep to wipe the
# vault too, forcing a full rebuild on the next cycle (slower; only worth it if the vault
# itself seems wrong).
#
# Onboarding, source flags, scheduler state, and permissions are preserved either way.
# For a full factory reset (rewind to onboarding), use Settings → System → Reset everything.
set -euo pipefail

DEEP=0
case "${1:-}" in
  --deep) DEEP=1 ;;
  -h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  ""|"") : ;;
  *) echo "Unknown flag: $1" >&2; exit 2 ;;
esac

APP_NAME="Sentient OS"
BUNDLE_ID="jesai.Sentient-OS-macOS"
APP_SUPPORT="$HOME/Library/Application Support/SentientOS"
VAULT_ROOT="$HOME/Sentient OS - Knowledge Base"

# 1) Quit the app so the SwiftData store is closed before we touch the files.
if pgrep -f "/Applications/${APP_NAME}.app" >/dev/null 2>&1; then
  echo "▸ Quitting ${APP_NAME}..."
  osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || pkill -f "/Applications/${APP_NAME}.app" 2>/dev/null || true
  # Give it a moment to close the store files cleanly.
  for _ in 1 2 3 4 5; do
    pgrep -f "/Applications/${APP_NAME}.app" >/dev/null 2>&1 || break
    sleep 1
  done
fi

# 2) Wipe the SwiftData store (notes + pointers + fingerprints). Forces a fresh first-run
#    on every bucket; the next Analyze re-summarizes everything from scratch.
echo "▸ Wiping IterativeCycle.store..."
for f in IterativeCycle.store IterativeCycle.store-shm IterativeCycle.store-wal; do
  if [ -f "$APP_SUPPORT/$f" ]; then
    rm -f "$APP_SUPPORT/$f"
    echo "  removed $f"
  fi
done

# 3) Clear proactive + realtime results from UserDefaults. The deck empties; the next run
#    writes fresh state.
echo "▸ Clearing proactive / realtime UserDefaults..."
for key in proactive.lastCycleAt \
           proactive.latestActionItems \
           proactive.latestReady \
           proactive.dismissedTitles \
           proactive.giftLetter \
           realtime.lastRunAt; do
  defaults delete "$BUNDLE_ID" "$key" 2>/dev/null && echo "  cleared $key" || true
done

# 4) Optional deep wipe: the knowledge base vault. The next cycle rebuilds it from the new
#    summaries (much slower — the KB build is the long pole).
if [ "$DEEP" -eq 1 ]; then
  if [ -d "$VAULT_ROOT" ]; then
    echo "▸ --deep: wiping knowledge base vault at ${VAULT_ROOT}..."
    rm -rf "$VAULT_ROOT"
    echo "  removed (will rebuild on next Analyze)"
  else
    echo "▸ --deep: no vault at ${VAULT_ROOT} (nothing to wipe)"
  fi
fi

echo "✓ Done. Launch ${APP_NAME} and click Analyze Now."
