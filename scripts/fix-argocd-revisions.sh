#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
fix-argocd-revisions.sh — ArgoCD YAML의 revision/targetRevision을 일괄 정리

이 스크립트는 YAML 포맷/주석을 유지하기 위해 "텍스트 기반"으로 수정합니다.
원칙:
  - 직전에 나온 repoURL이 GitOps 리포(기본: https://github.com/hanazzang/BABAMBA-gitops)일 때만
  - 같은 indent 레벨의 revision: / targetRevision: 값만 교체합니다.
  - Helm chart 버전(예: prometheus-community) 등 repoURL이 다른 라인은 건드리지 않습니다.

Usage:
  ./scripts/fix-argocd-revisions.sh <branch|--current> [--apply] [--repo <repoURL>] [--paths <p1,p2,...>]

Examples:
  # 변경될 파일만 출력(dry-run)
  ./scripts/fix-argocd-revisions.sh hana

  # 현재 git 브랜치로(dry-run)
  ./scripts/fix-argocd-revisions.sh --current

  # 실제 적용
  ./scripts/fix-argocd-revisions.sh hana --apply

  # cloud-prod 쪽만 대상으로(dry-run)
  ./scripts/fix-argocd-revisions.sh hana --paths applications/cloud-prod,applicationsets/cloud-prod,bootstrap/cloud-prod-root-app.yaml

  # repoURL이 다른 경우(사설 포크 등)
  ./scripts/fix-argocd-revisions.sh hana --apply --repo https://github.com/myorg/BABAMBA-gitops
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" || -z ${1:-} ]]; then
  usage
  exit 0
fi

if [[ ${1:-} == "--current" ]]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -z "$BRANCH" ]]; then
    echo "Failed to detect current git branch." >&2
    exit 2
  fi
else
  BRANCH="$1"
fi
shift || true

APPLY=0
REPO_URL="https://github.com/hanazzang/BABAMBA-gitops"
PATHS="applications,applicationsets,bootstrap,clusters"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --repo)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --paths)
      PATHS="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

python3 - "$BRANCH" "$REPO_URL" "$PATHS" "$APPLY" <<'PY'
import os
import re
import sys

branch = sys.argv[1]
repo_url = sys.argv[2]
paths_csv = sys.argv[3]
apply = sys.argv[4] == "1"

repo_urls = {
    repo_url.rstrip("/"),
    repo_url.rstrip("/") + ".git",
    # SSH 형태도 흔함
    repo_url.replace("https://github.com/", "git@github.com:") + ".git",
}

paths = [p.strip() for p in paths_csv.split(",") if p.strip()]

def indent_len(s: str) -> int:
    return len(s) - len(s.lstrip(" "))

# "- repoURL:"(리스트 아이템) 형태도 지원
repo_re = re.compile(r'^\s*-?\s*repoURL:\s*([^\s#]+)(\s*(#.*)?)$')
rev_re = re.compile(r'^(\s*)(targetRevision|revision):\s*([^#\n]*?)(\s*(#.*)?)$')

changed_files = []
total_replacements = 0

def normalize_url(u: str) -> str:
    u = u.strip().strip('"').strip("'")
    return u.rstrip("/")

def replace_value(orig_value: str, new_value: str) -> str:
    v = orig_value.strip()
    if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
        q = v[0]
        return f"{q}{new_value}{q}"
    return new_value

def process_file(path: str) -> int:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().splitlines(True)  # keep \n

    out = []
    active_repo = None
    active_indent = None
    replacements = 0

    for line in lines:
        # scope reset: indentation drops below repoURL indent (non-empty, non-comment)
        if active_indent is not None:
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                if indent_len(line) < active_indent:
                    active_repo = None
                    active_indent = None

        m_repo = repo_re.match(line)
        if m_repo:
            active_repo = normalize_url(m_repo.group(1))
            lead = indent_len(line)
            # "- repoURL:" 형태면 같은 리스트 아이템의 다른 키들은 보통 +2 indent에 위치
            active_indent = lead + 2 if line.lstrip().startswith("- ") else lead
            out.append(line)
            continue

        m_rev = rev_re.match(line)
        if m_rev and active_repo in repo_urls and active_indent is not None:
            # 같은 맵 레벨에 있는 revision/targetRevision만 교체
            if indent_len(m_rev.group(1)) == active_indent:
                new_v = replace_value(m_rev.group(3), branch)
                if m_rev.group(3).strip() != new_v.strip():
                    out.append(f"{m_rev.group(1)}{m_rev.group(2)}: {new_v}{m_rev.group(4)}\n")
                    replacements += 1
                    continue

        out.append(line)

    new_text = "".join(out)
    old_text = "".join(lines)
    if new_text != old_text:
        if apply:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new_text)
        return replacements
    return 0

def iter_yaml_files(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        # Git/빌드 산출물은 스킵
        dirnames[:] = [d for d in dirnames if d not in {".git", "node_modules", ".terraform"}]
        for fn in filenames:
            if fn.endswith((".yaml", ".yml")):
                yield os.path.join(dirpath, fn)

for p in paths:
    if not os.path.exists(p):
        continue

    if os.path.isfile(p):
        if p.endswith((".yaml", ".yml")):
            n = process_file(p)
            if n:
                changed_files.append((p, n))
                total_replacements += n
        continue

    for f in iter_yaml_files(p):
        n = process_file(f)
        if n:
            changed_files.append((f, n))
            total_replacements += n

if not changed_files:
    print("No changes.")
    sys.exit(0)

mode = "APPLY" if apply else "DRY-RUN"
print(f"[{mode}] branch={branch}")
for f, n in changed_files:
    print(f"- {f}: {n} replacements")
print(f"Total replacements: {total_replacements}")
if not apply:
    print("Re-run with --apply to write changes.")
PY
