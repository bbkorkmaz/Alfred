allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Eski eklentilerin (ör. file_picker) derleme sürümünü 36'ya yükseltir
subprojects {
    afterEvaluate {
        if (project.name != "app") {
            val android = project.extensions.findByName("android")
            if (android != null && android.javaClass.name.contains("Library")) {
                val metot = android.javaClass.methods.firstOrNull {
                    (it.name == "setCompileSdk" || it.name == "compileSdkVersion") &&
                        it.parameterTypes.size == 1 &&
                        (it.parameterTypes[0] == Int::class.javaPrimitiveType || it.parameterTypes[0] == Int::class.javaObjectType)
                }
                metot?.invoke(android, 36)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}