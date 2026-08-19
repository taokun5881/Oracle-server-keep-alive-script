#!/bin/sh
# Exercise the remote-download installer path without touching host services.

set -eu

repo_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/oalive-installer-test.XXXXXX")
fixture_dir=$test_root/source
install_dir=$test_root/bin
systemd_dir=$test_root/systemd

test_cleanup() {
  find "$test_root" -depth -type f -exec unlink {} \; 2>/dev/null || true
  find "$test_root" -depth -type d -exec rmdir {} \; 2>/dev/null || true
}

fail() {
  printf '%s\n' "installer regression test failed: $*" >&2
  exit 1
}

trap test_cleanup EXIT HUP INT TERM

mkdir -p "$fixture_dir" "$install_dir"
for test_file in \
  cpu-limit.sh \
  memory-limit.sh \
  bandwidth_occupier.sh \
  oalive-cron-runner.sh \
  cpu-limit.service \
  memory-limit.service \
  bandwidth_occupier.service \
  bandwidth_occupier.timer; do
  cp "$repo_root/$test_file" "$fixture_dir/$test_file"
done

unset OALIVE_BASE_URL
OALIVE_LIBRARY_MODE=1
export OALIVE_LIBRARY_MODE
. "$repo_root/oalive.sh"
unset OALIVE_LIBRARY_MODE

expected_base_url=https://raw.githubusercontent.com/spiritLHLS/Oracle-server-keep-alive-script/main
[ "$BASE_URL" = "$expected_base_url" ] || fail "unexpected default source: $BASE_URL"

# Keep the install isolated while forcing every file through download_to().
systemctl() {
  return 0
}

SCRIPT_DIR=$test_root/installer-only
BASE_URL=file://$fixture_dir
INSTALL_DIR=$install_dir
SYSTEMD_DIR=$systemd_dir
CPU_ENABLED=0
MEMORY_ENABLED=0
BANDWIDTH_ENABLED=0
CPU_QUOTA_PERCENT=25
BANDWIDTH_INTERVAL_MINUTES=45

install_runtime_files || fail "runtime files were not installed"
install_systemd || fail "systemd units were not installed"

for test_file in cpu-limit.sh memory-limit.sh bandwidth_occupier.sh oalive-cron-runner.sh; do
  test_dest=$install_dir/$test_file
  [ -x "$test_dest" ] || fail "$test_file is not executable"
  cmp "$fixture_dir/$test_file" "$test_dest" || fail "$test_file content differs"
done

for test_file in cpu-limit.service memory-limit.service bandwidth_occupier.service bandwidth_occupier.timer; do
  test_dest=$systemd_dir/$test_file
  [ -f "$test_dest" ] || fail "$test_file is missing"
  cmp "$fixture_dir/$test_file" "$test_dest" || fail "$test_file content differs"
done

[ -s "$systemd_dir/cpu-limit.service.d/quota.conf" ] || fail "CPU quota drop-in is missing"
[ -s "$systemd_dir/bandwidth_occupier.timer.d/interval.conf" ] || fail "bandwidth timer drop-in is missing"

printf '%s\n' "Remote installer download regression passed"
