# OpenShift 는 임의 UID(그룹 0)로 실행한다. 쿠버네티스 runAsNonRoot 검사를 통과하도록 USER 는 숫자로 둔다.
FROM node:20-slim
WORKDIR /app
COPY --chmod=644 package.json server.js ./
ENV NODE_ENV=production
EXPOSE 8080
USER 1000
CMD ["node", "server.js"]
