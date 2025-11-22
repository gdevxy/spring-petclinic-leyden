#!/usr/bin/env bash

set -u

ITERATIONS=100
OUTPUT="run-startup-time.txt"
TIMEOUT=120
PORT=8080
PORT_WAIT_TIMEOUT=20
START_SCRIPT="./start-and-load-cache.sh"
PATTERN="Started PetClinicApplication in"
REGEX='Started PetClinicApplication in ([0-9.]+) seconds \(process running for ([0-9.]+)\)'

usage() {
  echo "Usage: $0 [-n iterations] [-o output] [-t timeout] [-p port] [-s startup_script]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) ITERATIONS="$2"; shift 2 ;;
    -o) OUTPUT="$2"; shift 2 ;;
    -t) TIMEOUT="$2"; shift 2 ;;
    -p) PORT="$2"; shift 2 ;;
    -s) START_SCRIPT="$2"; shift 2 ;;
    -h) usage; exit 0 ;;
    *) echo "Unknown option $1"; usage; exit 1 ;;
  esac
done

[[ -x "$START_SCRIPT" ]] || { echo "Startup script not executable: $START_SCRIPT" >&2; exit 1; }
[[ -f "$OUTPUT" ]] || echo "iteration,startup_seconds,process_running_seconds" > "$OUTPUT"

get_server_pid() {
  lsof -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n1 || true
}

graceful_stop() {
  local pid="$1"
  local iter="$2"
  [[ -z "$pid" ]] && return
  if ! kill -0 "$pid" 2>/dev/null; then
    return
  fi
  kill -TERM "$pid" 2>/dev/null || true
  for _ in {1..100}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
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
    if [[ -z "$(get_server_pid)" ]]; then
      return 0
    fi
    sleep 0.1
    ((waited++))
  done
  return 1
}

run_once() {
  local idx="$1"
  local got=0
  local fifo=".__pipe.$$.$RANDOM"
  mkfifo "$fifo"

  "$START_SCRIPT" > "$fifo" 2>&1 &
  local wrapper_pid=$!

  (
    sleep "$TIMEOUT"
    if kill -0 "$wrapper_pid" 2>/dev/null; then
      echo "[Iteration $idx] Global timeout ${TIMEOUT}s" >&2
      local spid="$(get_server_pid)"
      graceful_stop "$spid" "$idx"
      kill "$wrapper_pid" 2>/dev/null || true
    fi
  ) & local watchdog_pid=$!

  while IFS= read -r line; do
    echo "[${idx}] $line"
    if [[ "$line" == *"$PATTERN"* && "$line" =~ $REGEX ]]; then
      local startup="${BASH_REMATCH[1]}"
      local proc_run="${BASH_REMATCH[2]}"
      echo "${idx},${startup},${proc_run}" >> "$OUTPUT"
      got=1
      local server_pid=""
      for _ in {1..50}; do
        server_pid="$(get_server_pid)"
        [[ -n "$server_pid" ]] && break
        sleep 0.1
      done
      graceful_stop "$server_pid" "$idx"
      break
    fi
  done < "$fifo"

  wait "$wrapper_pid" 2>/dev/null || true
  kill "$watchdog_pid" 2>/dev/null || true
  rm -f "$fifo"

  if ! wait_port_free; then
    local spid="$(get_server_pid)"
    if [[ -n "$spid" ]]; then
      echo "[Iteration $idx] Port still busy; forcing kill PID $spid" >&2
      kill -KILL "$spid" 2>/dev/null || true
      wait_port_free || echo "[Iteration $idx] Port still busy after force." >&2
    fi
  fi

  if [[ $got -eq 0 ]]; then
    echo "${idx},NA,NA" >> "$OUTPUT"
    echo "[Iteration $idx] Pattern not captured." >&2
  fi
}

echo "Starting ${ITERATIONS} iterations..."
for ((i=1; i<=ITERATIONS; i++)); do
  run_once "$i"
done

echo "Results written to $OUTPUT"

awk -F',' '
  NR>1 && $2 != "NA" {
    s1 += $2; s2 += $3; c++
  }
  END {
    if (c>0) {
      printf "Valid rows: %d\nAverage startup_seconds: %.3f\nAverage process_running_seconds: %.3f\n", c, s1/c, s2/c
    } else {
      print "No valid timing rows."
    }
  }
' "$OUTPUT"
