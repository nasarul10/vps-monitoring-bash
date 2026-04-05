#!/bin/bash
# =============================================================================
# vps_monitor.sh — VPS Health Monitor (HTML Email Edition)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/monitor.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found at $CONFIG_FILE"
  exit 1
fi

source "$CONFIG_FILE"

# --- Runtime vars -------------------------------------------------------------
LOG_DATE=$(date +"%Y-%m-%d")
LOG_TIME=$(date +"%Y-%m-%d %H:%M:%S")
DISPLAY_TIME=$(date +"%B %d, %Y at %I:%M %p")
LOG_FILE="$LOG_DIR/monitor_${LOG_DATE}.log"
HOSTNAME=$(hostname -f)
ALERT_TRIGGERED=false

# Metric storage (populated by check functions)
CPU_VALUE=0;    CPU_STATUS="ok"
RAM_VALUE=0;    RAM_STATUS="ok";   RAM_USED_MB=0;  RAM_TOTAL_MB=0
DISK_VALUE=0;   DISK_STATUS="ok"
LOAD_VALUE=0;   LOAD_STATUS="ok";  LOAD_LIMIT=0;   CPU_CORES=0
ZOMBIE_VALUE=0; ZOMBIE_STATUS="ok"

# Per-service and per-disk results (for HTML rows)
declare -A SERVICE_STATUS_MAP
declare -A DISK_STATUS_MAP
ALERT_ITEMS=""   # Plain-text summary lines for the log

# =============================================================================
# HELPERS
# =============================================================================

log() {
  mkdir -p "$LOG_DIR"
  echo "[$LOG_TIME] [$1] $2" | tee -a "$LOG_FILE"
}

add_alert() {
  ALERT_ITEMS+="  • $1\n"
  ALERT_TRIGGERED=true
}

status_for() {
  local value=$1 threshold=$2
  local warn_at=$(( threshold * 90 / 100 ))
  if (( value >= threshold ));  then echo "crit"
  elif (( value >= warn_at ));  then echo "warn"
  else                               echo "ok"
  fi
}

# =============================================================================
# CHECK FUNCTIONS
# =============================================================================

check_cpu() {
  read -r _ u1 n1 s1 i1 w1 r1 f1 st1 _ < /proc/stat
  sleep 1
  read -r _ u2 n2 s2 i2 w2 r2 f2 st2 _ < /proc/stat
  local total=$(( (u2+n2+s2+i2+w2+r2+f2+st2) - (u1+n1+s1+i1+w1+r1+f1+st1) ))
  local idle=$(( i2 - i1 ))
  CPU_VALUE=$(( (total - idle) * 100 / total ))
  CPU_STATUS=$(status_for "$CPU_VALUE" "$CPU_THRESHOLD")
  log "INFO" "CPU: ${CPU_VALUE}% (threshold: ${CPU_THRESHOLD}%)"
  [[ "$CPU_STATUS" == "crit" ]] && add_alert "CPU usage is ${CPU_VALUE}% — threshold is ${CPU_THRESHOLD}%"
}

check_ram() {
  local total avail
  read -r _ total _ < <(grep MemTotal     /proc/meminfo)
  read -r _ avail  _ < <(grep MemAvailable /proc/meminfo)
  local used=$(( total - avail ))
  RAM_VALUE=$(( used * 100 / total ))
  RAM_USED_MB=$(( used / 1024 ))
  RAM_TOTAL_MB=$(( total / 1024 ))
  RAM_STATUS=$(status_for "$RAM_VALUE" "$RAM_THRESHOLD")
  log "INFO" "RAM: ${RAM_VALUE}% (${RAM_USED_MB}MB / ${RAM_TOTAL_MB}MB)"
  [[ "$RAM_STATUS" == "crit" ]] && add_alert "RAM usage is ${RAM_VALUE}% (${RAM_USED_MB}MB / ${RAM_TOTAL_MB}MB)"
}

check_disk() {
  for mount in "${DISK_MOUNTS[@]}"; do
    local usage
    usage=$(df "$mount" --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
    local st=$(status_for "$usage" "$DISK_THRESHOLD")
    DISK_STATUS_MAP["$mount"]="$usage $st"
    log "INFO" "Disk $mount: ${usage}% ($st)"
    [[ "$st" == "crit" ]] && add_alert "Disk $mount is at ${usage}% — threshold is ${DISK_THRESHOLD}%"
    if [[ "$mount" == "/" ]]; then
      DISK_VALUE=$usage
      DISK_STATUS=$st
    fi
  done
}

check_load() {
  CPU_CORES=$(nproc)
  read -r LOAD_VALUE _ _ _ < /proc/loadavg
  LOAD_LIMIT=$(echo "$CPU_CORES * $LOAD_MULTIPLIER" | bc)
  local load_int=$(echo "$LOAD_VALUE * 100" | bc | cut -d'.' -f1)
  local limit_int=$(echo "$LOAD_LIMIT  * 100" | bc | cut -d'.' -f1)
  log "INFO" "Load: $LOAD_VALUE (limit: $LOAD_LIMIT, cores: $CPU_CORES)"
  if (( load_int >= limit_int )); then
    LOAD_STATUS="crit"
    add_alert "Load average is $LOAD_VALUE (limit: $LOAD_LIMIT for $CPU_CORES cores)"
  fi
}

check_services() {
  for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then
      SERVICE_STATUS_MAP["$svc"]="running"
      log "INFO" "Service $svc: running"
    else
      local st
      st=$(systemctl is-active "$svc")
      SERVICE_STATUS_MAP["$svc"]="$st"
      add_alert "Service '$svc' is $st"
      log "WARN" "Service $svc: $st"
    fi
  done
}

check_zombies() {
  ZOMBIE_VALUE=$(ps aux | awk '{print $8}' | grep -c '^Z$' || true)
  ZOMBIE_STATUS=$(status_for "$ZOMBIE_VALUE" "$ZOMBIE_THRESHOLD")
  log "INFO" "Zombies: $ZOMBIE_VALUE (threshold: $ZOMBIE_THRESHOLD)"
  [[ "$ZOMBIE_STATUS" == "crit" ]] && add_alert "$ZOMBIE_VALUE zombie processes detected"
}

rotate_logs() {
  find "$LOG_DIR" -name "monitor_*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
}

# =============================================================================
# HTML EMAIL BUILDER
# =============================================================================

status_color()  { case "$1" in ok) echo "#1a7f4b";; warn) echo "#b45309";; crit) echo "#b91c1c";; *) echo "#6b7280";; esac; }
status_bg()     { case "$1" in ok) echo "#f0fdf4";; warn) echo "#fffbeb";; crit) echo "#fef2f2";; *) echo "#f9fafb";; esac; }
status_border() { case "$1" in ok) echo "#86efac";; warn) echo "#fcd34d";; crit) echo "#fca5a5";; *) echo "#e5e7eb";; esac; }
status_label()  { case "$1" in ok) echo "NORMAL";;  warn) echo "WARNING";; crit) echo "CRITICAL";; *) echo "UNKNOWN";; esac; }
status_dot()    { case "$1" in ok) echo "&#9679;";; warn) echo "&#9650;";; crit) echo "&#10005;";; *) echo "?";; esac; }

metric_card() {
  local title="$1" value="$2" subtitle="$3" status="$4"
  local color bg border label dot
  color=$(status_color  "$status")
  bg=$(status_bg        "$status")
  border=$(status_border "$status")
  label=$(status_label  "$status")
  dot=$(status_dot      "$status")
  cat <<EOF
<td width="25%" style="padding:8px;vertical-align:top;">
  <div style="background:${bg};border:1px solid ${border};border-radius:14px;padding:24px 16px;text-align:center;">
    <div style="font-size:12px;font-weight:600;color:#6b7280;letter-spacing:.07em;text-transform:uppercase;margin-bottom:12px;">${title}</div>
    <div style="font-size:42px;font-weight:700;color:${color};line-height:1;">${value}</div>
    <div style="font-size:12px;color:#9ca3af;margin:8px 0 14px;">${subtitle}</div>
    <div style="display:inline-block;background:${color};color:#fff;font-size:11px;font-weight:600;padding:4px 14px;border-radius:20px;">${dot}&nbsp;${label}</div>
  </div>
</td>
EOF
}

service_row() {
  local name="$1" state="$2"
  local color dot bg
  if [[ "$state" == "running" ]]; then
    color="#1a7f4b"; dot="&#9679;"; bg="#f0fdf4"
  else
    color="#b91c1c"; dot="&#10005;"; bg="#fef2f2"
  fi
  cat <<EOF
<tr>
  <td style="padding:14px 20px;font-size:15px;color:#374151;border-bottom:1px solid #f3f4f6;">${name}</td>
  <td style="padding:14px 20px;text-align:right;border-bottom:1px solid #f3f4f6;">
    <span style="background:${bg};color:${color};font-size:12px;font-weight:600;padding:5px 14px;border-radius:20px;">${dot}&nbsp;${state}</span>
  </td>
</tr>
EOF
}

alert_rows() {
  [[ -z "$ALERT_ITEMS" ]] && return
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local clean="${line#  • }"
    echo "<li style='margin-bottom:6px;color:#374151;font-size:15px;'>${clean}</li>"
  done < <(printf "%b" "$ALERT_ITEMS")
}

build_html_email() {
  local header_bg header_label
  if [[ "$ALERT_TRIGGERED" == true ]]; then
    header_bg="#b91c1c"; header_label="&#9888;&nbsp; Action Required"
  else
    header_bg="#1a7f4b"; header_label="&#10003;&nbsp; All Systems Normal"
  fi

  local cards
  cards=$(metric_card  "CPU Usage"  "${CPU_VALUE}%"   "threshold: ${CPU_THRESHOLD}%"        "$CPU_STATUS")
  cards+=$(metric_card "Memory"     "${RAM_VALUE}%"   "${RAM_USED_MB}MB / ${RAM_TOTAL_MB}MB" "$RAM_STATUS")
  cards+=$(metric_card "Disk /"     "${DISK_VALUE}%"  "threshold: ${DISK_THRESHOLD}%"        "$DISK_STATUS")
  cards+=$(metric_card "Load Avg"   "$LOAD_VALUE"     "limit: $LOAD_LIMIT ($CPU_CORES cores)" "$LOAD_STATUS")

  local svc_rows=""
  for svc in "${SERVICES[@]}"; do
    svc_rows+=$(service_row "$svc" "${SERVICE_STATUS_MAP[$svc]:-unknown}")
  done

  local alert_section=""
  if [[ "$ALERT_TRIGGERED" == true ]]; then
    alert_section="
    <div style='margin-top:32px;background:#fef2f2;border:1px solid #fca5a5;border-radius:14px;padding:22px 26px;'>
      <div style='font-size:15px;font-weight:700;color:#b91c1c;margin-bottom:12px;'>Issues Detected</div>
      <ul style='margin:0;padding-left:20px;line-height:2.1;'>$(alert_rows)</ul>
    </div>"
  fi

  cat <<HTML
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;background:#f3f4f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6;padding:24px;">
<tr><td>
<table width="100%" cellpadding="0" cellspacing="0">

  <tr><td style="background:${header_bg};border-radius:16px 16px 0 0;padding:36px 44px;">
    <div style="font-size:12px;font-weight:600;color:rgba(255,255,255,.65);letter-spacing:.09em;text-transform:uppercase;margin-bottom:8px;">VPS Monitor</div>
    <div style="font-size:30px;font-weight:700;color:#fff;">${header_label}</div>
    <div style="font-size:15px;color:rgba(255,255,255,.75);margin-top:7px;">${HOSTNAME}&nbsp;&nbsp;·&nbsp;&nbsp;${DISPLAY_TIME}</div>
  </td></tr>

  <tr><td style="background:#fff;border-radius:0 0 16px 16px;padding:36px 44px;">

    <div style="font-size:12px;font-weight:600;color:#9ca3af;letter-spacing:.07em;text-transform:uppercase;margin-bottom:14px;">System Metrics</div>
    <table width="100%" cellpadding="0" cellspacing="0"><tr>${cards}</tr></table>

    <div style="margin-top:32px;">
      <div style="font-size:12px;font-weight:600;color:#9ca3af;letter-spacing:.07em;text-transform:uppercase;margin-bottom:12px;">Services</div>
      <table width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #f3f4f6;border-radius:12px;overflow:hidden;">
        ${svc_rows}
      </table>
    </div>

    ${alert_section}

    <div style="margin-top:36px;padding-top:22px;border-top:1px solid #f3f4f6;text-align:center;">
      <div style="font-size:12px;color:#d1d5db;">vps_monitor.sh &nbsp;·&nbsp; ${HOSTNAME}</div>
      <div style="font-size:12px;color:#d1d5db;margin-top:3px;">Log: ${LOG_FILE}</div>
    </div>

  </td></tr>
</table>
</td></tr></table>
</body></html>
HTML
}

# =============================================================================
# EMAIL SENDER
# =============================================================================

send_email() {
  local subject
  if [[ "$ALERT_TRIGGERED" == true ]]; then
    subject="[VPS ALERT] $HOSTNAME — Action Required"
  else
    subject="[VPS OK] $HOSTNAME — All Systems Normal"
  fi

  local html_body
  html_body=$(build_html_email)

  {
    echo "To: $ALERT_EMAIL"
    echo "Subject: $subject"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/html; charset=UTF-8"
    echo ""
    echo "$html_body"
  } | sendmail -t

  if [[ $? -eq 0 ]]; then
    log "INFO" "HTML email sent → $subject"
  else
    log "ERROR" "Failed to send email"
  fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  mkdir -p "$LOG_DIR"
  log "INFO" "========================================="
  log "INFO" "VPS Monitor started on $HOSTNAME"
  log "INFO" "========================================="

  check_cpu
  check_ram
  check_disk
  check_load
  check_services
  check_zombies
  rotate_logs

  if [[ "$ALERT_TRIGGERED" == true ]]; then
    log "WARN" "Alert conditions detected — sending HTML email"
  else
    log "INFO" "All checks passed. No alerts triggered."
  fi

  if [[ "$ALERT_TRIGGERED" == true ]] || [[ "${ALWAYS_EMAIL:-false}" == "true" ]]; then
    send_email
  fi

  log "INFO" "Monitor run complete."
}

main
