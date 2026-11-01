package com.example.kisisel_asistan

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Parmak izi / yüz doğrulaması (local_auth) FragmentActivity ister.
// "alfred/guvenlik" kanalı: son uygulamalarda ve ekran görüntüsünde içeriği gizler (FLAG_SECURE).
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "alfred/guvenlik").setMethodCallHandler { call, result ->
            when (call.method) {
                "ekranGizle" -> {
                    val acik = call.argument<Boolean>("acik") ?: false
                    runOnUiThread {
                        if (acik) {
                            window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}