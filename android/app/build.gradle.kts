import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Yayın anahtarı: android/key.properties varsa release derlemesi bu anahtarla imzalanır.
// Dosya yoksa (ör. depoyu yeni indiren biri) eskisi gibi debug anahtarı kullanılır.
// key.properties ve .jks dosyası GitHub'a gönderilmez (android/.gitignore).
val anahtarAyarlari = Properties()
val anahtarAyarDosyasi = rootProject.file("key.properties")
if (anahtarAyarDosyasi.exists()) {
    FileInputStream(anahtarAyarDosyasi).use { anahtarAyarlari.load(it) }
}

android {
    namespace = "com.example.kisisel_asistan"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.kisisel_asistan"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (anahtarAyarDosyasi.exists()) {
                keyAlias = anahtarAyarlari["keyAlias"] as String
                keyPassword = anahtarAyarlari["keyPassword"] as String
                storeFile = file(anahtarAyarlari["storeFile"] as String)
                storePassword = anahtarAyarlari["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (anahtarAyarDosyasi.exists()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            // Bildirim eklentisi, küçültme (R8) açıkken planlı bildirimleri okuyamıyor
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}