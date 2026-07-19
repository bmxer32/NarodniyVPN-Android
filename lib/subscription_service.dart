import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class SubscriptionService {
  static const String _cacheKey = 'vpn_subscription_cache';
  static const String _timeKey = 'vpn_subscription_time';
  static const String _uuidKey = 'vpn_subscription_last_uuid'; 

  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    await prefs.remove(_timeKey);
    debugPrint("--- КЭШ ПОДПИСКИ ОЧИЩЕН ---");
  }

  static String sanitizeUrl(String rawUrl) {
    String url = rawUrl.trim();

    if (url.startsWith("http://")) {
      url = url.replaceFirst("http://", "https://");
    }
    if (url.contains("api.narodniyvpn.online")) {
      url = url.replaceFirst("api.narodniyvpn.online", "narodniyvpn.online");
    }
    if (url.contains(":8443")) {
      url = url.replaceFirst(":8443", "");
    }
    return url;
  }

  static Future<List<String>> getSmartConfigList(String rawUrl, {bool forceUpdate = false}) async {
    if (rawUrl.trim().startsWith("vless://")) {
       final list = [rawUrl.trim()];
       await _saveToCache(list, "raw_vless"); 
       return list;
    }

    String url = sanitizeUrl(rawUrl);
    String currentUuid = _extractUuid(url);
    
    final prefs = await SharedPreferences.getInstance();
    final String? savedUuid = prefs.getString(_uuidKey);
    final List<String>? cachedList = prefs.getStringList(_cacheKey);

    bool needNetworkRequest = forceUpdate;

    if (savedUuid != null && savedUuid != currentUuid) {
      needNetworkRequest = true; 
    } 
    else {
      final int? lastUpdate = prefs.getInt(_timeKey);
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (lastUpdate == null || (now - lastUpdate > 1000 * 60 * 60)) {
        needNetworkRequest = true;
      }
    }

    if (cachedList == null || cachedList.isEmpty) {
      needNetworkRequest = true;
    }

    if (needNetworkRequest) {
      try {
        final fetchedList = await _fetchAndParse(url);
        
        if (fetchedList.isNotEmpty) {
          await _saveToCache(fetchedList, currentUuid);
          return fetchedList;
        }
      } catch (e) {
        // ✅ НОВОЕ: Если мы поймали сигнал о пустом балансе — убиваем кэш и прокидываем ошибку в UI
        if (e.toString().contains("BALANCE_EMPTY")) {
          debugPrint("Баланс исчерпан, очищаем кэш серверов");
          await clearCache();
          throw Exception("BALANCE_EMPTY"); 
        }
        debugPrint("Ошибка обновления конфига: $e");
      }
    }

    if (cachedList != null && cachedList.isNotEmpty) {
       if (savedUuid == currentUuid || savedUuid == null) {
          return cachedList;
       } 
    }

    return [];
  }

  static Future<void> backgroundUpdate(String url) async {
    if (url.trim().startsWith("vless://")) return;
    try {
      await getSmartConfigList(url, forceUpdate: true);
    } catch (e) {
      debugPrint("Ошибка фонового обновления: $e");
    }
  }

  static Future<void> _saveToCache(List<String> list, String uuid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_cacheKey, list);
    await prefs.setInt(_timeKey, DateTime.now().millisecondsSinceEpoch);
    await prefs.setString(_uuidKey, uuid);
  }

  static String _extractUuid(String url) {
    try {
      Uri uri = Uri.parse(url);
      if (uri.pathSegments.isNotEmpty) {
        return uri.pathSegments.last;
      }
    } catch (e) {}
    return "unknown";
  }

  static Future<List<String>> _fetchAndParse(String url) async {
    final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));

    // ✅ НОВОЕ: Обработка HTTP кодов отключенных аккаунтов (Marzban/3X-UI часто отдают 401, 402, 403 или 404)
    if (response.statusCode == 401 || response.statusCode == 402 || response.statusCode == 403 || response.statusCode == 404) {
       throw Exception("BALANCE_EMPTY");
    }

    if (response.statusCode == 200) {
      String body = response.body.trim();
      body = body.replaceAll('\r', '');
      
      String decodedText = "";
      try {
        List<int> bytes = base64Decode(body);
        decodedText = utf8.decode(bytes);
      } catch (e) {
        decodedText = body; 
      }

      List<String> configs = LineSplitter.split(decodedText)
          .map((s) => s.trim())
          .where((s) => s.startsWith("vless://"))
          .toList();

      // ✅ НОВОЕ: Если панель отдала статус 200, но серверов 0 — подписка отключена.
      if (configs.isEmpty) {
         throw Exception("BALANCE_EMPTY");
      }

      return configs;
    } else {
      throw Exception("Код ответа ${response.statusCode}");
    }
  }
}