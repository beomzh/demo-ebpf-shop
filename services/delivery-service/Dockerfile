# Debian 기반 공식 이미지: _ssl 모듈이 시스템 libssl.so.3 을 동적 링크한다 (eBPF uprobe 대상).
# OpenShift 는 임의 UID(그룹 0)로 실행하므로 앱 파일은 root 소유·읽기 전용(644)으로 둔다.
FROM docker.io/library/python:3.12-slim
WORKDIR /app
COPY --chmod=644 app.py .
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
EXPOSE 8080
USER 10001
CMD ["python", "app.py"]
