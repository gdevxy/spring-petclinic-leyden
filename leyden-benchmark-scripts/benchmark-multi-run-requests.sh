#!/usr/bin/env bash
set -u

ITERATIONS=100
OUTPUT="run-requests.txt"
PORT=8080
START_TIMEOUT=180
PORT_READY_TIMEOUT=30
BENCH_SCRIPT="./benchmark-requests.sh"
START_SCRIPT="./start-and-load-cache.sh"
PATTERN="Started PetClinicApplication in"
REGEX_START='Started PetClinicApplication in ([0-9.]+) seconds \(process running for ([0-9.]+)\)'
REGEX_200='\[200\][[:space:]]+([0-9]+)[[:space:]]+responses'
PORT_WAIT_TIMEOUT=20

usage() {
  echo "Usage: $0 -n iterations [-o output] [-p port] [-t start_timeout] [-s startup_script] [-b benchmark_script]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) ITERATIONS="$2"; shift 2 ;;
    -o) OUTPUT="$2"; shift 2 ;;
    -p) PORT="$2"; shift 2 ;;
    -t) START_TIMEOUT="$2"; shift 2 ;;
    -s) START_SCRIPT="$2"; shift 2 ;;
    -b) BENCH_SCRIPT="$2"; shift 2 ;;
    -h) usage; exit 0 ;;
    *) echo "Unknown option $1"; usage; exit 1 ;;
  esac
done

[[ -x "$START_SCRIPT" ]] || { echo "Startup script not executable: $START_SCRIPT" >&2; exit 1; }
[[ -x "$BENCH_SCRIPT" ]] || { echo "Benchmark script not executable: $BENCH_SCRIPT" >&2; exit 1; }
[[ -f "$OUTPUT" ]] || : > "$OUTPUT"  # no header, only numbers

get_server_pid() {
  lsof -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n1 || true
}

wait_for_port() {
  local waited=0
  while [[ $waited -lt $((PORT_READY_TIMEOUT*10)) ]]; do
    [[ -n "$(get_server_pid)" ]] && return 0
    sleep 0.1
    ((waited++))
  done
  return 1
}

graceful_stop() {
  local pid="$1" iter="$2"
  [[ -z "$pid" ]] && return
  if ! kill -0 "$pid" 2>/dev/null; then return; fi
  kill -TERM "$pid" 2>/dev/null || true
  for _ in {1..150}; do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "[Iteration $iter] Forcing SIGKILL on PID $pid" >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

wait_port_free() {
  local waited=0
  while [[ $waited -lt $((PORT_WAIT_TIMEOUT*10)) ]]; do
    [[ -z "$(get_server_pid)" ]] && return 0
    sleep 0.1
    ((waited++))
  done
  return 1
}

run_once() {
  local idx="$1"
  local log=".__startup_log.$$.$RANDOM"
  : > "$log"

  (
    "$START_SCRIPT" 2>&1 | while IFS= read -r line; do
      echo "[${idx}] $line"
      printf '%s\n' "$line" >> "$log"
    done
  ) &
  local service_wrapper_pid=$!

  local got=0
  local waited=0
  while [[ $waited -lt $((START_TIMEOUT*10)) ]]; do
    if grep -F "$PATTERN" "$log" >/dev/null 2>&1; then
      got=1
      break
    fi
    if ! kill -0 "$service_wrapper_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
    ((waited++))
  done

  if [[ $got -ne 1 ]]; then
    echo "[Iteration $idx] Startup line not captured (timeout or crash)" >&2
  fi

  if [[ $got -eq 1 ]] && ! wait_for_port; then
    echo "[Iteration $idx] Port $PORT not ready; skipping benchmark" >&2
    got=0
  fi

  local responses_200="NA"
  if [[ $got -eq 1 ]]; then
    # Run benchmark; send its detailed output to console (stderr) only
    local bench_out
    bench_out="$("$BENCH_SCRIPT" 2>&1)"
    # Print benchmark lines to console with prefix (do not let them enter the variable)
    while IFS= read -r line; do
      echo "[${idx} BENCH] $line" >&2
    done <<< "$bench_out"
    if [[ "$bench_out" =~ $REGEX_200 ]]; then
      responses_200="${BASH_REMATCH[1]}"
    fi
  fi

  # Stop server
  local server_pid=""
  server_pid="$(get_server_pid)"
  if [[ -z "$server_pid" ]] && kill -0 "$service_wrapper_pid" 2>/dev/null; then
    server_pid="$service_wrapper_pid"
  fi
  graceful_stop "$server_pid" "$idx"
  wait "$service_wrapper_pid" 2>/dev/null || true

  if ! wait_port_free; then
    local lingering="$(get_server_pid)"
    if [[ -n "$lingering" ]]; then
      echo "[Iteration $idx] Lingering PID $lingering; force kill" >&2
      kill -KILL "$lingering" 2>/dev/null || true
      wait_port_free || echo "[Iteration $idx] Port still busy after force" >&2
    fi
  fi

  rm -f "$log"

  # Append only the numeric responses (or NA) as requested
  echo "$responses_200" >> "$OUTPUT"
}

echo "Starting $ITERATIONS iterations..."
for ((i=1; i<=ITERATIONS; i++)); do
  run_once "$i"
done
echo "Numbers written to $OUTPUT"
