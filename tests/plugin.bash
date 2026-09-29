#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d /tmp/asdf-dockerfmt-tests.XXXXXX)
fake_bin="$test_root/fake bin"
fixture_dir="$test_root/fixture dir"
space_root="$test_root/path with spaces"
original_path="$PATH"
mkdir -p "$fake_bin" "$fixture_dir" "$space_root"

cleanup() {
	rm -f "$fake_bin/git" "$fake_bin/curl" "$fake_bin/uname" "$fake_bin/ldd"
	rmdir "$fake_bin" 2>/dev/null || true
}
trap cleanup EXIT

fail_test() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	local expected="$1" actual="$2" message="$3"
	[ "$expected" = "$actual" ] ||
		fail_test "$message (expected '$expected', got '$actual')"
}

assert_contains() {
	local needle="$1" haystack="$2" message="$3"
	case "$haystack" in
	*"$needle"*) ;;
	*) fail_test "$message (missing '$needle' in '$haystack')" ;;
	esac
}

cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
cat <<'TAGS'
111 refs/tags/v1.0.0
222 refs/tags/v0.10.0
333 refs/tags/v0.5.4
444 refs/tags/v0.3.9
555 refs/tags/v0.3.8
666 refs/tags/v0.3.7
777 refs/tags/v1.0.0-rc.1
888 refs/tags/0.4.0
999 refs/tags/v0.2.0
TAGS
EOF

cat >"$fake_bin/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
-s) printf '%s\n' "$MOCK_UNAME_S" ;;
-m) printf '%s\n' "$MOCK_UNAME_M" ;;
*) exit 1 ;;
esac
EOF

cat >"$fake_bin/ldd" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = --version ]; then
	printf '%s\n' "$MOCK_LDD_VERSION"
else
	exit 1
fi
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=''
url=''
headers=''
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o | --output)
		output="$2"
		shift 2
		;;
	-w | --write-out | --retry)
		shift 2
		;;
	-H | --header)
		headers="$headers$2\n"
		shift 2
		;;
	--*) shift ;;
	-*) shift ;;
	*) url="$1"; shift ;;
	esac
done

printf '%s\n' "$url" >>"$MOCK_URL_LOG"
printf '%s\t%s\n' "$url" "$headers" >>"$MOCK_HEADER_LOG"

if [[ "$url" == *"/releases/tags/"* ]]; then
	case "$MOCK_CURL_MODE" in
	rate-limit)
		printf '{"message":"rate limited"}\n' >"$output"
		printf '403'
		exit 0
		;;
	api-404)
		printf '{"message":"not found"}\n' >"$output"
		printf '404'
		exit 0
		;;
	esac
	if [ -n "$GITHUB_TOKEN" ] && [[ "$headers" != *"Authorization: Bearer $GITHUB_TOKEN"* ]]; then
		printf 'GitHub token was not sent to the API\n' >&2
		exit 99
	fi
	cp "$MOCK_API_JSON" "$output"
	printf '200'
	exit 0
fi

case "$url" in
*.tar.gz)
	if [[ "$headers" == *Authorization:* ]]; then
		printf 'GitHub token was sent to a release download\n' >&2
		exit 99
	fi
	if [ "$MOCK_CURL_MODE" = missing-archive ]; then
		printf '404'
		exit 22
	fi
	cp "$MOCK_ARCHIVE" "$output"
	;;
*)
	printf '404'
	exit 22
	;;
esac
EOF

chmod 755 "$fake_bin/git" "$fake_bin/curl" "$fake_bin/uname" "$fake_bin/ldd"

list_output=$(PATH="$fake_bin:$original_path" "$repo_root/bin/list-all")
assert_eq $'0.3.8\n0.3.9\n0.5.4\n0.10.0\n1.0.0' "$list_output" 'stable supported versions are filtered and numerically sorted'
assert_eq '1.0.0' "$(PATH="$fake_bin:$original_path" "$repo_root/bin/latest-stable")" 'latest stable version is selected'

digest_for() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

payload="$fixture_dir/payload"
mkdir -p "$payload"
printf '%s\n' '#!/usr/bin/env bash' 'printf "fixture dockerfmt\n"' >"$payload/dockerfmt"
chmod 755 "$payload/dockerfmt"

make_archive() {
	local directory="$1" asset="$2"
	mkdir -p "$directory"
	tar -C "$payload" -czf "$directory/$asset" dockerfmt
}

write_metadata() {
	local metadata="$1" archive="$2" asset="$3" mode digest
	mode=normal
	[ "$#" -lt 4 ] || mode="$4"
	digest=$(digest_for "$archive")
	jq -n --arg asset "$asset" --arg digest "sha256:$digest" \
		'{tag_name:"v0.5.4",draft:false,prerelease:false,assets:[{name:$asset,digest:$digest}]}' >"$metadata"
	case "$mode" in
	missing-digest)
		jq '.assets[0].digest = null' "$metadata" >"$metadata.tmp"
		mv "$metadata.tmp" "$metadata"
		;;
	duplicate)
		jq '.assets += .assets' "$metadata" >"$metadata.tmp"
		mv "$metadata.tmp" "$metadata"
		;;
	wrong-digest)
		jq '.assets[0].digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"' \
			"$metadata" >"$metadata.tmp"
		mv "$metadata.tmp" "$metadata"
		;;
	prerelease)
		jq '.prerelease = true' "$metadata" >"$metadata.tmp"
		mv "$metadata.tmp" "$metadata"
		;;
	esac
}

run_download() {
	local destination="$1" archive="$2" metadata="$3" system="$4" machine="$5" libc mode ldd_version
	libc=gnu
	mode=ok
	[ "$#" -lt 6 ] || libc="$6"
	[ "$#" -lt 7 ] || mode="$7"
	ldd_version='ldd (GNU libc) 2.39'
	[ "$libc" = musl ] && ldd_version='musl libc (x86_64)'
	[ "$libc" = missing ] && ldd_version=''
	PATH="$fake_bin:$original_path" \
		MOCK_URL_LOG="$test_root/urls.log" MOCK_HEADER_LOG="$test_root/headers.log" \
		MOCK_API_JSON="$metadata" MOCK_ARCHIVE="$archive" MOCK_CURL_MODE="$mode" \
		MOCK_UNAME_S="$system" MOCK_UNAME_M="$machine" MOCK_LDD_VERSION="$ldd_version" \
		ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.5.4 ASDF_DOWNLOAD_PATH="$destination" \
		GITHUB_TOKEN='' "$repo_root/bin/download"
}

valid_dir="$fixture_dir/valid"
darwin_asset='dockerfmt-v0.5.4-darwin-arm64.tar.gz'
linux_amd64_asset='dockerfmt-v0.5.4-linux-amd64.tar.gz'
linux_amd64_musl_asset='dockerfmt-v0.5.4-linux-amd64-musl.tar.gz'
linux_arm64_asset='dockerfmt-v0.5.4-linux-arm64.tar.gz'
linux_arm64_musl_asset='dockerfmt-v0.5.4-linux-arm64-musl.tar.gz'
for asset in "$darwin_asset" "$linux_amd64_asset" "$linux_amd64_musl_asset" "$linux_arm64_asset" "$linux_arm64_musl_asset"; do
	make_archive "$valid_dir" "$asset"
done

darwin_metadata="$fixture_dir/darwin.json"
linux_amd64_metadata="$fixture_dir/linux-amd64.json"
linux_amd64_musl_metadata="$fixture_dir/linux-amd64-musl.json"
linux_arm64_metadata="$fixture_dir/linux-arm64.json"
linux_arm64_musl_metadata="$fixture_dir/linux-arm64-musl.json"
write_metadata "$darwin_metadata" "$valid_dir/$darwin_asset" "$darwin_asset"
write_metadata "$linux_amd64_metadata" "$valid_dir/$linux_amd64_asset" "$linux_amd64_asset"
write_metadata "$linux_amd64_musl_metadata" "$valid_dir/$linux_amd64_musl_asset" "$linux_amd64_musl_asset"
write_metadata "$linux_arm64_metadata" "$valid_dir/$linux_arm64_asset" "$linux_arm64_asset"
write_metadata "$linux_arm64_musl_metadata" "$valid_dir/$linux_arm64_musl_asset" "$linux_arm64_musl_asset"

darwin_download="$space_root/darwin download"
run_download "$darwin_download" "$valid_dir/$darwin_asset" "$darwin_metadata" Darwin arm64
[ -x "$darwin_download/dockerfmt" ] || fail_test 'macOS ARM64 archive was not installed in the download directory'
assert_eq 'fixture dockerfmt' "$("$darwin_download/dockerfmt")" 'macOS ARM64 archive contains the expected executable'

linux_download="$space_root/linux download"
run_download "$linux_download" "$valid_dir/$linux_amd64_asset" "$linux_amd64_metadata" Linux x86_64
[ -x "$linux_download/dockerfmt" ] || fail_test 'Linux AMD64 archive was not selected'

musl_download="$space_root/musl download"
run_download "$musl_download" "$valid_dir/$linux_amd64_musl_asset" "$linux_amd64_musl_metadata" Linux x86_64 musl
[ -x "$musl_download/dockerfmt" ] || fail_test 'Linux AMD64 musl archive was not selected'

arm_download="$space_root/arm download"
run_download "$arm_download" "$valid_dir/$linux_arm64_asset" "$linux_arm64_metadata" Linux aarch64
[ -x "$arm_download/dockerfmt" ] || fail_test 'Linux ARM64 archive was not selected'

arm_musl_download="$space_root/arm musl download"
run_download "$arm_musl_download" "$valid_dir/$linux_arm64_musl_asset" "$linux_arm64_musl_metadata" Linux aarch64 musl
[ -x "$arm_musl_download/dockerfmt" ] || fail_test 'Linux ARM64 musl archive was not selected'

url_log="$test_root/urls.log"
PATH="$fake_bin:$original_path" MOCK_URL_LOG="$url_log" MOCK_HEADER_LOG="$test_root/headers.log" \
	MOCK_API_JSON="$linux_amd64_metadata" MOCK_ARCHIVE="$valid_dir/$linux_amd64_asset" \
	MOCK_CURL_MODE=ok MOCK_UNAME_S=Linux MOCK_UNAME_M=x86_64 MOCK_LDD_VERSION='ldd (GNU libc) 2.39' \
	ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.5.4 ASDF_DOWNLOAD_PATH="$space_root/url download" \
	GITHUB_TOKEN='' "$repo_root/bin/download" >/dev/null
grep -F "$linux_amd64_asset" "$url_log" >/dev/null || fail_test 'download did not request the exact release asset'

header_log="$test_root/headers.log"
PATH="$fake_bin:$original_path" MOCK_URL_LOG="$test_root/token urls.log" MOCK_HEADER_LOG="$header_log" \
	MOCK_API_JSON="$darwin_metadata" MOCK_ARCHIVE="$valid_dir/$darwin_asset" MOCK_CURL_MODE=ok \
	MOCK_UNAME_S=Darwin MOCK_UNAME_M=arm64 MOCK_LDD_VERSION='' ASDF_INSTALL_TYPE=version \
	ASDF_INSTALL_VERSION=0.5.4 ASDF_DOWNLOAD_PATH="$space_root/token download" \
	GITHUB_TOKEN='secret-token' "$repo_root/bin/download" >/dev/null
grep -F 'Authorization: Bearer secret-token' "$header_log" >/dev/null ||
	fail_test 'GITHUB_TOKEN was not sent to the GitHub API'

expect_download_failure() {
	local expected="$1" destination="$2" archive="$3" metadata="$4" system="$5" machine="$6" libc mode output
	libc=gnu
	mode=ok
	[ "$#" -lt 7 ] || libc="$7"
	[ "$#" -lt 8 ] || mode="$8"
	if output=$(run_download "$destination" "$archive" "$metadata" "$system" "$machine" "$libc" "$mode" 2>&1); then
		fail_test "download unexpectedly succeeded: $expected"
	fi
	assert_contains "$expected" "$output" 'download failure message'
}

expect_download_failure 'Intel macOS is not supported' "$space_root/intel" "$valid_dir/$darwin_asset" "$darwin_metadata" Darwin x86_64
expect_download_failure 'Unsupported platform' "$space_root/unsupported" "$valid_dir/$darwin_asset" "$darwin_metadata" FreeBSD x86_64
expect_download_failure 'Cannot detect the Linux libc' "$space_root/no ldd" "$valid_dir/$linux_amd64_asset" "$linux_amd64_metadata" Linux x86_64 missing

expect_download_failure 'rate limit' "$space_root/rate limit" "$valid_dir/$darwin_asset" "$darwin_metadata" Darwin arm64 gnu rate-limit
expect_download_failure 'release metadata was not found' "$space_root/api missing" "$valid_dir/$darwin_asset" "$darwin_metadata" Darwin arm64 gnu api-404

missing_digest_metadata="$fixture_dir/missing-digest.json"
write_metadata "$missing_digest_metadata" "$valid_dir/$darwin_asset" "$darwin_asset" missing-digest
expect_download_failure 'did not publish a SHA-256 digest' "$space_root/missing digest" "$valid_dir/$darwin_asset" "$missing_digest_metadata" Darwin arm64

duplicate_metadata="$fixture_dir/duplicate.json"
write_metadata "$duplicate_metadata" "$valid_dir/$darwin_asset" "$darwin_asset" duplicate
expect_download_failure 'Expected exactly one GitHub release asset' "$space_root/duplicate" "$valid_dir/$darwin_asset" "$duplicate_metadata" Darwin arm64

wrong_digest_metadata="$fixture_dir/wrong-digest.json"
write_metadata "$wrong_digest_metadata" "$valid_dir/$darwin_asset" "$darwin_asset" wrong-digest
existing_download="$space_root/existing download"
mkdir -p "$existing_download"
printf 'old download\n' >"$existing_download/dockerfmt"
expect_download_failure 'SHA-256 mismatch' "$existing_download" "$valid_dir/$darwin_asset" "$wrong_digest_metadata" Darwin arm64
assert_eq 'old download' "$(sed -n '1p' "$existing_download/dockerfmt")" 'checksum failure preserves an existing download'

corrupt_dir="$fixture_dir/corrupt"
corrupt_archive="$corrupt_dir/$darwin_asset"
mkdir -p "$corrupt_dir"
printf 'not a tar archive\n' >"$corrupt_archive"
corrupt_metadata="$fixture_dir/corrupt.json"
write_metadata "$corrupt_metadata" "$corrupt_archive" "$darwin_asset"
expect_download_failure 'Invalid or corrupt archive' "$space_root/corrupt" "$corrupt_archive" "$corrupt_metadata" Darwin arm64

unsafe_dir="$fixture_dir/unsafe"
unsafe_archive="$unsafe_dir/$darwin_asset"
mkdir -p "$unsafe_dir"
touch "$fixture_dir/evil"
tar -C "$payload" -czf "$unsafe_archive" -P ../evil
unsafe_metadata="$fixture_dir/unsafe.json"
write_metadata "$unsafe_metadata" "$unsafe_archive" "$darwin_asset"
expect_download_failure 'unsafe path' "$space_root/unsafe" "$unsafe_archive" "$unsafe_metadata" Darwin arm64

extra_dir="$fixture_dir/extra"
extra_archive="$extra_dir/$darwin_asset"
mkdir -p "$extra_dir"
printf 'extra\n' >"$payload/extra"
tar -C "$payload" -czf "$extra_archive" dockerfmt extra
extra_metadata="$fixture_dir/extra.json"
write_metadata "$extra_metadata" "$extra_archive" "$darwin_asset"
expect_download_failure 'unexpected member' "$space_root/extra" "$extra_archive" "$extra_metadata" Darwin arm64

missing_asset_metadata="$fixture_dir/missing-asset.json"
write_metadata "$missing_asset_metadata" "$valid_dir/$linux_amd64_asset" "$linux_amd64_asset"
expect_download_failure 'Expected exactly one GitHub release asset' "$space_root/missing musl" "$valid_dir/$linux_amd64_musl_asset" "$missing_asset_metadata" Linux x86_64 musl

expect_download_failure 'Could not download' "$space_root/missing archive" "$valid_dir/$darwin_asset" "$darwin_metadata" Darwin arm64 gnu missing-archive

prerelease_metadata="$fixture_dir/prerelease.json"
write_metadata "$prerelease_metadata" "$valid_dir/$darwin_asset" "$darwin_asset" prerelease
expect_download_failure 'not a stable release' "$space_root/prerelease" "$valid_dir/$darwin_asset" "$prerelease_metadata" Darwin arm64

invalid_output=''
if invalid_output=$(PATH="$fake_bin:$original_path" ASDF_INSTALL_TYPE=ref ASDF_INSTALL_VERSION=0.5.4 \
	ASDF_DOWNLOAD_PATH="$space_root/ref" "$repo_root/bin/download" 2>&1); then
	fail_test 'Git reference install was accepted'
fi
assert_contains 'Git references are not supported' "$invalid_output" 'Git reference rejection'

if invalid_output=$(PATH="$fake_bin:$original_path" ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.3.7 \
	ASDF_DOWNLOAD_PATH="$space_root/old" "$repo_root/bin/download" 2>&1); then
	fail_test 'unsupported old release was accepted'
fi
assert_contains 'Unsupported version' "$invalid_output" 'old release rejection'

install_root="$space_root/install root"
mkdir -p "$install_root/bin"
printf 'old install\n' >"$install_root/bin/dockerfmt"
chmod 755 "$install_root/bin/dockerfmt"
bad_download="$space_root/bad download"
mkdir -p "$bad_download"
printf 'not executable\n' >"$bad_download/dockerfmt"
if ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.5.4 ASDF_DOWNLOAD_PATH="$bad_download" \
	ASDF_INSTALL_PATH="$install_root" "$repo_root/bin/install" >/dev/null 2>&1; then
	fail_test 'invalid download was installed'
fi
assert_eq 'old install' "$(sed -n '1p' "$install_root/bin/dockerfmt")" 'failed install preserves an existing executable'

ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.5.4 ASDF_DOWNLOAD_PATH="$darwin_download" \
	ASDF_INSTALL_PATH="$install_root" "$repo_root/bin/install" >/dev/null
assert_eq 'fixture dockerfmt' "$("$install_root/bin/dockerfmt")" 'valid install exposes dockerfmt'

printf 'Plugin tests passed.\n'
