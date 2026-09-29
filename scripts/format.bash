#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
shfmt -w "$repo_dir/bin" "$repo_dir/lib" "$repo_dir/scripts" "$repo_dir/tests"
