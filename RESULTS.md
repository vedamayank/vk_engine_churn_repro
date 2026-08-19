# Device verification results

Harness: v2 (plugin-free, framework `JobScheduler` + Flutter embedding API only).
Ladder per README; recorded as run.

## Device

| | |
|---|---|
| Model | OnePlus 10 Pro (NE2211) |
| OS | Android 16 (SDK 36), OxygenOS |
| GPU | Adreno (`ro.hardware.egl=adreno`), Vulkan driver `0615.100`, driver build 2025-08-06 |
| Vulkan | 1.1 (feature `android.hardware.vulkan.version=4198400`) |
| Relevance | Same brand and `qglinternal` Adreno driver family as two crashing field models (CPH2707, CPH2487); same OS major (Android 16) as most field events |

## L0 mechanics (2026-08-19, release build): PASS

- **Backend**: `Using the Impeller rendering backend (Vulkan).` logged per engine; Adreno driver loaded from `/vendor/lib64/hw/vulkan.adreno.so`. The code path under test is live (an emulator falls back to GLES and never reaches it).
- **Churn cycle, full sequence observed** (cycle 2 shown; 10+ cycles ran):
  `onStartJob cycle=2 (main=true)` -> per-engine AdrenoVK + Impeller Vulkan init -> `cycle=2 rendered=12 pngBytes=1711465` -> `scheduled cycle=3` -> engine destroy on a later main-looper turn.
- **Production thread signature reproduced**: each cycle's engine appears as a fresh `N.raster`/`N.io` + `IplrVkFenceWait`/`IplrVkResMgr` pair and vanishes on destroy while older numbers stay dead; numbering climbed past 6 with predecessors gone, matching the field dumps ("only `3.raster` alive").
- **Resident engine**: spawned once, never destroyed, renders every 60s (`resident render #1..#3`, ~188KB PNG each), holds a second live Impeller Vulkan context alongside the churn, matching production's claim engine.
- **Render path is a true replica**: zero `implicitView NULL` fallback lines across 10+ churn cycles and all resident renders. `PlatformDispatcher.implicitView` exists in `executeDartEntrypoint` background engines, so the harness runs the exact `home_widget` RenderView pipeline, not the weaker Picture fallback.
- **Both destroy orderings exercised naturally**: this device's OS (OxygenOS under thermal load) stops background jobs 2-3s into execution, so most cycles hit `onStopJob` = the mid-task cancel destroy, on top of the happy-path deferred destroy. The cancel race the ladder saves for L3 fires organically here.
- **No crash** across L0 (expected; L0 is mechanics, not volume).

Operational notes for reproducers:
- OEM log buffer was 256 KiB and silently swallowed all evidence; `adb logcat -G 16M` first.
- `cmd jobscheduler run -f <pkg> 191168` executes even while the scheduler reports `Restricted due to: thermal.`; unforced scheduled cycles stall under that restriction until the app is foregrounded or the device cools.
- A secure lockscreen blocks UI taps only; job forcing, freezing, and rendering all run with the screen off and locked.

## L1 freeze stress (release build): PASS, no crash in 60 cycles

- 40 cycles `MODE=freeze FREEZE_SEC=15 WORK_SEC=6` + 20 cycles mid-render freeze (`WORK_SEC=1`).
- Every cycle verified via logcat: 60/60 `onStartJob`, 59/60 completed all 12 renders (1 cancelled mid-render), and because this OS stops the job 2-3s in, nearly every cycle exercised the mid-task cancel destroy on top of the happy-path deferred destroy.
- Thermal note: the freeze dwell keeps the device at thermal status 0 throughout.

## L2 debug + validation layer: **CRASH REPRODUCED, twice, 2-for-2 process generations**

Debug build (`EnableVulkanValidation`, stock flutter.jar Khronos layer), Flutter 3.47.0, engine `5f77625673248ee`, debug libflutter BuildID `1c5fc93e80023564cffa6a75977aefac85c8195d`.

**Crash 1** (11:15:12 IST): the FIRST unforced churn cycle after arming. SIGABRT, main thread, inside `Looper::pollOnce`, abort raised from `libVkLayer_khronos_validation.so` beneath 14 libflutter frames (Impeller treats validation errors as fatal in debug). Full tombstone in `evidence/dropbox_native_crashes.txt`.

**Crash 2** (11:16:43 IST, respawned process, cycle 5): timestamped mechanism, end to end:

```
11:16:42.881  mid-task destroy executing for cycle=5        (onStopJob cancel path)
11:16:43.108  VALIDATION: vkDestroyDevice(): Object Tracking - For VkDevice
              0xb4000071c636fce0[ImpellerDevice], VkRenderPass 0xaa00000000aa[LinearGradient]
              has not been destroyed.   [VUID-vkDestroyDevice-device-05137]
11:16:43.109  VALIDATION: ... VkFramebuffer 0xab00000000ab has not been destroyed. (same VUID)
11:16:43.138  SIGSEGV SEGV_MAPERR, main thread, pc = wild jump through the destroyed
              device's dispatch, inside Looper::pollOnce
```

The leaked children named by the validation layer, a `VkFramebuffer` + `VkRenderPass` pair, are exactly what `TextureSourceVK::frame_data_` caches.

**Symbolized crash chain** (identical addresses in both crashes; `evidence/l2_stack_symbolized.txt`; symbols BuildID-verified):

```
fml::MessageLoopAndroid::$_0::__invoke (message_loop_android.cc:39)
fml::MessageLoopImpl::FlushTasks (message_loop_impl.cc:122)
std::function destroy (an undelivered task being destroyed)
Picture::DoRasterizeToImage raster->UI result lambda dtor (picture.cc:266)   <- captures shared_ptr<impeller::Texture>
impeller::TextureVK::~TextureVK (texture_vk.cc:25)
std::vector<TextureSourceVK::CachedFrameDataEntry>::~vector                  <- frame_data_
TextureSourceVK::CachedFrameDataEntry::~CachedFrameDataEntry (texture_source_vk.h:169)
__release_shared -> SharedHandleVK deleter -> vkDestroyFramebuffer/RenderPass on dead device
```

This is frame-for-frame the stack of the fully-symbolicated production occurrence on Flutter 3.44.8 (`picture.cc:244` there; `frame_data_` is `std::array<FramebufferAndRenderPass, 2>` at that revision, `std::vector<CachedFrameDataEntry>` on current engines). Same member, same lambda, same destruction order, two Flutter versions.

Evidence files: `evidence/dropbox_native_crashes.txt` (both tombstones), `evidence/l2_crash_buffer.txt`, `evidence/l2_harness_log.txt` (harness-process log incl. full validation output), `evidence/l2_stack_symbolized.txt`. Logs are filtered to the harness process.

## L3 timeout-cancel race: subsumed by L2

The reproducing sequence IS the cancel race: crash 2 followed a mid-task `onStopJob` destroy by 257ms, and this OS fires that path naturally. A dedicated `MODE=timeout-cancel` run adds nothing the L2 evidence lacks.

## L4 soak: optional

Only remaining value: catching the release-build variant where the DRIVER (not the validation layer) trips over the dead device, for perfect production parity. Release survived 60 freeze cycles; the debug repro suggests `MODE=both` overnight on release is the best shot. Not required for the upstream report.
