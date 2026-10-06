#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
# Extract only the cleanup function, never source or run the guarded VM harness.
sed -n '/^cleanup() {$/,/^}$/p' "$repo_dir/tests/integration_systemd_vm.sh" > "$test_dir/cleanup.sh"
[[ -s "$test_dir/cleanup.sh" ]]
cat > "$test_dir/expected" <<'EOF'
disable --now shadowsocks-server.service
-f /etc/systemd/system/shadowsocks-server.service
daemon-reload
ss-integration
ss-integration-primary
-rf -- /mock/ss-integration
EOF
for original_status in 0 37; do
  for failure in none disable unit reload user group work all; do
    log="$test_dir/$original_status-$failure.log"
    output="$test_dir/$original_status-$failure.output"
    set +e
    (
      set -e
      # Used by the extracted cleanup function.
      # shellcheck disable=SC2034
      work=/mock/ss-integration
      mock_step() {
        printf '%s\n' "${*:2}" >> "$log"
        [[ "$failure" != all && "$failure" != "$1" ]]
      }
      # Every command in cleanup is mocked: no service/account/filesystem changes.
      systemctl() {
        case "$1" in
          disable) mock_step disable "$@" ;;
          daemon-reload) mock_step reload "$@" ;;
          *) echo 'unexpected systemctl command' >&2; exit 99 ;;
        esac
      }
      rm() {
        case "$1" in
          -f) mock_step unit "$@" ;;
          -rf) mock_step work "$@" ;;
          *) echo 'unexpected rm command' >&2; exit 99 ;;
        esac
      }
      userdel() { mock_step user "$@"; }
      groupdel() { mock_step group "$@"; }
      source "$test_dir/cleanup.sh"
      trap cleanup EXIT
      exit "$original_status"
    ) > "$output" 2>&1
    result=$?
    set -e
    expected_status="$original_status"
    if (( original_status == 0 )) && [[ "$failure" != none ]]; then expected_status=1; fi
    if [[ "$result" != "$expected_status" ]]; then
      cat "$output" >&2
      echo "cleanup status mismatch: original=$original_status failure=$failure actual=$result expected=$expected_status" >&2
      exit 1
    fi
    cmp "$test_dir/expected" "$log"
    if [[ "$failure" == none ]]; then
      [[ ! -s "$output" ]]
    else
      case "$failure" in
        disable) message='disable service' ;;
        unit) message='remove unit' ;;
        reload) message=daemon-reload ;;
        user) message='delete user' ;;
        group) message='delete group' ;;
        work) message='remove work directory' ;;
        all) message=daemon-reload; [[ "$(grep -c '^Cleanup failed:' "$output")" == 6 ]] ;;
      esac
      grep -q "^Cleanup failed: $message$" "$output"
    fi
  done
done
printf '%s\n' 'VM cleanup mock tests passed (harness not executed)'
