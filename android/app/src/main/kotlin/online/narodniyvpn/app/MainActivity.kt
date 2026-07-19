package online.narodniyvpn.app

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.VpnService
import android.os.Bundle
import android.provider.Settings
import android.util.Base64
import androidx.annotation.NonNull
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity: FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    private val CHANNEL = "online.narodniyvpn.app/vpn"
    private val VPN_REQUEST_CODE = 100
    // Сохраняем конфиг временно, пока ждем разрешения от пользователя
    private var pendingConfig: String? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> {
                    val config = call.argument<String>("config")
                    if (config != null) {
                        pendingConfig = config
                        prepareAndStartVpn()
                        result.success("OK")
                    } else {
                        result.error("ERROR", "Config is null", null)
                    }
                }
                "stopVpn" -> {
                    val intent = Intent(this, MyVpnService::class.java)
                    intent.action = "STOP"
                    startService(intent)
                    result.success("STOPPED")
                }
                // --- НОВОЕ: Метод для проверки статуса из Flutter ---
                "checkState" -> {
                    // Возвращаем true, если сервис работает (переменная из MyVpnService)
                    result.success(MyVpnService.isServiceRunning)
                }
                // --- TRIAL: стабильный идентификатор устройства для бесплатного триала ---
                // Используем именно Settings.Secure.ANDROID_ID: он переживает переустановку
                // приложения (пока та же подпись), поэтому лимит триала нельзя обойти
                // простой переустановкой. НЕ генерируем свой UUID.
                "getAndroidId" -> {
                    try {
                        val androidId = Settings.Secure.getString(
                            contentResolver,
                            Settings.Secure.ANDROID_ID
                        )
                        result.success(androidId)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                // ----------------------------------------------------
                // ----------------------------------------------------
                "getInstalledApps" -> {
                    Thread {
                        try {
                            val pm = packageManager
                            val launchIntent = Intent(Intent.ACTION_MAIN, null).apply {
                                addCategory(Intent.CATEGORY_LAUNCHER)
                            }
                            val resolveInfoList = pm.queryIntentActivities(launchIntent, 0)
                            val apps = resolveInfoList
                                .filter { it.activityInfo.packageName != packageName }
                                .sortedBy { it.loadLabel(pm).toString().lowercase() }

                            val list = apps.map { resolveInfo ->
                                val label = resolveInfo.loadLabel(pm).toString()
                                val pkg = resolveInfo.activityInfo.packageName
                                val drawable = resolveInfo.loadIcon(pm)
                                val bitmap = drawableToBitmap(drawable)
                                val scaled = Bitmap.createScaledBitmap(bitmap, 48, 48, true)
                                val baos = ByteArrayOutputStream()
                                scaled.compress(Bitmap.CompressFormat.PNG, 100, baos)
                                val iconB64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
                                mapOf("packageName" to pkg, "appName" to label, "icon" to iconB64)
                            }
                            runOnUiThread { result.success(list) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ERROR", e.message, null) }
                        }
                    }.start()
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap {
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            return drawable.bitmap
        }
        val w = drawable.intrinsicWidth.coerceAtLeast(1)
        val h = drawable.intrinsicHeight.coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, w, h)
        drawable.draw(canvas)
        return bitmap
    }

    private fun prepareAndStartVpn() {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            // Если нужно разрешение пользователя, Android вернет Intent
            startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            // Если разрешение уже есть, запускаем сразу
            startVpnService()
        }
    }

    private fun startVpnService() {
        val configToStart = pendingConfig ?: return

        // --- НОВОЕ: Сохраняем конфиг для кнопки в шторке ---
        val prefs = getSharedPreferences("vpn_prefs", Context.MODE_PRIVATE)
        prefs.edit().putString("last_vpn_config", configToStart).apply()
        // ----------------------------------------------------

        val intent = Intent(this, MyVpnService::class.java)
        intent.action = "START"
        intent.putExtra("config", configToStart)
        startForegroundService(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_REQUEST_CODE && resultCode == RESULT_OK) {
            startVpnService()
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}