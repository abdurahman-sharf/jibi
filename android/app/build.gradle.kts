import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from android/key.properties (see key.properties.example
// and docs/release/runbook.md). The file and the keystore stay out of the
// project tree's version control; a release build without them fails on
// purpose instead of silently falling back to the debug key.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}
val hasReleaseKey = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { !keyProperties.getProperty(it).isNullOrBlank() }

val releaseTaskPattern = Regex("^.*:(assemble|bundle|package|sign)[A-Za-z]*Release.*$")
gradle.taskGraph.whenReady {
    if (!hasReleaseKey && allTasks.any { releaseTaskPattern.matches(it.path) }) {
        throw GradleException(
            "Release signing is not configured. Create android/key.properties " +
                "(see android/key.properties.example and docs/release/runbook.md).",
        )
    }
}

android {
    namespace = "com.jibi.jibi"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (java.time on older Android).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The application id is permanent once the app is published. It is the
        // Play Console identity (com.alawal.jibi); `namespace` above is only the
        // code package (R class, MainActivity) and stays com.jibi.jibi on purpose.
        applicationId = "com.alawal.jibi"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Both come from `version:` in pubspec.yaml (1.10.0+16 = name + code).
        // Google Play needs a higher versionCode for every upload.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKey) {
                signingConfig = signingConfigs.getByName("release")
            }
            // The Flutter plugin already enables these (and adds
            // proguard-rules.pro); they are stated here so a Flutter upgrade
            // can never turn shrinking off unnoticed.
            isMinifyEnabled = true
            isShrinkResources = true
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
