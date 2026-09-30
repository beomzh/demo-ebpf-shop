FROM docker.io/library/php:8.3-cli
# 컨테이너 기본 시간대 = 한국 시간 (로그 ts 가 +09:00 으로 찍힘)
ENV TZ=Asia/Seoul
WORKDIR /app
COPY --chmod=644 index.php .
# 내장 웹서버를 여러 워커로 띄운다 (한 요청이 느려도 다른 요청을 막지 않게)
ENV PHP_CLI_SERVER_WORKERS=4
EXPOSE 8080
# -q: 내장 서버의 요청별 접근 로그(Accepted/Closing)를 끈다 — 앱 로그(JSON)만 남도록
# OpenShift 는 임의 UID(그룹 0)로 실행한다
USER 10001
CMD ["php", "-q", "-S", "0.0.0.0:8080", "index.php"]
