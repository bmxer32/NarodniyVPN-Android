pluginManagement {
    val flutterSdkPath = try {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        properties.getProperty("flutter.sdk")
    } catch (e: Exception) {
        throw GradleException("flutter.sdk not set in local.properties")
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // ОБНОВЛЕНО: Подняли версию AGP до 8.9.1 (Требование библиотек)
    id("com.android.application") version "8.9.1" apply false
    // ОБНОВЛЕНО: Подняли Kotlin до 2.1.0 (Рекомендация)
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}