#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/mocks"
export PATH="$work/mocks:$PATH"
REAL_MV="$(command -v mv)"
REAL_ID="$(command -v id)"
export REAL_MV REAL_ID
cat > "$work/mocks/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$CASE_DIR/calls"
case "$1" in
  is-active) [[ "$(cat "$CASE_DIR/active")" == 1 ]] && exit 0; exit 3 ;;
  is-enabled) cat "$CASE_DIR/enabled"; [[ "$(cat "$CASE_DIR/enabled")" == enabled ]] && exit 0; exit 1 ;;
  stop) echo 0 > "$CASE_DIR/active"; if [[ "$SCENARIO" == stop && ! -f "$CASE_DIR/failed" ]]; then touch "$CASE_DIR/failed"; exit 1; fi ;;
  disable) echo disabled > "$CASE_DIR/enabled"; echo 0 > "$CASE_DIR/active"; [[ "$SCENARIO" != disable ]] || exit 1 ;;
  enable) [[ "$SCENARIO" != restore_enable ]] || exit 1; echo enabled > "$CASE_DIR/enabled" ;;
  start) [[ "$SCENARIO" != restore_start ]] || exit 1; echo 1 > "$CASE_DIR/active" ;;
  daemon-reload)
    if [[ "$SCENARIO" == reload_always ]]; then exit 1; fi
    if [[ "$SCENARIO" == reload && ! -f "$CASE_DIR/failed" ]]; then touch "$CASE_DIR/failed"; exit 1; fi ;;
esac
MOCK
cat > "$work/mocks/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == '-u ss_test_user' ]]; then
  [[ ! -f "$CASE_DIR/deleted_user" ]] || exit 1
  echo 9876
else
  exec "$REAL_ID" "$@"
fi
MOCK
cat > "$work/mocks/userdel" <<'MOCK'
#!/usr/bin/env bash
printf 'userdel %s\n' "$*" >> "$CASE_DIR/calls"
if [[ "$SCENARIO" == userdel_partial ]]; then touch "$CASE_DIR/deleted_user"; exit 1; fi
if [[ "$SCENARIO" == backup_missing ]]; then
  rm -f "$CASE_DIR"/bin/.ss-uninstall.*/original
  exit 1
fi
case "$SCENARIO" in userdel|restore_mv|restore_start|restore_enable) exit 1 ;; esac
touch "$CASE_DIR/deleted_user"
MOCK
cat > "$work/mocks/mv" <<'MOCK'
#!/usr/bin/env bash
set -eu
# Arguments are -T -- source destination.
if [[ "$SCENARIO" == rename && "$3" == "$CASE_DIR/config/config.json" ]]; then exit 1; fi
if [[ "$SCENARIO" == restore_mv && "$3" == */original && "$4" == "$CASE_DIR/bin/ssserver" ]]; then exit 1; fi
exec "$REAL_MV" "$@"
MOCK
chmod +x "$work/mocks/"*
for SCENARIO in stop disable rename reload userdel restore_mv restore_start restore_enable reload_always userdel_partial backup_missing success inactive; do
  export SCENARIO
  CASE_DIR="$work/$SCENARIO"
  export CASE_DIR
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/config"
  echo 1 > "$CASE_DIR/active"; echo enabled > "$CASE_DIR/enabled"
  if [[ "$SCENARIO" == inactive ]]; then echo 0 > "$CASE_DIR/active"; echo disabled > "$CASE_DIR/enabled"; fi
  printf binary > "$CASE_DIR/bin/ssserver"
  printf config > "$CASE_DIR/config/config.json"
  printf unrelated > "$CASE_DIR/config/keep"
  jq -n --arg bin "$CASE_DIR/bin/ssserver" --arg dir "$CASE_DIR/config" \
    '{metaVersion:"2",ssserverPath:$bin,configDir:$dir,configPath:($dir+"/config.json"),runUser:"ss_test_user",serviceName:"shadowsocks-server.service",createdUser:true}' > "$CASE_DIR/config/install-meta.json"
  chmod 600 "$CASE_DIR/config/install-meta.json"
  printf 'ExecStart=%s -c %s/config.json\nUser=ss_test_user\n' "$CASE_DIR/bin/ssserver" "$CASE_DIR/config" > "$CASE_DIR/unit"
  cp "$CASE_DIR/unit" "$CASE_DIR/expected-unit"
  cp "$CASE_DIR/config/install-meta.json" "$CASE_DIR/expected-meta"
  sed -e "s|/run/shadowsocks-installer/operation.lock|$CASE_DIR/lock/operation.lock|g" \
    -e "s|/etc/systemd/system/\${SERVICE_NAME}|$CASE_DIR/unit|g" "$repo/uninstall.sh" > "$CASE_DIR/uninstaller"
  result=0
  bash "$CASE_DIR/uninstaller" --yes --config-dir "$CASE_DIR/config" > "$CASE_DIR/output" 2>&1 || result=$?
  [[ "$(cat "$CASE_DIR/config/keep")" == unrelated ]]
  if [[ "$SCENARIO" == success || "$SCENARIO" == inactive ]]; then
    [[ "$result" == 0 && ! -e "$CASE_DIR/unit" && ! -e "$CASE_DIR/bin/ssserver" && ! -e "$CASE_DIR/config/config.json" && ! -e "$CASE_DIR/config/install-meta.json" ]]
    [[ "$(cat "$CASE_DIR/active")" == 0 && "$(cat "$CASE_DIR/enabled")" == disabled ]]
    grep -q '卸载完成' "$CASE_DIR/output"
  else
    [[ "$result" != 0 ]]
    if grep -q '卸载完成' "$CASE_DIR/output"; then cat "$CASE_DIR/output"; exit 1; fi
    cmp "$CASE_DIR/unit" "$CASE_DIR/expected-unit"
    cmp "$CASE_DIR/config/install-meta.json" "$CASE_DIR/expected-meta"
    [[ "$(cat "$CASE_DIR/config/config.json")" == config ]]
    if [[ "$SCENARIO" == restore_mv ]]; then
      [[ ! -e "$CASE_DIR/bin/ssserver" ]]
      backup="$(find "$CASE_DIR/bin" -name original -type f)"
      [[ -n "$backup" && "$(cat "$backup")" == binary ]]
      grep -q "备份保留：${backup%/*}" "$CASE_DIR/output"
    elif [[ "$SCENARIO" == backup_missing ]]; then
      [[ ! -e "$CASE_DIR/bin/ssserver" ]]
      grep -q '必要备份丢失' "$CASE_DIR/output"
      [[ "$(cat "$CASE_DIR/active")" == 0 ]]
      if grep -qx start "$CASE_DIR/calls" || grep -q '已恢复卸载前' "$CASE_DIR/output"; then exit 1; fi
    else
      [[ "$(cat "$CASE_DIR/bin/ssserver")" == binary ]]
    fi
    case "$SCENARIO" in
      restore_*|reload_always|userdel_partial|backup_missing) grep -q '回滚不完整' "$CASE_DIR/output" ;;
      *) [[ "$(cat "$CASE_DIR/active")" == 1 && "$(cat "$CASE_DIR/enabled")" == enabled ]]; grep -q '已恢复卸载前' "$CASE_DIR/output" ;;
    esac
  fi
  if [[ "$SCENARIO" != restore_mv ]]; then
    [[ -z "$(find "$CASE_DIR" -name '.ss-uninstall.*' -type d -print)" ]]
  fi
  printf 'uninstall failure fixture passed: %s\n' "$SCENARIO"
done
