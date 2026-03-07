#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/server_health.conf"
CONFIG_FILE="${1:-$DEFAULT_CONFIG_FILE}"

# Defaults (override in config file).
CHECK_URLS=("http://127.0.0.1/")
TIMEOUT_SECONDS=8
ERROR_WINDOW_MINUTES=30
ERROR_TAIL_LINES=400
AUTO_RESTART_SERVICES=false
REPORT_FILE=""
ALERT_WEBHOOK_URL=""

APACHE_SERVICE_CANDIDATES=("apache2" "httpd")
SQL_SERVICE_CANDIDATES=("mysql" "mariadb" "mysqld")

APACHE_PROCESS_CANDIDATES=("apache2" "httpd")
SQL_PROCESS_CANDIDATES=("mysqld" "mariadbd")

APACHE_ERROR_LOG_PATHS=(
  "/var/log/apache2/error.log"
  "/var/log/httpd/error_log"
)
SQL_ERROR_LOG_PATHS=(
  "/var/log/mysql/error.log"
  "/var/log/mysql/mysql-error.log"
  "/var/log/mysqld.log"
)

declare -i TOTAL_CHECKS=0
declare -i PASS_COUNT=0
declare -i WARN_COUNT=0
declare -i FAIL_COUNT=0
declare -a FINDINGS=()
declare -a DIAGNOSES=()

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

record_finding() {
  local level="$1"
  local check="$2"
  local message="$3"

  TOTAL_CHECKS+=1
  case "$level" in
    PASS) PASS_COUNT+=1 ;;
    WARN) WARN_COUNT+=1 ;;
    FAIL) FAIL_COUNT+=1 ;;
    *) level="WARN"; WARN_COUNT+=1 ;;
  esac

  FINDINGS+=("[$level] $check: $message")
}

add_diagnosis() {
  local message="$1"
  DIAGNOSES+=("- $message")
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

detect_service_name() {
  local -n candidates_ref="$1"
  local svc
  local load_state
  for svc in "${candidates_ref[@]}"; do
    if command_exists systemctl; then
      load_state="$(systemctl show "$svc" --property=LoadState --value 2>/dev/null || true)"
      if [[ -n "$load_state" ]] && [[ "$load_state" != "not-found" ]]; then
        printf '%s\n' "$svc"
        return 0
      fi
    fi
  done
  printf '\n'
  return 1
}

is_service_active() {
  local service_name="$1"
  local -n processes_ref="$2"
  local proc

  if [[ -n "$service_name" ]] && command_exists systemctl; then
    if [[ "$(systemctl is-active "$service_name" 2>/dev/null || true)" == "active" ]]; then
      return 0
    fi
  fi

  for proc in "${processes_ref[@]}"; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

restart_service_if_enabled() {
  local service_name="$1"
  local human_name="$2"
  if [[ "$AUTO_RESTART_SERVICES" != "true" ]]; then
    return 1
  fi

  if [[ -z "$service_name" ]]; then
    add_diagnosis "$human_name is down and no matching systemd service unit was detected; restart manually."
    return 1
  fi

  if ! command_exists systemctl; then
    add_diagnosis "$human_name is down and systemctl is unavailable; restart manually."
    return 1
  fi

  if systemctl restart "$service_name" >/dev/null 2>&1; then
    add_diagnosis "$human_name was restarted automatically via systemctl restart $service_name."
    return 0
  fi

  add_diagnosis "$human_name restart failed (systemctl restart $service_name); check permissions and unit logs."
  return 1
}

check_service_health() {
  local human_name="$1"
  local candidates_var="$2"
  local processes_var="$3"
  local service_name

  service_name="$(detect_service_name "$candidates_var")"
  if is_service_active "$service_name" "$processes_var"; then
    if [[ -n "$service_name" ]]; then
      record_finding "PASS" "$human_name service" "running (unit: $service_name)"
    else
      record_finding "PASS" "$human_name service" "running (process detected)"
    fi
    return 0
  fi

  record_finding "FAIL" "$human_name service" "not running"
  if restart_service_if_enabled "$service_name" "$human_name"; then
    if is_service_active "$service_name" "$processes_var"; then
      record_finding "WARN" "$human_name recovery" "service was down, automatic restart succeeded"
      return 0
    fi
  fi

  if [[ "$human_name" == "Apache" ]]; then
    if command_exists apachectl && ! apachectl configtest >/dev/null 2>&1; then
      add_diagnosis "Apache configtest failed; run apachectl configtest for details before restarting."
    fi
  fi

  if [[ "$human_name" == "SQL" ]]; then
    if [[ -d "/var/lib/mysql" ]]; then
      local usage
      usage="$(df -P /var/lib/mysql 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
      if [[ -n "$usage" ]] && [[ "$usage" -ge 95 ]]; then
        add_diagnosis "MySQL/MariaDB data disk is ${usage}% full; free space may be blocking startup."
      fi
    fi
  fi

  return 1
}

check_url_connectivity() {
  local url="$1"
  local output code total_time clean_output
  local curl_status

  output="$(curl -sS -o /dev/null -w "%{http_code} %{time_total}" --max-time "$TIMEOUT_SECONDS" "$url" 2>&1)"
  curl_status=$?
  if [[ $curl_status -ne 0 ]]; then
    clean_output="$(tr '\n' ' ' <<<"$output" | sed -E 's/[[:space:]]+/ /g')"
    record_finding "FAIL" "Connectivity ($url)" "$clean_output"
    add_diagnosis "Endpoint $url is unreachable; check DNS, firewall, routing, and reverse proxy config."
    return 1
  fi

  code="$(awk '{print $1}' <<<"$output")"
  total_time="$(awk '{print $2}' <<<"$output")"

  if [[ "$code" =~ ^(2|3) ]]; then
    record_finding "PASS" "Connectivity ($url)" "HTTP $code in ${total_time}s"
    return 0
  fi

  if [[ "$code" =~ ^4 ]]; then
    record_finding "WARN" "Connectivity ($url)" "HTTP $code in ${total_time}s"
    add_diagnosis "Endpoint $url returned $code; verify route/auth expectations."
    return 0
  fi

  record_finding "FAIL" "Connectivity ($url)" "HTTP $code in ${total_time}s"
  add_diagnosis "Endpoint $url returned server error ($code); inspect application and Apache error logs."
  return 1
}

count_file_errors() {
  local -n files_ref="$1"
  local label="$2"
  local path
  local total=0
  local found=0

  for path in "${files_ref[@]}"; do
    if [[ -f "$path" ]]; then
      found=1
      # Capture the latest errors quickly without needing timestamp parsing.
      total=$((total + $(tail -n "$ERROR_TAIL_LINES" "$path" | grep -Eic "error|crit|alert|emerg|panic|exception|segfault|fatal|failed" || true)))
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    record_finding "WARN" "$label logs" "no known log file found"
    return 0
  fi

  if [[ "$total" -eq 0 ]]; then
    record_finding "PASS" "$label logs" "no obvious error lines in last $ERROR_TAIL_LINES lines"
    return 0
  fi

  record_finding "WARN" "$label logs" "$total error-like lines in last $ERROR_TAIL_LINES lines"
  add_diagnosis "$label logs contain recent errors; inspect the latest stack traces and correlate with deploy changes."
  return 0
}

count_journal_errors_for_service() {
  local service_name="$1"
  local human_name="$2"
  local count

  if [[ -z "$service_name" ]] || ! command_exists journalctl; then
    return 0
  fi

  count="$(journalctl -u "$service_name" --since "${ERROR_WINDOW_MINUTES} min ago" -p err --no-pager -o cat 2>/dev/null | wc -l | tr -d ' ')"
  if [[ -z "$count" ]]; then
    return 0
  fi

  if [[ "$count" -eq 0 ]]; then
    record_finding "PASS" "$human_name journal" "no errors in last ${ERROR_WINDOW_MINUTES} minutes"
  else
    record_finding "WARN" "$human_name journal" "$count errors in last ${ERROR_WINDOW_MINUTES} minutes"
    add_diagnosis "$human_name has recent journal errors; run journalctl -u $service_name --since '${ERROR_WINDOW_MINUTES} min ago' for detail."
  fi
}

post_webhook_if_needed() {
  if [[ -z "$ALERT_WEBHOOK_URL" ]]; then
    return 0
  fi

  if [[ "$FAIL_COUNT" -eq 0 && "$WARN_COUNT" -eq 0 ]]; then
    return 0
  fi

  if ! command_exists curl; then
    return 0
  fi

  local payload
  payload="$(printf '{"timestamp":"%s","pass":%d,"warn":%d,"fail":%d}' "$(timestamp)" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT")"
  curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || true
}

build_report() {
  echo "=== Server Health Report ($(timestamp)) ==="
  echo
  for finding in "${FINDINGS[@]}"; do
    echo "$finding"
  done
  echo
  echo "Summary: total=$TOTAL_CHECKS pass=$PASS_COUNT warn=$WARN_COUNT fail=$FAIL_COUNT"
  echo
  if [[ "${#DIAGNOSES[@]}" -gt 0 ]]; then
    echo "Diagnoses / Next Actions:"
    for diag in "${DIAGNOSES[@]}"; do
      echo "$diag"
    done
  else
    echo "Diagnoses / Next Actions:"
    echo "- No obvious issues detected."
  fi
}

write_report_file() {
  if [[ -z "$REPORT_FILE" ]]; then
    return 0
  fi

  local report_dir
  report_dir="$(dirname "$REPORT_FILE")"
  mkdir -p "$report_dir" 2>/dev/null || true

  if ! touch "$REPORT_FILE" >/dev/null 2>&1; then
    return 0
  fi

  {
    echo "=== Server Health Report ($(timestamp)) ==="
    echo
    for finding in "${FINDINGS[@]}"; do
      echo "$finding"
    done
    echo
    echo "Summary: total=$TOTAL_CHECKS pass=$PASS_COUNT warn=$WARN_COUNT fail=$FAIL_COUNT"
    echo
    if [[ "${#DIAGNOSES[@]}" -gt 0 ]]; then
      echo "Diagnoses / Next Actions:"
      for diag in "${DIAGNOSES[@]}"; do
        echo "$diag"
      done
    else
      echo "Diagnoses / Next Actions:"
      echo "- No obvious issues detected."
    fi
  } >"$REPORT_FILE"
}

main() {
  load_config

  local apache_service sql_service url

  apache_service="$(detect_service_name APACHE_SERVICE_CANDIDATES)"
  sql_service="$(detect_service_name SQL_SERVICE_CANDIDATES)"

  check_service_health "Apache" APACHE_SERVICE_CANDIDATES APACHE_PROCESS_CANDIDATES
  check_service_health "SQL" SQL_SERVICE_CANDIDATES SQL_PROCESS_CANDIDATES

  for url in "${CHECK_URLS[@]}"; do
    check_url_connectivity "$url"
  done

  count_file_errors APACHE_ERROR_LOG_PATHS "Apache"
  count_file_errors SQL_ERROR_LOG_PATHS "SQL"

  count_journal_errors_for_service "$apache_service" "Apache"
  count_journal_errors_for_service "$sql_service" "SQL"

  build_report
  write_report_file
  post_webhook_if_needed

  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
