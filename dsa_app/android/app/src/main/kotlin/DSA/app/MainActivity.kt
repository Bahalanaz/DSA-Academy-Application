package DSA.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Account > Notification Settings: opens this app's notification
        // settings, where a family can turn notifications back on after
        // saying no (Android stops showing the "Allow?" question after a
        // couple of refusals), or turn them off.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsa/settings")
            .setMethodCallHandler { call, result ->
                // Home's "A new version is available": opens the download
                // link in the phone's browser. Only https links are opened.
                if (call.method == "openUrl") {
                    val url = call.argument<String>("url") ?: ""
                    if (!url.startsWith("https://")) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "openNotificationSettings") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val intent =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    } else {
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName"),
                        )
                    }
                try {
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
    }
}
