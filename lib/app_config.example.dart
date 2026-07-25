/// Шаблон локальной конфигурации.
///
/// Скопируйте этот файл в `lib/app_config.dart` и подставьте свои значения.
/// Сам `app_config.dart` в репозиторий не коммитится (см. .gitignore).
class AppConfig {
  /// Базовый адрес backend'а.
  static const String baseUrl = "https://example.com";

  /// Эндпоинт активации ключа.
  static const String activateUrl = "$baseUrl/api/key/activate";

  /// Префикс фирменных зашифрованных ссылок.
  static const String linkPrefix = "example://";

  /// Ключ AES-256 — ровно 32 байта.
  static const List<int> aesKeyBytes = <int>[
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ];

  /// IV — ровно 16 байт.
  static const List<int> aesIvBytes = <int>[
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ];
}
