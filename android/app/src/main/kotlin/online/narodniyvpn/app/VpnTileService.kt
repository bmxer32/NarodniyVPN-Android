package online.narodniyvpn.app

import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast

class VpnTileService : TileService() {

    // Вызывается, когда шторка открывается (обновляем вид плитки)
    override fun onStartListening() {
        super.onStartListening()
        updateTileUI()
    }

    // Вызывается при нажатии
    override fun onClick() {
        super.onClick()
        
        // 1. ЕСЛИ VPN ВКЛЮЧЕН -> ВЫКЛЮЧАЕМ
        if (MyVpnService.isServiceRunning) {
            val intent = Intent(this, MyVpnService::class.java)
            intent.action = MyVpnService.ACTION_STOP
            startService(intent)
            
            // Сразу меняем вид плитки на "Выключено"
            updateTileVisuals(false)
            return
        }

        // 2. ЕСЛИ VPN ВЫКЛЮЧЕН -> ВКЛЮЧАЕМ
        
        // А. Проверяем разрешение на VPN
        val prepareIntent = VpnService.prepare(this)
        if (prepareIntent != null) {
            Toast.makeText(this, "Откройте приложение для разрешения VPN", Toast.LENGTH_LONG).show()
            val appIntent = Intent(this, MainActivity::class.java)
            appIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivityAndCollapse(appIntent)
            return
        }

        // Б. Достаем сохраненный конфиг
        val prefs = getSharedPreferences("vpn_prefs", Context.MODE_PRIVATE)
        val lastConfig = prefs.getString("last_vpn_config", null)

        if (lastConfig.isNullOrEmpty()) {
            Toast.makeText(this, "Сначала подключитесь через приложение", Toast.LENGTH_LONG).show()
            val appIntent = Intent(this, MainActivity::class.java)
            appIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivityAndCollapse(appIntent)
            return
        }

        // В. Запускаем сервис
        val intent = Intent(this, MyVpnService::class.java)
        intent.action = MyVpnService.ACTION_START
        intent.putExtra("config", lastConfig)
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        
        // Сразу меняем вид плитки на "Включено"
        updateTileVisuals(true)
    }

    // Метод проверки реального статуса сервиса
    private fun updateTileUI() {
        updateTileVisuals(MyVpnService.isServiceRunning)
    }

    // Метод отрисовки (иконка, цвет, текст)
    private fun updateTileVisuals(isActive: Boolean) {
        val tile = qsTile ?: return
        
        // Устанавливаем нашу новую иконку
        tile.icon = Icon.createWithResource(this, R.drawable.ic_quick_vpn)
        
        if (isActive) {
            tile.state = Tile.STATE_ACTIVE
            tile.label = "VPN ВКЛ"
        } else {
            tile.state = Tile.STATE_INACTIVE
            tile.label = "Народный VPN"
        }
        
        tile.updateTile()
    }
}