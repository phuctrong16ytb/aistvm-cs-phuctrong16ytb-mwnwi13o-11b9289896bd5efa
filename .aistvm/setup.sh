#!/usr/bin/env bash
# AISTVM: prepare this codespace as a Windows VM host.
# Runs unattended. Never prints passwords, keys or tokens.
set -uo pipefail

STATUS_DIR=".aistvm"
STATUS_FILE="${STATUS_DIR}/status.json"
LOG_FILE="${STATUS_DIR}/setup.log"
LOCK_FILE="${STATUS_DIR}/setup.lock"
mkdir -p "${STATUS_DIR}"
: > "${LOG_FILE}"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"${LOG_FILE}"; }

# Only one setup run may own this machine at a time. postStartCommand fires on
# every start, and the first run keeps waiting for Windows for up to 12 hours, so
# a restart would otherwise launch a second copy that fights over status.json and
# git and can leave the file empty. flock is released when the holder dies.
exec 9>"${LOCK_FILE}"
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
  log "another setup run holds the lock; exiting"
  exit 0
fi

# The app polls this file through the GitHub Contents API, so it must be pushed.
# The write is atomic (temp file + rename) and every git step is serialised: a
# partial or empty status.json is what left the app stuck on "installing".
publish_status() {
  (
    if command -v flock >/dev/null 2>&1; then flock -x 8; fi
    git add "${STATUS_FILE}" >/dev/null 2>&1 || return 0
    git -c user.email=aistvm@users.noreply.github.com -c user.name=AISTVM \
      commit -q -m "AISTVM: $1" >/dev/null 2>&1 || return 0
    git push -q origin HEAD >>"${LOG_FILE}" 2>&1 || log "status push failed (will retry on next write)"
  ) 8>"${STATUS_DIR}/git.lock"
}

write_status() {
  # $1 state, $2 tailscale ip, $3 error text (empty when fine)
  local state="$1" ip="$2" err="$3" tmp
  tmp="${STATUS_FILE}.tmp.$$"
  # printf, not a heredoc: bash backs every heredoc with a temp file under
  # $TMPDIR (/tmp), and a full /tmp would fail the write and leave an empty
  # status.json that keeps the app stuck. printf needs no temporary file.
  printf '{"state":"%s","ip":"%s","error":"%s","user":"aistvm","updatedAt":"%s"}\n' \
    "${state}" "${ip}" "${err}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${tmp}"
  mv -f "${tmp}" "${STATUS_FILE}"
  publish_status "${state}"
}

fail() {
  log "FAILED: $*"
  write_status failed "" "$*"
  exit 1
}

# Run from the repository root so the status file lands next to the script.
cd "$(dirname "$0")/.." || exit 1

write_status starting "" ""

# --- 0. Idle-timeout keepalive --------------------------------------------
# Started before the long Windows download so the codespace is not stopped
# while the VM is still being set up. keepalive.sh closes the descriptors it
# inherits, so starting it here does not keep this script's flock alive.
#
# The keepalive supervises its own printing loop, but a keepalive that is dead
# cannot report that it is dead. So its heartbeat is also checked here, and a
# stale one is restarted — this is the only place that can notice a keepalive
# that never came back.
KEEPALIVE="${STATUS_DIR}/keepalive.sh"
HEARTBEAT="${STATUS_DIR}/keepalive.heartbeat"
# Three missed intervals; the loop writes one per INTERVAL (180s).
KEEPALIVE_STALE_SECONDS=600
keepalive_alive() {
  local beat now
  [ -f "${HEARTBEAT}" ] || return 1
  beat=$(cat "${HEARTBEAT}" 2>/dev/null) || return 1
  case "${beat}" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date -u +%s)
  [ $(( now - beat )) -le "${KEEPALIVE_STALE_SECONDS}" ]
}
start_keepalive() {
  [ -f "${KEEPALIVE}" ] || return 0
  bash "${KEEPALIVE}" >>"${LOG_FILE}" 2>&1 || log "keepalive start failed"
}
if keepalive_alive; then
  log "keepalive already alive; leaving it running"
else
  log "keepalive not alive (no fresh heartbeat); starting it"
  start_keepalive
fi

# --- 1. Mount the real data volume at /mnt/data ----------------------------
# The guest image lives on /mnt/data, never on the small system disk. The data
# volume may already be mounted elsewhere (for example /workspaces), or it may
# be an unmounted partition whose device name and size vary, so the volume is
# chosen by size and reused whatever its current mount point. Mounting is
# best-effort: if no volume can be found the script keeps going with a plain
# directory, so the Windows container still starts.
mount_data() {
  local root_src line dev size mnt free_kb img_kb
  root_src=$(df --output=source / | tail -1)
  sudo mkdir -p /mnt/data
  if mountpoint -q /mnt/data; then
    log "/mnt/data already mounted"
  else
    # Largest partition that is not the root device, is not mounted at "/" (the
    # small system disk), and is at least 8 GiB. A partition already mounted
    # elsewhere (for example /workspaces) is the data volume and is reused.
    line=$(lsblk -rbno NAME,SIZE,TYPE,MOUNTPOINT \
      | awk -v root="${root_src}" '$3=="part" && ("/dev/"$1)!=root && $4!="/" && $2+0>=8589934592 {print $2" "$1" "$4}' \
      | sort -rn | head -1)
    dev=$(printf '%s' "${line}" | awk '{print $2}')
    size=$(printf '%s' "${line}" | awk '{print $1}')
    mnt=$(printf '%s' "${line}" | awk '{print $3}')
    if [ -n "${dev}" ] && [ -n "${mnt}" ] && [ "${mnt}" != "/" ]; then
      # The data volume is already mounted somewhere: reuse it in place.
      log "data volume ${mnt} (${size} bytes) already mounted; binding to /mnt/data"
      sudo mount --bind "${mnt}" /mnt/data || sudo mount --rbind "${mnt}" /mnt/data || log "bind mount of ${mnt} failed"
    elif [ -n "${dev}" ]; then
      log "data partition: /dev/${dev} (${size} bytes)"
      if sudo mount "/dev/${dev}" /mnt/data; then
        grep -qF "/mnt/data" /etc/fstab || echo "UUID=$(sudo blkid -s UUID -o value /dev/${dev}) /mnt/data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
      else
        log "could not mount /dev/${dev}"
      fi
    else
      log "no data partition found"
    fi
  fi
  if ! mountpoint -q /mnt/data; then
    # No usable volume: keep a sparse loopback image on the codespace disk. It is
    # created with truncate so it is sparse and always succeeds, then sized to the
    # free space that is actually there.
    free_kb=$(df --output=avail -k /workspaces 2>/dev/null | tail -1 | tr -dc '0-9')
    img_kb=$(( ${free_kb:-0} - 4194304 ))
    [ "${img_kb}" -gt 10485760 ] || img_kb=10485760
    img="/workspaces/.aistvm-data.img"
    log "no data volume; sparse loopback ${img} ($((img_kb / 1048576)) GiB)"
    if [ ! -f "${img}" ]; then
      truncate -s "${img_kb}K" "${img}" 2>/dev/null || sudo truncate -s "${img_kb}K" "${img}" || return 1
      sudo mkfs.ext4 -q -F "${img}" || return 1
    fi
    mountpoint -q /mnt/data || sudo mount -o loop "${img}" /mnt/data || return 1
  fi
  sudo chown -R codespace:codespace /mnt/data 2>/dev/null || true
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT >>"${LOG_FILE}" 2>&1 || true
  df -h /mnt/data >>"${LOG_FILE}" 2>&1 || true
}

mount_data || fail "khong mount duoc /mnt/data"

# --- 2. Swap on /tmp so the VM keeps real RAM ------------------------------
# Swap is only ever taken from a disk that is separate from the small system
# disk: the system disk must never be filled, because filling it gets the
# codespace killed. When /tmp lives on the system disk, swap is skipped and the
# guest runs on its real RAM alone.
setup_swap() {
  local avail_kb want_kb tmp_dev root_dev
  # Release any previous swap first so the space it held counts as free again.
  sudo swapoff /tmp/vmswap 2>/dev/null || true
  rm -f /tmp/vmswap
  avail_kb=$(df --output=avail -k /tmp | tail -1)
  tmp_dev=$(df --output=source /tmp | tail -1)
  root_dev=$(df --output=source / | tail -1)
  if [ "${tmp_dev}" = "${root_dev}" ]; then
    # /tmp shares the system disk: never touch it, or the codespace is killed
    # for filling its own disk.
    log "/tmp nam tren dia he thong; bo qua swap de khong dung vao dia he thong"
    return 0
  fi
  # /tmp has its own disk: use most of it, but keep a real reserve. Bash builds
  # every heredoc in $TMPDIR (which defaults to /tmp), and the package installs
  # below unpack there too; if /tmp is filled to the brim those writes fail with
  # "No space left on device", which used to leave status.json empty and the app
  # stuck. 8 GiB is enough for those temporaries and still leaves the bulk for
  # swap.
  want_kb=$(( avail_kb - 8388608 ))
  [ "${want_kb}" -lt 1048576 ] && { log "qua it cho trong tren /tmp; bo qua swap"; return 0; }
  log "swap size: $((want_kb / 1024 / 1024)) GiB on /tmp"
  sudo fallocate -l "${want_kb}K" /tmp/vmswap || sudo dd if=/dev/zero of=/tmp/vmswap bs=1M count=$((want_kb / 1024)) status=none || return 1
  sudo chmod 600 /tmp/vmswap
  sudo mkswap /tmp/vmswap >/dev/null || return 1
  sudo swapon /tmp/vmswap || return 1
  sudo sysctl -w vm.swappiness=100 >/dev/null || true
}

# Swap is a safeguard, not a prerequisite: if it cannot be created the machine
# still comes up, so this must not abort the whole setup.
setup_swap || log "khong tao duoc swap (may van chay nhung co the thieu RAM)"

# --- 3. KVM device permissions --------------------------------------------
# /dev/kvm is root:<kvm-gid> 660 and the container's root still needs the read
# bit widened, so open it up explicitly.
sudo chmod 666 /dev/kvm 2>/dev/null || log "no /dev/kvm (VM will be slow without KVM)"

# --- 4. Windows container --------------------------------------------------
if [ -z "${AISTVM_WIN_PASSWORD:-}" ]; then
  fail "thieu mat khau Windows"
fi

# The guest image lives on /mnt/data, the real data disk (never the small system
# disk). The guest is shown the full picked size — up to 5 TB — as a virtual disk
# size, while the image is created thin with qcow2 so /mnt/data only grows with
# the bytes Windows actually writes. qcow2 is required: the default "raw" format
# would try to pre-allocate the whole 5 TB on the 500 GB volume and crash at once.
DISK_SIZE_G=5120
log "guest disk: ${DISK_SIZE_G}G virtual, qcow2 thin-provisioned on /mnt/data"
df -h /mnt/data >>"${LOG_FILE}" 2>&1 || true

docker rm -f windows >/dev/null 2>&1 || true
docker run -d --name windows --restart unless-stopped \
  --oom-score-adj=-1000 \
  -e VERSION=11 -e CPU_CORES=4 -e RAM_SIZE=120G -e DISK_SIZE=${DISK_SIZE_G}G \
  -e DISK_FMT=qcow2 \
  -e USERNAME=aistvm -e PASSWORD="${AISTVM_WIN_PASSWORD}" \
  -e PROTECT=Y \
  -v "/mnt/data:/storage" -v "/mnt/data/oem:/oem" \
  -p "8006:8006" -p "3389:3389" \
  --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN --stop-timeout 120 \
  dockurr/windows >>"${LOG_FILE}" 2>&1 || fail "khong chay duoc container Windows"
unset AISTVM_WIN_PASSWORD

# Watch the real storage so the 500 GB physical cap on /mnt/data is never hit.
# The guest disk may claim 5 TB, but only written bytes are real; this records the
# actual usage after the container starts so a runaway image is visible in the log.
(
  sleep 60
  log "storage check: guest disk image"
  du -sh /mnt/data/* 2>/dev/null >>"${LOG_FILE}" || true
  df -h /mnt/data >>"${LOG_FILE}" 2>&1 || true
) &

# The container is up, but Windows still has to download and install. Report a
# distinct state so the app can show install progress instead of "ready".
write_status installing "" ""

# --- 4b. Make the console reachable without a GitHub sign-in ---------------
# GitHub forwards ports as private by default, so opening the console URL would
# bounce the user to a GitHub login. The console itself is password-protected
# (the container runs with PROTECT=Y and the Windows credentials), so publishing
# it is safe. The codespace's own token is used only here, inside the codespace.
publish_console() {
  command -v gh >/dev/null 2>&1 || return 0
  local token name tries=0
  # postStartCommand does not run as a login shell, so read the token and name
  # the way the codespace exposes them to an interactive session.
  token=$(bash -lc 'printf %s "${GITHUB_TOKEN:-}"' 2>/dev/null)
  name=$(bash -lc 'printf %s "${CODESPACE_NAME:-}"' 2>/dev/null)
  [ -n "${token}" ] && [ -n "${name}" ] || return 0
  until GH_TOKEN="${token}" gh cs ports visibility "8006:public" -c "${name}" >>"${LOG_FILE}" 2>&1; do
    tries=$(( tries + 1 ))
    [ "${tries}" -ge 40 ] && return 0
    sleep 5
  done
  unset token
}

publish_console || log "bo qua buoc cong khai bang dieu khien"

# --- 5. Tailscale so the machine is reachable from anywhere ----------------
# The key is the one saved in Settings, delivered as a codespace secret. The join
# is retried because the network can be briefly unavailable right after boot, and
# the tailnet address is what the app shows so RDP works from anywhere.
TS_IP=""
tailscale_ip() { sudo tailscale ip -4 2>/dev/null | head -n1; }

# The codespace has no systemd, so the official installer never starts the
# daemon: every start path in install.sh is 'systemctl enable --now tailscaled'
# (or 'service'/'rc-service'), and with no init system those are no-ops. The
# binary lands on disk but nothing listens, so 'tailscale up' then fails with
# "failed to connect to local tailscaled" and the machine never gets a tailnet
# address. The daemon is therefore started by hand, and only after the CLI can
# actually reach it is 'tailscale up' attempted.
tailscaled_running() { sudo tailscale status --json >/dev/null 2>&1; }
# Set to "kernel" or "userspace"; drives the serve fallback below.
TS_TUN_MODE=""
# Machine token for status.json, mapped to a message by the app. Empty = fine.
TS_ERROR=""
# tailscale0 exists only in kernel mode: userspace networking runs in the
# daemon and creates no link. Reading /sys avoids depending on iproute2.
detect_tun_mode() {
  if [ -e /sys/class/net/tailscale0 ]; then
    TS_TUN_MODE="kernel"
  else
    TS_TUN_MODE="userspace"
  fi
}
start_tailscaled() {
  local tun_mode
  if tailscaled_running; then
    # The daemon can already be up when this script re-runs (postStartCommand
    # fires on every start). Without probing the mode here it stayed empty, the
    # 'tailscale serve' fallback was skipped, and RDP was unreachable over the
    # tailnet for a machine that had been restarted.
    detect_tun_mode
    return 0
  fi
  # Kernel mode needs /dev/net/tun and CAP_NET_ADMIN. A codespace is itself a
  # container, so both can be missing; userspace networking needs neither, but
  # it cannot accept inbound connections by itself, which is why the RDP port is
  # also published with 'tailscale serve' further down when that mode is used.
  for tun_mode in "" "--tun=userspace-networking"; do
    log "starting tailscaled ${tun_mode:-kernel} mode"
    sudo mkdir -p /var/lib/tailscale /var/run/tailscale
    # The log goes to the workspace, not /var/log: the redirect is opened by the
    # unprivileged shell before sudo runs, so /var/log would be denied.
    # shellcheck disable=SC2086
    sudo nohup tailscaled --state=/var/lib/tailscale/tailscaled.state \
      ${tun_mode} >>"${STATUS_DIR}/tailscaled.log" 2>&1 &
    for _ in $(seq 1 20); do
      sleep 1
      if tailscaled_running; then
        [ -n "${tun_mode}" ] && TS_TUN_MODE="userspace" || TS_TUN_MODE="kernel"
        return 0
      fi
    done
    sudo pkill -x tailscaled 2>/dev/null || true
    sleep 2
  done
  return 1
}

# Installs the CLI and verifies it is actually on PATH. The official installer
# drives apt, and this image's apt lists are regularly broken ("Splitting up
# .../partial/... failed", unsigned InRelease): sh then exits 0 having installed
# nothing, so the old loop broke out on the first attempt and the machine lost
# Tailscale entirely. Each attempt is verified instead, and a static build that
# needs no package manager is the fallback.
tailscale_install() {
  local attempt dir
  command -v tailscale >/dev/null 2>&1 && return 0
  for attempt in 1 2 3; do
    curl -fsSL https://tailscale.com/install.sh 2>>"${LOG_FILE}" | sudo sh >>"${LOG_FILE}" 2>&1 || true
    if command -v tailscale >/dev/null 2>&1; then
      log "tailscale installed by the official installer on attempt ${attempt}"
      return 0
    fi
    log "tailscale installer attempt ${attempt} left no CLI; retrying"
    sleep 10
  done
  for attempt in 1 2 3; do
    if curl -fsSL https://pkgs.tailscale.com/stable/tailscale_latest_amd64.tgz \
        -o /tmp/tailscale.tgz >>"${LOG_FILE}" 2>&1 \
      && sudo tar -xzf /tmp/tailscale.tgz -C /tmp >>"${LOG_FILE}" 2>&1; then
      dir=$(find /tmp -maxdepth 1 -type d -name 'tailscale_*_amd64' 2>/dev/null | head -n1)
      if [ -n "${dir}" ] && [ -x "${dir}/tailscale" ] && [ -x "${dir}/tailscaled" ]; then
        sudo install -m 0755 "${dir}/tailscale" /usr/local/bin/tailscale
        sudo install -m 0755 "${dir}/tailscaled" /usr/local/bin/tailscaled
        rm -rf /tmp/tailscale.tgz "${dir}"
        if command -v tailscale >/dev/null 2>&1; then
          log "tailscale installed from the static build on attempt ${attempt}"
          return 0
        fi
      fi
    fi
    log "tailscale static build attempt ${attempt} failed; retrying"
    sleep 10
  done
  TS_ERROR="tailscale:install-failed"
  return 1
}

tailscale_join() {
  local attempt out
  for attempt in $(seq 1 10); do
    if out=$(sudo tailscale up --authkey="${AISTVM_TAILSCALE_AUTHKEY}" --hostname="aistvm-win" --accept-routes --ssh 2>&1); then
      [ -n "${out}" ] && printf '%s\n' "${out}" >>"${LOG_FILE}"
      return 0
    fi
    [ -n "${out}" ] && printf '%s\n' "${out}" >>"${LOG_FILE}"
    # A rejected key never starts working on retry: it is revoked, expired,
    # single-use and already consumed, or from another tailnet. Retrying only
    # burned ~3 minutes and hid the real cause behind "no IP".
    case "${out}" in
      *"invalid key"*|*"API key does not exist"*|*"key expired"*|*"key is expired"*)
        TS_ERROR="tailscale:key-rejected"
        return 1
        ;;
    esac
    log "tailscale up attempt ${attempt} failed; retrying"
    sleep 15
  done
  TS_ERROR="tailscale:join-failed"
  return 1
}
if [ -n "${AISTVM_TAILSCALE_AUTHKEY:-}" ]; then
  if tailscale_install; then
    if start_tailscaled; then
      if tailscale_join; then
        # Userspace mode cannot accept inbound connections on the tailnet address,
        # so the guest's RDP port is exposed explicitly. In kernel mode the port
        # publish from 'docker run -p' is already reachable and this is skipped.
        if [ "${TS_TUN_MODE}" = "userspace" ]; then
          log "tailscaled is in userspace mode; publishing RDP through tailscale serve"
          sudo tailscale serve --bg --tcp "3389" "tcp://127.0.0.1:3389" >>"${LOG_FILE}" 2>&1 || log "tailscale serve failed"
        fi
        for _ in $(seq 1 60); do
          TS_IP=$(tailscale_ip)
          [ -n "${TS_IP}" ] && break
          sleep 5
        done
        [ -n "${TS_IP}" ] || TS_ERROR="tailscale:no-address"
        log "tailscale ip after up: ${TS_IP:-none}"
        sudo tailscale status >>"${LOG_FILE}" 2>&1 || true
      fi
    else
      TS_ERROR="tailscale:daemon-failed"
      log "tailscaled would not start; RDP will not be reachable over the tailnet"
    fi
  fi
  unset AISTVM_TAILSCALE_AUTHKEY
else
  # No key means the whole block above is skipped, so say so: without this the
  # log stayed silent and the app could only report "no IP".
  TS_ERROR="tailscale:no-key"
  log "khong co AISTVM_TAILSCALE_AUTHKEY; may se khong vao duoc tailnet"
fi

# --- 6. Wait until Windows itself answers, then report ready --------------
# The container being up is not the same as Windows being installed: dockur
# boots the setup media first and QEMU accepts the RDP port for the whole
# install, so a bare TCP connect proves nothing. Only a complete RDP handshake
# is answered once Windows is installed and its RDP service is listening: the
# server must reply with an X.224 Connection Confirm (TPKT length byte 0x03,
# X.224 length 0x00, then the 0xd0 confirm code), so the whole header is checked
# and two consecutive confirms are required before the machine is called ready.
rdp_ready() {
  exec 3<>/dev/tcp/127.0.0.1/3389 2>/dev/null || return 1
  if ! printf '\x03\x00\x00\x13\x0e\xe0\x00\x00\x00\x00\x00\x01\x00\x08\x00\x03\x00\x00\x00' >&3 2>/dev/null; then
    exec 3<&- 2>/dev/null
    return 1
  fi
  local reply
  reply=$(timeout 5 head -c 6 <&3 2>/dev/null | od -An -tu1 | tr -s ' ' | tr -d '\n')
  exec 3<&- 2>/dev/null
  # Expected confirm: 03 00 00 13 0e d0 (6 bytes). Anything else is not RDP.
  [ "${reply}" = " 3 0 0 19 14 208" ]
}

confirm_attempts=0
attempt=0
MAX_WAIT_MINUTES=$(( 12 * 60 ))
until [ "${confirm_attempts}" -ge 2 ]; do
  if rdp_ready; then
    # A single confirm can be a transient reply from the setup media, so require
    # two in a row before the machine is called ready.
    confirm_attempts=$(( confirm_attempts + 1 ))
    [ "${confirm_attempts}" -ge 2 ] && break
    sleep 10
    continue
  fi
  confirm_attempts=0
  attempt=$(( attempt + 1 ))
  if [ "${attempt}" -ge "${MAX_WAIT_MINUTES}" ]; then
    # Never claim failure: the app keeps polling this file, and a slow install
    # must not be reported as broken.
    log "chua xac nhan duoc Windows sau ${attempt} phut; dung do"
    break
  fi
  if [ $(( attempt % 10 )) -eq 0 ]; then
    log "dang cai Windows... (${attempt} phut)"
  fi
  sleep 60
done

if [ "${confirm_attempts}" -ge 2 ]; then
  # Re-read the address now: the first attempt ran right after the tailnet join,
  # but Windows can take an hour to install, so the tailnet may only have been
  # fully joined since then. Fall back to the earlier value if the read fails.
  TS_IP_NOW=$(tailscale_ip)
  [ -n "${TS_IP_NOW}" ] && TS_IP="${TS_IP_NOW}"
  # A machine that is ready but has no tailnet address is not usable, so the
  # reason travels with the status: the app turns the token into a message.
  [ -n "${TS_IP}" ] && TS_ERROR=""
  write_status ready "${TS_IP}" "${TS_ERROR}"
  log "ready; tailscale ip=${TS_IP:-none} error=${TS_ERROR:-none}"
fi
