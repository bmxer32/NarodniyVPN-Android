import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SplitTunnelScreen extends StatefulWidget {
  const SplitTunnelScreen({super.key});

  @override
  State<SplitTunnelScreen> createState() => _SplitTunnelScreenState();
}

class _SplitTunnelScreenState extends State<SplitTunnelScreen> {
  static const _channel = MethodChannel('online.narodniyvpn.app/vpn');

  List<Map<String, dynamic>> _apps = [];
  Set<String> _excludedPackages = {};
  bool _isLoading = true;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final excludedJson = prefs.getString('split_tunnel_excluded') ?? '[]';
    final excluded = List<String>.from(jsonDecode(excludedJson));

    try {
      final List<dynamic> apps = await _channel.invokeMethod('getInstalledApps');
      if (mounted) {
        setState(() {
          _apps = apps.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          _excludedPackages = excluded.toSet();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleApp(String packageName, bool throughVpn) async {
    setState(() {
      if (throughVpn) {
        _excludedPackages.remove(packageName);
      } else {
        _excludedPackages.add(packageName);
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('split_tunnel_excluded', jsonEncode(_excludedPackages.toList()));
  }

  List<Map<String, dynamic>> get _filteredApps {
    if (_searchQuery.isEmpty) return _apps;
    final q = _searchQuery.toLowerCase();
    return _apps.where((a) => (a['appName'] as String).toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final filtered = _filteredApps;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text("Раздельный трафик"),
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        elevation: 0,
        actions: [
          if (!_isLoading)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  "${_apps.length - _excludedPackages.length} / ${_apps.length} через VPN",
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Баннер-подсказка
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.blueAccent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blueAccent.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded, color: Colors.blueAccent, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "Включённые приложения работают через VPN. Выключенные — напрямую.",
                    style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black87),
                  ),
                ),
              ],
            ),
          ),
          // Поиск
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: "Поиск приложений...",
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: isDark ? const Color(0xFF2C2C2C) : Colors.grey[100],
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          // Кнопка Вкл/Выкл всё
          if (!_isLoading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: Icon(
                    _excludedPackages.isEmpty ? Icons.toggle_off_rounded : Icons.toggle_on_rounded,
                    size: 22,
                    color: Colors.blueAccent,
                  ),
                  label: Text(
                    _excludedPackages.isEmpty ? "Выключить все (обход VPN)" : "Включить все (через VPN)",
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    backgroundColor: Colors.blueAccent.withOpacity(0.1),
                    side: const BorderSide(color: Colors.blueAccent, width: 1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () async {
                    final allPackages = _apps.map((a) => a['packageName'] as String? ?? '').toSet();
                    setState(() {
                      if (_excludedPackages.isEmpty) {
                        _excludedPackages = allPackages;
                      } else {
                        _excludedPackages = {};
                      }
                    });
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString('split_tunnel_excluded', jsonEncode(_excludedPackages.toList()));
                  },
                ),
              ),
            ),
          // Список приложений
          Expanded(
            child: _isLoading
                ? const Center(child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text("Загрузка приложений...", style: TextStyle(color: Colors.grey)),
                    ],
                  ))
                : filtered.isEmpty
                    ? const Center(child: Text("Приложения не найдены", style: TextStyle(color: Colors.grey)))
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final app = filtered[index];
                          final pkg = app['packageName'] as String? ?? '';
                          final appName = app['appName'] as String? ?? pkg;
                          final iconB64 = app['icon'] as String?;
                          final throughVpn = !_excludedPackages.contains(pkg);

                          return ListTile(
                            leading: _buildIcon(iconB64),
                            title: Text(appName, overflow: TextOverflow.ellipsis),
                            subtitle: Text(pkg, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11, color: Colors.grey)),
                            trailing: Switch.adaptive(
                              value: throughVpn,
                              activeColor: Colors.blueAccent,
                              onChanged: (v) => _toggleApp(pkg, v),
                            ),
                            onTap: () => _toggleApp(pkg, !throughVpn),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildIcon(String? b64) {
    if (b64 != null && b64.isNotEmpty) {
      try {
        final Uint8List bytes = base64Decode(b64);
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(bytes, width: 40, height: 40, fit: BoxFit.cover),
        );
      } catch (_) {}
    }
    return const CircleAvatar(
      radius: 20,
      child: Icon(Icons.android_rounded, size: 20),
    );
  }
}
