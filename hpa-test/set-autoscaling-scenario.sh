#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 시나리오 정의(앱별):
# - 0: HPA/KEDA 끔
# - 1: HPA(cpu/memory) 켬, KEDA 끔
# - 2: KEDA(RPS/p95 등) 켬
#
# 사용법:
#   ./set-autoscaling-scenario.sh [--auth <0|1|2>] [--employee-get <0|1|2>] [--employee-write <0|1|2>] [--photo <0|1|2>] [--gateway <0|1|2>]
#   ./set-autoscaling-scenario.sh --default
#
# 예:
#   ./set-autoscaling-scenario.sh --employee-get 0 --employee-write 0
#   ./set-autoscaling-scenario.sh --employee-get 2 --employee-write 1 --gateway 1 --auth 2
#   ./set-autoscaling-scenario.sh   # 옵션 없으면 변경 없이 "현재 상태 출력"만 수행

# ===== 디폴트 시나리오(값을 안 주면 이 값 사용) =====
# 요구사항(현재 기본 운영):
# - employee: GET=KEDA(2), WRITE=HPA(1)
# - auth: KEDA                     -> scenario 2
# - photo: HPA                     -> scenario 1
# - gateway: HPA                   -> scenario 1
DEFAULT_AUTH="${DEFAULT_AUTH:-2}"
DEFAULT_EMPLOYEE_GET="${DEFAULT_EMPLOYEE_GET:-2}"
DEFAULT_EMPLOYEE_WRITE="${DEFAULT_EMPLOYEE_WRITE:-1}"
DEFAULT_PHOTO="${DEFAULT_PHOTO:-1}"
DEFAULT_GATEWAY="${DEFAULT_GATEWAY:-1}"

usage() {
  cat >&2 <<'EOF'
usage:
  set-autoscaling-scenario.sh [--auth [0|1|2]] [--employee-get [0|1|2]] [--employee-write [0|1|2]] [--photo [0|1|2]] [--gateway [0|1|2]]
  set-autoscaling-scenario.sh --default

behavior:
  - 지정한 대상만 values-autoscaling.yaml을 덮어씁니다.
  - 지정하지 않은 대상은 파일을 건드리지 않습니다.
  - 실행 시 auth/employee(get/write)/photo/gateway 각각의 "현재 시나리오(0/1/2)"를 출력합니다.
  - 시나리오 값을 생략하면(예: --auth) 디폴트 시나리오를 사용합니다.
  - --default를 주면 스크립트에 정의된 "디폴트 시나리오"로 되돌립니다.
    (auth=${DEFAULT_AUTH}, employee-get=${DEFAULT_EMPLOYEE_GET}, employee-write=${DEFAULT_EMPLOYEE_WRITE}, photo=${DEFAULT_PHOTO}, gateway=${DEFAULT_GATEWAY})

EOF
}

dst_for_target() {
  local target="$1"
  case "${target}" in
    auth|employee|photo) echo "${repo_root}/clusters/onprem/dev/apps/${target}/values-autoscaling.yaml" ;;
    gateway)             echo "${repo_root}/clusters/onprem/dev/platform/gateway/values-autoscaling.yaml" ;;
    *) echo "" ;;
  esac
}

# 시나리오 전환 시 HPA ↔ KEDA ScaledObject 충돌 방지: 기존 스케일러를 먼저 삭제
# - 0: 둘 다 삭제 (어떤 스케일러도 사용 안 함)
# - 1: ScaledObject 삭제 (HPA만 사용)
# - 2: HPA 삭제 (ScaledObject만 사용)
delete_scaler_conflicts() {
  local target="$1"
  local scenario="$2"
  local ns hpa_name so_name
  case "${target}" in
    employee-get)
      ns="employee"; hpa_name="employee-server-get"; so_name="employee-server-get"
      ;;
    employee-write)
      ns="employee"; hpa_name="employee-server-write"; so_name="employee-server-write"
      ;;
    auth)
      ns="auth"; hpa_name="auth-server-hpa"; so_name="auth-server"
      ;;
    photo)
      ns="photo"; hpa_name="photo-server-hpa"; so_name="photo-server"
      ;;
    gateway)
      ns="gateway"; hpa_name="envoy-gw-infra-dataplane"; so_name="envoy-gw-infra-dataplane"
      ;;
    *) return 0 ;;
  esac
  case "${scenario}" in
    0)
      kubectl -n "${ns}" delete hpa "${hpa_name}" --ignore-not-found 2>/dev/null || true
      kubectl -n "${ns}" delete scaledobject "${so_name}" --ignore-not-found 2>/dev/null || true
      ;;
    1)
      kubectl -n "${ns}" delete scaledobject "${so_name}" --ignore-not-found 2>/dev/null || true
      ;;
    2)
      kubectl -n "${ns}" delete hpa "${hpa_name}" --ignore-not-found 2>/dev/null || true
      ;;
  esac
}

apply_switch() {
  local target="$1"   # auth|photo|gateway
  local scenario="$2" # 0|1|2
  local dst
  dst="$(dst_for_target "${target}")"
  if [[ -z "${dst}" ]]; then
    echo "[ERROR] unknown target: ${target}" >&2
    exit 2
  fi

  if [[ ! -f "${dst}" ]]; then
    echo "[ERROR] values-autoscaling.yaml not found: ${dst}" >&2
    exit 2
  fi

  # 시나리오 -> enabled 값 매핑
  local auto_enabled keda_enabled keda_get_enabled keda_write_enabled
  case "${scenario}" in
    0)
      auto_enabled="false"
      keda_enabled="false"
      keda_get_enabled="false"
      keda_write_enabled="false"
      ;;
    1)
      auto_enabled="true"
      keda_enabled="false"
      keda_get_enabled="false"
      keda_write_enabled="false"
      ;;
    2)
      auto_enabled="true"
      keda_enabled="true"
      # employee는 GET=KEDA, WRITE=HPA가 기본이므로 scenario=2에서도 write는 false 유지
      keda_get_enabled="true"
      keda_write_enabled="false"
      ;;
    *)
      echo "[ERROR] invalid scenario for --${target}: ${scenario} (expected: 0|1|2)" >&2
      usage
      exit 2
      ;;
  esac

  local tmp="${dst}.tmp"

  # auth/photo/gateway: autoscaling.enabled + keda.enabled 만 변경
  awk -v A="${auto_enabled}" -v K="${keda_enabled}" '
    BEGIN { inA=0; inK=0 }
    /^[[:space:]]*autoscaling:[[:space:]]*$/ { inA=1; inK=0 }
    /^[[:space:]]*keda:[[:space:]]*$/        { inK=1; inA=0 }
    /^[^[:space:]]/ && $0 !~ /^(autoscaling|keda):[[:space:]]*$/ { inA=0; inK=0 }

    inA && $0 ~ /^[[:space:]]{2}enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
      print "  enabled: " A; next
    }
    inK && $0 ~ /^[[:space:]]{2}enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
      print "  enabled: " K; next
    }
    { print }
  ' "${dst}" > "${tmp}"

  mv "${tmp}" "${dst}"
  echo "applied: ${target} scenario ${scenario} -> ${dst}"
}

employee_role_flags() {
  # role: get|write, scenario: 0|1|2  -> print: "<auto_enabled> <keda_enabled>"
  local role="$1" sc="$2"
  case "${sc}" in
    0) echo "false false" ;;
    1) echo "true false" ;;
    2) echo "true true" ;;
    *) echo "" ;;
  esac
}

apply_employee_switch() {
  # 시나리오를 GET/WRITE로 분리 적용합니다.
  # - GET/WRITE 중 일부만 지정된 경우, 지정된 블록만 패치합니다.
  # - 단, get/write 시나리오가 1/2인 경우 autoscaling.enabled는 true가 되어야 동작하므로 필요 시 true로 올립니다.
  local get_scenario="${1:-}"   # ""|0|1|2
  local write_scenario="${2:-}" # ""|0|1|2
  local dst tmp
  dst="$(dst_for_target employee)"
  if [[ ! -f "${dst}" ]]; then
    echo "[ERROR] values-autoscaling.yaml not found: ${dst}" >&2
    exit 2
  fi

  local A="KEEP" AG="KEEP" AW="KEEP" KG="KEEP" KW="KEEP"

  if [[ -n "${get_scenario}" ]]; then
    read -r AG KG < <(employee_role_flags get "${get_scenario}")
    if [[ "${get_scenario}" != "0" ]]; then A="true"; fi
  fi
  if [[ -n "${write_scenario}" ]]; then
    read -r AW KW < <(employee_role_flags write "${write_scenario}")
    if [[ "${write_scenario}" != "0" ]]; then A="true"; fi
  fi

  # 둘 다 명시된 경우에는 autoscaling.enabled를 일관되게 계산(둘 다 0이면 false)
  if [[ -n "${get_scenario}" && -n "${write_scenario}" ]]; then
    if [[ "${get_scenario}" == "0" && "${write_scenario}" == "0" ]]; then
      A="false"
    else
      A="true"
    fi
  fi

  tmp="${dst}.tmp"
  awk -v A="${A}" -v AG="${AG}" -v AW="${AW}" -v KG="${KG}" -v KW="${KW}" '
    BEGIN { inA=0; inK=0; inGet=0; inWrite=0; inAGet=0; inAWrite=0 }
    /^[[:space:]]*autoscaling:[[:space:]]*$/ { inA=1; inK=0; inAGet=0; inAWrite=0; nextPrint=1 }
    /^[[:space:]]*keda:[[:space:]]*$/        { inK=1; inA=0; inGet=0; inWrite=0; inAGet=0; inAWrite=0; nextPrint=1 }
    /^[^[:space:]]/ && $0 !~ /^(autoscaling|keda):[[:space:]]*$/ { inA=0; inK=0; inGet=0; inWrite=0; inAGet=0; inAWrite=0 }

    # autoscaling.get / autoscaling.write block entry
    inA && $0 ~ /^[[:space:]]{2}get:[[:space:]]*$/   { inAGet=1; inAWrite=0; print; next }
    inA && $0 ~ /^[[:space:]]{2}write:[[:space:]]*$/ { inAWrite=1; inAGet=0; print; next }

    # autoscaling.enabled (2-space indent)
    inA && !inAGet && !inAWrite && $0 ~ /^[[:space:]]{2}enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
      if (A != "KEEP") { print "  enabled: " A; next }
    }

    # autoscaling.get.enabled / autoscaling.write.enabled (4-space indent)
    inAGet && $0 ~ /^[[:space:]]{4}enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
      if (AG != "KEEP") { print "    enabled: " AG; next }
    }
    inAWrite && $0 ~ /^[[:space:]]{4}enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
      if (AW != "KEEP") { print "    enabled: " AW; next }
    }

    # keda.get / keda.write block entry
    inK && $0 ~ /^[[:space:]]{2}get:[[:space:]]*$/   { inGet=1; inWrite=0; print; next }
    inK && $0 ~ /^[[:space:]]{2}write:[[:space:]]*$/ { inWrite=1; inGet=0; print; next }

    # keda.get.enabled / keda.write.enabled (4-space indent)
    inGet && $0 ~ /^[[:space:]]{4}enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
      if (KG != "KEEP") { print "    enabled: " KG; next }
    }
    inWrite && $0 ~ /^[[:space:]]{4}enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
      if (KW != "KEEP") { print "    enabled: " KW; next }
    }

    { print }
  ' "${dst}" > "${tmp}"
  mv "${tmp}" "${dst}"

  echo -n "applied: employee"
  [[ -n "${get_scenario}" ]] && echo -n " get=${get_scenario}"
  [[ -n "${write_scenario}" ]] && echo -n " write=${write_scenario}"
  echo " -> ${dst}"
}

print_current_status() {
  local target="$1"
  local dst s
  dst="$(dst_for_target "${target}")"
  if [[ ! -f "${dst}" ]]; then
    s="unknown"
  else
    if [[ "${target}" == "employee" ]]; then
      # employee: autoscaling.get.enabled + keda.get.enabled / autoscaling.write.enabled + keda.write.enabled 조합으로 추론
      read -r a ag aw kg kw < <(
        awk '
          BEGIN { a="unknown"; ag="unknown"; aw="unknown"; kg="unknown"; kw="unknown"; inA=0; inK=0; inGet=0; inWrite=0; inAGet=0; inAWrite=0 }
          /^[[:space:]]*autoscaling:[[:space:]]*$/ { inA=1; inK=0 }
          /^[[:space:]]*keda:[[:space:]]*$/        { inK=1; inA=0; inGet=0; inWrite=0; inAGet=0; inAWrite=0 }
          /^[^[:space:]]/ && $0 !~ /^(autoscaling|keda):[[:space:]]*$/ { inA=0; inK=0; inGet=0; inWrite=0; inAGet=0; inAWrite=0 }
          inA && $0 ~ /^[[:space:]]{2}get:[[:space:]]*$/   { inAGet=1; inAWrite=0 }
          inA && $0 ~ /^[[:space:]]{2}write:[[:space:]]*$/ { inAWrite=1; inAGet=0 }
          inA && !inAGet && !inAWrite && $0 ~ /^[[:space:]]{2}enabled:[[:space:]]*(true|false)[[:space:]]*$/ { a=$2 }
          inAGet && $0 ~ /^[[:space:]]{4}enabled:[[:space:]]*(true|false)[[:space:]]*$/ { ag=$2 }
          inAWrite && $0 ~ /^[[:space:]]{4}enabled:[[:space:]]*(true|false)[[:space:]]*$/ { aw=$2 }
          inK && $0 ~ /^[[:space:]]{2}get:[[:space:]]*$/   { inGet=1; inWrite=0 }
          inK && $0 ~ /^[[:space:]]{2}write:[[:space:]]*$/ { inWrite=1; inGet=0 }
          inGet && $0 ~ /^[[:space:]]{4}enabled:[[:space:]]*(true|false)[[:space:]]*$/ { kg=$2 }
          inWrite && $0 ~ /^[[:space:]]{4}enabled:[[:space:]]*(true|false)[[:space:]]*$/ { kw=$2 }
          END { print a, ag, aw, kg, kw }
        ' "${dst}"
      )

      # get scenario
      if [[ "${ag}" == "false" && "${kg}" == "false" ]]; then sg="0"
      elif [[ "${ag}" == "true" && "${kg}" == "false" ]]; then sg="1"
      elif [[ "${kg}" == "true" ]]; then sg="2"
      else sg="unknown"; fi

      # write scenario
      if [[ "${aw}" == "false" && "${kw}" == "false" ]]; then sw="0"
      elif [[ "${aw}" == "true" && "${kw}" == "false" ]]; then sw="1"
      elif [[ "${kw}" == "true" ]]; then sw="2"
      else sw="unknown"; fi

      echo "current: employee get=${sg} write=${sw} (autoscaling.enabled=${a}) file=${dst}"
      return 0
    else
      # 일반: autoscaling.enabled / keda.enabled 조합
      read -r a k < <(
        awk '
          BEGIN { a="unknown"; k="unknown"; section="" }
          /^[[:space:]]*autoscaling:[[:space:]]*$/ { section="a"; next }
          /^[[:space:]]*keda:[[:space:]]*$/        { section="k"; next }
          /^[^[:space:]]/ && $0 !~ /^(autoscaling|keda):[[:space:]]*$/ { section="" }
          section!="" && $0 ~ /^[[:space:]]{2}enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
            if (section=="a") a=$2
            else if (section=="k") k=$2
          }
          END { print a, k }
        ' "${dst}"
      )
      if [[ "${a}" == "false" && "${k}" == "false" ]]; then
        s="0"
      elif [[ "${a}" == "true" && "${k}" == "false" ]]; then
        s="1"
      elif [[ "${k}" == "true" ]]; then
        s="2"
      else
        s="unknown"
      fi
    fi
  fi
  echo "current: ${target} scenario=${s} file=${dst}"
}

# ===== 입력 파싱: --target <scenario> =====
declare -A DESIRED=()
DEFAULT_RESET="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --default|--org)
      DEFAULT_RESET="true"
      shift
      ;;
    --auth|--employee-get|--employee-write|--photo|--gateway)
      target="${1#--}"
      shift
      # 시나리오가 생략되면 디폴트 사용(다음 토큰이 --로 시작하거나, 토큰이 없는 경우)
      if [[ $# -eq 0 || "${1:-}" == --* ]]; then
        case "${target}" in
          auth) sc="${DEFAULT_AUTH}" ;;
          employee-get) sc="${DEFAULT_EMPLOYEE_GET}" ;;
          employee-write) sc="${DEFAULT_EMPLOYEE_WRITE}" ;;
          photo) sc="${DEFAULT_PHOTO}" ;;
          gateway) sc="${DEFAULT_GATEWAY}" ;;
        esac
      else
        sc="$1"
        shift
      fi
      if [[ "${sc}" != "0" && "${sc}" != "1" && "${sc}" != "2" ]]; then
        echo "[ERROR] invalid scenario for --${target}: ${sc} (expected: 0|1|2)" >&2
        usage
        exit 2
      fi
      DESIRED["${target}"]="${sc}"
      ;;
    *)
      echo "[ERROR] unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# --default: 스크립트에 적힌 "초기(디폴트) 셋팅값"으로 되돌리기
# - 사용자가 특정 대상을 명시했다면(예: --employee-get 0) 그 값이 우선입니다.
if [[ "${DEFAULT_RESET}" == "true" ]]; then
  [[ -n "${DESIRED[auth]+x}" ]] || DESIRED["auth"]="${DEFAULT_AUTH}"
  if [[ -z "${DESIRED["employee-get"]+x}" && -z "${DESIRED["employee-write"]+x}" ]]; then
    DESIRED["employee-get"]="${DEFAULT_EMPLOYEE_GET}"
    DESIRED["employee-write"]="${DEFAULT_EMPLOYEE_WRITE}"
  fi
  [[ -n "${DESIRED[photo]+x}" ]] || DESIRED["photo"]="${DEFAULT_PHOTO}"
  [[ -n "${DESIRED[gateway]+x}" ]] || DESIRED["gateway"]="${DEFAULT_GATEWAY}"
fi

# ===== 적용: 지정된 대상만 =====
if [[ ${#DESIRED[@]} -gt 0 ]]; then
  # 1) employee는 GET/WRITE를 합쳐 1번만 패치(같은 파일이므로)
  emp_get=""
  emp_write=""
  [[ -n "${DESIRED["employee-get"]+x}" ]] && emp_get="${DESIRED["employee-get"]}"
  [[ -n "${DESIRED["employee-write"]+x}" ]] && emp_write="${DESIRED["employee-write"]}"

  if [[ -n "${emp_get}" || -n "${emp_write}" ]]; then
    apply_employee_switch "${emp_get}" "${emp_write}"
    [[ -n "${emp_get}" ]] && delete_scaler_conflicts "employee-get" "${emp_get}"
    [[ -n "${emp_write}" ]] && delete_scaler_conflicts "employee-write" "${emp_write}"
  fi

  # 2) 나머지 대상 적용(순서 고정)
  for t in auth photo gateway; do
    if [[ -n "${DESIRED[$t]+x}" ]]; then
      apply_switch "${t}" "${DESIRED[$t]}"
      delete_scaler_conflicts "${t}" "${DESIRED[$t]}"
    fi
  done
else
  echo "[INFO] no targets specified. leaving files unchanged."
fi

# ===== 현재 상태 출력(항상) =====
echo
print_current_status auth
print_current_status employee
print_current_status photo
print_current_status gateway
echo

