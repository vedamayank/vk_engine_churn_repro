#!/usr/bin/env bash
# Accelerated repro loop for flutter/flutter#191168.
# Run AFTER: app opened, "Start churn burst" tapped, HOME pressed.
set -uo pipefail

PKG=${PKG:-app.vedapath.vk_engine_churn_repro}
CYCLES=${1:-60}

echo "Stressing $PKG for $CYCLES cycles (forced job runs + trim-memory)..."
for i in $(seq 1 "$CYCLES"); do
  # Force the queued WorkManager job to run NOW instead of waiting out its
  # initialDelay. Job ids change on every enqueue, so resolve each pass.
  JOB=$(adb shell dumpsys jobscheduler 2>/dev/null \
        | grep -m1 -oE "JOB #u0a?[0-9]+/[0-9]+:[^ ]* $PKG" \
        | grep -oE "/[0-9]+" | tr -d '/') || true
  if [ -n "${JOB:-}" ]; then
    adb shell cmd jobscheduler run -f "$PKG" "$JOB" >/dev/null 2>&1 || true
  fi

  # OS-side memory/GPU reclaim that otherwise needs hours of background dwell.
  adb shell am send-trim-memory "$PKG" RUNNING_CRITICAL >/dev/null 2>&1 || true

  sleep 8

  if ! adb shell pidof "$PKG" >/dev/null 2>&1; then
    echo "Process not running after cycle $i (crashed, or OS killed it)."
    echo "--- recent crash buffer ---"
    adb logcat -d -b crash | tail -80
    echo "--- tombstones ---"
    adb shell "ls -t /data/tombstones 2>/dev/null | head -3" || true
    exit 0
  fi
  echo "cycle $i ok"
done
echo "No crash after $CYCLES cycles. Try the 'Don't keep activities' variant from the README."
