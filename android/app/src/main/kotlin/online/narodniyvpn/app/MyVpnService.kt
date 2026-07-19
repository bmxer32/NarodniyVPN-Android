package online.narodniyvpn.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.service.quicksettings.TileService
import android.util.Log
import androidx.core.app.NotificationCompat
import libv2ray.Libv2ray
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class MyVpnService : VpnService() {

    companion object {
        private const val TAG = "MyVpnService"

        const val ACTION_START = "START"
        const val ACTION_STOP = "STOP"

        private const val NOTIF_CHANNEL_ID = "vpn_channel"
        private const val NOTIF_CHANNEL_NAME = "VPN"
        private const val NOTIF_ID = 1

        private const val VPN_SESSION_NAME = "MyProVPN"
        private const val TUN_ADDR = "26.26.26.1"
        private const val TUN_PREFIX = 24
        private const val TUN_MTU = 1280

        // Настройки для tun2socks
        private const val TUN2SOCKS_IP = "26.26.26.2"
        private const val TUN2SOCKS_NETMASK = "255.255.255.0"

        private const val SOCKS_ADDR = "127.0.0.1"
        private const val SOCKS_PORT = 10808
        // HTTP порт зарезервирован, но для tun2socks нужен только SOCKS
        private const val HTTP_PORT = 10809

        // --- ДОБАВЛЕНО: Глобальный флаг состояния для Плитки (Tile) ---
        @Volatile
        var isServiceRunning: Boolean = false
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var coreController: CoreController? = null
    private var tun2socksWrapperProc: java.lang.Process? = null
    private val isRunning = AtomicBoolean(false)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START

        if (action == ACTION_STOP) {
            stopVpn("stop action")
            return START_NOT_STICKY
        }

        try {
            startAsForeground()
        } catch (t: Throwable) {
            Log.e(TAG, "startAsForeground failed", t)
        }

        val configJsonRaw = intent?.getStringExtra("config") ?: ""
        if (configJsonRaw.isBlank()) {
            Log.e(TAG, "Empty config; stop")
            stopVpn("empty config")
            return START_NOT_STICKY
        }

        if (isRunning.getAndSet(true)) {
            Log.w(TAG, "VPN already running; ignoring START")
            return START_STICKY
        }

        // --- ДОБАВЛЕНО: Обновляем статус для плитки ---
        isServiceRunning = true
        requestTileUpdate()
        // ----------------------------------------------

        thread(name = "vpn-start") {
            try {
                startVpnInternal(configJsonRaw)
            } catch (t: Throwable) {
                Log.e(TAG, "startVpn error", t)
                stopVpn("start error")
            }
        }

        return START_STICKY
    }

    override fun onDestroy() {
        stopVpn("service destroyed")
        super.onDestroy()
    }

    private fun startVpnInternal(configJsonRaw: String) {
        Log.d(TAG, "=== START VPN (FULL TUNNEL via tun2socks FD-bridge) ===")

        // 1. Создаем TUN интерфейс
        val pfd = setupTun()
        vpnInterface = pfd

        // 2. Запускаем ядро Xray/V2Ray
        val configJson = sanitizeXrayConfig(configJsonRaw)
        startV2Ray(configJson)

        Log.d(TAG, "Ждем поднятия порта $SOCKS_PORT...")
        val isReady = waitForPort(SOCKS_PORT, maxAttempts = 25)

        if (!isReady) {
            Log.e(TAG, "Ядро Xray не успело запустить порт $SOCKS_PORT! Отменяем запуск.")
            stopVpn("Xray start timeout")
            return
        }
        
        Log.d(TAG, "Порт $SOCKS_PORT доступен! Запускаем tun2socks.")

        // 3. Запускаем tun2socks и передаем ему FD
        try {
            startTun2SocksWrapperAndSendFd(pfd)
            Log.d(TAG, "VPN started successfully.")
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка запуска tun2socks", e)
            stopVpn("tun2socks error")
        }
    }

    private fun waitForPort(port: Int, maxAttempts: Int): Boolean {
        for (i in 1..maxAttempts) {
            try {
                val socket = java.net.Socket()
                socket.connect(java.net.InetSocketAddress("127.0.0.1", port), 100)
                socket.close()
                return true
            } catch (_: Throwable) {
                try { Thread.sleep(200) } catch (_: Throwable) {}
            }
        }
        return false
    }

    private fun setupTun(): ParcelFileDescriptor {
        val builder = Builder()
            .setSession(VPN_SESSION_NAME)
            .setMtu(TUN_MTU)
            .addAddress(TUN_ADDR, TUN_PREFIX)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")

        // Само приложение всегда идёт напрямую (иначе VPN будет туннелировать сам себя)
        try {
            builder.addDisallowedApplication(packageName)
        } catch (t: Throwable) {
            Log.w(TAG, "addDisallowedApplication failed (ignored)", t)
        }

        // Раздельный трафик: исключаем приложения выбранные пользователем
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val excludedJson = prefs.getString("flutter.split_tunnel_excluded", "[]") ?: "[]"
        try {
            val excludedApps = JSONArray(excludedJson)
            for (i in 0 until excludedApps.length()) {
                val pkg = excludedApps.getString(i)
                try {
                    builder.addDisallowedApplication(pkg)
                    Log.d(TAG, "Split tunnel: excluding $pkg")
                } catch (t: Throwable) {
                    Log.w(TAG, "addDisallowedApplication failed for $pkg", t)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Failed to parse split_tunnel_excluded", t)
        }

        val pfd = builder.establish()
            ?: throw IllegalStateException("builder.establish() returned null")

        Log.d(TAG, "TUN established. fd=${pfd.fd}")
        return pfd
    }

    private fun startV2Ray(configJson: String) {
        val callback = object : CoreCallbackHandler {
            override fun onEmitStatus(p0: Long, p1: String?): Long { return 0 }
            override fun shutdown(): Long { return 0 }
            override fun startup(): Long { return 0 }
        }

        val controller = Libv2ray.newCoreController(callback)
        coreController = controller

        Log.d(TAG, "Starting Xray core...")
        controller.startLoop(configJson)
        Log.d(TAG, "Xray core started command sent.")
    }

    private fun sanitizeXrayConfig(raw: String): String {
        return try {
            val root = JSONObject(raw)
            if (!root.has("outbounds")) return raw
            val outbounds = root.optJSONArray("outbounds") ?: return raw
            for (i in 0 until outbounds.length()) {
                val ob = outbounds.optJSONObject(i) ?: continue
                val protocol = ob.optString("protocol", "")
                if (protocol != "vless") continue
                val settings = ob.optJSONObject("settings") ?: continue
                val vnext = settings.optJSONArray("vnext") ?: continue
                if (vnext.length() > 1) {
                    val first = vnext.optJSONObject(0)
                    val newVnext = JSONArray()
                    if (first != null) newVnext.put(first)
                    settings.put("vnext", newVnext)
                    ob.put("settings", settings)
                    outbounds.put(i, ob)
                }
            }
            root.toString()
        } catch (t: Throwable) {
            raw
        }
    }

    private fun startTun2SocksWrapperAndSendFd(pfd: ParcelFileDescriptor) {
        val libDir = applicationInfo.nativeLibraryDir
        val wrapperPath = File(libDir, "libtun2socks.so").absolutePath

        val sockFile = File(cacheDir, "vpn_sock")
        if (sockFile.exists()) {
            sockFile.delete()
        }
        val sockPath = sockFile.absolutePath

        Log.d(TAG, "nativeLibraryDir=$libDir")
        Log.d(TAG, "tun2socks wrapper path=$wrapperPath")
        Log.d(TAG, "sockPath=$sockPath")

        val cmd = listOf(
            wrapperPath,
            "--netif-ipaddr", TUN2SOCKS_IP,
            "--netif-netmask", TUN2SOCKS_NETMASK,
            "--socks-server-addr", "$SOCKS_ADDR:$SOCKS_PORT",
            "--tunmtu", TUN_MTU.toString(),
            "--sock-path", sockPath,
            "--loglevel", "3",
            "--enable-udprelay"
        )

        Log.d(TAG, "Starting tun2socks wrapper: ${cmd.joinToString(" ")}")

        val pb = ProcessBuilder(cmd)
        pb.redirectErrorStream(true)
        pb.directory(cacheDir)
        val env = pb.environment()
        env["LD_LIBRARY_PATH"] = applicationInfo.nativeLibraryDir

        val proc = pb.start()
        tun2socksWrapperProc = proc

        thread(name = "tun2socks-log") {
            try {
                BufferedReader(InputStreamReader(proc.inputStream)).use { br ->
                    while (true) {
                        val line = br.readLine() ?: break
                        Log.d("tun2socks", line)
                    }
                }
            } catch (_: Throwable) {
            }
        }

        Thread.sleep(500)

        val ok = connectAndSendFd(sockPath, pfd.fileDescriptor, timeoutMs = 5000)
        if (!ok) {
            Log.e(TAG, "FD send failed -> stop VPN")
            throw IllegalStateException("Failed to send TUN fd to wrapper")
        }

        Log.d(TAG, "TUN fd sent to wrapper via FILESYSTEM sock=$sockPath")
    }

    private fun connectAndSendFd(sockName: String, fd: java.io.FileDescriptor, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        var lastErr: Throwable? = null

        while (System.currentTimeMillis() < deadline) {
            try {
                val s = LocalSocket()
                s.connect(LocalSocketAddress(sockName, LocalSocketAddress.Namespace.FILESYSTEM))
                
                s.setFileDescriptorsForSend(arrayOf(fd))
                s.outputStream.write(0)
                s.outputStream.flush()
                s.setFileDescriptorsForSend(null)
                s.close()
                return true
            } catch (t: Throwable) {
                lastErr = t
                try { Thread.sleep(200) } catch (_: Throwable) {}
            }
        }
        Log.e(TAG, "connectAndSendFd timeout; last error=${lastErr?.message}", lastErr)
        return false
    }

    private fun stopVpn(reason: String) {
        if (!isRunning.getAndSet(false)) return

        // --- ДОБАВЛЕНО: Обновляем статус для плитки ---
        isServiceRunning = false
        requestTileUpdate()
        // ----------------------------------------------

        Log.d(TAG, "Stopping VPN. reason=$reason")
        try { tun2socksWrapperProc?.destroy() } catch (_: Throwable) {}
        tun2socksWrapperProc = null
        try { coreController?.stopLoop() } catch (_: Throwable) {}
        coreController = null
        try { vpnInterface?.close() } catch (_: Throwable) {}
        vpnInterface = null
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Throwable) {}
        try { stopSelf() } catch (_: Throwable) {}
        Log.d(TAG, "VPN stopped")
    }

    private fun startAsForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(NOTIF_CHANNEL_ID, NOTIF_CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW)
            nm.createNotificationChannel(ch)
        }
        val intent = Intent(this, MainActivity::class.java)
        val pi = PendingIntent.getActivity(this, 0, intent, (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0) or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification: Notification = NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setContentTitle("VPN работает")
            .setContentText("Трафик защищен")
            .setSmallIcon(R.drawable.ic_quick_vpn)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    // --- ДОБАВЛЕНО: Функция для принудительного обновления UI плитки ---
    private fun requestTileUpdate() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                // Если сервис VpnTileService еще не создан, ничего страшного
                TileService.requestListeningState(
                    this,
                    ComponentName(this, VpnTileService::class.java)
                )
            } catch (e: Exception) {
                Log.w(TAG, "Error updating tile: ${e.message}")
            }
        }
    }
}