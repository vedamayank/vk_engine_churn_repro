package app.vedapath.vk_engine_churn_repro

// Framework-only replica of workmanager_android 0.10.6 BackgroundWorker.kt,
// which is what the production app used to run its background tasks.
//
// workmanager wraps androidx.work, and androidx.work wraps JobScheduler. This
// file cuts out both wrappers and talks to JobScheduler directly, so the repro
// needs no third-party package and no extra Gradle dependency, while the
// OS-visible FlutterEngine lifecycle stays exactly what production had:
//
//   job starts -> FlutterLoader init -> new FlutterEngine on the main thread
//   -> Dart entrypoint -> Dart reports done -> job resolved FIRST
//   -> engine.destroy() posted to a LATER main-looper turn.
//
// Every block below is annotated with the BackgroundWorker line it mirrors.
//
// Invariant that keeps the single `engine` member safe: all cycles use the same
// JOB_ID, so JobScheduler guarantees only one of them is in flight at a time.
// A new start cannot overwrite a live engine reference, exactly as one
// BackgroundWorker instance owned one engine.

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class ChurnJobService : JobService() {
    companion object {
        private const val TAG = "vk-churn"
        const val JOB_ID = 191168 // fixed: adb shell cmd jobscheduler run -f <pkg> 191168
        private const val EXTRA_CYCLE = "cycle"
        private const val MAX_CYCLES = 200
        private const val CYCLE_DELAY_MS = 20_000L

        // Same JOB_ID every time == ExistingWorkPolicy.replace, the production
        // self-rescheduling one-off pattern.
        fun scheduleCycle(context: Context, cycle: Int, delayMs: Long = CYCLE_DELAY_MS) {
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, ChurnJobService::class.java))
                .setMinimumLatency(delayMs)
                .setExtras(PersistableBundle().apply { putInt(EXTRA_CYCLE, cycle) })
                .build()
            context.getSystemService(JobScheduler::class.java).schedule(job)
            Log.i(TAG, "scheduled cycle=$cycle (job=$JOB_ID, delay=${delayMs}ms)")
        }
    }

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

    override fun onStartJob(params: JobParameters): Boolean {
        val cycle = params.extras.getInt(EXTRA_CYCLE, 0)
        Log.i(TAG, "onStartJob cycle=$cycle (main=${Looper.myLooper() == Looper.getMainLooper()})")
        // == BackgroundWorker.startWork: loader init, then async completion on
        //    the main handler; the callback body runs on the MAIN thread.
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) loader.startInitialization(applicationContext)
        loader.ensureInitializationCompleteAsync(
            applicationContext, null, Handler(Looper.getMainLooper())
        ) {
            // == engine = FlutterEngine(applicationContext): fresh engine, own
            //    Impeller Vulkan context (NOT FlutterEngineGroup: grouped
            //    engines share one VkDevice and the bug needs per-engine
            //    device teardown).
            val e = FlutterEngine(applicationContext)
            engine = e
            // Handler registered BEFORE Dart starts so 'ready' cannot race it.
            channel = MethodChannel(e.dartExecutor.binaryMessenger, "vk_churn/bg").apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        // == the backgroundChannelInitialized -> executeTask
                        //    handshake: hand Dart its task input as the reply.
                        "ready" -> result.success(mapOf("cycle" to cycle))
                        "done" -> {
                            result.success(null)
                            onDartDone(params, cycle)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
            // Production ran executeDartCallback(callbackHandle); a named
            // secondary entrypoint is the plugin-free equivalent.
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundMain")
            )
        }
        return true
    }

    // Happy path == BackgroundWorker.stopEngine(Result.success()). ORDER MATTERS.
    private fun onDartDone(params: JobParameters, cycle: Int) {
        // Production's Dart task re-registered the next one-off BEFORE completing.
        if (cycle < MAX_CYCLES) scheduleCycle(applicationContext, cycle + 1)
        getSharedPreferences("churn", MODE_PRIVATE).edit().putInt("last_cycle", cycle).apply()
        // (1) == completer.set(Result.success()): scheduler told "done" FIRST...
        jobFinished(params, false)
        // (2) == Handler(Looper.getMainLooper()).post { engine?.destroy() }:
        //     destroy runs on a LATER main-looper turn, racing any raster work
        //     still in flight. This is the crash-relevant ordering.
        Handler(Looper.getMainLooper()).post {
            Log.i(TAG, "destroying engine for cycle=$cycle (deferred main-looper turn)")
            engine?.destroy()
            engine = null
            channel = null
        }
    }

    // Timeout/cancel path == BackgroundWorker.onStopped: notify Dart, then
    // destroy WITHOUT resolving the job - destroy races an engine mid-task.
    // Trigger: adb shell cmd jobscheduler timeout <pkg> 191168
    override fun onStopJob(params: JobParameters): Boolean {
        val cycle = params.extras.getInt(EXTRA_CYCLE, 0)
        Log.w(TAG, "onStopJob cycle=$cycle: destroying engine MID-TASK (no jobFinished)")
        // Harness continuity only (not a production mirror): keep the chain alive.
        if (cycle < MAX_CYCLES) scheduleCycle(applicationContext, cycle + 1)
        val ch = channel
        if (ch != null) {
            ch.invokeMethod("stopped", null, object : MethodChannel.Result {
                override fun success(result: Any?) = postDestroy(cycle)

                override fun error(code: String, msg: String?, details: Any?) = postDestroy(cycle)

                override fun notImplemented() = postDestroy(cycle)
            })
        } else {
            postDestroy(cycle)
        }
        return false // we chained the next cycle ourselves above
    }

    private fun postDestroy(cycle: Int) {
        Handler(Looper.getMainLooper()).post { // == stopEngine's posted destroy
            Log.w(TAG, "mid-task destroy executing for cycle=$cycle")
            engine?.destroy()
            engine = null
            channel = null
        }
    }
}
