FROM docker.io/library/php:8.3-cli
WORKDIR /app
COPY --chmod=644 index.php .
# 내장 웹서버를 여러 워커로 띄운다 (한 요청이 느려도 다른 요청을 막지 않게)
ENV PHP_CLI_SERVER_WORKERS=4
EXPOSE 8080
# OpenShift 는 임의 UID(그룹 0)로 실행한다
USER 10001
CMD ["php", "-S", "0.0.0.0:8080", "index.php"]
