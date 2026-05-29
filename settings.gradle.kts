rootProject.name = "spring-durable-executor-sample"

includeBuild("../spring-durable-executor") {
    dependencySubstitution {
        substitute(module("com.durableexecutor:spring-durable-executor")).using(project(":"))
    }
}
