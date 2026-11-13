plugins { kotlin("jvm") version "2.1.0" }
repositories { mavenCentral() }
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
java { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
sourceSets {
    main { kotlin.srcDir("../../android/app/src/main/kotlin/org/mewx/wenku8_flutter/legado") }
    test { kotlin.srcDir("../../android/app/src/test/kotlin/org/mewx/wenku8_flutter/legado") }
}
dependencies {
    implementation("org.mozilla:rhino:1.7.15")
    implementation("com.jayway.jsonpath:json-path:2.9.0")
    implementation("org.jsoup:jsoup:1.23.2")
    implementation("org.json:json:20250517")
    testImplementation("junit:junit:4.13.2")
}
sourceSets.main { kotlin.srcDir("src/main/kotlin") }
tasks.register<JavaExec>("smoke") {
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("SourceSmokeKt")
    args(providers.gradleProperty("sourceFile").getOrElse("sources.json"), providers.gradleProperty("sourceIndex").getOrElse("12"), providers.gradleProperty("query").getOrElse("斗破"))
    systemProperties(System.getProperties().entries.filter { it.key.toString().startsWith("http.") || it.key.toString().startsWith("https.") }.associate { it.key.toString() to it.value })
}
