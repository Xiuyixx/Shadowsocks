#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2317
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load installer functions without running main.
source "${repo_dir}/install.sh"

uname() { printf '%s\n' 'x86_64'; }
[[ "$(get_arch)" == "x86_64-unknown-linux-musl" ]]

uname() { printf '%s\n' 'aarch64'; }
[[ "$(get_arch)" == "aarch64-unknown-linux-musl" ]]

printf '%s\n' 'architecture asset selection passed'
