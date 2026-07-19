import 'package:encrypt/encrypt.dart' as encrypt;

class SecurityService {
  // === МИНИМАЛЬНАЯ ЗАЩИТА (ОБФУСКАЦИЯ) ===
  // Мы храним ключи не как текст, а как набор кодов символов.
  // Это защищает от простого поиска текста в скомпилированном приложении.
  //
  // ЗНАЧЕНИЯ УДАЛЕНЫ ИЗ ИСТОРИИ РЕПОЗИТОРИЯ.
  // Подставьте свои: ключ — ровно 32 байта, IV — ровно 16 байт.

  static final List<int> _keyBytes = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0
  ];

  static final List<int> _ivBytes = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0
  ];

  static const String _prefix = "narodniy://";

  /// Собираем строку ключа из байтов "на лету"
  static String get _secretKey => String.fromCharCodes(_keyBytes);
  static String get _initVector => String.fromCharCodes(_ivBytes);

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
