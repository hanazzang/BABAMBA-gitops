#!/usr/bin/env bash
# 점프서버(xubuntu@192.168.13.126)에서 실행용: 192.168.1.146 vs 147/148 연결 비교
# 사용: ssh xubuntu@192.168.13.126 "bash -s" < scripts/check-jump-to-1dot146.sh
# 또는 점프서버에 접속한 뒤: bash check-jump-to-1dot146.sh

set +e
echo "=== 1) Port 22 (SSH) ==="
for ip in 192.168.1.146 192.168.1.147 192.168.1.148; do
  echo -n "$ip:22 => "
  (timeout 2 nc -zv "$ip" 22 2>&1) || echo "fail/timeout"
done

echo ""
echo "=== 2) Port 8080 (Argo CD port-forward) ==="
for ip in 192.168.1.146 192.168.1.147 192.168.1.148; do
  echo -n "$ip:8080 => "
  (timeout 2 nc -zv "$ip" 8080 2>&1) || echo "fail/timeout"
done

echo ""
echo "=== 3) Ping ==="
for ip in 192.168.1.146 192.168.1.147 192.168.1.148; do
  echo -n "$ip => "
  ping -c 1 -W 2 "$ip" 2>&1 | tail -1 || echo "fail"
done
