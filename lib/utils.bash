#!/usr/bin/env bash

set -euo pipefail

GH_REPO="https://github.com/reteps/dockerfmt"
GH_API_REPO="https://api.github.com/repos/reteps/dockerfmt"
TOOL_NAME="dockerfmt"
MIN_SUPPORTED_VERSION="0.3.8"

fail() {
	printf 'asdf-%s: %s\n' "$TOOL_NAME" "$*" >&2
	exit 1
}

sort_versions() {
	LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n -u
}

version_is_supported() {
	local version="$1" major rest minor patch

	[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1
	major="${version%%.*}"
	rest="${version#*.}"
	minor="${rest%%.*}"
	patch="${rest#*.}"

	if [ "$major" -gt 0 ]; then
		return 0
	fi
	[ "$minor" -gt 3 ] || { [ "$minor" -eq 3 ] && [ "$patch" -ge 8 ]; }
}

list_all_versions() {
	local tags
	tags=$(git ls-remote --tags --refs "$GH_REPO.git") ||
		fail "Could not list release tags from $GH_REPO."

	printf '%s\n' "$tags" |
		sed -nE 's#^[^[:space:]]+[[:space:]]+refs/tags/v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$#\1#p' |
		awk -F. -v minimum_minor=3 -v minimum_patch=8 '
			$1 > 0 || ($1 == 0 && ($2 > minimum_minor || ($2 == minimum_minor && $3 >= minimum_patch)))
		'
}

validate_version() {
	local install_type="${ASDF_INSTALL_TYPE:-}" version="${ASDF_INSTALL_VERSION:-}"

	[ "$install_type" = version ] ||
		fail "Only stable release versions are supported; Git references are not supported."
	version_is_supported "$version" ||
		fail "Unsupported version '$version'. Use a stable release version $MIN_SUPPORTED_VERSION or later."
}

platform_target() {
	local system architecture
	system=$(uname -s)
	architecture=$(uname -m)

	case "$system/$architecture" in
	Darwin/arm64 | Darwin/aarch64)
		printf 'darwin-arm64\n'
		;;
	Darwin/x86_64 | Darwin/amd64)
		fail 'Intel macOS is not supported; use macOS ARM64.'
		;;
	Linux/x86_64 | Linux/amd64)
		printf 'linux-amd64\n'
		;;
	Linux/arm64 | Linux/aarch64)
		printf 'linux-arm64\n'
		;;
	*)
		fail "Unsupported platform: $system/$architecture. Supported platforms are macOS ARM64 and Linux AMD64 or ARM64."
		;;
	esac
}

linux_libc_suffix() {
	local ldd_version

	command -v ldd >/dev/null 2>&1 ||
		fail 'Cannot detect the Linux libc because ldd is not available.'
	ldd_version=$(ldd --version 2>&1 || true)
	[ -n "$ldd_version" ] || fail 'Cannot detect the Linux libc from ldd.'

	if printf '%s\n' "$ldd_version" | grep -qi musl; then
		printf '%s\n' '-musl'
	else
		printf '%s\n' ''
	fi
}

release_asset() {
	local target suffix=''
	target=$(platform_target) || exit 1
	case "$target" in
	linux-*) suffix=$(linux_libc_suffix) || exit 1 ;;
	esac
	printf '%s\n' "dockerfmt-v${ASDF_INSTALL_VERSION}-${target}${suffix}.tar.gz"
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		fail 'Install sha256sum or shasum to verify downloads.'
	fi
}

require_jq() {
	command -v jq >/dev/null 2>&1 ||
		fail 'jq is required to read GitHub release metadata.'
}

github_api_get() {
	local url="$1" output="$2" http_code
	local -a curl_args

	case "$url" in
	"$GH_API_REPO"/*) ;;
	*) fail 'Refusing to send the GitHub token to an unrelated host.' ;;
	esac

	curl_args=(--silent --show-error --retry 3 --output "$output" --write-out '%{http_code}'
		-H 'Accept: application/vnd.github+json'
		-H 'X-GitHub-Api-Version: 2022-11-28')
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
	fi

	if ! http_code=$(curl "${curl_args[@]}" "$url"); then
		fail 'Could not query the GitHub release API.'
	fi
	case "$http_code" in
	200) ;;
	403 | 429) fail "GitHub release API rate limit or access error (HTTP $http_code)." ;;
	404) fail 'GitHub release metadata was not found.' ;;
	*) fail "GitHub release API returned HTTP $http_code." ;;
	esac
}

release_digest() {
	local metadata="$1" asset="$2" count digest

	count=$(jq -er --arg asset "$asset" '[.assets[]? | select(.name == $asset)] | length' "$metadata") ||
		fail "Could not parse GitHub release assets for $asset."
	[ "$count" = 1 ] || fail "Expected exactly one GitHub release asset named $asset; found $count."

	digest=$(jq -er --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // empty' "$metadata") ||
		fail "GitHub did not publish a SHA-256 digest for $asset."
	[[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] ||
		fail "GitHub published an invalid SHA-256 digest for $asset."
	printf '%s\n' "${digest#sha256:}" | tr '[:upper:]' '[:lower:]'
}

validate_archive() {
	local archive="$1" destination="$2" members member_count=0 member

	members=$(tar -tzf "$archive" 2>/dev/null) ||
		fail "Invalid or corrupt archive: $archive."

	while IFS= read -r member; do
		[ -n "$member" ] || continue
		case "$member" in
		/* | ../* | */../* | */.. | ..)
			fail "Archive contains an unsafe path: $member."
			;;
		dockerfmt)
			member_count=$((member_count + 1))
			;;
		*)
			fail "Archive contains an unexpected member: $member."
			;;
		esac
	done <<EOF
$members
EOF

	[ "$member_count" -eq 1 ] || fail 'Archive must contain one dockerfmt executable.'
	tar -xzf "$archive" -C "$destination" dockerfmt 2>/dev/null ||
		fail "Could not extract dockerfmt from $archive."
	[ -f "$destination/dockerfmt" ] &&
		[ ! -L "$destination/dockerfmt" ] &&
		[ -x "$destination/dockerfmt" ] ||
		fail 'Archive does not contain an executable dockerfmt file.'
}

download_release() (
	validate_version
	local version="$ASDF_INSTALL_VERSION" download_path="${ASDF_DOWNLOAD_PATH:-}"
	local asset metadata archive expected actual staging temp_dir

	[ -n "$download_path" ] || fail 'ASDF_DOWNLOAD_PATH is required.'
	asset=$(release_asset) || exit 1
	temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/asdf-dockerfmt.XXXXXX") ||
		fail 'Could not create a temporary directory.'
	metadata="$temp_dir/release.json"
	archive="$temp_dir/$asset"
	staging=''

	# shellcheck disable=SC2329
	cleanup() {
		[ -z "$staging" ] || rm -f "$staging"
		rm -f "$metadata" "$archive" "$temp_dir/dockerfmt"
		rmdir "$temp_dir" 2>/dev/null || true
	}
	trap cleanup EXIT

	require_jq
	github_api_get "$GH_API_REPO/releases/tags/v$version" "$metadata"
	jq -e --arg tag "v$version" \
		'type == "object" and .tag_name == $tag and .draft == false and .prerelease == false and (.assets | type == "array")' \
		"$metadata" >/dev/null || fail "GitHub release v$version is not a stable release with asset metadata."
	expected=$(release_digest "$metadata" "$asset") || exit 1

	printf '* Downloading %s release %s (%s)...\n' "$TOOL_NAME" "$version" "$asset" >&2
	curl --fail --silent --show-error --location --retry 3 \
		-o "$archive" "$GH_REPO/releases/download/v$version/$asset" ||
		fail "Could not download $asset. The release may not provide this platform asset."
	actual=$(sha256_file "$archive") || exit 1
	[ "$actual" = "$expected" ] || fail "SHA-256 mismatch for $asset."
	validate_archive "$archive" "$temp_dir"

	mkdir -p "$download_path" || fail "Could not create $download_path."
	staging=$(mktemp "$download_path/.dockerfmt.XXXXXX") ||
		fail "Could not create a staging file in $download_path."
	if ! cp -p "$temp_dir/dockerfmt" "$staging" ||
		! chmod 755 "$staging" ||
		! mv -f "$staging" "$download_path/dockerfmt"; then
		fail "Could not store dockerfmt in $download_path."
	fi
	staging=''
)

install_version() {
	validate_version
	local download_path="${ASDF_DOWNLOAD_PATH:-}" install_path="${ASDF_INSTALL_PATH:-}" staging

	[ -n "$download_path" ] || fail 'ASDF_DOWNLOAD_PATH is required.'
	[ -n "$install_path" ] || fail 'ASDF_INSTALL_PATH is required.'
	[ -f "$download_path/dockerfmt" ] &&
		[ ! -L "$download_path/dockerfmt" ] &&
		[ -x "$download_path/dockerfmt" ] ||
		fail 'Download is missing an executable dockerfmt file.'

	mkdir -p "$install_path/bin" || fail "Could not create $install_path/bin."
	staging=$(mktemp "$install_path/bin/.dockerfmt.XXXXXX") ||
		fail "Could not create a staging file in $install_path/bin."
	if ! cp -p "$download_path/dockerfmt" "$staging" ||
		! chmod 755 "$staging" ||
		! mv -f "$staging" "$install_path/bin/dockerfmt"; then
		rm -f "$staging"
		fail "Could not install dockerfmt into $install_path/bin."
	fi

	printf '%s %s installation was successful.\n' "$TOOL_NAME" "$ASDF_INSTALL_VERSION"
}
