#!/usr/bin/env bash
# network_diagnostics.sh
# Perform network diagnostics for a given host/IP:
#  - DNS lookup (A, AAAA, MX, NS, TXT)
#  - Port scan (custom ports, default common ports)
#  - Latency test (ping)
#  - HTTP status & timing (curl)
#
# Usage:
#   ./network_diagnostics.sh -t example.com -p 22,80,443 -o /tmp/diag.log
#
# Requirements: dig or host, ping, curl, nc (netcat) or bash /dev/tcp fallback
# Optional: nmap (if available, will be used for a more thorough port scan)

set -euo pipefail
IFS=$'\n\t'

PROGNAME=$(basename "$0")
VERSION="1.0"

print_help(){
  cat <<EOF
$PROGNAME v$VERSION

Usage: $PROGNAME -t target [options]

Options:
  -t, --target     Target hostname or IP (required)
  -p, --ports      Comma-separated list of ports (default: 22,80,443,53,25,3389,8080)
  -o, --output     Output log file (default: ./network_diagnostics.<target>.log)
  -c, --count      Number of pings for latency test (default: 4)
  -T, --timeout    Timeout seconds for port probe (default: 3)
  -n, --nmap       Use nmap if installed for port scanning (no argument)
  -h, --help       Show this help

Examples:
  $PROGNAME -t example.com
  $PROGNAME -t 8.8.8.8 -p 53,443 -o /var/log/diag.log -c 6

EOF
}

# default values
PORTS="22,80,443,53,25,3389,8080"
PING_COUNT=4
TIMEOUT=3
USE_NMAP=0
OUTPUT=""
TARGET=""

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target) TARGET="$2"; shift 2 ;;
    -p|--ports) PORTS="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -c|--count) PING_COUNT="$2"; shift 2 ;;
    -T|--timeout) TIMEOUT="$2"; shift 2 ;;
    -n|--nmap) USE_NMAP=1; shift 1 ;;
    -h|--help) print_help; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1" >&2; print_help; exit 1 ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Error: target is required." >&2
  print_help
  exit 1
fi

# set default output if not provided
if [[ -z "$OUTPUT" ]]; then
  SAFE_TARGET=$(echo "$TARGET" | sed 's/[^a-zA-Z0-9._-]/_/g')
  OUTPUT="./network_diagnostics.${SAFE_TARGET}.log"
fi

# helper to log with timestamp
log(){
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$OUTPUT"
}

# start
: > "$OUTPUT"
log "Starting network diagnostics for: $TARGET"
log "Options: ports=$PORTS ping_count=$PING_COUNT timeout=$TIMEOUT use_nmap=$USE_NMAP"

# 1) DNS lookups
log "--- DNS lookups ---"
if command -v dig >/dev/null 2>&1; then
  log "Using dig for DNS lookups"
  for t in A AAAA MX NS TXT; do
    log "dig +short $t $TARGET"
    dig +noall +answer $TARGET $t | sed 's/^/    /' | tee -a "$OUTPUT"
  done
else
  log "dig not found, falling back to host"
  if command -v host >/dev/null 2>&1; then
    log "host $TARGET"
    host $TARGET | sed 's/^/    /' | tee -a "$OUTPUT"
  else
    log "No dig or host command available. Skipping DNS lookups."
  fi
fi


# 2) Port scanning
log "--- Port scanning ---"
if [[ $USE_NMAP -eq 1 && $(command -v nmap || true) ]]; then
  log "nmap found -> running nmap scan (this can take a moment)"
  nmap -Pn -p ${PORTS//,/ } "$TARGET" | sed 's/^/    /' | tee -a "$OUTPUT"
else
  log "Using lightweight port probes"
  IFS=',' read -r -a PORT_ARRAY <<< "$PORTS"
  for p in "${PORT_ARRAY[@]}"; do
    p_trim=$(echo "$p" | tr -d '[:space:]')
    if [[ -z "$p_trim" ]]; then continue; fi
    status=$(check_port "$TARGET" "$p_trim" "$TIMEOUT")
    log "Port $p_trim: $status"
  done
fi

# 3) Latency test (ping)
log "--- Latency test (ping) ---"
if command -v ping >/dev/null 2>&1; then
  # prefer ping -c on unix-like systems
  if ping -c "$PING_COUNT" -W "$TIMEOUT" "$TARGET" >/dev/null 2>&1; then
    log "Ping output:"
    ping -c "$PING_COUNT" "$TARGET" | sed 's/^/    /' | tee -a "$OUTPUT"
  else
    log "Ping failed or no ICMP response (may be blocked). Still capturing output."
    ping -c "$PING_COUNT" "$TARGET" | sed 's/^/    /' | tee -a "$OUTPUT" || true
  fi
else
  log "ping command not found; skipping latency test"
fi

# 4) HTTP status & timing
log "--- HTTP(S) checks ---"
if command -v curl >/dev/null 2>&1; then
  # get scheme candidates
  SCHEMES=("http" "https")
  for s in "${SCHEMES[@]}"; do
    url="$s://$TARGET/"
    log "Checking $url"
    # capture HTTP code, total time, connect time
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time $TIMEOUT "$url" 2>/dev/null || echo "000")
    total_time=$(curl -sS -o /dev/null -w "%{time_total}" --max-time $TIMEOUT "$url" 2>/dev/null || echo "-1")
    connect_time=$(curl -sS -o /dev/null -w "%{time_connect}" --max-time $TIMEOUT "$url" 2>/dev/null || echo "-1")
    log "URL: $url"
    log "    HTTP status: $http_code"
    log "    connect_time: ${connect_time}s total_time: ${total_time}s"
  done
else
  log "curl not found; skipping HTTP checks"
fi


# exit
exit 0
