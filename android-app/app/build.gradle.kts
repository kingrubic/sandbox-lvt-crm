import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.gms.google-services")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}

fun localProperty(name: String): String? {
    val fromFile = localProperties.getProperty(name)?.trim().orEmpty()
    if (fromFile.isNotEmpty()) return fromFile
    return (project.findProperty(name) as String?)?.trim()?.takeIf { it.isNotEmpty() }
}

val lvtVersionCode = 46
val lvtVersionName = "0.22.0"

android {
    namespace = "lvt.crm"
    compileSdk = 36

    defaultConfig {
        applicationId = "lvt.crm"
        minSdk = 26
        targetSdk = 36
        versionCode = lvtVersionCode
        // x.y.z — x new menu, y new feature (no new menu), z bug fix
        versionName = lvtVersionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

    }

    signingConfigs {
        create("release") {
            val storePath = localProperty("lvt.release.storeFile").orEmpty()
            if (storePath.isNotEmpty()) {
                storeFile = rootProject.file(storePath)
                storePassword = localProperty("lvt.release.storePassword")
                keyAlias = localProperty("lvt.release.keyAlias") ?: "lvt-release"
                keyPassword = localProperty("lvt.release.keyPassword") ?: storePassword
                // AAB upload to Play requires a JAR (v1) signature on the bundle.
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            isMinifyEnabled = false
            buildConfigField(
                "String",
                "CONVEX_URL",
                "\"${localProperty("lvt.convex.debug.url") ?: project.findProperty("lvt.convex.debug.url") ?: "https://confident-guanaco-953.convex.cloud"}\"",
            )
            buildConfigField(
                "String",
                "WEB_URL",
                "\"${localProperty("lvt.web.debug.url") ?: project.findProperty("lvt.web.debug.url") ?: "https://lvt.vscgroup.io.vn"}\"",
            )
        }
        release {
            val releaseSigning = signingConfigs.getByName("release")
            if (releaseSigning.storeFile != null) {
                signingConfig = releaseSigning
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            buildConfigField(
                "String",
                "CONVEX_URL",
                "\"${localProperty("lvt.convex.release.url") ?: project.findProperty("lvt.convex.release.url") ?: "https://confident-guanaco-953.convex.cloud"}\"",
            )
            buildConfigField(
                "String",
                "WEB_URL",
                "\"${localProperty("lvt.web.release.url") ?: project.findProperty("lvt.web.release.url") ?: "https://lvt.vscgroup.io.vn"}\"",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.navigation:navigation-compose:2.8.5")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("androidx.compose.foundation:foundation")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.firebase:firebase-messaging:24.1.2")
    implementation("com.google.android.play:app-update:2.1.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("org.json:json:20240303")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

base {
    archivesName.set("lvt-crm-$lvtVersionName-$lvtVersionCode")
}

tasks.matching { it.name == "bundleRelease" }.configureEach {
    doLast {
        val dir = layout.buildDirectory.dir("outputs/bundle/release").get().asFile
        val dest = dir.resolve("lvt-crm-$lvtVersionName-$lvtVersionCode.aab")
        val src = dir.listFiles()
            ?.filter { it.extension == "aab" && it.name != dest.name }
            ?.maxByOrNull { it.lastModified() }
        if (src != null && src.exists()) {
            src.copyTo(dest, overwrite = true)
        }
    }
}
