import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is read from `android/key.properties` (git-ignored, see
// `key.properties.example`). When the file is absent — a fresh clone, or CI
// without the keystore secrets — the release build falls back to the debug
// key so `flutter run --release` and `flutter build apk --release` still work.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.medora.medora"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (uses java.time APIs)
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.medora.medora"
        // Android 9 (Pie) minimum
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                // A missing entry must name itself; `as String` on a null
                // value only says "null cannot be cast to String".
                fun required(key: String): String =
                    keystoreProperties.getProperty(key)
                        ?: error("android/key.properties is missing $key")

                keyAlias = required("keyAlias")
                keyPassword = required("keyPassword")
                storeFile = file(required("storeFile"))
                storePassword = required("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Signed with the release keystore when android/key.properties
            // exists, otherwise with the debug key so `flutter run --release`
            // still works.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // Enable minification and apply ProGuard rules
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Core library desugaring — required by flutter_local_notifications for devices with API < 26
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

