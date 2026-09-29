# Feasibility and verification

Investigation date: 2026-09-29.

## Decision

An asdf plugin is feasible. dockerfmt publishes standalone Go binaries, so no
Go, Docker, or separate shfmt executable is required to run an installed
binary.

The plugin supports stable releases from `0.3.8` onward. Earlier releases do
not provide GitHub SHA-256 asset digests. Stable tags from `0.3.8` onward use
the `v` prefix.

## Distribution details

Release `v0.5.4` publishes these supported targets:

- `dockerfmt-v0.5.4-darwin-arm64.tar.gz`
- `dockerfmt-v0.5.4-linux-amd64.tar.gz`
- `dockerfmt-v0.5.4-linux-arm64.tar.gz`
- `dockerfmt-v0.5.4-linux-amd64-musl.tar.gz`
- `dockerfmt-v0.5.4-linux-arm64-musl.tar.gz`

The macOS archive contains one executable named `dockerfmt`. There is no Intel
macOS archive. Upstream also publishes MD5 sidecars, but this plugin requires
the SHA-256 digest in the GitHub release API and does not fall back to MD5.

The plugin detects musl with `ldd --version` and selects the explicit musl
asset. If the selected release lacks that asset or its API digest, installation
stops before changing the ASDF download directory.

## Verification boundary

The local fixture suite validates script behavior without network access. The
isolated smoke command downloads and installs the oldest supported release and
the current release on the host platform, then runs dockerfmt through the
installed executable. GitHub Actions adds native macOS ARM64 and Linux AMD64
and ARM64 ASDF installation coverage, plus a Linux AMD64 musl runtime job.
Hosted CI is not verified until the repository is pushed.

## Sources

- [asdf plugin template](https://github.com/asdf-vm/asdf-plugin-template/tree/8ee7a1f9d7eaa2658355df1e9dc9f646cdeab615)
- [dockerfmt releases](https://github.com/reteps/dockerfmt/releases)
- [dockerfmt v0.5.4 release](https://github.com/reteps/dockerfmt/releases/tag/v0.5.4)
- [dockerfmt v0.3.8 release](https://github.com/reteps/dockerfmt/releases/tag/v0.3.8)
