// MRE harness for flutter/flutter#191168
//
// Production crash signature this tries to reproduce:
//   FORTIFY: pthread_mutex_lock called on a destroyed mutex
//   ... qglinternal::vkDestroyFramebuffer ... (SIGABRT)
//   or SIGSEGV (SEGV_MAPERR) at the same site on other driver builds.
//   Crashed thread: main (platform) thread, inside Looper::pollOnce.
//
// Conditions observed in production (Sentry thread dumps + analytics):
//   1. App is BACKGROUNDED (no foreground lifecycle events for 8-19 hours).
//   2. Background tasks run on a 6h periodic + a self-rescheduling one-off.
//      Each Android task execution creates a fresh FlutterEngine and destroys
//      it on completion. Crashed processes show engine thread names like
//      "3.raster" with no "1.raster"/"2.raster", i.e. earlier engines
//      (including the UI engine) were already destroyed. One process reached
//      engine number 6.
//   3. Every engine (headless included) had live IplrVkFenceWait/IplrVkResMgr
//      threads, i.e. its own Impeller Vulkan context.
//   4. Each background task rendered 8-16 offscreen widget snapshots, every
//      one of which allocates a real VkFramebuffer in that engine's context.
//
// This harness is FRAMEWORK-ONLY: no pub packages and no added Gradle
// dependencies. Android's JobScheduler drives the cycles and the Flutter
// embedding API drives the engines, which is the layer workmanager reached
// through androidx.work anyway. Every mechanism is annotated in-code with the
// production behaviour it mirrors.
//
// One background cycle:
//   - JobScheduler starts ChurnJobService, which spawns a FRESH FlutterEngine
//     with its own Impeller Vulkan context.
//   - That engine runs [backgroundMain], which renders [rendersPerCycle]
//     offscreen snapshots at the production sizes and pixel ratios.
//   - The service tells the scheduler the job is done, THEN destroys the
//     engine on a later main-looper turn, racing any raster work still queued.
//
// Compressed cadence: what production took 8-19h to reach, churn.sh reaches in
// minutes by forcing job starts and freezing the process in between.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'offscreen_render.dart';

const _uiChannel = MethodChannel('vk_churn/ui');
const _bgChannel = MethodChannel('vk_churn/bg');

const int rendersPerCycle =
    12; // production: 8-16 renderFlutterWidget calls per task

// Escalation knob: when true, the LAST render is not awaited, so a raster
// snapshot is still in flight when 'done' resolves and the deferred destroy
// lands. Default false for deterministic cycles.
const bool leaveLastRenderInFlight = false;

/// Entry point for the per-task background engine spawned by ChurnJobService.
///
/// Mirrors the production Dart background task: it is handed its input over a
/// method channel, does the widget-render work, then reports completion, which
/// is what triggers the engine destroy on the platform side.
@pragma('vm:entry-point')
Future<void> backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  _bgChannel.setMethodCallHandler((call) async {
    if (call.method == 'stopped') {
      debugPrint('[vk-churn] onStopJob notified Dart mid-task (cancel path)');
    }
  });
  final Map<dynamic, dynamic> task = await _bgChannel.invokeMethod('ready');
  final int cycle = task['cycle'] as int;
  // Production sizes/pixel ratios from the app's widget render call sites.
  const specs = <(Size, double)>[
    (Size(360, 170), 3.0),
    (Size(360, 382), 2.0),
    (Size(360, 160), 3.0),
  ];
  var bytesTotal = 0;
  for (var i = 0; i < rendersPerCycle; i++) {
    final (size, ratio) = specs[i % specs.length];
    // Each call allocates a real VkFramebuffer in THIS engine's Impeller
    // Vulkan context via Scene.toImage on the raster thread.
    final future = renderOffscreen(
      probeWidget('cycle $cycle #$i'),
      logicalSize: size,
      pixelRatio: ratio,
    );
    if (leaveLastRenderInFlight && i == rendersPerCycle - 1) {
      unawaited(future);
    } else {
      bytesTotal += (await future).length;
    }
  }
  debugPrint(
    '[vk-churn] cycle=$cycle rendered=$rendersPerCycle pngBytes=$bytesTotal',
  );
  await _bgChannel.invokeMethod('done');
}

/// Entry point for the long-lived headless engine, spawned on demand from the
/// UI.
@pragma('vm:entry-point')
Future<void> residentMain() async {
  // Mirror of the production app's second long-lived headless engine
  // (created once, NEVER destroyed): a second live Impeller Vulkan context.
  WidgetsFlutterBinding.ensureInitialized();
  var n = 0;
  Future<void> renderOnce() async {
    n++;
    final png = await renderOffscreen(
      probeWidget('resident #$n'),
      logicalSize: const Size(360, 170),
      pixelRatio: 3.0,
    );
    debugPrint('[vk-churn] resident render #$n (${png.length} bytes)');
  }

  await renderOnce();
  // Timer does not fire while the process is frozen; that is fine.
  Timer.periodic(const Duration(minutes: 1), (_) => renderOnce());
}

/// The thing every engine rasterises: gradient, rounded corners, a shadow and
/// text.
///
/// Deliberately real raster work rather than a solid colour, and deliberately
/// no MaterialApp: renderOffscreen supplies the Directionality, and a
/// background engine has no business building an app shell. The expand
/// constraint makes the snapshot fill the requested logical size, so the
/// output really is at the production pixel dimensions.
Widget probeWidget(String label) {
  return Container(
    constraints: const BoxConstraints.expand(),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Colors.deepOrange, Colors.indigo],
      ),
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [BoxShadow(blurRadius: 30, color: Colors.black38)],
    ),
    child: Text(
      label,
      style: const TextStyle(color: Colors.white, fontSize: 20),
    ),
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChurnApp());
}

class ChurnApp extends StatelessWidget {
  const ChurnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(title: 'vk churn repro', home: ChurnHome());
  }
}

class ChurnHome extends StatefulWidget {
  const ChurnHome({super.key});

  @override
  State<ChurnHome> createState() => _ChurnHomeState();
}

class _ChurnHomeState extends State<ChurnHome>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();
  bool _churning = false;
  bool _resident = false;
  int? _lastCycle;

  Future<void> _startChurn() async {
    await _uiChannel.invokeMethod('startChurn');
    setState(() => _churning = true);
  }

  Future<void> _spawnResident() async {
    await _uiChannel.invokeMethod('spawnResident');
    setState(() => _resident = true);
  }

  Future<void> _refreshStatus() async {
    final int cycle = await _uiChannel.invokeMethod('getStatus') as int;
    if (!mounted) return;
    setState(() => _lastCycle = cycle);
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('flutter#191168 churn harness')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Continuous raster work: keeps the UI engine's swapchain and
            // framebuffers hot until the app is backgrounded.
            RotationTransition(
              turns: _spin,
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Colors.deepOrange, Colors.indigo],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(blurRadius: 30, color: Colors.black38),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              _churning
                  ? 'Churn armed: press HOME now.\n'
                        'A background engine spawns, renders $rendersPerCycle '
                        'snapshots and dies every ~20s.\n'
                        'Watch: adb logcat -s vk-churn flutter'
                  : 'Tap start, then background the app.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _churning ? null : _startChurn,
              child: Text(_churning ? 'Churn running' : 'Start churn burst'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _resident ? null : _spawnResident,
              child: Text(
                _resident ? 'Resident engine live' : 'Spawn resident engine',
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _lastCycle == null
                  ? 'Last completed cycle: unknown'
                  : 'Last completed cycle: $_lastCycle',
            ),
            TextButton(
              onPressed: _refreshStatus,
              child: const Text('Refresh status'),
            ),
          ],
        ),
      ),
    );
  }
}
