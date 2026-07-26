plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "dev.lorepia.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.lorepia.app"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += setOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    sourceSets {
        named("main") {
            java.srcDir("src/main/generated")
            jniLibs.srcDir("src/main/jniLibs")
        }
        named("androidTest") {
            assets.srcDir(rootProject.file("../../testdata/packages"))
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = false
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }

    lint {
        abortOnError = true
        checkReleaseBuilds = true
    }
}

val requiredNativeAbis = listOf("arm64-v8a", "x86_64")
val verifyRustNativeLibraries by tasks.registering {
    group = "verification"
    description = "Verifies that every supported ABI has the Rust UniFFI library."
    doLast {
        val jniRoot = layout.projectDirectory.dir("src/main/jniLibs").asFile
        val missing = requiredNativeAbis.filter { abi ->
            !jniRoot.resolve("$abi/liblorepia_uniffi.so").isFile
        }
        check(missing.isEmpty()) {
            "Missing liblorepia_uniffi.so for: ${missing.joinToString()}. " +
                "Run scripts/build-android.sh from the repository root."
        }
    }
}

tasks.matching { task ->
    task.name == "mergeDebugNativeLibs" || task.name == "mergeReleaseNativeLibs"
}.configureEach {
    dependsOn(verifyRustNativeLibraries)
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(platform(libs.androidx.compose.bom))

    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(variantOf(libs.jna) { artifactType("aar") })
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)

    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.test.espresso.core)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)

    debugImplementation(libs.androidx.compose.ui.test.manifest)
    debugImplementation(libs.androidx.compose.ui.tooling)
}
