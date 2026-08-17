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
//   2. Workmanager background tasks run on a 6h periodic + a self-rescheduling
//      one-off. Each Android task execution creates a fresh FlutterEngine and
//      destroys it on completion. Crashed processes show engine thread names
//      like "3.raster" with no "1.raster"/"2.raster", i.e. earlier engines
//      (including the UI engine) were already destroyed. One process reached
//      engine number 6.
//   3. Every engine (headless included) had live IplrVkFenceWait/IplrVkResMgr
//      threads, i.e. its own Impeller Vulkan context.
//
// This harness compresses the production cadence (hours) into seconds:
//   - Foreground: continuous animation so the UI engine holds real
//     framebuffers/swapchain images.
//   - "Start churn burst": schedules a self-rescheduling one-off Workmanager
//     task that runs every ~20s for [_maxCycles] cycles. Background the app
//     after starting it; engines then spawn and die while the UI engine's
//     surface is torn down / trimmed by the OS.
//   - Combine with `adb shell am send-trim-memory <pkg> RUNNING_CRITICAL`
//     and/or Developer options > "Don't keep activities" to force the OS-side
//     resource reclamation that otherwise needs an overnight dwell.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

const String churnTaskId = 'vk-churn-task';
const int _maxCycles = 200;
const Duration _cycleDelay = Duration(seconds: 20);

/// Background entry point. Runs in a fresh background FlutterEngine per
/// execution on Android; the engine is destroyed when the task returns.
@pragma('vm:entry-point')
void churnDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    final int cycle = (inputData?['cycle'] as int?) ?? 0;
    debugPrint('[vk-churn] background cycle $cycle running '
        '(pid=$pid, engine spawned for this task)');
    // Small real workload so the engine lives long enough to finish
    // bringing up its Impeller context before teardown.
    await Future<void>.delayed(const Duration(seconds: 3));
    if (cycle < _maxCycles) {
      await Workmanager().registerOneOffTask(
        'vk-churn-unique', // same unique name: replace, like production's
        churnTaskId, //        self-rescheduling midnight rollover task
        initialDelay: _cycleDelay,
        existingWorkPolicy: ExistingWorkPolicy.replace,
        inputData: <String, dynamic>{'cycle': cycle + 1},
      );
    }
    return true;
  });
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChurnApp());
}

class ChurnApp extends StatelessWidget {
  const ChurnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'vk churn repro',
      home: ChurnHome(),
    );
  }
}

class ChurnHome extends StatefulWidget {
  const ChurnHome({super.key});

  @override
  State<ChurnHome> createState() => _ChurnHomeState();
}

class _ChurnHomeState extends State<ChurnHome>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();
  bool _churning = false;

  Future<void> _startChurn() async {
    await Workmanager().initialize(churnDispatcher);
    await Workmanager().registerOneOffTask(
      'vk-churn-unique',
      churnTaskId,
      initialDelay: const Duration(seconds: 10),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      inputData: <String, dynamic>{'cycle': 1},
    );
    setState(() => _churning = true);
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
                      'A background engine will spawn/die every '
                      '${_cycleDelay.inSeconds}s for $_maxCycles cycles.\n'
                      'Watch: adb logcat | grep vk-churn'
                  : 'Tap start, then background the app.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _churning ? null : _startChurn,
              child: Text(_churning ? 'Churn running' : 'Start churn burst'),
            ),
          ],
        ),
      ),
    );
  }
}
