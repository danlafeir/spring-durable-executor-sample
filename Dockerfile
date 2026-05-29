FROM gradle:8.9-jdk17 AS build
WORKDIR /workspace
# Copy both the library and the sample so the composite build can resolve the dependency
COPY spring-durable-executor ./spring-durable-executor
COPY spring-durable-executor-sample ./spring-durable-executor-sample
WORKDIR /workspace/spring-durable-executor-sample
RUN gradle bootJar --no-daemon -x test

FROM eclipse-temurin:17-jre-jammy
WORKDIR /app
COPY --from=build /workspace/spring-durable-executor-sample/build/libs/*.jar app.jar
# Mount point for the durable-executions.json store — survives container restarts
VOLUME /app/data
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
