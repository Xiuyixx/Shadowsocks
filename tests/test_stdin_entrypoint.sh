#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Regression test: bash -u leaves BASH_SOURCE unset when the script is read from stdin.
# Keep the pipe to exercise the documented curl | bash invocation.
# shellcheck disable=SC2002
help_output="$(cat "${repo_dir}/install.sh" | bash -s -- --help)"
grep -Fq 'Install Shadowsocks (shadowsocks-rust)' <<<"${help_output}"

printf '%s\n' 'stdin entrypoint test passed'
