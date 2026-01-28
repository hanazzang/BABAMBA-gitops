#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
ipctl.sh — 리포 내 하드코딩 IP/포트를 한 곳에서 관리

원칙:
  - 무작정 "IP 문자열 전부"를 바꾸지 않고,
    이 리포에서 실제로 운영 값으로 쓰는 특정 키만 안전하게 교체합니다.

준비:
  cp scripts/ips.example.env scripts/ips.env
  (scripts/ips.env 수정)

Usage:
  bash scripts/ipctl.sh scan [--env <envfile>]
  bash scripts/ipctl.sh apply [--env <envfile>]

Notes:
  - envfile 기본값: scripts/ips.env (없으면 현재 환경변수만 사용)
EOF
}

MODE="${1:-scan}"
shift || true

ENV_FILE="scripts/ips.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" != "scan" && "$MODE" != "apply" ]]; then
  echo "MODE must be scan|apply" >&2
  usage >&2
  exit 2
fi

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$ENV_FILE"
  set +a
fi

python3 - "$MODE" <<'PY'
import os
import re
import sys
from pathlib import Path

mode = sys.argv[1]
repo_root = Path.cwd()

def env(name: str) -> str | None:
    v = os.environ.get(name)
    if v is None:
        return None
    v = v.strip()
    return v if v else None

def read_text(p: Path) -> str:
    return p.read_text(encoding="utf-8")

def write_text(p: Path, s: str) -> None:
    p.write_text(s, encoding="utf-8")

def apply_regex(path: Path, pattern: str, repl: str, count: int = 0) -> tuple[int, str, str]:
    old = read_text(path)
    new, n = re.subn(pattern, repl, old, flags=re.MULTILINE)
    return n, old, new

def print_kv(path: Path, label: str, value: str | None) -> None:
    v = value if value is not None else "(unset)"
    print(f"- {label}: {v}  ({path})")

targets: list[dict] = []

# 0) applications/cloud-prod — destination.server (온프 ArgoCD → EKS 원격 관리)
eks_url = env("EKS_CLUSTER_URL")
cloud_prod_dir = repo_root / "applications/cloud-prod"
if cloud_prod_dir.exists():
    for f in sorted(cloud_prod_dir.glob("*.yaml")):
        txt = read_text(f)
        m = re.search(r"^\s*server:\s*(.+?)(\s*(#.*))?$", txt, flags=re.MULTILINE)
        if not m:
            continue
        cur = m.group(1).strip()
        if mode == "scan":
            print_kv(f, f"cloud-prod {f.name} destination.server", cur)
        elif eks_url:
            # https://kubernetes.default.svc 또는 <EKS-CLUSTER-URL> → EKS_CLUSTER_URL
            pat = r"^(\s*server:\s*)(?:https://kubernetes\.default\.svc|<EKS-CLUSTER-URL>)(\s*(#.*)?)$"
            new_txt, n = re.subn(pat, rf"\g<1>{eks_url}\g<2>", txt, flags=re.MULTILINE)
            if n:
                write_text(f, new_txt)
                print(f"[apply] {f}: {n} replacements")

# 1) cloud-prod fluent-bit → onprem loki(NodePort)
fb_host = env("ONPREM_LOKI_NODE_IP")
fb_port = env("ONPREM_LOKI_NODEPORT")
fb_file = repo_root / "clusters/cloud/prod/platform/fluent-bit/values.yaml"
if fb_file.exists():
    if mode == "scan":
        # best-effort: show current host/port lines
        txt = read_text(fb_file)
        m_host = re.search(r"^\s*host:\s*([^\s#]+)", txt, flags=re.MULTILINE)
        m_port = re.search(r"^\s*port:\s*([0-9]+)", txt, flags=re.MULTILINE)
        print_kv(fb_file, "cloud-prod fluent-bit output.loki.host", m_host.group(1) if m_host else None)
        print_kv(fb_file, "cloud-prod fluent-bit output.loki.port", m_port.group(1) if m_port else None)
    else:
        total = 0
        if fb_host:
            n, old, new = apply_regex(fb_file, r"^(\s*host:\s*)([^\s#]+)(\s*(#.*)?)$", rf"\g<1>{fb_host}\g<3>")
            if n:
                write_text(fb_file, new)
            total += n
        if fb_port:
            n, old, new = apply_regex(fb_file, r"^(\s*port:\s*)([0-9]+)(\s*(#.*)?)$", rf"\g<1>{fb_port}\g<3>")
            if n:
                write_text(fb_file, new)
            total += n
        if total:
            print(f"[apply] {fb_file}: {total} replacements")

# 2) cloud-prod prometheus remoteWrite (values-eks.yaml)
rw_ip = env("ONPREM_PROM_REMOTEWRITE_IP")
rw_port = env("ONPREM_PROM_REMOTEWRITE_PORT")
rw_file = repo_root / "clusters/cloud/prod/platform/monitoring/values-eks.yaml"
if rw_file.exists():
    if mode == "scan":
        txt = read_text(rw_file)
        m = re.search(r'url:\s*"(https?://)([^":]+)(:([0-9]+))?/api/v1/write"', txt)
        if m:
            print_kv(rw_file, "cloud-prod remoteWrite host", m.group(2))
            print_kv(rw_file, "cloud-prod remoteWrite port", m.group(4) or "(default)")
        else:
            print_kv(rw_file, "cloud-prod remoteWrite url", None)
    else:
        if rw_ip or rw_port:
            ip = rw_ip or r"[^\":]+"
            port = rw_port or r"[0-9]+"
            # host/port만 바꾸기: http(s)://<host>:<port>/api/v1/write
            pat = r'(\burl:\s*"(?:https?://))([^":]+)(?::([0-9]+))?(/api/v1/write")'
            rep = lambda m: f'{m.group(1)}{rw_ip or m.group(2)}:{rw_port or (m.group(3) or "9090")}{m.group(4)}'
            old = read_text(rw_file)
            new, n = re.subn(pat, rep, old)
            if n:
                write_text(rw_file, new)
                print(f"[apply] {rw_file}: {n} replacements")

# 3) onprem MetalLB 풀 주소
metallb_ip = env("ONPREM_METALLB_POOL_IP")
metallb_file = repo_root / "clusters/onprem/dev/platform/metallb-system/values.yaml"
if metallb_file.exists():
    if mode == "scan":
        txt = read_text(metallb_file)
        m = re.search(r"addresses:\s*\n\s*-\s*([0-9.]+)/32", txt)
        print_kv(metallb_file, "onprem MetalLB pool address", m.group(1) if m else None)
    elif metallb_ip:
        n, old, new = apply_regex(metallb_file, r"^(\s*-\s*)([0-9.]+)(/32\s*)$", rf"\g<1>{metallb_ip}\g<3>")
        if n:
            write_text(metallb_file, new)
            print(f"[apply] {metallb_file}: {n} replacements")

# 4) onprem gateway LoadBalancerIP (MetalLB 쓸 때만, 풀에 있는 IP여야 함)
gw_ip = env("ONPREM_GATEWAY_LB_IP")
gw_file = repo_root / "clusters/onprem/dev/platform/gateway/values.yaml"
if gw_file.exists():
    if mode == "scan":
        txt = read_text(gw_file)
        m = re.search(r"loadBalancerIP:\s*([0-9.]+)", txt)
        print_kv(gw_file, "onprem gateway loadBalancerIP", m.group(1) if m else None)
    elif gw_ip:
        n, old, new = apply_regex(gw_file, r"^(\s*loadBalancerIP:\s*)([0-9.]+)(\s*(#.*)?)$", rf"\g<1>{gw_ip}\g<3>")
        if n:
            write_text(gw_file, new)
            print(f"[apply] {gw_file}: {n} replacements")

# 5) onprem photo NFS 서버 (chart 기본값 + onprem-dev override)
nfs_ip = env("ONPREM_NFS_SERVER_IP")
photo_chart = repo_root / "charts/photo/values.yaml"
photo_onprem = repo_root / "clusters/onprem/dev/apps/photo/values.yaml"
for f, label in [(photo_chart, "charts/photo nfsServer"), (photo_onprem, "onprem-dev photo nfsServer")]:
    if not f.exists():
        continue
    if mode == "scan":
        txt = read_text(f)
        m = re.search(r'nfsServer:\s*"?([0-9.]+)"?', txt)
        print_kv(f, label, m.group(1) if m else None)
    elif nfs_ip:
        n, old, new = apply_regex(f, r'^(\s*nfsServer:\s*"?)([0-9.]+)("?\s*(#.*)?)$', rf"\g<1>{nfs_ip}\g<3>")
        if n:
            write_text(f, new)
            print(f"[apply] {f}: {n} replacements")

# 5) redis-session endpoints IP
redis_ip = env("ONPREM_REDIS_SESSION_IP")
redis_file = repo_root / "clusters/onprem/dev/platform/redis-session/values.yaml"
if redis_file.exists():
    if mode == "scan":
        txt = read_text(redis_file)
        m = re.search(r"\bip:\s*([0-9.]+)", txt)
        print_kv(redis_file, "onprem-dev redis-session ip", m.group(1) if m else None)
    elif redis_ip:
        n, old, new = apply_regex(redis_file, r"^(\s*-\s*ip:\s*)([0-9.]+)(\s*(#.*)?)$", rf"\g<1>{redis_ip}\g<3>")
        if n:
            write_text(redis_file, new)
            print(f"[apply] {redis_file}: {n} replacements")

# 7) proxysql connector IP
px_ip = env("PROXYSQL_IP")
px_file = repo_root / "platform/proxysql/db-connector.yaml"
if px_file.exists():
    if mode == "scan":
        txt = read_text(px_file)
        ips = re.findall(r"\bip:\s*([0-9.]+)", txt)
        print_kv(px_file, "proxysql db-connector ip(s)", ", ".join(ips) if ips else None)
    elif px_ip:
        n, old, new = apply_regex(px_file, r"^(\s*-\s*ip:\s*)([0-9.]+)(\s*(#.*)?)$", rf"\g<1>{px_ip}\g<3>")
        if n:
            write_text(px_file, new)
            print(f"[apply] {px_file}: {n} replacements")

# 8) Loki NFS values (옵션)
loki_nfs_ip = env("LOKI_NFS_SERVER_IP")
loki_nfs_file = repo_root / "platform/loki/values-nfs.yaml"
if loki_nfs_file.exists():
    if mode == "scan":
        txt = read_text(loki_nfs_file)
        m = re.search(r'^\s*server:\s*"?([0-9.]+)"?', txt, flags=re.MULTILINE)
        print_kv(loki_nfs_file, "platform/loki values-nfs server", m.group(1) if m else None)
    elif loki_nfs_ip:
        n, old, new = apply_regex(loki_nfs_file, r'^(\s*server:\s*"?)([0-9.]+)("?\s*(#.*)?)$', rf"\g<1>{loki_nfs_ip}\g<3>")
        if n:
            write_text(loki_nfs_file, new)
            print(f"[apply] {loki_nfs_file}: {n} replacements")
PY

