# Debian 기반 공식 이미지: _ssl 모듈이 시스템 libssl.so.3 을 동적 링크한다 (eBPF uprobe 대상).
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
ENV PYTHONUNBUFFERED=1
EXPOSE 8080
USER 10001
CMD ["python", "app.py"]
