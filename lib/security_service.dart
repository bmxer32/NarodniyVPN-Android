import 'package:encrypt/encrypt.dart' as encrypt;

import 'app_config.dart';

class SecurityService {
  // Ключ и IV лежат в lib/app_config.dart, который не коммитится.
  // Шаблон со значениями-заглушками — lib/app_config.example.dart.
  //
  // Важно: это клиентское приложение, поэтому ключ всё равно попадает в APK и
  // извлекаем из него. Шифрование ссылок здесь — обфускация, а не защита;
  // проверять права доступа обязан сервер.

  static String get _secretKey => String.fromCharCodes(AppConfig.aesKeyBytes);
  static String get _initVector => String.fromCharCodes(AppConfig.aesIvBytes);

  static String get _prefix => AppConfig.linkPrefix;

  /// Проверяет, является ли ссылка нашей фирменной
  static bool isNarodniyLink(String text) {
    return text.trim().toLowerCase().startsWith(_prefix);
  }

  /// Расшифровывает ссылку. Возвращает чистый vless:// или null, если ошибка.
  static String? decrypt(String encryptedLink) {
    try {
      final text = encryptedLink.trim();
      if (!isNarodniyLink(text)) return null;

      // 1. Убираем префикс
      final cipherText = text.substring(_prefix.length);

      // 2. Инициализируем шифровальщик восстановленными ключами
      final key = encrypt.Key.fromUtf8(_secretKey);
      final iv = encrypt.IV.fromUtf8(_initVector);

      final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));

      // 3. Расшифровываем
      final decrypted = encrypter.decrypt64(cipherText, iv: iv);

      return decrypted;
    } catch (e) {
      // print("Ошибка дешифровки: $e"); // Можно раскомментировать для отладки
      return null;
    }
  }
}
