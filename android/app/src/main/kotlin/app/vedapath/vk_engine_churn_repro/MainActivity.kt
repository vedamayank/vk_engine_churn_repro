package app.vedapath.vk_engine_churn_repro

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

// Mirror of the production app's long-lived headless engine: created once on
// the main thread, NEVER destroyed - a second live Impeller Vulkan context for
// the whole soak. Process-wide so it survives Activity death
// ("Don't keep activities").
object ResidentEngine {
    var engine: FlutterEngine? = null

    fun spawn(context: Context) {
        if (engine != null) return
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) loader.startInitialization(context)
        loader.ensureInitializationCompleteAsync(context, null, Handler(Looper.getMainLooper())) {
            engine = FlutterEngine(context).also {
                it.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "residentMain")
                )
            }
            Log.i("vk-churn", "resident engine spawned (never destroyed)")
        }
    }
}

class MainActivity : FlutterActivity() {
    // The three harness actions the foreground UI drives. Everything they do
    // happens on the application context, so nothing is tied to this Activity
    // surviving.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vk_churn/ui")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startChurn" -> {
                        ChurnJobService.scheduleCycle(applicationContext, 1, 10_000L)
                        result.success(null)
                    }
                    "spawnResident" -> {
                        ResidentEngine.spawn(applicationContext)
                        result.success(null)
                    }
                    "getStatus" ->
                        result.success(
                            getSharedPreferences("churn", MODE_PRIVATE).getInt("last_cycle", 0)
                        )
                    else -> result.notImplemented()
                }
            }
    }
}
