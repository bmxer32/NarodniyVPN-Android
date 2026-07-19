import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Принудительное обновление через Google Play In-App Updates (IMMEDIATE).
/// Полностью на клиенте, бэкенд не нужен. Работает ТОЛЬКО для сборок,
/// установленных из Play Store (тест — internal app sharing / закрытый трек).
class UpdateService {
  static bool _inProgress = false;

  /// Проверяет наличие обновления и при необходимости запускает блокирующий
  /// полноэкранный IMMEDIATE-флоу. Вызывать на старте и в onResume.
  static Future<void> checkAndForceUpdate() async {
    if (_inProgress) return;
    _inProgress = true;
    try {
      final AppUpdateInfo info = await InAppUpdate.checkForUpdate();

      // Текущий установленный versionCode.
      int currentCode = 0;
      try {
        final pkg = await PackageInfo.fromPlatform();
        currentCode = int.tryParse(pkg.buildNumber) ?? 0;
      } catch (_) {}

      // Жёсткая защита: считаем обновление настоящим, только если доступная
      // версия РЕАЛЬНО выше установленной. Иначе (стейл-кэш Play сразу после
      // установки, рассинхрон треков и т.п.) экран обновления НЕ показываем.
      final int? availableCode = info.availableVersionCode;
      final bool genuinelyNewer =
          availableCode != null && currentCode > 0 && availableCode > currentCode;

      if (!genuinelyNewer) return;

      final bool updateAvailable =
          info.updateAvailability == UpdateAvailability.updateAvailable;
      // IMMEDIATE-обновление было прервано (юзер свернул апку) — нужно возобновить.
      final bool resumeNeeded =
          info.updateAvailability == UpdateAvailability.developerTriggeredUpdateInProgress;

      if (resumeNeeded || (updateAvailable && info.immediateUpdateAllowed)) {
        // Если форсить нужно только для важных релизов — гейтить по приоритету
        // (ставится в Play Console при публикации релиза, 0..5). Пример:
        //   if (!resumeNeeded && info.updatePriority < 4) {
        //     if (info.flexibleUpdateAllowed) await InAppUpdate.startFlexibleUpdate();
        //     return;
        //   }
        await InAppUpdate.performImmediateUpdate();
      }
    } catch (e) {
      // Нет Play / dev-сборка / обновления нет — тихо игнорируем.
      debugPrint("InAppUpdate: $e");
    } finally {
      _inProgress = false;
    }
  }
}
