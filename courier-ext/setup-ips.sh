#!/usr/bin/env bash
# 택배사 호스트에 택배사 API 용 보조 IP 를 붙인다 (호스트의 다른 서비스와 443 을 나눠 쓸 때).
#   sudo ./setup-ips.sh add  <NIC> <IP>/<PREFIX>    예) sudo ./setup-ips.sh add eth0 10.0.0.61/24
#   sudo ./setup-ips.sh del  <NIC> <IP>/<PREFIX>
#   ./setup-ips.sh show
# 주의: ip addr 로 붙인 IP 는 재부팅하면 사라진다. 촬영 기간 동안 유지하려면
#       netplan / nmcli 등 배포판 방식으로 영구 설정한다.
set -euo pipefail

cmd="${1:-show}"
case "$cmd" in
  add) ip addr add "$3" dev "$2" && echo "added $3 to $2" ;;
  del) ip addr del "$3" dev "$2" && echo "removed $3 from $2" ;;
  show) ip -4 -brief addr show ;;
  *) echo "usage: $0 add|del <NIC> <IP/PREFIX> | show" >&2; exit 1 ;;
esac
