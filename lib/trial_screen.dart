import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'main.dart' show LoginScreen, buildVersionLabel;
import 'trial_service.dart';
import 'vless_parser.dart';

/// Ключ в SharedPreferences: триал уже получен на этом устройстве.
const String kTrialClaimedKey = 'trial_claimed';

/// Экран бесплатного триала.
/// active   — VPN работает, показываем остаток трафика/таймер.
/// cooldown — пауза, VPN выключен, показываем экран паузы с таймером.
class TrialScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final ThemeMode currentMode;
  final String androidId;
  final TrialState? initialState;

  const TrialScreen({
    super.key,
    required this.onThemeChanged,
    required this.currentMode,
    required this.androidId,
    this.initialState,
  });

  @override
  State<TrialScreen> createState() => _TrialScreenState();
}

class _TrialScreenState extends State<TrialScreen> with WidgetsBindingObserver {
  static const platform = MethodChannel('online.narodniyvpn.app/vpn');

  TrialState? _trial;
  bool _loadingInitial = true;
  String? _fatalError; // например, 503 при первом запросе
  bool _isConnected = false;
  bool _connecting = false;

  // Инфо об IP-адресе (как на главном экране).
  String _currentIp = "...";
  String _currentCity = "Загрузка...";
  String _countryCode = "--";
  bool _isLoadingIp = true;

  // Premium-серверы (заблокированы в триале) — список приходит с бэкенда.
  List<TrialServerInfo> _premiumServers = [];

  Timer? _pollTimer; // опрос /status каждые 45 сек
  Timer? _tickTimer; // локальный отсчёт seconds_left раз в секунду
  bool _zeroFetchInFlight = false; // защита от двойного запроса при secondsLeft==0

  // Абсолютное время конца текущего окна/паузы. Считаем таймер от него по
  // «настенным» часам — он точен, переживает перезапуск и не «замерзает» в фоне.
  DateTime? _windowEnd;

  DateTime _endFor(TrialState s) {
    final abs = s.isCooldown ? s.cooldownUntil : s.windowExpires;
    // Если бэкенд не прислал абсолютную метку — падаем на seconds_left.
    return abs ?? DateTime.now().add(Duration(seconds: s.secondsLeft));
  }

  /// Текущее оставшееся время (сек) для отображения.
  int get _displaySeconds {
    if (_windowEnd == null) return _trial?.secondsLeft ?? 0;
    final left = _windowEnd!.difference(DateTime.now()).inSeconds;
    return left < 0 ? 0 : left;
  }

  /// Берём самую раннюю метку конца в пределах окна (таймер не прыгает вверх),
  /// при смене состояния — переустанавливаем.
  void _syncTimer(TrialState fresh, {required bool stateChanged}) {
    final candidate = _endFor(fresh);
    if (stateChanged || _windowEnd == null || candidate.isBefore(_windowEnd!)) {
      _windowEnd = candidate;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (widget.initialState != null) {
      _trial = widget.initialState;
      _syncTimer(widget.initialState!, stateChanged: true);
      _loadingInitial = false;
      _checkVpnState().then((_) => _applyTrialState());
    } else {
      _bootstrap();
    }

    _updateIpInfo();
    _loadServers();
    _startTimers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkVpnState();
      _fetchStatus();
      _updateIpInfo();
    }
  }

  void _startTimers() {
    _pollTimer = Timer.periodic(const Duration(seconds: 45), (_) => _fetchStatus());
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _localTick());
  }

  void _localTick() {
    if (_trial == null || !mounted) return;
    setState(() {}); // перерисовываем таймер (значение считается по _displaySeconds)

    if (_displaySeconds <= 0 && !_zeroFetchInFlight) {
      // Таймер дошёл до нуля — сразу синхронизируемся с сервером (смена окна/паузы).
      _zeroFetchInFlight = true;
      _fetchStatus();
    }
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loadingInitial = true;
      _fatalError = null;
    });
    try {
      TrialState state;
      try {
        state = await TrialService.status(widget.androidId);
      } on TrialException catch (e) {
        // 404 — статус запрошен до claim. Получаем триал.
        if (e.code == 404) {
          state = await TrialService.claim(widget.androidId);
        } else {
          rethrow;
        }
      }
      if (!mounted) return;
      setState(() {
        _trial = state;
        _syncTimer(state, stateChanged: true);
        _loadingInitial = false;
      });
      await _checkVpnState();
      _applyTrialState();
    } on TrialException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingInitial = false;
        _fatalError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingInitial = false;
        _fatalError = "Нет соединения с сервером. Проверьте интернет.";
      });
    }
  }

  Future<void> _fetchStatus() async {
    try {
      final fresh = await TrialService.status(widget.androidId);
      if (!mounted) return;
      final prev = _trial;
      final bool stateChanged = prev == null || prev.state != fresh.state;
      setState(() {
        _trial = fresh;
        _syncTimer(fresh, stateChanged: stateChanged);
      });
      _zeroFetchInFlight = false;

      // Реагируем на смену состояния. Туннель сам НЕ поднимаем — только
      // принудительно останавливаем при уходе в cooldown (ключ на сервере
      // отключается). Включение VPN — только вручную по кнопке.
      if (stateChanged) {
        _applyTrialState();
      }
    } on TrialException catch (e) {
      _zeroFetchInFlight = false;
      if (e.code == 404) {
        // Триал пропал на бэке — пробуем перезаявить.
        try {
          final reclaimed = await TrialService.claim(widget.androidId);
          if (mounted) {
            setState(() {
              _trial = reclaimed;
              _syncTimer(reclaimed, stateChanged: true);
            });
            _applyTrialState();
          }
        } catch (_) {}
      }
      // 503/прочее во время поллинга — молча оставляем текущее состояние.
    } catch (_) {
      _zeroFetchInFlight = false;
    }
  }

  /// Реагирует на состояние триала. VPN сам НЕ включаем (только вручную
  /// по кнопке). В cooldown принудительно останавливаем — ключ на сервере
  /// отключён, трафик всё равно не пойдёт.
  void _applyTrialState() {
    final t = _trial;
    if (t == null) return;

    if (t.isCooldown && (_isConnected || _connecting)) {
      _stopTunnel();
    }
  }

  Future<void> _checkVpnState() async {
    try {
      final bool running = await platform.invokeMethod('checkState');
      if (mounted && _isConnected != running) {
        setState(() => _isConnected = running);
        // Состояние туннеля изменилось — IP мог поменяться, перезапрашиваем
        // (теперь уже через прокси, если VPN поднят).
        _updateIpInfo();
      }
    } catch (_) {}
  }

  Future<void> _startTunnel(String vlessLink) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      final String configJson = VlessParser.generateConfig(vlessLink);
      await platform.invokeMethod('startVpn', {"config": configJson});
      if (!mounted) return;
      setState(() => _isConnected = true);
      // Подтверждаем фактический статус через небольшую паузу.
      Future.delayed(const Duration(milliseconds: 1200), () {
        _checkVpnState();
        _updateIpInfo();
      });
    } catch (e) {
      debugPrint("Trial: ошибка запуска туннеля: $e");
      if (mounted) setState(() => _isConnected = false);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _stopTunnel() async {
    try {
      await platform.invokeMethod('stopVpn');
    } catch (_) {}
    if (mounted) setState(() => _isConnected = false);
    Future.delayed(const Duration(seconds: 1), _updateIpInfo);
  }

  /// Определяет текущий внешний IP (через прокси Xray, если VPN включён).
  Future<void> _updateIpInfo() async {
    if (!mounted) return;
    setState(() => _isLoadingIp = true);

    try {
      final HttpClient client = HttpClient();
      if (_isConnected) {
        client.findProxy = (uri) => "PROXY 127.0.0.1:10809";
        client.badCertificateCallback = ((cert, host, port) => true);
      }
      client.connectionTimeout = const Duration(seconds: 5);

      final request = await client.getUrl(Uri.parse('https://ipinfo.io/json'));
      request.headers.set('Accept', 'application/json');
      final response = await request.close();

      if (response.statusCode == 200) {
        final String jsonString = await response.transform(utf8.decoder).join();
        final data = json.decode(jsonString);
        if (mounted) {
          setState(() {
            _currentIp = data['ip'] ?? "Неизвестно";
            final city = data['city'] ?? '?';
            final country = data['country'] ?? '?';
            _currentCity = "$city, $country";
            _countryCode = data['country'] ?? "??";
            _isLoadingIp = false;
          });
        }
      } else {
        throw Exception('API Error');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _currentIp = _isConnected ? "Нет сети" : "Ошибка";
          _currentCity = _isConnected ? "Ошибка VPN" : "Проверьте интернет";
          _isLoadingIp = false;
        });
      }
    }
  }

  String _getFlag(String countryCode) {
    try {
      if (countryCode.length != 2) return "🌐";
      String country = countryCode.toUpperCase();
      if (!RegExp(r'^[A-Z]{2}$').hasMatch(country)) return "🌐";
      const int flagOffset = 0x1F1E6;
      const int asciiOffset = 0x41;
      final int first = country.codeUnitAt(0) - asciiOffset + flagOffset;
      final int second = country.codeUnitAt(1) - asciiOffset + flagOffset;
      return String.fromCharCode(first) + String.fromCharCode(second);
    } catch (e) {
      return "🏳️";
    }
  }

  void _toggleManually() {
    HapticFeedback.mediumImpact();
    final t = _trial;
    if (t == null || !t.isActive) return;
    if (_isConnected) {
      _stopTunnel();
    } else if (t.vlessLink != null) {
      _startTunnel(t.vlessLink!);
    }
  }

  Future<void> _openSupport() async {
    final Uri url = Uri.parse('https://t.me/narodniyVPN_support');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _openBot() async {
    final Uri tgUri = Uri.parse('tg://resolve?domain=narodniy_vpn_bot&start=start');
    final Uri webUri = Uri.parse('https://t.me/narodniy_vpn_bot?start=start');
    try {
      if (await canLaunchUrl(tgUri)) {
        await launchUrl(tgUri);
      } else {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Future<void> _loadServers() async {
    final servers = await TrialService.getServers();
    if (mounted && servers.isNotEmpty) {
      setState(() => _premiumServers = servers);
    }
  }

  /// Имя бесплатного (триал) сервера — из vless_link.
  String get _freeServerName {
    final link = _trial?.vlessLink;
    if (link == null || link.isEmpty) return "Бесплатный сервер";
    final name = VlessParser.getName(link);
    return name.isEmpty ? "Бесплатный сервер" : name;
  }

  void _showServerList() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final bool isDark = Theme.of(ctx).brightness == Brightness.dark;
        final Color textColor = isDark ? Colors.white : Colors.black87;
        final Color headerColor = isDark ? Colors.grey[400]! : Colors.grey[700]!;

        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("Выберите сервер",
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold, color: textColor)),
                    IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close),
                        color: textColor),
                  ],
                ),
              ),
              const Divider(),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                      child: Text("ДОСТУПНО БЕСПЛАТНО",
                          style: TextStyle(
                              color: headerColor, fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.card_giftcard_rounded,
                          color: Color(0xFF00C853), size: 26),
                      title: Text(_freeServerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: textColor, fontWeight: FontWeight.w600)),
                      trailing: const Icon(Icons.check_circle, color: Color(0xFF00C853)),
                    ),
                    if (_premiumServers.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                        child: Row(
                          children: [
                            const Icon(Icons.workspace_premium_rounded,
                                size: 16, color: Color(0xFFFFB300)),
                            const SizedBox(width: 6),
                            Text("ПО ПОДПИСКЕ",
                                style: TextStyle(
                                    color: headerColor,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                      ..._premiumServers.map((s) => ListTile(
                            leading: Opacity(
                              opacity: 0.5,
                              child: Text(_getFlag(s.country), style: const TextStyle(fontSize: 26)),
                            ),
                            title: Text(s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: isDark ? Colors.grey[400] : Colors.grey[600])),
                            trailing: const Icon(Icons.lock_rounded, color: Colors.grey, size: 20),
                            onTap: () {
                              Navigator.pop(ctx);
                              _showPremiumDialog();
                            },
                          )),
                    ],
                    // Тизер: серверов много — все по подписке
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.public_rounded,
                          color: Color(0xFFFFB300), size: 26),
                      title: Text("Все серверы",
                          style: TextStyle(color: textColor, fontWeight: FontWeight.w600)),
                      subtitle: Text("Десятки локаций — открываются по подписке",
                          style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.grey[500] : Colors.grey[600])),
                      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                      onTap: () {
                        Navigator.pop(ctx);
                        _showPremiumDialog();
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPremiumDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        final bool isDark = Theme.of(ctx).brightness == Brightness.dark;
        final Color cardColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
        final Color textColor = isDark ? Colors.white : Colors.black87;

        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          backgroundColor: cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFB300).withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.workspace_premium_rounded,
                      size: 44, color: Color(0xFFFFB300)),
                ),
                const SizedBox(height: 20),
                Text("Сервер для подписчиков",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 21, fontWeight: FontWeight.bold, color: textColor)),
                const SizedBox(height: 12),
                Text(
                  "Этот сервер доступен только по подписке. Оформите её, чтобы открыть все локации без пауз и лимитов.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: isDark ? Colors.grey[400] : Colors.grey[600]),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _openBot();
                    },
                    icon: const Icon(Icons.workspace_premium_rounded),
                    label: const Text("Купить подписку",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2979FF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: TextButton.styleFrom(foregroundColor: Colors.grey),
                  child: const Text("Позже"),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Памятка-сравнение «Бесплатно vs Премиум» (по тапу на карточку трафика/таймера).
  void _showInfoSheet() {
    final String quota = _trial != null ? _formatBytes(_trial!.quotaBytes) : "лимит";
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final bool isDark = Theme.of(ctx).brightness == Brightness.dark;
        final Color textColor = isDark ? Colors.white : const Color(0xFF1D1D1F);
        final Color subColor = isDark ? Colors.grey[400]! : Colors.grey[600]!;
        final Color lineColor = isDark ? Colors.white12 : Colors.black12;

        Widget cell(Widget child, {Alignment align = Alignment.center}) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 6),
              child: Align(alignment: align, child: child),
            );
        Widget txt(String s,
                {bool bold = false, Color? color, TextAlign align = TextAlign.center}) =>
            Text(s,
                textAlign: align,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                    color: color ?? textColor));
        Widget yes() => const Icon(Icons.check_circle_rounded, color: Color(0xFF00C853), size: 20);
        Widget no() => Text("—", style: TextStyle(color: subColor, fontSize: 16));

        TableRow rowOf(String feature, Widget free, Widget prem) => TableRow(children: [
              cell(txt(feature, align: TextAlign.left), align: Alignment.centerLeft),
              cell(free),
              cell(prem),
            ]);

        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text("Бесплатно и Премиум",
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold, color: textColor)),
                  const SizedBox(height: 4),
                  Text("Бесплатно: лимит на окно → пауза → снова бесплатно.",
                      style: TextStyle(fontSize: 13, color: subColor)),
                  const SizedBox(height: 14),
                  Table(
                    columnWidths: const {
                      0: FlexColumnWidth(1.5),
                      1: FlexColumnWidth(1),
                      2: FlexColumnWidth(1),
                    },
                    border: TableBorder(horizontalInside: BorderSide(color: lineColor)),
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    children: [
                      TableRow(children: [
                        cell(const SizedBox()),
                        cell(txt("Бесплатно", bold: true)),
                        cell(Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.workspace_premium_rounded,
                                size: 16, color: Color(0xFFFFB300)),
                            const SizedBox(width: 4),
                            txt("Премиум", bold: true, color: const Color(0xFFFFB300)),
                          ],
                        )),
                      ]),
                      rowOf("Серверы", txt("1"), txt("Все")),
                      rowOf("Скорость", txt("Обычная"), txt("Макс.")),
                      rowOf("Трафик", txt(quota), txt("Без лимита")),
                      rowOf("Паузы", txt("Есть"), txt("Нет")),
                      rowOf("Раздельный трафик", no(), yes()),
                      rowOf("Белые списки", no(), yes()),
                      rowOf("Программа для ПК", no(), yes()),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openBot();
                      },
                      icon: const Icon(Icons.workspace_premium_rounded),
                      label: const Text("Купить подписку",
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2979FF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _switchToSubscription() async {
    if (_isConnected) {
      try {
        await platform.invokeMethod('stopVpn');
      } catch (_) {}
    }
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          onThemeChanged: widget.onThemeChanged,
          currentMode: widget.currentMode,
        ),
      ),
    );
  }

  // --- Форматирование ---

  String _formatBytes(int bytes) {
    if (bytes <= 0) return "0 МБ";
    const mb = 1024 * 1024;
    const gb = 1024 * 1024 * 1024;
    final double mbVal = bytes / mb;
    if (mbVal >= 1023.5) {
      return "${(bytes / gb).toStringAsFixed(2)} ГБ";
    }
    return "${mbVal.toStringAsFixed(0)} МБ";
  }

  /// Остаток/лимит в одной единице (по лимиту), чтобы не было «1023 МБ / 1.00 ГБ».
  String _formatTrafficPair(int remaining, int quota) {
    const mb = 1024 * 1024;
    const gb = 1024 * 1024 * 1024;
    if (quota >= gb) {
      String g(int b) => (b / gb).toStringAsFixed(2);
      return "${g(remaining)} / ${g(quota)} ГБ";
    }
    String m(int b) => (b / mb).toStringAsFixed(0);
    return "${m(remaining)} / ${m(quota)} МБ";
  }

  String _formatDuration(int seconds) {
    if (seconds < 0) seconds = 0;
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    if (h > 0) return "${two(h)}:${two(m)}:${two(s)}";
    return "${two(m)}:${two(s)}";
  }

  // --- Settings sheet ---

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
                ),
              ),
              _themeOption(Icons.brightness_auto, "Системная", ThemeMode.system),
              _themeOption(Icons.wb_sunny_rounded, "Светлая", ThemeMode.light),
              _themeOption(Icons.nightlight_round, "Темная", ThemeMode.dark),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.support_agent_rounded, color: Colors.blueAccent),
                title: const Text("Поддержка", style: TextStyle(color: Colors.blueAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  _openSupport();
                },
              ),
              ListTile(
                leading: const Icon(Icons.vpn_key_rounded, color: Colors.blueAccent),
                title: const Text("У меня есть подписка",
                    style: TextStyle(color: Colors.blueAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  _switchToSubscription();
                },
              ),
              ListTile(
                leading: const Icon(Icons.privacy_tip_rounded, color: Colors.grey),
                title: const Text("Политика конфиденциальности"),
                onTap: () {
                  Navigator.pop(ctx);
                  launchUrl(Uri.parse('https://narodniyvpn.online/privacy'),
                      mode: LaunchMode.externalApplication);
                },
              ),
              const Divider(),
              buildVersionLabel(),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _themeOption(IconData icon, String title, ThemeMode mode) {
    final isSelected = widget.currentMode == mode;
    final color = isSelected ? Colors.blueAccent : Theme.of(context).iconTheme.color;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title,
          style: TextStyle(
              color: color, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      trailing: isSelected ? const Icon(Icons.check_circle_rounded, color: Colors.blueAccent) : null,
      onTap: () {
        widget.onThemeChanged(mode);
        Navigator.pop(context);
      },
    );
  }

  // --- BUILD ---

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color bg = isDark ? const Color(0xFF121212) : const Color(0xFFF2F4F8);
    final Color textColor = isDark ? Colors.white : const Color(0xFF1D1D1F);
    final Color iconColor = isDark ? Colors.white : Colors.black87;

    Widget body;
    if (_loadingInitial) {
      body = const Center(child: CircularProgressIndicator(color: Colors.blueAccent));
    } else if (_fatalError != null && _trial == null) {
      body = _buildError(textColor, isDark);
    } else if (_trial != null && _trial!.isCooldown) {
      body = _buildCooldown(textColor, isDark);
    } else {
      body = _buildActive(textColor, isDark);
    }

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 16, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  RichText(
                    text: TextSpan(
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textColor),
                      children: const [
                        TextSpan(text: "Народный "),
                        TextSpan(text: "V", style: TextStyle(color: Colors.redAccent)),
                        TextSpan(text: "PN", style: TextStyle(color: Colors.blueAccent)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _showSettings,
                    icon: Icon(Icons.settings_rounded, color: iconColor),
                  ),
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget _buildError(Color textColor, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 64, color: Colors.orangeAccent),
          const SizedBox(height: 20),
          Text(
            _fatalError ?? "Ошибка",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: textColor),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _bootstrap,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text("Повторить", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2979FF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActive(Color textColor, bool isDark) {
    final t = _trial!;
    final Color cardColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final double progress = t.quotaBytes > 0
        ? (t.usedBytes / t.quotaBytes).clamp(0.0, 1.0)
        : 0.0;

    final buttonColors = _isConnected
        ? [const Color(0xFF00E676), const Color(0xFF00C853)]
        : (isDark ? [const Color(0xFF424242), const Color(0xFF212121)] : [Colors.white, const Color(0xFFF0F0F0)]);
    final powerIconColor = _isConnected ? Colors.white : Colors.grey[400];

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          children: [
            // Бейдж статуса
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: _isConnected
                    ? const Color(0xFFE8F5E9)
                    : (isDark ? Colors.grey[800] : Colors.grey[300]),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _connecting
                    ? "ПОДКЛЮЧЕНИЕ…"
                    : (_isConnected ? "ПОДКЛЮЧЕНО · БЕСПЛАТНО" : "ОТКЛЮЧЕНО"),
                style: TextStyle(
                  color: _isConnected
                      ? const Color(0xFF2E7D32)
                      : (isDark ? Colors.white70 : Colors.black54),
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            const SizedBox(height: 18),

            // Карточка с текущим IP
            GestureDetector(
              onTap: () => _updateIpInfo(),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(isDark ? 0.3 : 0.05),
                        blurRadius: 20,
                        offset: const Offset(0, 10))
                  ],
                ),
                child: _isLoadingIp
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 6),
                          child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  color: Colors.blueAccent, strokeWidth: 2)),
                        ),
                      )
                    : Row(
                        children: [
                          Text(_getFlag(_countryCode), style: const TextStyle(fontSize: 30)),
                          const SizedBox(width: 18),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_currentIp,
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                        color: textColor)),
                                Text(_currentCity,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: isDark ? Colors.grey[400] : Colors.grey[600]),
                                    overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                          Icon(Icons.refresh_rounded, size: 16, color: Colors.grey[400]),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 24),

            // Кнопка питания
            GestureDetector(
              onTap: _connecting ? null : _toggleManually,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                height: 180,
                width: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight, colors: buttonColors),
                  boxShadow: [
                    BoxShadow(
                      color: _isConnected
                          ? const Color(0xFF00C853).withOpacity(0.6)
                          : Colors.black.withOpacity(0.1),
                      blurRadius: _isConnected ? 45 : 20,
                      spreadRadius: _isConnected ? 4 : 0,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Center(
                  child: _connecting
                      ? const SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                      : Icon(Icons.power_settings_new_rounded, size: 72, color: powerIconColor),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Выбор сервера
            SizedBox(
              width: 220,
              child: OutlinedButton.icon(
                onPressed: _showServerList,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: isDark ? Colors.grey[700]! : Colors.grey[400]!),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  backgroundColor: isDark ? Colors.white.withOpacity(0.05) : Colors.white,
                ),
                icon: Icon(Icons.list_rounded, size: 20, color: textColor),
                label: Text(
                  _freeServerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 28),

            // Карточка лимитов (тап — памятка о том, как работает триал)
            GestureDetector(
              onTap: _showInfoSheet,
              child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(isDark ? 0.3 : 0.05),
                      blurRadius: 20,
                      offset: const Offset(0, 10))
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Text("Остаток трафика",
                              style: TextStyle(
                                  color: isDark ? Colors.grey[400] : Colors.grey[600],
                                  fontSize: 14)),
                          const SizedBox(width: 6),
                          Icon(Icons.info_outline_rounded,
                              size: 15, color: isDark ? Colors.grey[500] : Colors.grey[500]),
                        ],
                      ),
                      Text(
                        _formatTrafficPair(t.remainingBytes, t.quotaBytes),
                        style: TextStyle(fontWeight: FontWeight.bold, color: textColor, fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                      backgroundColor: isDark ? Colors.grey[800] : Colors.grey[200],
                      valueColor: AlwaysStoppedAnimation(
                        progress > 0.85 ? Colors.redAccent : Colors.blueAccent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      const Icon(Icons.timer_outlined, size: 18, color: Colors.blueAccent),
                      const SizedBox(width: 8),
                      Text("До конца окна:",
                          style: TextStyle(color: isDark ? Colors.grey[400] : Colors.grey[600], fontSize: 14)),
                      const Spacer(),
                      Text(
                        _formatDuration(_displaySeconds),
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: textColor,
                            fontSize: 16,
                            fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            ),
            const SizedBox(height: 24),

            _buildBuyButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildCooldown(Color textColor, bool isDark) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 30, 28, 24),
        child: Column(
          children: [
            const SizedBox(height: 10),
            const Text("😴", style: TextStyle(fontSize: 64)),
            const SizedBox(height: 20),
            Text(
              "Бесплатный лимит исчерпан",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: textColor),
            ),
            const SizedBox(height: 12),
            Text(
              "Доступ восстановится через:",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: isDark ? Colors.grey[400] : Colors.grey[600]),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(isDark ? 0.3 : 0.06),
                      blurRadius: 20,
                      offset: const Offset(0, 10))
                ],
              ),
              child: Text(
                _formatDuration(_displaySeconds),
                style: TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              "Хотите без пауз и лимитов?\nОформите подписку 👇",
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 16,
                  color: isDark ? Colors.grey[300] : Colors.grey[700],
                  height: 1.5),
            ),
            const SizedBox(height: 20),
            _buildBuyButton(),
            const SizedBox(height: 14),
            TextButton(
              onPressed: _fetchStatus,
              child: const Text("Проверить сейчас",
                  style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBuyButton() {
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: ElevatedButton.icon(
        onPressed: _openBot,
        icon: const Icon(Icons.workspace_premium_rounded),
        label: const Text("Купить подписку",
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF2979FF),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 6,
        ),
      ),
    );
  }
}
