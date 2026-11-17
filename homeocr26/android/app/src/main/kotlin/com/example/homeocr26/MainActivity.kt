package com.example.homeocr26

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.os.Build
import android.os.Bundle
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.content.FileProvider
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val hapticsChannel = "com.example.homeocr26/haptics"
    private val lifecycleChannel = "com.example.homeocr26/lifecycle"
    private val shareChannel = "com.example.homeocr26/share"

    override fun onCreate(savedInstanceState: Bundle?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            installSplashScreen().setOnExitAnimationListener { splashView ->
                splashView.remove()
            }
        }
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, hapticsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "vibrate") {
                    val durationMs = when (val raw = call.argument<Any>("durationMs")) {
                        is Int -> raw.toLong()
                        is Long -> raw
                        is Number -> raw.toLong()
                        else -> 250L
                    }.coerceIn(40L, 1500L)
                    val ok = vibratePhone(durationMs)
                    Log.i(TAG, "vibrate requested durationMs=$durationMs ok=$ok")
                    result.success(ok)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, lifecycleChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "moveToBackground") {
                    moveTaskToBack(true)
                    result.success(true)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "sharePdfToWhatsApp") {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "path required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(sharePdfToWhatsApp(path))
                    } catch (e: Exception) {
                        Log.e(TAG, "sharePdfToWhatsApp failed", e)
                        result.error("share_failed", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    /**
     * Opens WhatsApp (or Business) with a PDF attached.
     * Returns true when an activity was started.
     */
    private fun sharePdfToWhatsApp(path: String): Boolean {
        val file = File(path)
        if (!file.exists() || !file.isFile) {
            throw IllegalArgumentException("PDF file missing: $path")
        }
        val authority = "${applicationContext.packageName}.fileprovider"
        val uri = FileProvider.getUriForFile(this, authority, file)
        val packages = listOf("com.whatsapp", "com.whatsapp.w4b")
        for (pkg in packages) {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "application/pdf"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                setPackage(pkg)
            }
            try {
                startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
                // try next package
            }
        }
        return false
    }

    /** Returns true when the OS accepted a vibrate request. */
    private fun vibratePhone(durationMs: Long): Boolean {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            manager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

        if (!vibrator.hasVibrator()) {
            Log.w(TAG, "device reports no vibrator")
            return false
        }

        // Double buzz is easier to feel than a soft haptic click.
        val timings = longArrayOf(0L, durationMs, 60L, durationMs)
        val amplitudes = intArrayOf(0, 255, 0, 255)

        return try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                    // USAGE_NOTIFICATION is not muted when "Touch feedback" is off (Samsung).
                    vibrator.vibrate(
                        VibrationEffect.createWaveform(timings, amplitudes, -1),
                        VibrationAttributes.Builder()
                            .setUsage(VibrationAttributes.USAGE_NOTIFICATION)
                            .build(),
                    )
                    true
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                    val attrs = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(
                        VibrationEffect.createWaveform(timings, amplitudes, -1),
                        attrs,
                    )
                    true
                }
                else -> {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(timings, -1)
                    true
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "vibrate failed", e)
            false
        }
    }

    companion object {
        private const val TAG = "ScanHaptics"
    }
}
