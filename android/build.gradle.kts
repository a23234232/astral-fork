buildscript {
    repositories {
        // Check that you have the following line (if not, add it):
        google()  // Google's Maven repository
        mavenCentral()
    }
    dependencies {
        // Add this line
        classpath("com.google.gms:google-services:4.3.3")
    }
}

// 只把 Kotlin 插件「挂到根构建脚本的 classpath」，不在这里应用（apply false）。
// 目的：让下面的 subprojects 块能拿到 KotlinCompile 类型，从而统一各模块的
// JVM target。版本由 settings.gradle.kts 的 pluginManagement 提供，不重复声明。
plugins {
    id("org.jetbrains.kotlin.android") apply false
}

allprojects {
    repositories {
        // Check that you have the following line (if not, add it):
        google()  // Google's Maven repository
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 统一所有模块（含第三方插件）的 JVM target 为 11。
//
// 背景：home_widget 0.9.0 之类的插件仍按 JVM target 1.8 编译，而它们内联的
// androidx / Flutter embedding 是 11，Kotlin 2.2 会直接报错：
//   Cannot inline bytecode built with JVM target 11 into bytecode that is being
//   built with JVM target 1.8. Specify proper '-jvm-target' option.
// 该错误不受 kotlin.jvm.target.validation.mode 影响（那个开关只作用于
// 「JVM target 不一致」的校验），必须在模块级把目标对齐。
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        // 用 compilerOptions（Kotlin 2.x 的稳定 API），不用已废弃的 kotlinOptions。
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
        }
    }
    tasks.withType<JavaCompile>().configureEach {
        sourceCompatibility = JavaVersion.VERSION_11.toString()
        targetCompatibility = JavaVersion.VERSION_11.toString()
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
