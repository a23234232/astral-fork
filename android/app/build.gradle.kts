import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val altBuild =
    System.getenv("ALT_BUILD") == "true" ||
        project.findProperty("altBuild") == "true"

if (!altBuild) {
    apply(plugin = "com.google.gms.google-services")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val resolvedApplicationId =
    System.getenv("ANDROID_APPLICATION_ID")
        ?: project.findProperty("applicationId") as String?
        ?: "com.kevin.astral"

android {
    namespace = "com.kevin.astral"
    // 保持 Flutter 默认的 compileSdk（3.47.9 = 36）。
    // 曾尝试改成 37，但 SDK 仓库里没有 platforms;android-37（只有 37.0/37.1/37.2
    // 这种 minor 版本包，AGP 8.11 不支持按 minor 指定），装不上；
    // 根因在 home_widget 的动态依赖，已在文件末尾用 resolutionStrategy 钉住 glance。
    compileSdk = flutter.compileSdkVersion
    // ndkVersion = flutter.ndkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // 启用 core library desugaring
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }
     // 添加 buildFeatures 配置
    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = resolvedApplicationId
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        // 添加对多窗口模式的配置
        manifestPlaceholders["isResizeableActivity"] = "true"
    }

  signingConfigs {
      create("release") {
          keyAlias = keystoreProperties["keyAlias"] as? String
          keyPassword = keystoreProperties["keyPassword"] as? String
          storeFile = keystoreProperties["storeFile"]?.let { file(it) }
          storePassword = keystoreProperties["storePassword"] as? String
      }
  }

    buildTypes {
        release {
          signingConfig = signingConfigs.getByName("release")
            //   signingConfig = signingConfigs.getByName("debug")

        }
    }

}

// 添加 dependencies 块
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // 添加对窗口模式的支持
    implementation("androidx.window:window:1.2.0-beta05")
    implementation("androidx.window:window-java:1.2.0-beta05")

    if (!altBuild) {
        // add the Firebase SDK for Google Analytics
        implementation("com.google.firebase:firebase-analytics:17.4.1")
        // add SDKs for any other desired Firebase products
        // https://firebase.google.com/docs/android/setup#available-libraries
    }
}

// 固定 androidx.glance 版本。
//
// 原因：home_widget 0.9.0 的 android/build.gradle 写的是动态版本
//   api "androidx.glance:glance-appwidget:1.+"
// Gradle 会解析到当时最新的 1.3.0-alpha02，而它的 AAR metadata 要求使用方
// compileSdk >= 37：
//   :app:checkReleaseAarMetadata FAILED
//   requires ... compile against version 37 or later of the Android APIs
// 但 Android SDK 仓库当前没有 platforms;android-37（只有 37.0 / 37.1 / 37.2
// 这类 minor 版本包，AGP 8.11 也不支持按 minor 指定 compileSdk），因此只能把
// glance 钉回稳定版 1.2.0（它只要求 compileSdk 35），让构建可复现。
configurations.all {
    resolutionStrategy {
        force("androidx.glance:glance-appwidget:1.2.0")
        force("androidx.glance:glance:1.2.0")
    }
}

flutter {
    source = "../.."
}
