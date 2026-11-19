#!/usr/bin/env bash
# AISTVM: keep the codespace out of its idle timeout.
#
# GitHub resets the idle timer on activity that indicates a user is present:
# personal interaction, and terminal input or output. The idle ceiling is 240
# minutes (4 hours) and it is fixed at create time, so the only way past it is to
# keep producing that activity - which is what this loop does. With the loop
# running the machine is not stopped at 4 hours; it lives until the codespace's
# own hard lifetime cap (observed ~13 hours). The 4-hour figure only applies to
# a machine whose keepalive is dead, which is why the loop must be supervised.
#
# Three things make this survive, and each one was a real failure before:
#
#  1. It closes the file descriptors it inherits. `setup.sh` holds its own
#     `flock` on fd 9 and starts this script before releasing it, so the daemon
#     used to inherit that fd and hold the setup lock forever. The next start
#     then found the lock taken and exited at once, so a restarted machine never
#     re-ran setup: no tailscaled, no console publish, no status update.
#  2. A supervisor re-spawns the printing loop. The loop ran once and, if its pty
#     was ever torn down, nothing brought it back, so the keepalive silently
#     stopped and the machine idled out.
#  3. It records a heartbeat, so "is the keepalive actually alive?" is a fact
#     that can be checked instead of assumed.
set -uo pipefail

INTERVAL=180
STATUS_DIR=".aistvm"
LOG_FILE="${STATUS_DIR}/keepalive.log"
HEARTBEAT_FILE="${STATUS_DIR}/keepalive.heartbeat"
PID_FILE="${STATUS_DIR}/keepalive.pid"
mkdir -p "${STATUS_DIR}"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"${LOG_FILE}"; }

# --- Inner loop: the only thing that emits terminal output ------------------
if [ "${1:-}" = "--loop" ]; then
  while true; do
    printf '[%s] aistvm keepalive\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    date -u +%s >"${HEARTBEAT_FILE}" 2>/dev/null || true
    if [ -n "${CONSOLE_URL:-}" ]; then
      # 401 is the expected answer: the console is password protected
      # (PROTECT=Y). The request is unauthenticated and carries no token.
      curl -s -o /dev/null -m 15 "${CONSOLE_URL}" >/dev/null 2>&1 || true
    fi
    sleep "${INTERVAL}"
  done
fi

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
QUOTED_SELF="$(printf '%q' "${SELF}")"

# postStartCommand is not a login shell, so the codespace's own name is read the
# way an interactive session exposes it.
CONSOLE_NAME="$(bash -lc 'printf %s "${CODESPACE_NAME:-}"' 2>/dev/null)"
CONSOLE_URL=""
[ -n "${CONSOLE_NAME}" ] && CONSOLE_URL="https://${CONSOLE_NAME}-8006.app.github.dev/"
export CONSOLE_URL

# --- Supervisor: keeps the pty loop alive ----------------------------------
if [ "${1:-}" = "--supervise" ]; then
  printf '%s\n' "$$" >"${PID_FILE}"
  log "supervisor started (pid $$)"
  # Only one supervisor may run; a previous one would fight over the heartbeat.
  while true; do
    if command -v script >/dev/null 2>&1; then
      # script(1) allocates the pty the loop prints on. It is a child of this
      # supervisor, so when it dies the loop is simply started again below.
      script -qfc "bash ${QUOTED_SELF} --loop" /dev/null >>"${LOG_FILE}" 2>&1
    else
      bash "${SELF}" --loop >>"${LOG_FILE}" 2>&1
    fi
    log "keepalive loop exited; restarting"
    sleep 5
  done
fi

# --- Entry point: detach the supervisor ------------------------------------
# Close every descriptor above stderr. fd 9 is setup.sh's flock and fd 8 its git
# lock; inheriting either one deadlocks the next setup run. The log is reopened
# by the supervisor itself, so nothing it needs is lost here.
for fd in 3 4 5 6 7 8 9; do
  eval "exec ${fd}>&-" 2>/dev/null || true
done

# Stop a supervisor left over from a previous start so they do not stack up.
if [ -f "${PID_FILE}" ]; then
  OLD_PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [ -n "${OLD_PID}" ] && [ "${OLD_PID}" != "$$" ]; then
    kill "${OLD_PID}" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "${OLD_PID}" >/dev/null 2>&1 || true
  fi
fi

# nohup + setsid -f + </dev/null: the devcontainer CLI tears down the pty that
# postStartCommand runs on and sends SIGHUP to its process group, so the
# supervisor must be in its own session and must ignore that signal.
nohup setsid -f bash "${SELF}" --supervise </dev/null >>"${LOG_FILE}" 2>&1
exit 0
