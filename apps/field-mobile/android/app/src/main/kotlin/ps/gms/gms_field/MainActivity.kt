package ps.gms.gms_field

import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity is required by local_auth (BiometricPrompt).
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Monotonic clock evidence for the server's capture-time check (BR-24): elapsed time since boot
        // cannot be changed by the user, unlike the wall clock.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ps.gms/clock").setMethodCallHandler { call, result ->
            if (call.method == "evidence") {
                val boots = try { Settings.Global.getInt(contentResolver, Settings.Global.BOOT_COUNT) } catch (e: Exception) { -1 }
                result.success(mapOf(
                    "elapsed_ms" to SystemClock.elapsedRealtime(),
                    "boot_id" to if (boots >= 0) "boot-$boots" else null,
                ))
            } else {
                result.notImplemented()
            }
        }
    }
}
