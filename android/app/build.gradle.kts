import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名（H-7）：从 android/key.properties 读取；该文件已 gitignore。
// CI 用 Secrets 生成该文件，本地无文件时回退 debug（仅限非 prod 构建）。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.trackerone.app"
    // 37：permission_handler_android 14.x 的 AAR 元数据要求依赖方 ≥37。
    // AGP 9.1 对 37 会提示“非推荐 SDK”（warning 可忽略）；
    // targetSdk 保持 36（发布目标，docs/00 §7）。
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications 需要 core library desugaring。
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 正式包名（ADR-015 已定稿，与高德/极光 Key 绑定，docs/15）。
        applicationId = "com.trackerone.app"
        minSdk = 24 // Android 7.0（docs/00 §7）
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 极光推送：默认使用正式 AppKey（与包名 com.trackerone.app 绑定），
        // 可通过 -PJPUSH_APPKEY=xxx 或 gradle.properties 覆盖（docs/10 §7.1）。
        manifestPlaceholders["JPUSH_PKGNAME"] = applicationId ?: ""
        manifestPlaceholders["JPUSH_APPKEY"] =
            (project.findProperty("JPUSH_APPKEY") ?: "2e6135fffb1db1d409ab1d62").toString()
        manifestPlaceholders["JPUSH_CHANNEL"] =
            (project.findProperty("JPUSH_CHANNEL") ?: "developer-default").toString()

        // 高德地图 Key 由原生 SDK 通过 --dart-define 注入（AMapInitializer），
        // 无需在此声明；如需原生渠道号可扩展。
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // H-7：prod 构建必须用正式签名；缺失 key.properties 时构建失败，
            // 避免用公开口令的 debug keystore 签出可被覆盖安装的"正式包"。
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            } else if (project.hasProperty("ALLOW_DEBUG_SIGNING")) {
                signingConfig = signingConfigs.getByName("debug")
            } else {
                throw GradleException(
                    "缺少 android/key.properties：release 构建需要正式签名。本地调试可加 -PALLOW_DEBUG_SIGNING=true（产物不可发布）"
                )
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // 中国大陆包拆分（docs/09 §3.9）应在 CI 中移除 firebase_* 依赖；
    // 此处不做构建期断言，避免海外包误报。
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
