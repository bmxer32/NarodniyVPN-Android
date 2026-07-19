import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
    id("kotlin-android")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    FileInputStream(localPropertiesFile).use { stream ->
        localProperties.load(stream)
    }
}

val flutterVersionCode = localProperties.getProperty("flutter.versionCode")
if (flutterVersionCode == null) {
    localProperties.setProperty("flutter.versionCode", "1")
}

val flutterVersionName = localProperties.getProperty("flutter.versionName")
if (flutterVersionName == null) {
    localProperties.setProperty("flutter.versionName", "1.0")
}

android {
    namespace = "online.narodniyvpn.app"
    compileSdk = 36
    // ИСПРАВЛЕНО: Версия NDK, которую просят плагины
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    sourceSets {
        getByName("main").java.srcDirs("src/main/kotlin")
    }

    defaultConfig {
        applicationId = "online.narodniyvpn.app"
        minSdk = 24
        targetSdk = 36
        versionCode = flutterVersionCode?.toInt() ?: 1
        versionName = flutterVersionName ?: "1.0"
        
        // arm64-v8a и armeabi-v7a поддерживаются
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
        
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        create("release") {
            keyAlias = localProperties.getProperty("keystore.alias")
            keyPassword = localProperties.getProperty("keystore.password")
            storeFile = file("upload-keystore.jks")
            storePassword = localProperties.getProperty("keystore.storePassword")
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            isDebuggable = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    // Исключаем только x86/x86_64, так как поддерживаем arm64-v8a и armeabi-v7a
    packaging {
        jniLibs {
            useLegacyPackaging = true
            excludes += listOf(
                "lib/x86/**",
                "lib/x86_64/**"
            )
        }
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.core:core-ktx:1.13.1")
    
    // ВАЖНО: Подключаем папку libs, чтобы найти libv2ray.aar (если он есть)
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.jar", "*.aar"))))
}