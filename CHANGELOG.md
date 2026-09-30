[2026-09-30 14:24]
- [Changed] - services/*/Dockerfile: ENV TZ=Asia/Seoul — 컨테이너 기본 시간대를 한국 시간으로
- [Changed] - services/*/ (payment server.js, delivery app.py, inventory app.rb, notification index.php, member·order JsonLog.java, product main.go, gateway JsonLog.cs): 로그 ts 를 UTC 대신 로컬 시간 + 오프셋(+09:00)으로
- [Changed] - services/product-service/main.go: time/tzdata 내장 — distroless 이미지에 시간대 데이터가 없어도 TZ 적용
- [Changed] - k8s/10-mysql.yaml, k8s/15-redis.yaml, k8s/60-loadgen.yaml: TZ 환경변수 (loadgen 은 시간대 데이터가 없어 KST-9)
- [Changed] - k8s/47-dns-forwarder.yaml, k8s/45-corp-dns.yaml: CoreDNS log 를 기본 형식으로 — 실제 클러스터 CoreDNS 처럼 클라이언트 IP:포트·질의 ID·응답 코드가 보이게
- [Changed] - scripts/corpdns.sh `forwarder_up`: 포워더 Corefile 이 바뀌면 파드 재시작 (CoreDNS 는 기동할 때만 설정을 읽음)
- [Changed] - README.md: 포워더·사내 DNS 로그 예시, 로그 ts 한국 시간 설명

