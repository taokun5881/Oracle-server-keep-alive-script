#!/bin/sh
# by spiritlhl
# from https://github.com/spiritLHLS/Oracle-server-keep-alive-script

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

init_locale() {
  utf8_locale=$(locale -a 2>/dev/null | awk 'tolower($0) ~ /utf-?8/ {print; exit}')
  if [ -n "$utf8_locale" ]; then
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
  fi
}

init_locale

OALIVE_CONFIG=${OALIVE_CONFIG:-/etc/oalive/oalive.conf}
[ -r "$OALIVE_CONFIG" ] && . "$OALIVE_CONFIG"

LOG_DIR=${OALIVE_LOG_DIR:-/var/log/oalive}
STATE_DIR=${OALIVE_STATE_DIR:-/var/lib/oalive}
RUN_DIR=${OALIVE_RUN_DIR:-${TMPDIR:-/tmp}}
LOG_FILE=${MEMORY_LOG_FILE:-$LOG_DIR/memory-limit.log}
LOCK_DIR=$RUN_DIR/oalive-memory-limit.lock
LOG_MAX_BYTES=${OALIVE_LOG_MAX_BYTES:-131072}

MEMORY_TARGET_PERCENT=${MEMORY_TARGET_PERCENT:-25}
MEMORY_HOLD_SECONDS=${MEMORY_HOLD_SECONDS:-300}
MEMORY_REST_SECONDS=${MEMORY_REST_SECONDS:-300}
MEMORY_MAX_MB=${MEMORY_MAX_MB:-0}
MEMORY_FILE=${MEMORY_FILE:-}

is_uint() {
  case ${1:-} in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

now() {
  date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date
}

ensure_dirs() {
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null || LOG_FILE=/dev/null
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
}

rotate_log() {
  [ "$LOG_FILE" = /dev/null ] && return 0
  [ -f "$LOG_FILE" ] || return 0
  size=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
  is_uint "$size" || size=0
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || : >"$LOG_FILE"
  fi
}

log() {
  ensure_dirs
  rotate_log
  line="$(now) $*"
  printf '%s\n' "$line"
  [ "$LOG_FILE" = /dev/null ] || printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

rate_log() {
  key=$1
  interval=$2
  shift 2
  ensure_dirs
  now_s=$(date '+%s' 2>/dev/null || echo 0)
  last_file=$STATE_DIR/$key.last
  last=0
  [ -r "$last_file" ] && last=$(sed -n '1p' "$last_file" 2>/dev/null || echo 0)
  is_uint "$last" || last=0
  if [ "$now_s" -eq 0 ] || [ $((now_s - last)) -ge "$interval" ]; then
    printf '%s\n' "$now_s" >"$last_file" 2>/dev/null || true
    log "$@"
  fi
}

pid_is_alive() {
  pid=${1:-}
  is_uint "$pid" || return 1
  kill -0 "$pid" 2>/dev/null
}

acquire_lock() {
  [ -d "$RUN_DIR" ] || mkdir -p "$RUN_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi

  old_pid=
  [ -r "$LOCK_DIR/pid" ] && old_pid=$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null)
  if pid_is_alive "$old_pid"; then
    log "内存占用已在运行，PID: $old_pid / Memory occupier is already running, PID: $old_pid"
    exit 0
  fi

  rm -rf "$LOCK_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi

  log "无法创建内存锁目录 / Failed to create memory lock directory: $LOCK_DIR"
  exit 1
}

cleanup() {
  trap - INT TERM EXIT
  [ -n "$ACTIVE_MEMORY_FILE" ] && rm -f "$ACTIVE_MEMORY_FILE" 2>/dev/null || true
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

terminate() {
  cleanup
  exit 0
}

normalize_settings() {
  is_uint "$MEMORY_TARGET_PERCENT" || MEMORY_TARGET_PERCENT=25
  is_uint "$MEMORY_HOLD_SECONDS" || MEMORY_HOLD_SECONDS=300
  is_uint "$MEMORY_REST_SECONDS" || MEMORY_REST_SECONDS=300
  is_uint "$MEMORY_MAX_MB" || MEMORY_MAX_MB=0
  [ "$MEMORY_TARGET_PERCENT" -ge 1 ] || MEMORY_TARGET_PERCENT=25
  [ "$MEMORY_TARGET_PERCENT" -le 90 ] || MEMORY_TARGET_PERCENT=90
  [ "$MEMORY_HOLD_SECONDS" -ge 1 ] || MEMORY_HOLD_SECONDS=300
  [ "$MEMORY_REST_SECONDS" -ge 1 ] || MEMORY_REST_SECONDS=300
}

get_total_kb() {
  if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo
    return
  fi
  bytes=$(sysctl -n hw.memsize 2>/dev/null || sysctl -n hw.physmem64 2>/dev/null || sysctl -n hw.physmem 2>/dev/null || true)
  if is_uint "$bytes" && [ "$bytes" -gt 0 ]; then
    printf '%s\n' $((bytes / 1024))
    return
  fi
  pages=$(sysctl -n vm.stats.vm.v_page_count 2>/dev/null || true)
  page_size=$(sysctl -n hw.pagesize 2>/dev/null || true)
  if is_uint "$pages" && is_uint "$page_size" && [ "$pages" -gt 0 ] && [ "$page_size" -gt 0 ]; then
    printf '%s\n' $((pages * page_size / 1024))
    return
  fi
  if command -v vm_stat >/dev/null 2>&1; then
    page_size=$(vm_stat 2>/dev/null | awk '/page size of/ {gsub(/[^0-9]/, "", $8); print $8; exit}')
    pages=$(vm_stat 2>/dev/null | awk '
      /^Pages / {
        value = $NF
        gsub(/[^0-9]/, "", value)
        if (value != "") sum += value
      }
      END {print sum + 0}
    ')
    if is_uint "$page_size" && is_uint "$pages" && [ "$pages" -gt 0 ]; then
      printf '%s\n' $((pages * page_size / 1024))
      return
    fi
  fi
}

get_available_kb() {
  if [ -r /proc/meminfo ]; then
    awk '
      /^MemAvailable:/ {print $2; found=1; exit}
      /^MemFree:/ {free=$2}
      /^Buffers:/ {buffers=$2}
      /^Cached:/ {cached=$2}
      END {if (!found && free) print free + buffers + cached}
    ' /proc/meminfo
    return
  fi
  page_size=$(sysctl -n hw.pagesize 2>/dev/null || true)
  free_pages=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null || echo 0)
  inactive_pages=$(sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null || echo 0)
  cache_pages=$(sysctl -n vm.stats.vm.v_cache_count 2>/dev/null || echo 0)
  is_uint "$page_size" || page_size=0
  is_uint "$free_pages" || free_pages=0
  is_uint "$inactive_pages" || inactive_pages=0
  is_uint "$cache_pages" || cache_pages=0
  pages=$((free_pages + inactive_pages + cache_pages))
  if [ "$page_size" -gt 0 ] && [ "$pages" -gt 0 ]; then
    printf '%s\n' $((pages * page_size / 1024))
    return
  fi

  if command -v vmstat >/dev/null 2>&1; then
    pages=$(vmstat -s 2>/dev/null | awk '
      /pages free|free pages/ {sum += $1}
      /pages inactive|inactive pages/ {sum += $1}
      /pages in VM cache|cache pages/ {sum += $1}
      END {print sum + 0}
    ')
    if [ "$page_size" -gt 0 ] && is_uint "$pages" && [ "$pages" -gt 0 ]; then
      printf '%s\n' $((pages * page_size / 1024))
      return
    fi
  fi

  if command -v vm_stat >/dev/null 2>&1; then
    page_size=$(vm_stat 2>/dev/null | awk '/page size of/ {gsub(/[^0-9]/, "", $8); print $8; exit}')
    pages=$(vm_stat 2>/dev/null | awk '
      /Pages free/ {gsub(/[^0-9]/, "", $3); sum += $3}
      /Pages inactive/ {gsub(/[^0-9]/, "", $3); sum += $3}
      /Pages speculative/ {gsub(/[^0-9]/, "", $3); sum += $3}
      END {print sum + 0}
    ')
    if is_uint "$page_size" && is_uint "$pages" && [ "$pages" -gt 0 ]; then
      printf '%s\n' $((pages * page_size / 1024))
      return
    fi
  fi

  return
}

choose_memory_file() {
  if [ -n "$MEMORY_FILE" ]; then
    dir=$(dirname "$MEMORY_FILE")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
    ACTIVE_MEMORY_FILE=$MEMORY_FILE
    return 0
  fi

  for dir in /dev/shm /run/shm /var/run/shm /tmp; do
    [ -d "$dir" ] && [ -w "$dir" ] || continue
    ACTIVE_MEMORY_FILE=$dir/oalive-memory-block
    return 0
  done
  return 1
}

df_free_mb() {
  dir=$1
  free_kb=$( (df -Pk "$dir" 2>/dev/null || df -k "$dir" 2>/dev/null) | awk 'NR==2 {print $4}')
  is_uint "$free_kb" || free_kb=0
  if [ "$free_kb" -gt 20480 ]; then
    printf '%s\n' $(((free_kb - 10240) / 1024))
  else
    printf '%s\n' 0
  fi
}

allocate_memory() {
  mb=$1
  file=$2
  rm -f "$file" 2>/dev/null || true
  dd if=/dev/zero of="$file" bs=1048576 count="$mb" >/dev/null 2>&1
}

run_cycle() {
  total_kb=$(get_total_kb)
  avail_kb=$(get_available_kb)
  if ! is_uint "$total_kb" || ! is_uint "$avail_kb" || [ "$total_kb" -le 0 ]; then
    rate_log memory-metrics 3600 "无法读取内存指标，跳过本轮 / Unable to read memory metrics, skipping this cycle"
    sleep "$MEMORY_REST_SECONDS"
    return
  fi

  used_kb=$((total_kb - avail_kb))
  [ "$used_kb" -ge 0 ] || used_kb=0
  target_kb=$((total_kb * MEMORY_TARGET_PERCENT / 100))

  if [ "$used_kb" -ge "$target_kb" ]; then
    rate_log memory-skip 3600 "内存使用已达到目标，跳过占用 / Memory usage already reached target, skipping allocation"
    sleep "$MEMORY_REST_SECONDS"
    return
  fi

  need_kb=$((target_kb - used_kb))
  need_mb=$((need_kb / 1024))
  [ "$need_mb" -ge 1 ] || need_mb=1

  if ! choose_memory_file; then
    rate_log memory-file 3600 "无法找到可写入的临时目录，跳过内存占用 / No writable temporary directory found, skipping memory allocation"
    sleep "$MEMORY_REST_SECONDS"
    return
  fi

  file_dir=$(dirname "$ACTIVE_MEMORY_FILE")
  free_mb=$(df_free_mb "$file_dir")
  cap_mb=$((free_mb * 80 / 100))
  [ "$MEMORY_MAX_MB" -eq 0 ] || [ "$cap_mb" -le "$MEMORY_MAX_MB" ] || cap_mb=$MEMORY_MAX_MB

  if [ "$cap_mb" -lt 1 ]; then
    rate_log memory-space 3600 "临时目录空间不足，跳过内存占用 / Not enough temporary space, skipping memory allocation"
    sleep "$MEMORY_REST_SECONDS"
    return
  fi
  [ "$need_mb" -le "$cap_mb" ] || need_mb=$cap_mb

  log "开始内存占用 ${need_mb}MB，保持 ${MEMORY_HOLD_SECONDS}s / Allocating ${need_mb}MB memory pressure for ${MEMORY_HOLD_SECONDS}s"
  if allocate_memory "$need_mb" "$ACTIVE_MEMORY_FILE"; then
    sleep "$MEMORY_HOLD_SECONDS"
  else
    rate_log memory-dd 900 "内存占用文件创建失败 / Failed to create memory pressure file"
  fi
  rm -f "$ACTIVE_MEMORY_FILE" 2>/dev/null || true
  sleep "$MEMORY_REST_SECONDS"
}

case ${1:-} in
  --help|-h)
    printf '%s\n' "Usage: sh memory-limit.sh"
    printf '%s\n' "配置 / Config: MEMORY_TARGET_PERCENT, MEMORY_HOLD_SECONDS, MEMORY_REST_SECONDS, MEMORY_MAX_MB, MEMORY_FILE"
    exit 0
    ;;
  --check)
    normalize_settings
    total_kb=$(get_total_kb)
    [ -n "$total_kb" ] || {
      printf '%s\n' "Memory metrics unavailable / 内存指标不可用"
      exit 1
    }
    printf '%s\n' "Memory script OK / 内存脚本检查通过"
    exit 0
    ;;
esac

ACTIVE_MEMORY_FILE=
normalize_settings
acquire_lock
trap terminate INT TERM
trap cleanup EXIT
log "内存占用已启动，目标=${MEMORY_TARGET_PERCENT}% / Memory occupier started, target=${MEMORY_TARGET_PERCENT}%"

while :; do
  run_cycle
done
