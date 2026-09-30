# OpenShift 는 임의 UID(그룹 0)로 실행한다. 쿠버네티스 runAsNonRoot 검사를 통과하도록 USER 는 숫자로 둔다.
FROM docker.io/library/node:20-slim
# 컨테이너 기본 시간대 = 한국 시간 (로그 ts 가 +09:00 으로 찍힘)
ENV TZ=Asia/Seoul
WORKDIR /app
COPY --chmod=644 package.json server.js ./
ENV NODE_ENV=production
EXPOSE 8080
USER 1000
CMD ["node", "server.js"]
