import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';

import 'app_config.dart';

/// Ошибка триала с HTTP-кодом (400/404/503 и т.п.), чтобы UI мог показать
/// корректное сообщение по ТЗ (п.7).
class TrialException implements Exception {
  final int code;
  final String message;
  TrialException(this.code, this.message);
  @override
  String toString() => "TrialException($code): $message";
}

/// Состояние бесплатного триала (ответ /api/trial/claim и /api/trial/status).
class TrialState {
  final String androidId;
  final String state; // "active" | "cooldown"
  final String? vlessLink;
  final String? uuid;
  final int quotaBytes;
  final int usedBytes;
  final DateTime? windowExpires;
  final DateTime? cooldownUntil;
  final int secondsLeft;
  final int cycleCount;

  const TrialState({
    required this.androidId,
    required this.state,
    required this.vlessLink,
    required this.uuid,
    required this.quotaBytes,
    required this.usedBytes,
    required this.windowExpires,
    required this.cooldownUntil,
    required this.secondsLeft,
    required this.cycleCount,
  });

  bool get isActive => state == "active";
  bool get isCooldown => state == "cooldown";

  /// Остаток трафика в текущем окне (не уходит ниже нуля).
  int get remainingBytes {
    final left = quotaBytes - usedBytes;
    return left > 0 ? left : 0;
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    try {
      return DateTime.parse(v.toString()).toLocal();
    } catch (_) {
      return null;
    }
  }

  static int _parseInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? "") ?? fallback;
  }

  factory TrialState.fromJson(Map<String, dynamic> json) {
    return TrialState(
      androidId: json['android_id']?.toString() ?? "",
      state: json['state']?.toString() ?? "active",
      vlessLink: json['vless_link']?.toString(),
      uuid: json['uuid']?.toString(),
      quotaBytes: _parseInt(json['quota_bytes']),
      usedBytes: _parseInt(json['used_bytes']),
      windowExpires: _parseDate(json['window_expires']),
      cooldownUntil: _parseDate(json['cooldown_until']),
      secondsLeft: _parseInt(json['seconds_left']),
      cycleCount: _parseInt(json['cycle_count'], fallback: 1),
    );
  }

  /// Копия с локально уменьшенным таймером — для плавного отсчёта между опросами.
  TrialState copyWithSecondsLeft(int value) {
    return TrialState(
      androidId: androidId,
      state: state,
      vlessLink: vlessLink,
      uuid: uuid,
      quotaBytes: quotaBytes,
      usedBytes: usedBytes,
      windowExpires: windowExpires,
      cooldownUntil: cooldownUntil,
      secondsLeft: value < 0 ? 0 : value,
      cycleCount: cycleCount,
    );
  }
}

/// Premium-сервер (платный), показывается в триале как заблокированный.
class TrialServerInfo {
  final String name; // отображаемое имя, напр. "Нидерланды"
  final String country; // ISO-код для флага, напр. "NL" (опционально)

  const TrialServerInfo({required this.name, required this.country});

  factory TrialServerInfo.fromJson(Map<String, dynamic> json) {
    return TrialServerInfo(
      name: (json['name'] ?? json['title'] ?? "Сервер").toString(),
      country: (json['country'] ?? json['flag'] ?? json['code'] ?? "").toString(),
    );
  }
}

class TrialService {
  static const String _baseUrl = AppConfig.baseUrl;
  static const MethodChannel _channel = MethodChannel('online.narodniyvpn.app/vpn');

  /// Стабильный идентификатор устройства — Settings.Secure.ANDROID_ID (нативно).
  /// НЕ генерируем свой UUID и не храним его в файлах приложения.
  static Future<String?> getAndroidId() async {
    try {
      final String? id = await _channel.invokeMethod<String>('getAndroidId');
      if (id != null && id.trim().length >= 4) {
        return id.trim();
      }
    } catch (e) {
      debugPrint("Ошибка получения ANDROID_ID: $e");
    }
    return null;
  }

  /// Модель устройства и версия ОС (опциональные поля для claim).
  static Future<Map<String, String>> _deviceMeta() async {
    final meta = <String, String>{};
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        meta['device_model'] = "${info.manufacturer} ${info.model}".trim();
        meta['os_version'] = "Android ${info.version.release}";
      }
    } catch (_) {}
    return meta;
  }

  static TrialState _handleResponse(http.Response response) {
    if (response.statusCode == 200) {
      final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return TrialState.fromJson(data);
    }
    if (response.statusCode == 400) {
      throw TrialException(400, "Некорректный идентификатор устройства");
    }
    if (response.statusCode == 404) {
      throw TrialException(404, "Триал ещё не получен");
    }
    if (response.statusCode == 503) {
      throw TrialException(503, "Сервис временно недоступен, попробуйте позже");
    }
    throw TrialException(response.statusCode, "Ошибка сервера (${response.statusCode})");
  }

  /// POST /api/trial/claim — получить триал (при первом запуске). Идемпотентно.
  static Future<TrialState> claim(String androidId) async {
    final meta = await _deviceMeta();
    final body = <String, dynamic>{
      "android_id": androidId,
      ...meta,
    };

    final response = await http
        .post(
          Uri.parse("$_baseUrl/api/trial/claim"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));

    return _handleResponse(response);
  }

  /// GET /api/trial/status?android_id=… — текущее состояние (поллинг).
  static Future<TrialState> status(String androidId) async {
    final response = await http
        .get(Uri.parse("$_baseUrl/api/trial/status?android_id=$androidId"))
        .timeout(const Duration(seconds: 15));

    return _handleResponse(response);
  }

  /// GET /api/trial/servers — список premium-серверов (заблокированных в триале).
  /// При любой ошибке/отсутствии эндпоинта возвращает пустой список — экран
  /// триала продолжает работать, просто без заблокированных серверов.
  static Future<List<TrialServerInfo>> getServers() async {
    try {
      final response = await http
          .get(Uri.parse("$_baseUrl/api/trial/servers"))
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) return const [];

      final decoded = json.decode(utf8.decode(response.bodyBytes));
      // Поддерживаем оба формата: {"servers":[...]} и просто [...].
      final List list = decoded is List
          ? decoded
          : (decoded is Map && decoded['servers'] is List ? decoded['servers'] : const []);

      return list
          .whereType<Map>()
          .map((e) => TrialServerInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      debugPrint("Ошибка загрузки списка premium-серверов: $e");
      return const [];
    }
  }
}
