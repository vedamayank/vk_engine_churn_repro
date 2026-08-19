#!/usr/bin/env bash
# v2 stress loop for flutter/flutter#191168. Run AFTER: app opened,
# "Start churn burst" tapped (optionally "Spawn resident engine"), HOME pressed.
#
# MODE=freeze         freeze dwell between cycles (production-shaped: the next
#                     forced job START is what thaws the process)
# MODE=trim           trim-memory pressure only
# MODE=both (default) trim + freeze
# MODE=timeout-cancel force onStopJob: engine destroyed MID-render
# FREEZE_SEC (15)     frozen dwell per cycle
# WORK_SEC (6)        seconds given to renders+destroy; 1-2 = act mid-render
set -uo pipefail

PKG=${PKG:-app.vedapath.vk_engine_churn_repro}
CYCLES=${1:-60}; MODE=${MODE:-both}; FREEZE_SEC=${FREEZE_SEC:-15}; WORK_SEC=${WORK_SEC:-6}
JOB_ID=191168

# Dump everything useful about a death. Tombstones are unreadable on user
# builds, so the dropbox copy is the one that actually works there.
dump_crash() {
  echo "--- crash buffer ---"
  adb logcat -d -b crash 2>/dev/null | tail -120
  echo "--- dropbox native crash ---"
  adb shell dumpsys dropbox --print data_app_native_crash 2>/dev/null | tail -100
  echo "--- tombstones (best effort, usually denied on user builds) ---"
  adb shell "ls -t /data/tombstones 2>/dev/null | head -3" 2>/dev/null || true
}

adb logcat -c >/dev/null 2>&1 || true
LAST_PID=$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
if [ -z "${LAST_PID:-}" ]; then
  echo "WARNING: $PKG is not running. Open the app, tap Start churn burst, press HOME."
fi
echo "Stressing $PKG for $CYCLES cycles (mode=$MODE work=${WORK_SEC}s freeze=${FREEZE_SEC}s), pid=$LAST_PID"

for i in $(seq 1 "$CYCLES"); do
  # Force the queued job to run NOW. Deliberately WITHOUT unfreezing first:
  # in production nothing thaws the process either, the job start itself is
  # what wakes it. Keeping that order preserves the wake path under test.
  RUN_OUT=$(adb shell cmd jobscheduler run -f "$PKG" "$JOB_ID" 2>&1 | tr -d '\r')
  if printf '%s' "$RUN_OUT" | grep -qiE "error|fail|unable|no such"; then
    echo "forced run refused; thawing explicitly and retrying (deviation from production wake path)"
    echo "  scheduler said: $RUN_OUT"
    adb shell am unfreeze "$PKG" >/dev/null 2>&1 || true
    adb shell cmd jobscheduler run -f "$PKG" "$JOB_ID" >/dev/null 2>&1 || true
  fi

  # Give the engine its renders and its deferred destroy. Cut this to 1-2s to
  # land the next action while raster work is still in flight.
  sleep "$WORK_SEC"

  case "$MODE" in
    timeout-cancel)
      # Drives ChurnJobService.onStopJob: engine destroyed mid-task with the
      # job left unresolved. Argument shape varies by Android build, so try
      # the explicit job id first and fall back to the package-wide form.
      if ! adb shell cmd jobscheduler timeout "$PKG" "$JOB_ID" >/dev/null 2>&1; then
        adb shell cmd jobscheduler timeout "$PKG" >/dev/null 2>&1 || true
      fi
      ;;
    trim)
      adb shell am send-trim-memory "$PKG" RUNNING_CRITICAL >/dev/null 2>&1 || true
      ;;
    freeze|both)
      if [ "$MODE" = "both" ]; then
        adb shell am send-trim-memory "$PKG" RUNNING_CRITICAL >/dev/null 2>&1 || true
      fi
      # The freezer is what production got for free over an 8-19h dwell.
      if ! adb shell am freeze "$PKG" >/dev/null 2>&1; then
        sleep 2
        if ! adb shell am freeze "$PKG" >/dev/null 2>&1; then
          echo "  freeze refused (process still bound to the running job?)"
        fi
      fi
      sleep "$FREEZE_SEC"
      ;;
  esac

  # Validation-layer evidence. Debug builds only; release ships no layer.
  VERRS=$(adb logcat -d 2>/dev/null | grep -cE "Validation Error|VUID-")
  if [ "${VERRS:-0}" -gt 0 ]; then
    echo "VULKAN VALIDATION: $VERRS matching lines so far, last 20:"
    adb logcat -d 2>/dev/null | grep -E "Validation Error|VUID-" | tail -20
  fi

  # Crash detection by PID CHANGE, not just absence: JobScheduler respawns the
  # process for the queued next cycle, so "a process exists" proves nothing.
  PID=$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
  if [ -z "${PID:-}" ] || [ "${PID:-}" != "${LAST_PID:-}" ]; then
    echo "PROCESS DIED after cycle $i (pid ${LAST_PID:-none} -> ${PID:-none})"
    dump_crash
    if [ -z "${PID:-}" ]; then
      exit 0
    fi
    LAST_PID=$PID
    echo "respawned; continuing"
    continue
  fi
  echo "cycle $i ok (pid $PID)"
done

echo "No crash after $CYCLES cycles."
echo "Escalate per README: WORK_SEC=1, MODE=timeout-cancel, spawn the resident"
echo "engine, then an overnight unforced soak."
