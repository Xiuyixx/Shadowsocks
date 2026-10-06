#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
# Redirect the unit destination so even an accidental successful test is isolated.
sed -e "s|/run/shadowsocks-installer/operation.lock|$work/lock/operation.lock|g" -e "s|/etc/systemd/system/\${SERVICE_NAME}|$work/unit|g" "$repo/uninstall.sh" > "$work/uninstaller"
for args in '--config-dir /etc' '--config-dir /tmp/../usr' '--user root' '--user daemon' '--service ssh.service' '--bin-path /etc/passwd'; do
  # Intentional splitting: each fixture is a literal option/value pair.
  # shellcheck disable=SC2086
  if bash "$work/uninstaller" $args </dev/null > "$work/output" 2>&1; then cat "$work/output"; exit 1; fi
  grep -Eq 'Unsafe|Critical|Invalid' "$work/output"
done
mkdir -p "$work/config" "$work/bin" "$work/mocks"
printf keep > "$work/config/keep"
printf keep > "$work/bin/ssserver"
for cmd in systemctl userdel; do
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "$CALL_LOG"\n' "$cmd" > "$work/mocks/$cmd"
  chmod +x "$work/mocks/$cmd"
done
export CALL_LOG="$work/log" PATH="$work/mocks:$PATH"
run_uninstall() { bash "$work/uninstaller" --yes --config-dir "$work/config" --bin-path "$work/bin/ssserver" "$@" > "$work/output" 2>&1; }
assert_refused() {
  : > "$work/log"
  if run_uninstall "$@"; then cat "$work/output"; echo 'expected refusal'; exit 1; fi
  [[ ! -s "$work/log" && -f "$work/bin/ssserver" && -f "$work/config/keep" ]]
}
# Arbitrary directories with no installation evidence cannot authorize deletion.
assert_refused
printf 'ExecStart=%s -c %s/config.json\nUser=shadowsocks\n' "$work/bin/ssserver" "$work/config" > "$work/unit"
assert_refused
printf '%s\n' '{"server":"0.0.0.0","server_port":8388,"password":"key","method":"aes-128-gcm","mode":"tcp_only"}' > "$work/config/config.json"
cp "$work/config/config.json" "$work/good-config"
printf 'false\n' > "$work/config/config.json"; cat "$work/good-config" >> "$work/config/config.json"
assert_refused
cat "$work/good-config" "$work/good-config" > "$work/config/config.json"
assert_refused
cp "$work/good-config" "$work/config/config.json"
# A piped script must never consume its own source as confirmation.
if command -v setsid >/dev/null; then
  if setsid bash -s -- --config-dir "$work/config" --bin-path "$work/bin/ssserver" < "$work/uninstaller" > "$work/output" 2>&1; then exit 1; fi
  grep -q 'Confirmation requires a terminal' "$work/output"
fi
run_uninstall
grep -q '^systemctl disable --now shadowsocks-server.service' "$work/log"
[[ -e "$work/config/keep" && ! -e "$work/bin/ssserver" && ! -e "$work/config/config.json" && ! -e "$work/unit" ]]
if grep -q '^userdel' "$work/log"; then echo 'legacy user deletion attempted'; exit 1; fi
# v1 path canonicalization, strict metadata cardinality, and override association.
for fixture in trailing noncanonical stream objects override_bin override_user override_service wrong_unit; do
  printf keep > "$work/bin/ssserver"
  cp "$work/good-config" "$work/config/config.json"
  printf 'ExecStart=%s -c %s/config.json\nUser=shadowsocks\n' "$work/bin/ssserver" "$work/config" > "$work/unit"
  legacy_dir="$work/config/"; legacy_bin="$work/bin/ssserver"; legacy_config="$work/config//config.json"
  if [[ "$fixture" == noncanonical ]]; then legacy_dir="$work/config/../config/"; legacy_bin="$work/bin/../bin/ssserver"; legacy_config="$work/config/./config.json"; fi
  jq -n --arg dir "$legacy_dir" --arg bin "$legacy_bin" --arg config "$legacy_config" '{metaVersion:"1",configDir:$dir,configPath:$config,ssserverPath:$bin,runUser:"shadowsocks",serviceName:"shadowsocks-server.service"}' > "$work/meta"
  cp "$work/meta" "$work/config/install-meta.json"
  case "$fixture" in
    stream) { echo false; cat "$work/meta"; } > "$work/config/install-meta.json" ;;
    objects) cat "$work/meta" "$work/meta" > "$work/config/install-meta.json" ;;
    wrong_unit) printf 'ExecStart=/unrelated/ssserver -c /unrelated/config.json\nUser=shadowsocks\n' > "$work/unit" ;;
  esac
  chmod 600 "$work/config/install-meta.json"
  case "$fixture" in
    trailing|noncanonical) run_uninstall; [[ -f "$work/config/keep" && ! -e "$work/config/install-meta.json" && ! -e "$work/bin/ssserver" ]] ;;
    override_bin) mkdir -p "$work/other"; printf other > "$work/other/ssserver"; assert_refused --bin-path "$work/other/ssserver"; [[ -f "$work/other/ssserver" ]] ;;
    override_user) assert_refused --user anotheruser ;;
    override_service) assert_refused --service ssh.service ;;
    *) assert_refused ;;
  esac
  [[ -f "$work/config/keep" ]]
done
printf '%s\n' 'uninstall ownership, legacy, JSON stream, and confirmation tests passed'
