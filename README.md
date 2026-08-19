# vk_engine_churn_repro

MRE harness for [flutter/flutter#191168](https://github.com/flutter/flutter/issues/191168):
`SIGABRT`/`SIGSEGV` in `vkDestroyFramebuffer` (Impeller Vulkan) on Android.

## 1. What this reproduces

All 9 production occurrences (7 device models, Mali and Adreno) share these conditions:

1. The app had been **backgrounded for hours** (8h to 19h measured; no foreground lifecycle events in between).
2. The app runs **background tasks** (a 6h periodic refresh plus a one-off that re-schedules itself from
   inside the background isolate).
   On Android each task execution creates a fresh `FlutterEngine` and destroys it on completion.
3. Crashed thread dumps show **engine churn**: processes with only `3.raster` alive
   (engines 1 and 2, including the UI engine, already destroyed), or `1.raster`/`2.raster`/`6.raster`
   alive (engines 3 to 5 already destroyed).
4. Every engine, headless ones included, had its own Impeller Vulkan context
   (`IplrVkFenceWait`/`IplrVkResMgr` thread pairs per engine).
5. The crash fires on the **main (platform) thread inside `Looper::pollOnce`**, in
   `vkDestroyFramebuffer`, with the driver's device-level mutex already destroyed
   (`FORTIFY: pthread_mutex_lock called on a destroyed mutex`), while the app is still backgrounded.
   One crash landed 5 minutes after the app's self-scheduled 00:10-local background task fired.
6. Each background task rendered 8-16 offscreen widget snapshots, one `VkFramebuffer` allocation each,
   inside the short-lived engine that was about to be destroyed.

Working hypothesis: a deferred framebuffer destruction runs on the platform thread against a
`VkDevice` that engine teardown already destroyed.
Multi-engine churn while backgrounded (plus OS resource reclamation during long dwell) makes the
window hittable.

## 2. Zero third-party dependencies

v1 of this harness used the `workmanager` plugin.
This version uses none: `pubspec.yaml` depends only on `flutter`, and nothing was added to Gradle.

That costs nothing in fidelity, because `workmanager` wraps `androidx.work`, and `androidx.work`
wraps `JobScheduler`.
Talking to `JobScheduler` directly removes two wrappers and leaves the OS-visible engine lifecycle
identical.
Every mechanic below is annotated in-code with the exact plugin or production behaviour it mirrors,
including the two teardown orderings, the pre-completion reschedule, and the undisposed snapshot
image.

**NOTE:** the harness deliberately creates each background engine with plain
`FlutterEngine(applicationContext)` and never with `FlutterEngineGroup`.
Grouped engines share one `VkDevice`, so a grouped harness would never destroy a device while
another engine still holds resources against it.
The bug requires per-engine device teardown, which is what production had.

## 3. Anatomy

| File | Production mechanism mirrored |
|---|---|
| `android/.../ChurnJobService.kt` | `workmanager_android` 0.10.6 `BackgroundWorker`: loader init, fresh `FlutterEngine` per task on the main thread, named Dart entrypoint in place of `executeDartCallback`, next cycle rescheduled BEFORE completion, and both destroy orderings (happy path: `jobFinished` first then a posted `engine.destroy()`; cancel path: `onStopJob` destroys mid-task without resolving the job) |
| `lib/main.dart` `backgroundMain` + `lib/offscreen_render.dart` | `home_widget` 0.9.3 `renderFlutterWidget`, run 12 times per cycle at the production logical sizes and pixel ratios (360x170@3.0, 360x382@2.0, 360x160@3.0), including the parity leak: the produced `ui.Image` is never disposed, exactly as in the plugin, so it finalizes during engine teardown |
| `lib/main.dart` `residentMain` + `ResidentEngine` in `MainActivity.kt` | The production app's second long-lived headless engine: created once, never destroyed, holding a second live Impeller Vulkan context for the whole soak |
| `android/app/src/main/AndroidManifest.xml` | `io.flutter.embedding.android.ImpellerBackend=vulkan`, forcing the Vulkan backend for every engine in the process, in release too |
| `android/app/src/debug/AndroidManifest.xml` | `io.flutter.embedding.android.EnableVulkanValidation=true`, debug-only, so release stays production-parity |

## 4. Requirements

- A **physical** Vulkan-capable Android device.
  Impeller falls back to GLES on most emulators, which sidesteps the crashing code path entirely.
  Production hits were on realme RMX5003 / RMX5033 / RMX3999 and Samsung SM-A146P (all Mali),
  and OnePlus CPH2707 / CPH2487 and Samsung SM-S906U (all Adreno), on Android 15 and 16.
- **Android 14+** for the app-freezer levels `churn.sh` drives (`am freeze` / `am unfreeze`).
- **Flutter 3.47.0 stable** or newer.
- `adb` on PATH with the device authorised.

## 5. Run it

```bash
flutter run --release   # production parity: no validation layer, Impeller Vulkan forced
flutter run --debug     # same harness plus the Khronos validation layer
```

1. Tap **Start churn burst**.
2. Optionally tap **Spawn resident engine** to add the second, never-destroyed engine.
3. Press HOME (do not swipe the app away).
4. Run `./churn.sh` from this directory.
5. **Refresh status** in the app shows the last cycle that completed, if you foreground it again.

The debug build ships the validation layer automatically: the debug `android-arm64` `flutter.jar`
bundles `lib/arm64-v8a/libVkLayer_khronos_validation.so`, and the debug manifest turns it on.
No `adb shell settings put global gpu_debug_layers` dance is needed.

## 6. churn.sh modes

`./churn.sh [CYCLES]`, default 60 cycles.

| Variable | Default | What it stresses |
|---|---|---|
| `MODE=freeze` | | Frozen dwell between cycles. The closest compression of the production 8-19h background dwell. |
| `MODE=trim` | | `am send-trim-memory RUNNING_CRITICAL` only: OS-driven GPU and memory reclaim without the freezer. |
| `MODE=both` | default | Trim, then freeze. Reclaim plus dwell. |
| `MODE=timeout-cancel` | | Forces `onStopJob`, so the engine is destroyed mid-render with the job left unresolved. The nastiest ordering. |
| `FREEZE_SEC` | 15 | Frozen seconds per cycle. |
| `WORK_SEC` | 6 | Seconds the cycle gets for renders plus the deferred destroy. Set to 1 or 2 to act while raster work is still in flight. |
| `PKG` | `app.vedapath.vk_engine_churn_repro` | Target package. |

The loop deliberately does **not** unfreeze before forcing the job.
In production nothing thaws the process either; the job start is itself the wake.
If the scheduler refuses the forced run, the script says so, unfreezes explicitly, retries, and
labels that pass as a deviation from the production wake path.

## 7. What to observe

Engine churn, live:

```bash
adb shell ps -T $(adb shell pidof app.vedapath.vk_engine_churn_repro) | grep -E "raster|IplrVk"
```

The `N.raster` number climbing while older ones disappear, each with its own
`IplrVkFenceWait`/`IplrVkResMgr` pair, is the production signature.

Expected logcat, one block per cycle.
Note the two tags: the Kotlin side logs under `vk-churn`, and Dart `debugPrint` goes out under
`flutter`, so watch both.

```bash
adb logcat -s vk-churn flutter
```

```
vk-churn: onStartJob cycle=2 (main=true)
flutter : [vk-churn] cycle=2 rendered=12 pngBytes=...
vk-churn: scheduled cycle=3 (job=191168, delay=20000ms)
vk-churn: destroying engine for cycle=2 (deferred main-looper turn)
```

Crash signature to match: main thread, `Looper::pollOnce` -> libflutter.so frames ->
`vkDestroyFramebuffer` -> destroyed-mutex abort inside the driver, or `SIGSEGV` at the same site.

Validation evidence, debug builds only:

```bash
adb logcat -d | grep -E "Validation Error|VUID-"
```

`churn.sh` runs that grep every cycle and prints the last 20 matches when it is non-empty.

## 8. Escalation ladder

- **L0, mechanics check.**
  Run `MODE=trim ./churn.sh 5` and confirm the four log lines above appear per cycle and that the
  raster thread number climbs.
  If cycles do not fire, the rest of the ladder is measuring nothing.
- **L1, freeze stress.**
  `MODE=freeze ./churn.sh 40`, then a second pass with `WORK_SEC=1`.
  Confirm the freezer is really engaging: `adb shell dumpsys activity | grep -A5 "Apps frozen"`.
- **L2, debug plus validation.**
  `flutter run --debug`, same loop.
  `VUID-` lines naming a destroyed `VkDevice` or a framebuffer destroyed after its device are
  deterministic evidence even if the process never crashes, and are worth reporting on their own.
- **L3, timeout-cancel race.**
  `MODE=timeout-cancel WORK_SEC=1 ./churn.sh 40`, with the resident engine spawned.
  This destroys an engine while its raster thread is mid-snapshot, and is the most likely to trip.
  Pair it with `leaveLastRenderInFlight = true` in `lib/main.dart` for the widest window.
- **L4, overnight soak.**
  Tap start, press HOME, and leave it.
  The service chains itself every 20s with no `adb` involvement, which is the closest thing to the
  production cadence, just compressed.
  Collect with `adb logcat -d -b crash` and `adb shell dumpsys dropbox --print data_app_native_crash`
  in the morning.

## 9. Caveats

- **implicitView fallback.**
  A background `FlutterEngine` with no attached surface can have no implicit view, which is exactly
  where `home_widget` would throw on its `implicitView!`.
  `renderOffscreen` logs `implicitView NULL` and falls back to `Picture.toImage`, which still
  rasterises on the raster thread against the same Impeller context but skips the `RenderView` path.
  If you see that line every cycle, note it in any report: the workload is then a near-miss rather
  than an exact replica of the production pipeline.
- **`am freeze` refusals.**
  The freezer will not take while the process is bound to a running job.
  The script retries once and logs the refusal rather than pretending it froze.
- **`cmd jobscheduler timeout` syntax varies** across Android builds.
  The script tries `timeout <pkg> <job-id>` and falls back to `timeout <pkg>`.
  If both fail on your device, force the cancel path from the UI instead by swiping the app away
  mid-cycle.
- **Validation layer performance.**
  The layer is slow enough that 12 renders may not finish inside `WORK_SEC`.
  Raise `WORK_SEC`, or cut `rendersPerCycle` in `lib/main.dart` to 4.
  Also watch for `lowmemorykiller` lines in logcat: an OOM kill is a process death, but it is not
  this crash, and the PID-change detection in `churn.sh` will report both the same way until you
  read the dump.
- **Tombstones are unreadable on user builds.**
  `/data/tombstones` needs root.
  Use `adb shell dumpsys dropbox --print data_app_native_crash`, which `churn.sh` already does.
