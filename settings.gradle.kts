rootProject.name = "spring-durable-executor-sample"

includeBuild("../durable-executor") {
    dependencySubstitution {
        substitute(module("com.github.danlafeir:durable-executor-spring")).using(project(":durable-executor-spring"))
    }
}
