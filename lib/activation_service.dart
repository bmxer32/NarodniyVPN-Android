import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import 'app_config.dart';

class ActivationService {
  static const String _activateUrl = AppConfig.activateUrl;

  /// Получает уникальный ID устройства (Hardware ID)
  static Future<String> getHardwareId() async {
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    String id = "unknown_device";

    try {
      if (Platform.isAndroid) {
        final AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        id = androidInfo.id; 
      } else if (Platform.isIOS) {
        final IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        id = iosInfo.identifierForVendor ?? "ios_unknown";
      }
    } catch (e) {
      debugPrint("Ошибка получения ID устройства: $e");
      id = "error_getting_id"; 
    }
    return id;
  }

  /// Отправляет запрос на активацию ключа
  static Future<int> activateKey(String subscriptionUrl) async {
    try {
      final String hwId = await getHardwareId();
      
      debugPrint("Activation Request: ID=*** | URL=***");

      final Map<String, String> body = {
        "vless_key": subscriptionUrl, // Отправляем саму ссылку-подписку
        "hardware_id": hwId
      };

      final response = await http.post(
        Uri.parse(_activateUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      debugPrint("Server Response: ${response.statusCode}");
      return response.statusCode;

    } catch (e) {
      debugPrint("Activation Network Error: $e");
      return -1; 
    }
  }
}