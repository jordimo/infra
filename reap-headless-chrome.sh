#!/bin/bash
# Reap orphaned headless Chrome instances left behind by Claude Code (or any
# automation) doing HTML->PNG screenshot rendering. Those launches use
# `--headless` with a throwaway `--user-data-dir=/tmp/chrome-*` profile and are
# supposed to self-exit via --virtual-time-budget, but they get orphaned when
# the parent session dies, then pile up and slow down launching your real Chrome.
#
# This ONLY targets headless instances. Your normal interactive Chrome is never
# matched, so it is safe to run any time.
#
#   ./reap-headless-chrome.sh          # show count, kill orphans, clean /tmp profiles
#   ./reap-headless-chrome.sh --dry-run # just report, kill nothing
set -e

DRY_RUN=0
[ "$1" = "--dry-run" ] || [ "$1" = "-n" ] && DRY_RUN=1

count_headless() {
  pgrep -fl "Google Chrome.*--headless" 2>/dev/null | grep -v "pgrep" | wc -l | tr -d ' '
}

BEFORE="$(count_headless)"
echo "Orphaned headless Chrome processes: $BEFORE"

if [ "$BEFORE" -eq 0 ]; then
  echo "Nothing to reap."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "(dry run) Would kill the above and remove /tmp/chrome-* profiles. Matched commands:"
  pgrep -fl "Google Chrome.*--headless" | sed 's/^/  /' | cut -c1-120
  exit 0
fi

# TERM first, give them a moment, then KILL any stragglers.
pkill -f "Google Chrome.*--headless" 2>/dev/null || true
sleep 2
pkill -9 -f "Google Chrome.*--headless" 2>/dev/null || true

# Throwaway profiles these instances used.
rm -rf /tmp/chrome-* 2>/dev/null || true

AFTER="$(count_headless)"
echo "Reaped $((BEFORE - AFTER)). Remaining headless: $AFTER"
[ "$AFTER" -eq 0 ] && echo "Clean. Your real Chrome will launch normally now." || echo "Some survived — re-run, or check 'pgrep -fl \"Google Chrome\"'."
