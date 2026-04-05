#!/bin/bash
# =============================================================================
# vps_monitor.sh — VPS Health Monitor
# Checks CPU, RAM, disk, load average, and services.
# Sends email alerts when thresholds are exceeded.
# Schedule with cron for automated monitoring.
# =============================================================================

# --- Load config file (same directory as this script) ------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/monitor.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found at $CONFIG_FILE"
  exit 1
fi

# shellcheck source=monitor.conf
source "$CONFIG_FILE"

# --- Derived settings --------------------------------------------------------
LOG_DATE=$(date +"%Y-%m-%d")
LOG_TIME=$(date +"%Y-%m-%d %H:%M:%S")
LOG_FILE="$LOG_DIR/monitor_${LOG_DATE}.log"
ALERT_TRIGGERED=false
ALERT_BODY=""
HOSTNAME=$(hostname -f)

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log() {
  local level="$1"
  local message="$2"
  echo "[$LOG_TIME] [$level] $message" | tee -a "$LOG_FILE"
}

append_alert() {
  ALERT_BODY+="$1\n"
  ALERT_TRIGGERED=true
}

send_alert_email() {
  local subject="[VPS ALERT] $HOSTNAME — $1"
  local body
  body="$(printf "VPS Monitor Alert\n=================\nHost     : %s\nTime     : %s\n\nISSUES DETECTED:\n----------------\n%b\n\nFull log : %s\n" \
    "$HOSTNAME" "$LOG_TIME" "$ALERT_BODY" "$LOG_FILE")"

  echo "$body" | mail -s "$subject" "$ALERT_EMAIL"

  if [[ $? -eq 0 ]]; then
    log "INFO" "Alert email sent to $ALERT_EMAIL"
  else
    log "ERROR" "Failed to send alert email"
  fi
}

# =============================================================================
# CHECK FUNCTIONS
# =============================================================================

# --- CPU Usage ----------------------------------------------------------------
check_cpu() {
  # Average CPU usage over a 1-second sample using /proc/stat
  local cpu_idle cpu_total cpu_used_pct

  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat

  local total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
  local idle1=$idle

  sleep 1

  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat

  local total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
  local idle2=$idle

  local delta_total=$((total2 - total1))
  local delta_idle=$((idle2 - idle1))

  cpu_used_pct=$(( (delta_total - delta_idle) * 100 / delta_total ))

  log "INFO" "CPU usage: ${cpu_used_pct}% (threshold: ${CPU_THRESHOLD}%)"

  if (( cpu_used_pct >= CPU_THRESHOLD )); then
    append_alert "  [CPU]  Usage is ${cpu_used_pct}% — threshold is ${CPU_THRESHOLD}%"
    log "WARN" "CPU threshold exceeded: ${cpu_used_pct}%"
  fi
}

# --- RAM Usage ----------------------------------------------------------------
check_ram() {
  local total used free available used_pct
  read -r _ total _ < <(grep MemTotal /proc/meminfo)
  read -r _ available _ < <(grep MemAvailable /proc/meminfo)

  used=$(( total - available ))
  used_pct=$(( used * 100 / total ))

  local total_mb=$(( total / 1024 ))
  local used_mb=$(( used / 1024 ))

  log "INFO" "RAM usage: ${used_pct}% (${used_mb}MB / ${total_mb}MB) — threshold: ${RAM_THRESHOLD}%"

  if (( used_pct >= RAM_THRESHOLD )); then
    append_alert "  [RAM]  Usage is ${used_pct}% (${used_mb}MB / ${total_mb}MB) — threshold is ${RAM_THRESHOLD}%"
    log "WARN" "RAM threshold exceeded: ${used_pct}%"
  fi
}

# --- Disk Usage ---------------------------------------------------------------
check_disk() {
  log "INFO" "Checking disk usage on mount points: ${DISK_MOUNTS[*]}"

  for mount in "${DISK_MOUNTS[@]}"; do
    if ! mountpoint -q "$mount" && [[ "$mount" != "/" ]]; then
      log "WARN" "Mount point $mount does not exist, skipping"
      continue
    fi

    local usage
    usage=$(df "$mount" --output=pcent | tail -1 | tr -d ' %')

    log "INFO" "Disk $mount: ${usage}% used (threshold: ${DISK_THRESHOLD}%)"

    if (( usage >= DISK_THRESHOLD )); then
      local details
      details=$(df -h "$mount" | tail -1)
      append_alert "  [DISK] $mount is at ${usage}% — threshold is ${DISK_THRESHOLD}%\n         $details"
      log "WARN" "Disk threshold exceeded on $mount: ${usage}%"
    fi
  done
}

# --- Load Average -------------------------------------------------------------
check_load() {
  local cpu_cores load1 load5 load15
  cpu_cores=$(nproc)
  read -r load1 load5 load15 _ < /proc/loadavg

  # Convert to integer by multiplying by 100 for comparison
  local load1_int load_limit_int
  load1_int=$(echo "$load1 * 100" | bc | cut -d'.' -f1)
  local load_limit
  load_limit=$(echo "$cpu_cores * $LOAD_MULTIPLIER" | bc)
  load_limit_int=$(echo "$load_limit * 100" | bc | cut -d'.' -f1)

  log "INFO" "Load average (1m/5m/15m): $load1 / $load5 / $load15 (cores: $cpu_cores, limit: $load_limit)"

  if (( load1_int >= load_limit_int )); then
    append_alert "  [LOAD] 1-min load average is $load1 (limit: $load_limit for $cpu_cores cores)"
    log "WARN" "Load average too high: $load1 (limit: $load_limit)"
  fi
}

# --- Service Status -----------------------------------------------------------
check_services() {
  if [[ ${#SERVICES[@]} -eq 0 ]]; then
    log "INFO" "No services configured to monitor"
    return
  fi

  log "INFO" "Checking services: ${SERVICES[*]}"

  for service in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$service"; then
      log "INFO" "Service $service: running"
    else
      local status
      status=$(systemctl is-active "$service")
      append_alert "  [SVC]  Service '$service' is $status (expected: active)"
      log "WARN" "Service $service is NOT running (status: $status)"
    fi
  done
}

# --- Zombie Processes ---------------------------------------------------------
check_zombies() {
  local zombie_count
  zombie_count=$(ps aux | awk '{print $8}' | grep -c '^Z$' || true)

  log "INFO" "Zombie processes: $zombie_count (threshold: ${ZOMBIE_THRESHOLD})"

  if (( zombie_count >= ZOMBIE_THRESHOLD )); then
    append_alert "  [PROC] $zombie_count zombie processes detected"
    log "WARN" "Zombie processes detected: $zombie_count"
  fi
}

# =============================================================================
# LOG ROTATION — keep last N days
# =============================================================================

rotate_logs() {
  if [[ -d "$LOG_DIR" ]]; then
    find "$LOG_DIR" -name "monitor_*.log" -mtime +"$LOG_RETENTION_DAYS" -delete
    log "INFO" "Log rotation: removed logs older than $LOG_RETENTION_DAYS days"
  fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  # Ensure log directory exists
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
    log "WARN" "Alert condition(s) detected — sending email to $ALERT_EMAIL"
    send_alert_email "Action required on $HOSTNAME"
  else
    log "INFO" "All checks passed. No alerts triggered."
  fi

  log "INFO" "Monitor run complete."
}

main
