#!/usr/bin/env bash

set -euo pipefail

[ "$#" -eq 1 ] || {
	printf 'Usage: %s /path/to/dockerfmt\n' "$0" >&2
	exit 2
}
tool="$1"
[ -x "$tool" ] || {
	printf 'Executable not found: %s\n' "$tool" >&2
	exit 1
}

test_root=$(mktemp -d "${TMPDIR:-/tmp}/asdf-dockerfmt-runtime.XXXXXX")
cleanup() {
	rm -f "$test_root/Dockerfile" "$test_root/formatted" "$test_root/unformatted" \
		"$test_root/check.out" "$test_root/check.err"
	rmdir "$test_root" 2>/dev/null || true
}
trap cleanup EXIT

unformatted=$'FROM   alpine\nRUN   echo   hi\n'
expected=$'FROM alpine\nRUN echo hi'

formatted=$(printf '%s' "$unformatted" | "$tool")
[ "$formatted" = "$expected" ] || {
	printf 'Unexpected formatted stdin output.\n' >&2
	exit 1
}
printf '%s' "$formatted" | "$tool" -c

set +e
printf '%s' "$unformatted" | "$tool" -c >"$test_root/check.out" 2>"$test_root/check.err"
exit_code=$?
set -e
[ "$exit_code" -ne 0 ] || {
	printf 'dockerfmt -c accepted unformatted stdin.\n' >&2
	exit 1
}
printf '%s' "$unformatted" >"$test_root/Dockerfile"
set +e
"$tool" -c "$test_root/Dockerfile" >"$test_root/check.out" 2>"$test_root/check.err"
exit_code=$?
set -e
[ "$exit_code" -ne 0 ] || {
	printf 'dockerfmt -c accepted an unformatted file.\n' >&2
	exit 1
}
"$tool" -w "$test_root/Dockerfile"
"$tool" -c "$test_root/Dockerfile"
[ "$(cat "$test_root/Dockerfile")" = "$expected" ]
