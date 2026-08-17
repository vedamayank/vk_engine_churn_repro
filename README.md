# vk_engine_churn_repro

MRE harness for [flutter/flutter#191168](https://github.com/flutter/flutter/issues/191168):
`SIGABRT`/`SIGSEGV` in `vkDestroyFramebuffer` (Impeller Vulkan) on Android.

## What production data shows

All 9 production occurrences (7 device models, Mali and Adreno) share these conditions:

1. The app had been **backgrounded for hours** (8h to 19h measured; no foreground lifecycle events in between).
2. The app runs **Workmanager background tasks** (a 6h periodic refresh plus a one-off that
   re-schedules itself from inside the background isolate).
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

Working hypothesis: a deferred framebuffer destruction runs on the platform thread against a
`VkDevice` that engine teardown already destroyed. Multi-engine churn while backgrounded
(plus OS resource reclamation during long dwell) makes the window hittable.

## What this harness does

- Foreground: continuous animation, so the UI engine holds a live swapchain and framebuffers.
- "Start churn burst": arms a self-rescheduling Workmanager one-off task
  (the same pattern and plugin version the production app uses). After you background the app,
  a background `FlutterEngine` spawns and dies every ~20s, up to 200 cycles.
- `churn.sh` adds the OS-side pressure that otherwise needs an overnight dwell:
  forced job runs and `am send-trim-memory RUNNING_CRITICAL`.

## Repro steps

Requires a **physical** Vulkan-capable Android device (Impeller falls back to GLES on most
emulators, which sidesteps the crashing code path entirely). Production hits were on:
realme RMX5003 / RMX5033 / RMX3999, Samsung SM-A146P (all Mali), OnePlus CPH2707 / CPH2487,
Samsung SM-S906U (all Adreno). Android 15 and 16.

```bash
flutter run --release   # release: matches production; debug also works
```

1. Tap **Start churn burst**.
2. Press HOME (do not swipe the app away).
3. Run `./churn.sh` from this directory.
4. Watch `adb logcat | grep vk-churn` for background cycles, and
   `adb logcat -b crash` / `/data/tombstones` for the SIGABRT.

Escalation variants, in order of aggressiveness:

- Developer options > **Don't keep activities**: backgrounding destroys the Activity and its
  Android surface immediately, forcing the UI engine's swapchain teardown path on every HOME press.
  Then foreground/background the app between churn cycles.
- Open 2 or 3 GPU-heavy apps (camera, a game) while churning, to force real GPU memory reclaim.
- Leave the churn running backgrounded for a few hours (production cadence needed 8h+; the
  compressed cycle should shrink that substantially since each cycle is one engine create/destroy).

To surface the invalid Vulkan call deterministically rather than waiting for the driver to trip on
it, enable the Khronos validation layer for the app:

```bash
adb shell settings put global enable_gpu_debug_layers 1
adb shell settings put global gpu_debug_app <applicationId>
adb shell settings put global gpu_debug_layers VK_LAYER_KHRONOS_validation
```

(validation layer libs must be present on the device or packaged in the APK).

## What to observe

- Engine churn is visible live: `adb shell ps -T $(adb shell pidof <applicationId>) | grep -E "raster|IplrVk"`.
  The `N.raster` number climbing while old ones disappear is the production signature.
- Crash signature to match: main thread, `Looper::pollOnce` -> (libflutter.so frames) ->
  `vkDestroyFramebuffer` -> destroyed-mutex abort inside the driver.
