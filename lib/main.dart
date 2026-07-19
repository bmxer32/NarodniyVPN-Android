import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'vless_parser.dart';
import 'security_service.dart';
import 'activation_service.dart';
import 'subscription_service.dart';
import 'trial_service.dart';
import 'trial_screen.dart';
import 'update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'split_tunnel_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
  ));

  // Запускаем сразу с экраном загрузки, инициализацию делаем внутри MyApp —
  // так пользователь видит брендированную «загрузку», а не логотип Flutter.
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  ThemeMode _themeMode = ThemeMode.system;

  // Пока идёт инициализация — показываем экран загрузки.
  bool _ready = false;
  String? _savedKey;
  bool _onboardingDone = false;
  bool _trialClaimed = false;
  String? _androidId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Принудительное обновление из Google Play (IMMEDIATE) на старте.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      UpdateService.checkAndForceUpdate();
    });
    _resolveStartScreen();
  }

  Future<void> _resolveStartScreen() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedKey = prefs.getString('vpn_key');
    final bool onboardingDone = prefs.getBool('onboarding_done') ?? false;
    final bool trialClaimed = prefs.getBool(kTrialClaimedKey) ?? false;

    // Если активна платная подписка — триал не нужен. Иначе, если триал уже
    // получен на этом устройстве, заранее читаем ANDROID_ID для экрана триала.
    String? androidId;
    if ((savedKey == null || savedKey.isEmpty) && trialClaimed) {
      androidId = await TrialService.getAndroidId();
    }

    if (!mounted) return;
    setState(() {
      _savedKey = savedKey;
      _onboardingDone = onboardingDone;
      _trialClaimed = trialClaimed;
      _androidId = androidId;
      _ready = true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Возобновляем прерванный IMMEDIATE-флоу, чтобы юзер не остался на старой версии.
    if (state == AppLifecycleState.resumed) {
      UpdateService.checkAndForceUpdate();
    }
  }

  void _changeTheme(ThemeMode mode) {
    setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    final Widget startScreen;
    if (!_ready) {
      startScreen = const LoadingScreen();
    } else if (_savedKey != null && _savedKey!.isNotEmpty) {
      startScreen = HomeScreen(
        onThemeChanged: _changeTheme,
        currentMode: _themeMode,
        subscriptionUrl: _savedKey!,
      );
    } else if (_trialClaimed && _androidId != null) {
      startScreen = TrialScreen(
        onThemeChanged: _changeTheme,
        currentMode: _themeMode,
        androidId: _androidId!,
      );
    } else if (!_onboardingDone) {
      startScreen = OnboardingScreen(
        onThemeChanged: _changeTheme,
        currentMode: _themeMode,
      );
    } else {
      startScreen = LoginScreen(
        onThemeChanged: _changeTheme,
        currentMode: _themeMode,
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Народный VPN',
      themeMode: _themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF2F4F8),
        fontFamily: 'Roboto',
        useMaterial3: true,
        splashFactory: InkRipple.splashFactory, 
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      home: startScreen,
    );
  }
}

// --- ЭКРАН ЗАГРУЗКИ (вместо логотипа Flutter при запуске) ---
class LoadingScreen extends StatelessWidget {
  const LoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color bg = isDark ? const Color(0xFF121212) : const Color(0xFFF2F4F8);
    final Color textColor = isDark ? Colors.white : const Color(0xFF1D1D1F);

    return Scaffold(
      backgroundColor: bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RichText(
              text: TextSpan(
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: textColor),
                children: const [
                  TextSpan(text: "Народный "),
                  TextSpan(text: "V", style: TextStyle(color: Colors.redAccent)),
                  TextSpan(text: "PN", style: TextStyle(color: Colors.blueAccent)),
                ],
              ),
            ),
            const SizedBox(height: 28),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.blueAccent),
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка с версией приложения для блоков настроек (на всех экранах).
Widget buildVersionLabel() {
  return FutureBuilder<PackageInfo>(
    future: PackageInfo.fromPlatform(),
    builder: (context, snapshot) {
      final String v = snapshot.hasData ? snapshot.data!.version : "...";
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 15),
        child: Text("Версия $v",
            style: TextStyle(color: Colors.grey.withOpacity(0.5), fontSize: 12)),
      );
    },
  );
}

class SmoothPageLayout extends StatelessWidget {
  final List<Widget> children;
  const SmoothPageLayout({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).padding;
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 24.0, 
                  right: 24.0, 
                  top: 10 + padding.top, 
                  bottom: 20 + padding.bottom 
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween, 
                  children: children,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// --- ОНБОРДИНГ ---
class OnboardingScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final ThemeMode currentMode;

  const OnboardingScreen({super.key, required this.onThemeChanged, required this.currentMode});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _curve;

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    _curve = CurvedAnimation(parent: _animController, curve: Curves.easeInOutQuart);

    // После заставки сразу переходим на экран входа.
    _animController.forward().then((_) {
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) _finishOnboarding();
      });
    });
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => LoginScreen(
          onThemeChanged: widget.onThemeChanged,
          currentMode: widget.currentMode,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color bg = isDark ? const Color(0xFF121212) : const Color(0xFFF2F4F8);
    final Color textColor = isDark ? Colors.white : const Color(0xFF1D1D1F);

    return Scaffold(
      backgroundColor: bg,
      body: _buildPage1(textColor),
    );
  }

  // --- Страница 1: Анимация ---
  Widget _buildPage1(Color textColor) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _curve,
        builder: (context, _) {
          final screenH = MediaQuery.of(context).size.height;
          final progress = _curve.value;
          final topOffset = (1 - progress) * -screenH;
          final botOffset = (1 - progress) * screenH;

          return Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Transform.translate(
                  offset: Offset(0, topOffset),
                  child: Text(
                    "Народный ",
                    style: TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                ),
                Transform.translate(
                  offset: Offset(0, botOffset),
                  child: RichText(
                    text: const TextSpan(
                      children: [
                        TextSpan(
                          text: "V",
                          style: TextStyle(fontSize: 38, fontWeight: FontWeight.bold, color: Colors.redAccent),
                        ),
                        TextSpan(
                          text: "PN",
                          style: TextStyle(fontSize: 38, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

}

// --- ЭКРАН ВХОДА ---
class LoginScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final ThemeMode currentMode;

  const LoginScreen({
    super.key, 
    required this.onThemeChanged,
    required this.currentMode,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with WidgetsBindingObserver {
  final TextEditingController _keyController = TextEditingController();
  bool _hasText = false;
  bool _isLoading = false;
  bool _trialLoading = false;

  bool _showPasteSuccess = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); 
    _checkClipboard(); 
    _keyController.addListener(() {
      final text = _keyController.text.trim();
      if (_hasText != text.isNotEmpty) setState(() => _hasText = text.isNotEmpty);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
    }
  }

  Future<void> _checkClipboard() async {
    if (_keyController.text.isNotEmpty) return;

    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null) {
      String content = data.text!.trim();
      
      if (SecurityService.isNarodniyLink(content) || content.startsWith("http") || content.startsWith("vless://")) {
         setState(() {
           _keyController.text = content;
           _keyController.selection = TextSelection.fromPosition(TextPosition(offset: _keyController.text.length));
           
           _showPasteSuccess = true;
         });

         Future.delayed(const Duration(milliseconds: 1500), () {
           if (mounted) {
             setState(() => _showPasteSuccess = false);
           }
         });
      } 
    }
  }

  void _showThemeSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      isScrollControlled: true, 
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SingleChildScrollView( 
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Wrap(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Center(
                      child: Container(
                        width: 40, height: 4,
                        decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                  ),
                  _buildThemeOption(Icons.brightness_auto, "Системная", ThemeMode.system),
                  _buildThemeOption(Icons.wb_sunny_rounded, "Светлая", ThemeMode.light),
                  _buildThemeOption(Icons.nightlight_round, "Темная", ThemeMode.dark),
                  const Divider(),
                  Center(child: buildVersionLabel()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildThemeOption(IconData icon, String title, ThemeMode mode) {
    final isSelected = widget.currentMode == mode;
    final color = isSelected ? Colors.blueAccent : Theme.of(context).iconTheme.color;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: TextStyle(color: color, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      trailing: isSelected ? const Icon(Icons.check_circle_rounded, color: Colors.blueAccent) : null,
      onTap: () {
        widget.onThemeChanged(mode);
        Navigator.pop(context);
      },
    );
  }

  // --- ЛОГИКА ВХОДА ---
  void _login() async {
    String input = _keyController.text.trim();
    String? cleanUrl; 
    
    if (input.isEmpty) {
      _showError("Поле не может быть пустым");
      return;
    }

    if (SecurityService.isNarodniyLink(input)) {
      cleanUrl = SecurityService.decrypt(input);
      if (cleanUrl == null) {
        _showError("Ошибка: Неверный зашифрованный ключ");
        return;
      }
    } else {
      cleanUrl = input;
    }

    bool isRawKey = cleanUrl!.startsWith("vless://");
    
    if (!isRawKey && !cleanUrl.startsWith("http://") && !cleanUrl.startsWith("https://")) {
      _showError("Неверный формат. Вставьте ссылку-подписку или VLESS ключ.");
      return;
    }

    if (!isRawKey) {
      cleanUrl = SubscriptionService.sanitizeUrl(cleanUrl);
    }

    setState(() => _isLoading = true);

    try {
      final configs = await SubscriptionService.getSmartConfigList(cleanUrl!, forceUpdate: true);
      
      if (configs.isEmpty) {
        setState(() => _isLoading = false);
        _showError("Ошибка: Список конфигураций пуст или сервер недоступен");
        return; 
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (e.toString().contains("BALANCE_EMPTY")) {
         _showError("Ошибка: Подписка истекла или удалена!");
      } else {
         _showError("Не удалось загрузить настройки: $e");
      }
      return;
    }

    int responseCode = 200; 
    
    if (!isRawKey) {
       responseCode = await ActivationService.activateKey(cleanUrl);
    }

    if (!mounted) return;
    setState(() => _isLoading = false);

    bool allowAccess = false;

    if (responseCode == 200) {
      allowAccess = true;
    } 
    else if (responseCode == 404) {
      allowAccess = true;
    }

    if (allowAccess) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vpn_key', cleanUrl);

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => HomeScreen(
            onThemeChanged: widget.onThemeChanged,
            currentMode: widget.currentMode,
            subscriptionUrl: cleanUrl!, 
          ),
        ),
      );
    } else if (responseCode == 409) {
      _showDialog("Доступ запрещен", "Эта подписка уже активирована на другом устройстве.");
    } else if (responseCode == -1) {
      _showError("Ошибка сети. Проверьте интернет.");
    } else {
      _showError("Ошибка активации (Код $responseCode)");
    }
  }

  // --- БЕСПЛАТНЫЙ TRIAL (без регистрации/Telegram) ---
  Future<void> _startTrial() async {
    if (_trialLoading || _isLoading) return;
    setState(() => _trialLoading = true);

    final String? androidId = await TrialService.getAndroidId();
    if (androidId == null) {
      if (mounted) setState(() => _trialLoading = false);
      _showError("Не удалось определить устройство. Попробуйте позже.");
      return;
    }

    try {
      TrialState state;
      try {
        state = await TrialService.claim(androidId);
      } catch (claimErr) {
        // Если claim недоступен (например, 503) — пробуем status: бэкенд
        // возвращает по нему текущее состояние триала. Если и он не отвечает —
        // прокидываем исходную ошибку дальше.
        try {
          state = await TrialService.status(androidId);
        } catch (_) {
          throw claimErr;
        }
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kTrialClaimedKey, true);
      await prefs.setBool('onboarding_done', true);

      if (!mounted) return;
      setState(() => _trialLoading = false);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => TrialScreen(
            onThemeChanged: widget.onThemeChanged,
            currentMode: widget.currentMode,
            androidId: androidId,
            initialState: state,
          ),
        ),
      );
    } on TrialException catch (e) {
      if (mounted) setState(() => _trialLoading = false);
      _showError(e.message);
    } catch (_) {
      if (mounted) setState(() => _trialLoading = false);
      _showError("Нет соединения с сервером. Проверьте интернет.");
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.redAccent));
  }

  void _showDialog(String title, String content) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
        title: Text(title), content: Text(content),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK"))],
    ));
  }

  Future<void> _pasteFromClipboard() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null) {
      setState(() {
        _keyController.text = data.text!.trim();
      });
    }
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
    } catch (e) {}
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color textColor = isDark ? Colors.white : const Color(0xFF1D1D1F);
    final Color inputFill = isDark ? const Color(0xFF2C2C2C) : Colors.white;
    final Color iconColor = isDark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF2F4F8),
      body: SmoothPageLayout(
        children: [
          const SizedBox(height: 10),
          Row(
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
              GestureDetector(
                onTap: _showThemeSettings,
                child: Container(
                  color: Colors.transparent, 
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.settings_rounded, size: 28, color: iconColor), 
                ),
              ),
            ],
          ),
          const Spacer(),
          Text("Добро пожаловать", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: textColor), textAlign: TextAlign.center),
          const SizedBox(height: 10),
          Text("Введите ссылку-подписку или VLESS ключ", style: TextStyle(fontSize: 16, color: isDark ? Colors.grey[400] : Colors.grey[500]), textAlign: TextAlign.center),
          const SizedBox(height: 40),
          
          Container(
            decoration: BoxDecoration(
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 15, offset: const Offset(0, 5))],
            ),
            child: TextField(
              controller: _keyController,
              enabled: !_isLoading,
              style: TextStyle(color: textColor),
              cursorColor: Colors.blueAccent,
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.link_rounded, color: Colors.grey[500]),
                suffixIcon: IconButton(
                  icon: Icon(Icons.paste_rounded, color: Colors.grey[500]),
                  onPressed: _isLoading ? null : _pasteFromClipboard,
                  tooltip: "Вставить из буфера",
                ),
                hintText: "https://... или vless://...",
                hintStyle: TextStyle(color: Colors.grey[500]),
                filled: true,
                fillColor: inputFill,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
              ),
            ),
          ),

          AnimatedOpacity(
            opacity: _showPasteSuccess ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle_rounded, color: Colors.green, size: 16),
                  const SizedBox(width: 6),
                  const Text(
                    "Ссылка вставлена автоматически",
                    style: TextStyle(
                      color: Colors.green, 
                      fontWeight: FontWeight.bold,
                      fontSize: 14
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 25),
          SizedBox(
            width: double.infinity,
            height: 60,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _login,
              style: ElevatedButton.styleFrom(
                backgroundColor: (_hasText && !_isLoading) ? const Color(0xFF2979FF) : const Color(0xFF9098A5),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                elevation: (_hasText && !_isLoading) ? 8 : 2,
              ),
              child: _isLoading 
                ? const SizedBox(
                    width: 24, height: 24, 
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                  )
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text("Активировать и Войти", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      SizedBox(width: 10),
                      Icon(Icons.arrow_forward_rounded),
                    ],
                  ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: Divider(color: Colors.grey.withOpacity(0.4))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text("или", style: TextStyle(color: Colors.grey[500], fontSize: 14)),
              ),
              Expanded(child: Divider(color: Colors.grey.withOpacity(0.4))),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 60,
            child: ElevatedButton.icon(
              onPressed: (_isLoading || _trialLoading) ? null : _startTrial,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C853),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                elevation: 6,
              ),
              icon: _trialLoading
                  ? const SizedBox(
                      width: 22, height: 22,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.card_giftcard_rounded),
              label: Text(
                _trialLoading ? "Подключаем…" : "Попробовать бесплатно",
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Без регистрации · сразу рабочий VPN",
            style: TextStyle(color: isDark ? Colors.grey[500] : Colors.grey[600], fontSize: 13),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: _openBot,
            child: const Padding(
              padding: EdgeInsets.all(10.0),
              child: Text("Нет подписки? Получить", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.w600, fontSize: 15)),
            ),
          ),
          const Spacer(flex: 2),
        ],
      ),
    );
  }
}

// --- ГЛАВНЫЙ ЭКРАН ---
class HomeScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final ThemeMode currentMode;
  final String subscriptionUrl;

  const HomeScreen({
    super.key, 
    required this.onThemeChanged,
    required this.currentMode,
    required this.subscriptionUrl, 
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const platform = MethodChannel('online.narodniyvpn.app/vpn');

  bool _isConnected = false;
  bool _isConnecting = false;
  String _currentIp = "...";
  String _currentCity = "Загрузка...";
  String _countryCode = "--";
  bool _isLoadingIp = true;
  String _appVersion = "..."; 

  List<String> _servers = [];
  int _selectedServerIndex = -1;
  Map<int, int> _serverPings = {};
  bool _isPinging = false;
  bool _isOpeningServerList = false;
  StateSetter? _serverListModalSetter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkVpnState();
    _updateIpInfo().then((success) {
      if (!success) Future.delayed(const Duration(seconds: 4), _updateIpInfo);
    });
    _getAppVersion();
    _tryBackgroundUpdate();
    _loadServersInitial();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkVpnState();
      _updateIpInfo();
    }
  }

  Future<void> _checkVpnState() async {
    try {
      final bool isRunning = await platform.invokeMethod('checkState');
      
      if (mounted && _isConnected != isRunning) {
        setState(() {
          _isConnected = isRunning;
        });
        
        if (isRunning) {
            _updateIpInfo();
        }
      }
    } on PlatformException catch (e) {
      debugPrint("Ошибка проверки статуса: ${e.message}");
    }
  }

  Future<void> _loadServersInitial() async {
    try {
      List<String> configs = await SubscriptionService.getSmartConfigList(
        widget.subscriptionUrl,
        forceUpdate: true,
      );
      if (mounted) {
        setState(() => _servers = configs);
        _serverListModalSetter?.call(() {});
      }
    } catch (e) {
      if (e.toString().contains("BALANCE_EMPTY")) {
        _serverListModalSetter?.call(() {});
        _showZeroBalanceDialog();
      }
    }
  }

  Future<void> _tryBackgroundUpdate() async {
    await SubscriptionService.backgroundUpdate(widget.subscriptionUrl);
    if (!mounted) return;
    _loadServersInitial();
  }

  Future<void> _getAppVersion() async {
    try {
        PackageInfo packageInfo = await PackageInfo.fromPlatform();
        if (mounted) {
          setState(() {
            _appVersion = packageInfo.version.isNotEmpty ? packageInfo.version : "1.0.3";
          });
        }
    } catch(e) {}
  }

  void _showZeroBalanceDialog() {
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final bool isDark = Theme.of(context).brightness == Brightness.dark;
        final Color cardColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
        final Color textColor = isDark ? Colors.white : Colors.black87;

        return Dialog(
          insetPadding: const EdgeInsets.all(20.0), 
          elevation: 0,
          backgroundColor: cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.account_balance_wallet_rounded, 
                    size: 44, 
                    color: Colors.redAccent
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  "Баланс исчерпан 😔",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textColor),
                ),
                const SizedBox(height: 12),
                Text(
                  "Срок действия вашей подписки подошел к концу или закончился трафик. Пожалуйста, пополните баланс в нашем Telegram-боте.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: isDark ? Colors.grey[400] : Colors.grey[600], height: 1.4),
                ),
                const SizedBox(height: 25),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _openBot(); 
                    },
                    icon: const Icon(Icons.telegram),
                    label: const Text("Перейти в бота", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent, 
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(foregroundColor: Colors.grey),
                  child: const Text("Закрыть"),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pingAllServers(StateSetter setModalState) async {
    if (_isPinging) return;
    
    setModalState(() {
      _isPinging = true;
      _serverPings.clear();
    });

    for (int i = 0; i < _servers.length; i++) {
      final target = VlessParser.getTarget(_servers[i]);
      if (target == null) continue;

      final String host = target['address'];
      final int port = target['port'];

      final stopwatch = Stopwatch()..start();
      try {
        final socket = await Socket.connect(host, port, timeout: const Duration(milliseconds: 2000));
        socket.destroy();
        stopwatch.stop();
        
        if (mounted) {
          setModalState(() {
             _serverPings[i] = stopwatch.elapsedMilliseconds;
          });
        }
      } catch (e) {
        if (mounted) {
          setModalState(() {
             _serverPings[i] = -1; 
          });
        }
      }
    }
    
    setModalState(() => _isPinging = false);
  }

  Color _getPingColor(int ping) {
    if (ping == -1) return Colors.red;
    if (ping < 200) return Colors.green;
    if (ping < 500) return Colors.orange;
    return Colors.red;
  }

  Future<void> _restartVpn() async {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Смена сервера..."),
        duration: Duration(milliseconds: 800),
      ));

      try {
        await platform.invokeMethod('stopVpn');
      } catch(e) {}
      
      setState(() => _isConnected = false);

      await Future.delayed(const Duration(milliseconds: 700));

      _toggleVpn();
  }

  void _showServerList() {
    if (_isOpeningServerList) return;
    _isOpeningServerList = true;

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        final bool isDark = Theme.of(context).brightness == Brightness.dark;
        final Color iconColor = isDark ? Colors.white : Colors.black87;
        final Color headerColor = isDark ? Colors.grey[400]! : Colors.grey[700]!;

        bool isRefreshingSub = false;

        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            _serverListModalSetter = setModalState;

            if (_servers.isEmpty) {
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 20),
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Выберите сервер", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close), color: iconColor),
                        ],
                      ),
                    ),
                    const Divider(),
                    const SizedBox(height: 40),
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text("Загрузка серверов...", style: TextStyle(color: Colors.grey[500])),
                    const SizedBox(height: 40),
                  ],
                ),
              );
            }

            List<int> mainServerIndices = [];
            List<int> rescueServerIndices = [];

            for (int i = 0; i < _servers.length; i++) {
              if (VlessParser.getName(_servers[i]).contains('📄')) {
                rescueServerIndices.add(i);
              } else {
                mainServerIndices.add(i);
              }
            }

            mainServerIndices.sort((a, b) =>
                VlessParser.getName(_servers[a]).compareTo(VlessParser.getName(_servers[b])));

            rescueServerIndices.sort((a, b) =>
                VlessParser.getName(_servers[a]).compareTo(VlessParser.getName(_servers[b])));

            return Container(
              padding: const EdgeInsets.symmetric(vertical: 20),
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Выберите сервер", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 48, height: 48,
                              child: isRefreshingSub
                                  ? Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: iconColor)))
                                  : IconButton(
                                      icon: const Icon(Icons.refresh_rounded),
                                      color: iconColor,
                                      tooltip: "Обновить список серверов",
                                      onPressed: () async {
                                        setModalState(() => isRefreshingSub = true);
                                        final startTime = DateTime.now();

                                        try {
                                          List<String> newConfigs = await SubscriptionService.getSmartConfigList(widget.subscriptionUrl, forceUpdate: true);
                                          if (mounted) setState(() => _servers = newConfigs);
                                        } catch (e) {
                                          if (e.toString().contains("BALANCE_EMPTY")) {
                                            Navigator.pop(ctx);
                                            _showZeroBalanceDialog();
                                            return;
                                          }
                                        }
                                        
                                        final elapsed = DateTime.now().difference(startTime);
                                        const minDuration = Duration(seconds: 10);
                                        if (elapsed < minDuration) {
                                          await Future.delayed(minDuration - elapsed);
                                        }

                                        if (context.mounted) {
                                          setModalState(() => isRefreshingSub = false);
                                        }
                                      },
                                    ),
                            ),
                            
                            SizedBox(
                              width: 48, height: 48,
                              child: _isPinging
                                  ? Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: iconColor)))
                                  : IconButton(
                                      icon: const Icon(Icons.speed_rounded),
                                      color: iconColor,
                                      tooltip: "Проверить скорость",
                                      onPressed: () => _pingAllServers(setModalState),
                                    ),
                            ),
                            
                            IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close), color: iconColor),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView(
                      children: [
                        ListTile(
                          leading: CircleAvatar(
                            backgroundColor: _selectedServerIndex == -1 ? Colors.blueAccent : Colors.grey[300],
                            child: const Icon(Icons.auto_awesome, color: Colors.white, size: 20),
                          ),
                          title: const Text("Автоматически"),
                          subtitle: const Text("Лучший доступный сервер"),
                          trailing: _selectedServerIndex == -1 ? const Icon(Icons.check_circle, color: Colors.blueAccent) : null,
                          onTap: () {
                            bool needRestart = _isConnected; 
                            setState(() => _selectedServerIndex = -1);
                            Navigator.pop(ctx);
                            if (needRestart) _restartVpn(); 
                          },
                        ),

                        if (mainServerIndices.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 5),
                            child: Text("🚀 БЫСТРЫЕ СЕРВЕРЫ", style: TextStyle(color: headerColor, fontSize: 13, fontWeight: FontWeight.bold)),
                          ),
                          ...mainServerIndices.map((index) => _buildServerTile(index, isRescue: false)).toList(),
                        ],

                        if (rescueServerIndices.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 5),
                            child: Text("🛡 БЕЛЫЕ СПИСКИ (Анти глушилки)", 
                              style: TextStyle(color: headerColor, fontSize: 13, fontWeight: FontWeight.bold)),
                          ),
                          ...rescueServerIndices.map((index) => _buildServerTile(index, isRescue: true)).toList(),
                        ],
                        
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }
        );
      },
    ).whenComplete(() {
      _isOpeningServerList = false;
      _serverListModalSetter = null;
    });
  }

  Widget _buildServerTile(int index, {required bool isRescue}) {
    String config = _servers[index];
    String name = VlessParser.getName(config);
    bool isSelected = _selectedServerIndex == index;
    
    int? ping = _serverPings[index];
    Widget? trailingWidget;
    
    if (ping != null) {
      trailingWidget = Text(
        ping == -1 ? "Timeout" : "${ping}ms",
        style: TextStyle(fontWeight: FontWeight.bold, color: _getPingColor(ping)),
      );
    } else if (isSelected) {
      trailingWidget = const Icon(Icons.check_circle, color: Colors.blueAccent);
    }

    return ListTile(
      leading: Icon(
        isRescue ? Icons.shield_rounded : Icons.rocket_launch_rounded, 
        color: isSelected ? (isRescue ? Colors.green : Colors.blueAccent) : Colors.grey
      ),
      title: Text(name, overflow: TextOverflow.ellipsis),
      subtitle: null, 
      trailing: trailingWidget,
      onTap: () {
        bool needRestart = _isConnected; 
        setState(() => _selectedServerIndex = index);
        Navigator.pop(context);
        if (needRestart) _restartVpn(); 
      },
    );
  }

  Future<void> _openSupport() async {
     final Uri url = Uri.parse('https://t.me/narodniyVPN_support');
     try { await launchUrl(url, mode: LaunchMode.externalApplication); } catch (e) {}
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      isScrollControlled: true, 
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SingleChildScrollView(
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Container(
                      width: 40, height: 4,
                      decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  _buildThemeOption(Icons.brightness_auto, "Системная", ThemeMode.system),
                  _buildThemeOption(Icons.wb_sunny_rounded, "Светлая", ThemeMode.light),
                  _buildThemeOption(Icons.nightlight_round, "Темная", ThemeMode.dark),
                  
                  const Divider(),
                  
                  ListTile(
                    leading: const Icon(Icons.support_agent_rounded, color: Colors.blueAccent),
                    title: const Text("Поддержка", style: TextStyle(color: Colors.blueAccent)),
                    onTap: () {
                      Navigator.pop(context);
                      _openSupport();
                    },
                  ),

                  ListTile(
                    leading: const Icon(Icons.privacy_tip_rounded, color: Colors.grey),
                    title: const Text("Политика конфиденциальности"),
                    onTap: () {
                      Navigator.pop(context);
                      launchUrl(Uri.parse('https://narodniyvpn.online/privacy'), mode: LaunchMode.externalApplication);
                    },
                  ),

                  ListTile(
                    leading: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                    title: const Text("Сменить подписку (Выйти)", style: TextStyle(color: Colors.redAccent)),
                    onTap: () {
                      Navigator.pop(context);
                      _logout();
                    },
                  ),
                  
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    child: Text("Версия $_appVersion", style: TextStyle(color: Colors.grey.withOpacity(0.4), fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildThemeOption(IconData icon, String title, ThemeMode mode) {
    final isSelected = widget.currentMode == mode;
    final color = isSelected ? Colors.blueAccent : Theme.of(context).iconTheme.color;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: TextStyle(color: color, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      trailing: isSelected ? const Icon(Icons.check_circle_rounded, color: Colors.blueAccent) : null,
      onTap: () {
        widget.onThemeChanged(mode);
         Navigator.pop(context);
      },
    );
  }

  String _getFlag(String countryCode) {
    try {
      if (countryCode.length != 2) return "🌐";
      String country = countryCode.toUpperCase();
      if (!RegExp(r'^[A-Z]{2}$').hasMatch(country)) return "🌐";

      int flagOffset = 0x1F1E6;
      int asciiOffset = 0x41;

      int firstChar = country.codeUnitAt(0) - asciiOffset + flagOffset;
      int secondChar = country.codeUnitAt(1) - asciiOffset + flagOffset;

      return String.fromCharCode(firstChar) + String.fromCharCode(secondChar);
    } catch (e) {
      return "🏳️";
    }
  }

  Future<bool> _updateIpInfo({bool isSilent = false}) async {
    if (!mounted) return false;
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
        return true;
      } else {
        throw Exception('API Error');
      }
    } catch (e) {
      if (mounted && !isSilent && !_isConnecting) {
        setState(() {
          _currentIp = _isConnected ? "Нет сети" : "Ошибка";
          _currentCity = _isConnected ? "Ошибка VPN" : "Проверьте интернет";
          _isLoadingIp = false;
        });
      }
      return false;
    }
  }

  Future<void> _checkConnectionWithRetries() async {
    // Сокращённые задержки: 500мс → 1с → 2с (вместо 2с → 3с → 3с)
    const delaysMs = [500, 1000, 2000];
    for (int i = 0; i < delaysMs.length; i++) {
      await Future.delayed(Duration(milliseconds: delaysMs[i]));

      if (!mounted || !_isConnected) return;

      bool success = await _updateIpInfo(isSilent: true);
      if (success) {
        if (mounted) setState(() => _isConnecting = false);
        return;
      }
    }

    if (mounted && _isConnected) {
      if (mounted) setState(() => _isConnecting = false);
      await _updateIpInfo(isSilent: false);
      if (mounted && _isLoadingIp) {
        setState(() => _isLoadingIp = false);
      }
    }
  }

  Future<void> _toggleVpn() async {
    HapticFeedback.mediumImpact();

    if (_isConnected) {
      try {
        await platform.invokeMethod('stopVpn');
        setState(() { _isConnected = false; _isConnecting = false; });
        Future.delayed(const Duration(seconds: 1), () => _updateIpInfo());
      } on PlatformException catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Ошибка остановки: ${e.message}")));
      }
    } else {
      String url = widget.subscriptionUrl;

      // Мгновенная визуальная реакция: кнопка сразу становится зелёной
      setState(() {
        _isConnected = true;
        _isConnecting = true;
        _isLoadingIp = true;
        _currentCity = "Подключение...";
        _currentIp = "...";
      });

      List<String> configsToTry = [];
      try {
        // Сначала пробуем кеш (мгновенно), сеть только если кеш пуст
        configsToTry = await SubscriptionService.getSmartConfigList(url, forceUpdate: false);
      } catch (e) {
        if (e.toString().contains("BALANCE_EMPTY")) {
          setState(() { _isConnected = false; _isConnecting = false; });
          _showZeroBalanceDialog();
          return;
        }
      }

      if (configsToTry.isEmpty) {
          setState(() { _isConnected = false; _isConnecting = false; });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Ошибка: Список серверов пуст")));
          return;
      }

      _servers = configsToTry;
      bool success = false;

      if (_selectedServerIndex != -1 && _selectedServerIndex < configsToTry.length) {
        try {
           String config = configsToTry[_selectedServerIndex];
           String configJson = VlessParser.generateConfig(config);
           await platform.invokeMethod('startVpn', {"config": configJson});
           success = true;
        } catch (e) {
           debugPrint("Ошибка подключения к серверу #$_selectedServerIndex: $e");
        }
      } else {
        for (String config in configsToTry) {
          try {
            String configJson = VlessParser.generateConfig(config);
            await platform.invokeMethod('startVpn', {"config": configJson});
            success = true;
            break;
          } catch (e) {
            continue;
          }
        }
      }

      if (success) {
        // Запускаем проверку соединения и фоновое обновление подписки
        _checkConnectionWithRetries();
        SubscriptionService.backgroundUpdate(url);
      } else {
        setState(() { _isConnected = false; _isConnecting = false; });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Не удалось подключиться")));
      }
    }
  }

  void _logout() async {
    if (_isConnected) await platform.invokeMethod('stopVpn');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('vpn_key'); 
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => LoginScreen(
            onThemeChanged: widget.onThemeChanged,
            currentMode: widget.currentMode,
          ),
        ),
      );
    }
  }

  Future<void> _openChannel() async {
     final Uri url = Uri.parse('https://t.me/NarodniyVpn'); 
     try { await launchUrl(url, mode: LaunchMode.externalApplication); } catch (e) {}
  }

  Future<void> _openReferralProgram() async {
     final Uri url = Uri.parse('https://t.me/narodniy_vpn_bot?start=referral'); 
     try { await launchUrl(url, mode: LaunchMode.externalApplication); } catch (e) {}
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
    } catch (e) {}
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color textColor = isDark ? Colors.white : const Color(0xFF1D1D1F);
    final Color cardColor = isDark ? const Color(0xFF1E1E1E) : Colors.white; 
    final Color btnColor = isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE0E0E0);
    final Color iconColor = isDark ? Colors.white : Colors.black87;

    final buttonColors = _isConnected
        ? [const Color(0xFF00E676), const Color(0xFF00C853)] 
        : (isDark 
            ? [const Color(0xFF424242), const Color(0xFF212121)] 
            : [Colors.white, const Color(0xFFF0F0F0)]);
            
    final powerIconColor = _isConnected ? Colors.white : Colors.grey[400];
    
    String currentServerName = "Авто-выбор";
    if (_selectedServerIndex != -1 && _selectedServerIndex < _servers.length) {
       currentServerName = VlessParser.getName(_servers[_selectedServerIndex]);
       if (currentServerName.length > 20) currentServerName = "${currentServerName.substring(0, 18)}...";
    }

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF2F4F8),
      body: SmoothPageLayout(
        children: [
          const SizedBox(height: 10),
          Row(
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
              GestureDetector(
                onTap: _showSettings,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle, color: btnColor,
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
                  ),
                  child: Icon(Icons.settings_rounded, size: 20, color: iconColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 40),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: _isConnected ? const Color(0xFFE8F5E9) : (isDark ? Colors.grey[800] : Colors.grey[300]),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _isConnected ? "ПОДКЛЮЧЕНО" : "ОТКЛЮЧЕНО",
              style: TextStyle(
                color: _isConnected ? const Color(0xFF2E7D32) : (isDark ? Colors.white70 : Colors.black54),
                fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 20),

          GestureDetector(
            onTap: () => _updateIpInfo(isSilent: false),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cardColor, borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.3 : 0.05), blurRadius: 20, offset: const Offset(0, 10))],
              ),
              child: _isLoadingIp 
                  ? Center(child: CircularProgressIndicator(color: Colors.blueAccent, strokeWidth: 2)) 
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _getFlag(_countryCode), 
                          style: const TextStyle(fontSize: 32),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_currentIp, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: textColor)),
                              Text(_currentCity, style: TextStyle(fontSize: 12, color: isDark ? Colors.grey[400] : Colors.grey[600]), overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        Icon(Icons.refresh_rounded, size: 16, color: Colors.grey[400])
                      ],
                    ),
            ),
          ),

          const Spacer(),
          GestureDetector(
            onTap: _toggleVpn,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              height: 200, width: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: buttonColors),
                boxShadow: [
                  BoxShadow(
                    color: _isConnected ? const Color(0xFF00C853).withOpacity(0.6) : Colors.black.withOpacity(0.1),
                    blurRadius: _isConnected ? 50 : 20,
                    spreadRadius: _isConnected ? 5 : 0,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Center(child: Icon(Icons.power_settings_new_rounded, size: 80, color: powerIconColor)),
            ),
          ),
          
          const SizedBox(height: 25),
          SizedBox(
            width: 200,
            child: OutlinedButton.icon(
              onPressed: _showServerList, 
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                side: BorderSide(color: isDark ? Colors.grey[700]! : Colors.grey[400]!),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                backgroundColor: isDark ? Colors.white.withOpacity(0.05) : Colors.white,
              ),
              icon: Icon(Icons.list_rounded, size: 20, color: isDark ? Colors.white : Colors.black87),
              label: Text(
                currentServerName,
                style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          
          const Spacer(),
          
          Row(
            children: [
              Expanded(
                child: _buildBottomCard(
                  icon: Icons.card_giftcard_rounded, label: "7 Дней\nБесплатно", color: const Color(0xFFAB47BC), 
                  isDark: isDark, cardColor: cardColor, textColor: textColor, onTap: _openReferralProgram, 
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildBottomCard(
                  icon: Icons.tune_rounded, label: "Приложения\nVPN", color: const Color(0xFF00897B),
                  isDark: isDark, cardColor: cardColor, textColor: textColor,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SplitTunnelScreen())),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _buildBottomCard({
    required IconData icon, required String label, required Color color, required bool isDark,
    required Color cardColor, required Color textColor, required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 100, 
        decoration: BoxDecoration(
          color: cardColor, borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.2 : 0.05), blurRadius: 15, offset: const Offset(0, 8))],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center, 
            children: [
              Icon(icon, color: color, size: 30),
              const SizedBox(height: 8),
              Text(label, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, color: textColor, fontSize: 13, height: 1.2)),
            ],
          ),
        ),
      ),
    );
  }
}