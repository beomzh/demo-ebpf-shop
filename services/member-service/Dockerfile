FROM docker.io/library/maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

# OpenShift 는 임의 UID(그룹 0)로 실행한다. jar 는 root 소유·읽기 전용, JVM 임시파일은 /tmp(emptyDir).
FROM docker.io/library/eclipse-temurin:21-jre
# 컨테이너 기본 시간대 = 한국 시간 (로그 ts 가 +09:00 으로 찍힘)
ENV TZ=Asia/Seoul
WORKDIR /app
COPY --from=build --chmod=644 /src/target/member-service.jar app.jar
EXPOSE 8080
USER 10001
CMD ["java", "-Dstdout.encoding=UTF-8", "-Dstderr.encoding=UTF-8", "-jar", "app.jar"]
