import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasSigningProperties = keystorePropertiesFile.exists()

if (hasSigningProperties) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val signingMode = keystoreProperties.getProperty("signingMode", "private")
val historicalSigningFile = File(
    System.getProperty("user.home"),
    "Library/Application Support/Recall/signing/recall-historical.keystore",
)
val usesHistoricalContinuityKey =
    hasSigningProperties &&
        signingMode == "historicalContinuity" &&
        historicalSigningFile.isFile
val requiredPrivateSigningProperties = listOf(
    "keyAlias",
    "keyPassword",
    "storeFile",
    "storePassword",
)
val usesPrivateReleaseKey =
    hasSigningProperties &&
        signingMode == "private" &&
        requiredPrivateSigningProperties.all {
            !keystoreProperties.getProperty(it).isNullOrBlank()
        } &&
        rootProject.file(keystoreProperties.getProperty("storeFile", "missing")).isFile
val hasReleaseSigning = usesHistoricalContinuityKey || usesPrivateReleaseKey

gradle.taskGraph.whenReady {
    if (!hasReleaseSigning && allTasks.any { it.name.contains("Release") }) {
        throw GradleException(
            "Release signing requires android/key.properties. " +
                "Select a complete private keystore or the provisioned " +
                "historicalContinuity mode.",
        )
    }
}

android {
    namespace = "com.german.health_anki_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.german.health_anki_flutter"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        getByName("debug") {
            if (usesHistoricalContinuityKey) {
                // This is the exact key behind Recall's first Android build.
                // Keeping AGP's built-in debug credentials avoids copying a
                // credential into source or command output; the owner-only
                // keystore file is the continuity identity.
                storeFile = historicalSigningFile
            }
        }
        create("release") {
            if (usesPrivateReleaseKey) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = rootProject.file(
                    keystoreProperties.getProperty("storeFile"),
                )
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (usesPrivateReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    testOptions {
        unitTests.all {
            it.useJUnit()
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
}
