# --- Flutter Wrapper rules ---
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# --- Игнорируем Google Play Core (Deferred Components) ---
# Эти классы вызывает движок Flutter, но они не нужны, если мы не грузим модули динамически
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
-dontwarn com.google.android.play.core.**

# --- Защита V2Ray (твоя библиотека VPN) ---
-keep class libv2ray.** { *; }
-keep interface libv2ray.** { *; }

# --- Стандартные правила Android ---
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# --- HTTP и SSL классы (нужны для сетевых запросов) ---
-keep class javax.net.ssl.** { *; }
-keep class java.net.** { *; }
-keep class javax.security.** { *; }

# --- JSON парсинг (используется для конфига Xray) ---
-keep class org.json.** { *; }

# --- LocalSocket (передача TUN fd в tun2socks) ---
-keep class android.net.LocalSocket { *; }
-keep class android.net.LocalSocketAddress { *; }

# --- Классы приложения (VPN сервис, Tile и т.д.) ---
-keep class online.narodniyvpn.app.** { *; }