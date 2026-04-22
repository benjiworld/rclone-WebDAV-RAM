#!/bin/bash

set -euo pipefail

# =========================
# Configurazione fissa
# =========================
RAMDISK_BASE="/dev/shm"
LOGFILE="${HOME}/rclone-webdav.log"
MIN_CACHE_MIB=512

RCLONE_ADDR="127.0.0.1"
RCLONE_PORT="2022"
RCLONE_USER="benjiworld"
RCLONE_PASS="spender"
RCLONE_MIN_FREE_SPACE="512M"

DEFAULT_RAM_PERCENT="80"
# =========================

RCLONE_PID=""
NEMO_PID=""
CLEANED_UP="false"

RAMDISK_PATH=""
NEMO_URL=""
GTK_BOOKMARKS_FILE="${HOME}/.config/gtk-3.0/bookmarks"
BOOKMARK_LABEL=""
BOOKMARK_LINE=""
RAM_PERCENT=""

cleanup() {
    if [ "${CLEANED_UP}" = "true" ]; then
        return
    fi
    CLEANED_UP="true"

    echo
    echo "--- Shutdown requested: closing everything... ---"

    if command -v nemo >/dev/null 2>&1; then
        nemo -q >/dev/null 2>&1 || true
    fi

    if [ -n "${NEMO_PID:-}" ] && ps -p "${NEMO_PID}" >/dev/null 2>&1; then
        kill "${NEMO_PID}" 2>/dev/null || true
        wait "${NEMO_PID}" 2>/dev/null || true
    fi

    pkill -TERM -x nemo 2>/dev/null || true
    sleep 1

    if [ -n "${NEMO_URL:-}" ]; then
        echo "Unmounting GVFS WebDAV mount..."
        gio mount -u "${NEMO_URL}" >/dev/null 2>&1 || true
        sleep 1
    fi

    if [ -n "${RCLONE_PID:-}" ] && ps -p "${RCLONE_PID}" >/dev/null 2>&1; then
        echo "Stopping rclone (PID: ${RCLONE_PID})..."
        kill -TERM "${RCLONE_PID}" 2>/dev/null || true

        for _ in $(seq 1 30); do
            if ! ps -p "${RCLONE_PID}" >/dev/null 2>&1; then
                break
            fi
            sleep 0.2
        done

        if ps -p "${RCLONE_PID}" >/dev/null 2>&1; then
            echo "Rclone still running, forcing stop..."
            kill -KILL "${RCLONE_PID}" 2>/dev/null || true
        fi

        wait "${RCLONE_PID}" 2>/dev/null || true
    fi

    if [ -n "${RAMDISK_PATH:-}" ] && mountpoint -q "${RAMDISK_PATH}" 2>/dev/null; then
        echo "Trying to unmount RAM cache..."

        if ! sudo umount "${RAMDISK_PATH}" 2>/dev/null; then
            echo "Mountpoint is busy. Checking open users..."

            if command -v fuser >/dev/null 2>&1; then
                sudo fuser -vm "${RAMDISK_PATH}" 2>/dev/null || true
                sudo fuser -km "${RAMDISK_PATH}" 2>/dev/null || true
            fi

            if command -v lsof >/dev/null 2>&1; then
                sudo lsof +D "${RAMDISK_PATH}" 2>/dev/null || true
            fi

            sleep 1

            if ! sudo umount "${RAMDISK_PATH}" 2>/dev/null; then
                echo "Normal unmount failed, trying lazy unmount..."
                sudo umount -l "${RAMDISK_PATH}" 2>/dev/null || true
            fi
        fi
    fi

    if [ -n "${BOOKMARK_LINE:-}" ] && [ -f "${GTK_BOOKMARKS_FILE}" ]; then
        echo "Removing temporary bookmark..."
        tmpfile=$(mktemp)
        grep -Fvx "${BOOKMARK_LINE}" "${GTK_BOOKMARKS_FILE}" > "${tmpfile}" || true
        mv "${tmpfile}" "${GTK_BOOKMARKS_FILE}"
    fi

    echo "--- Cleanup completed. ---"
}

trap cleanup INT TERM EXIT

need_cmds() {
    for cmd in rclone awk numfmt ss nc ps id mountpoint mount tail grep findmnt df du chmod chown pkill sudo sed tr printf nemo gio mktemp mkdir mv touch; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: '$cmd' is not installed." >&2
            exit 1
        fi
    done
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value
    read -r -p "${prompt} [${default}]: " value
    if [ -z "${value}" ]; then
        echo "${default}"
    else
        echo "${value}"
    fi
}

choose_remote() {
    mapfile -t REMOTES < <(rclone listremotes 2>/dev/null | sed 's/:$//')

    if [ "${#REMOTES[@]}" -eq 0 ]; then
        echo "No rclone remotes found. Run 'rclone config' first." >&2
        exit 1
    fi

    echo "Available rclone remotes:"
    PS3="Select a remote number: "
    select remote in "${REMOTES[@]}"; do
        if [ -n "${remote:-}" ]; then
            RCLONE_REMOTE_NAME="${remote}"
            RCLONE_REMOTE="${remote}:"
            break
        fi
        echo "Invalid selection."
    done
}

show_remote_info() {
    local remote="$1"
    local remote_type
    remote_type=$(rclone config show "${remote}" 2>/dev/null | awk -F' = ' '/^type = /{print $2; exit}')
    if [ -n "${remote_type}" ]; then
        echo "Selected remote: ${remote} (type: ${remote_type})"
    else
        echo "Selected remote: ${remote}"
    fi
}

collect_inputs() {
    choose_remote
    show_remote_info "${RCLONE_REMOTE_NAME}"

    RAM_PERCENT=$(prompt_default "Percent of MemAvailable for RAM cache" "${DEFAULT_RAM_PERCENT}")

    if ! [[ "${RAM_PERCENT}" =~ ^[0-9]+$ ]] || [ "${RAM_PERCENT}" -lt 1 ] || [ "${RAM_PERCENT}" -gt 95 ]; then
        echo "RAM percent must be an integer between 1 and 95." >&2
        exit 1
    fi

    RAMDISK_NAME_SAFE=$(printf '%s' "${RCLONE_REMOTE_NAME}" | tr -cs '[:alnum:]_.-' '-')
    RAMDISK_NAME="rclone-webdav-cache-${RAMDISK_NAME_SAFE}-${RCLONE_PORT}"
    RAMDISK_PATH="${RAMDISK_BASE}/${RAMDISK_NAME}"

    NEMO_URL="dav://${RCLONE_USER}@${RCLONE_ADDR}:${RCLONE_PORT}/"
    BOOKMARK_LABEL="${RCLONE_REMOTE_NAME}"
    BOOKMARK_LINE="${NEMO_URL} ${BOOKMARK_LABEL}"
}

prepare_ram_cache() {
    MEM_AVAILABLE_KB=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
    if [ -z "${MEM_AVAILABLE_KB}" ] || ! [[ "${MEM_AVAILABLE_KB}" =~ ^[0-9]+$ ]]; then
        echo "Error: unable to read MemAvailable from /proc/meminfo" >&2
        exit 1
    fi

    CACHE_SIZE_KB=$(( MEM_AVAILABLE_KB * RAM_PERCENT / 100 ))
    MIN_CACHE_KB=$(( MIN_CACHE_MIB * 1024 ))
    if [ "${CACHE_SIZE_KB}" -lt "${MIN_CACHE_KB}" ]; then
        CACHE_SIZE_KB="${MIN_CACHE_KB}"
    fi

    CACHE_SIZE_BYTES=$(( CACHE_SIZE_KB * 1024 ))
    CACHE_SIZE_MIB=$(( CACHE_SIZE_BYTES / 1024 / 1024 ))
    CACHE_SIZE_RCLONE="${CACHE_SIZE_MIB}Mi"

    CACHE_SIZE_DISPLAY=$(numfmt --to=iec --suffix=B "${CACHE_SIZE_BYTES}")
    MEM_AVAILABLE_DISPLAY=$(numfmt --to=iec --suffix=B $(( MEM_AVAILABLE_KB * 1024 )))

    USER_UID=$(id -u)
    USER_GID=$(id -g)

    echo "MemAvailable: ${MEM_AVAILABLE_DISPLAY}"
    echo "Allocating ${RAM_PERCENT}% to RAM cache: ${CACHE_SIZE_DISPLAY}"
    echo "Rclone cache max size: ${CACHE_SIZE_RCLONE}"
    echo "RAM cache path: ${RAMDISK_PATH}"
    echo "Remote: ${RCLONE_REMOTE}"
    echo "WebDAV URL: ${NEMO_URL}"
    echo "Bookmark label: ${BOOKMARK_LABEL}"
    echo "Log file: ${LOGFILE}"

    echo "Preparing RAM cache mountpoint..."
    sudo mkdir -p "${RAMDISK_PATH}"

    if mountpoint -q "${RAMDISK_PATH}"; then
        echo "RAM cache already mounted on ${RAMDISK_PATH}"
        echo "Remounting tmpfs with new size and permissions..."
        sudo mount -o remount,size="${CACHE_SIZE_KB}k",uid="${USER_UID}",gid="${USER_GID}",mode=700 tmpfs "${RAMDISK_PATH}"
    else
        echo "Mounting tmpfs on ${RAMDISK_PATH} ..."
        sudo mount -t tmpfs -o "size=${CACHE_SIZE_KB}k,uid=${USER_UID},gid=${USER_GID},mode=700" tmpfs "${RAMDISK_PATH}"
    fi

    sudo chown "${USER_UID}:${USER_GID}" "${RAMDISK_PATH}"
    chmod 700 "${RAMDISK_PATH}"

    mkdir -p "${RAMDISK_PATH}/vfs"

    if [ ! -w "${RAMDISK_PATH}/vfs" ]; then
        echo "Error: cache path is not writable: ${RAMDISK_PATH}/vfs" >&2
        exit 1
    fi
}

install_bookmark() {
    mkdir -p "$(dirname "${GTK_BOOKMARKS_FILE}")"
    touch "${GTK_BOOKMARKS_FILE}"

    tmpfile=$(mktemp)
    grep -Fvx "${BOOKMARK_LINE}" "${GTK_BOOKMARKS_FILE}" > "${tmpfile}" || true
    printf '%s\n' "${BOOKMARK_LINE}" >> "${tmpfile}"
    mv "${tmpfile}" "${GTK_BOOKMARKS_FILE}"
}

start_rclone() {
    if ss -ltn "( sport = :${RCLONE_PORT} )" | grep -q ":${RCLONE_PORT}"; then
        echo "Error: port ${RCLONE_PORT} is already in use." >&2
        ss -ltnp "( sport = :${RCLONE_PORT} )"
        exit 1
    fi

    : > "${LOGFILE}"

    echo "--- Starting rclone server in background... ---"

    rclone serve webdav "${RCLONE_REMOTE}" \
      --vfs-cache-mode full \
      --cache-dir "${RAMDISK_PATH}/vfs" \
      --vfs-cache-max-size "${CACHE_SIZE_RCLONE}" \
      --vfs-cache-min-free-space "${RCLONE_MIN_FREE_SPACE}" \
      --user "${RCLONE_USER}" \
      --pass "${RCLONE_PASS}" \
      --addr "${RCLONE_ADDR}:${RCLONE_PORT}" \
      --progress \
      -vv >> "${LOGFILE}" 2>&1 &

    RCLONE_PID=$!

    echo "Waiting for rclone server (PID: ${RCLONE_PID}) to start..."

    STARTED=false
    for _ in $(seq 1 100); do
        if nc -z "${RCLONE_ADDR}" "${RCLONE_PORT}" 2>/dev/null; then
            STARTED=true
            break
        fi

        if ! ps -p "${RCLONE_PID}" >/dev/null 2>&1; then
            echo
            echo "Error: rclone server failed to start!" >&2
            echo "Recent log output:" >&2
            tail -n 60 "${LOGFILE}" >&2
            exit 1
        fi

        echo -n "."
        sleep 0.2
    done
    echo

    if [ "${STARTED}" != "true" ]; then
        echo "Error: rclone did not open ${RCLONE_ADDR}:${RCLONE_PORT} in time." >&2
        echo "Recent log output:" >&2
        tail -n 60 "${LOGFILE}" >&2
        exit 1
    fi
}

mount_gvfs() {
    echo "Mounting WebDAV with gio..."

    gio mount -u "${NEMO_URL}" >/dev/null 2>&1 || true

    GIO_OUTPUT=""
    GIO_RC=0
    set +e
    GIO_OUTPUT=$(gio mount "${NEMO_URL}" 2>&1)
    GIO_RC=$?
    set -e

    if [ "${GIO_RC}" -ne 0 ]; then
        if printf '%s' "${GIO_OUTPUT}" | grep -Fq "Location is already mounted"; then
            echo "GVFS reports the location is already mounted, reusing existing mount."
        else
            printf '%s\n' "${GIO_OUTPUT}" >&2
            exit 1
        fi
    fi
}

launch_nemo() {
    install_bookmark

    echo "Server is UP!"
    echo "Launching Nemo..."
    nemo "${HOME}" >/dev/null 2>&1 &
    NEMO_PID=$!

    echo "--- Rclone progress is active below ---"
    echo "--- Press CTRL+C to close Nemo, unmount GVFS, stop rclone, unmount RAM cache, and remove the temporary bookmark ---"
    echo "--- In Nemo, click the bookmark named '${BOOKMARK_LABEL}' in the sidebar ---"
    echo "--- Live log: tail -f ${LOGFILE} ---"
    echo "--- Verify RAM mount: findmnt --target ${RAMDISK_PATH} ---"
    echo "--- Verify cache size: du -sh ${RAMDISK_PATH}/vfs && df -h ${RAMDISK_PATH} ---"
    echo "--- Bookmark file: ${GTK_BOOKMARKS_FILE} ---"

    wait "${RCLONE_PID}"
}

main() {
    need_cmds
    collect_inputs
    prepare_ram_cache
    start_rclone
    mount_gvfs
    launch_nemo
}

main "$@"
