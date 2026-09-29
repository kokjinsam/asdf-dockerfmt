# asdf-dockerfmt

An [asdf](https://asdf-vm.com/) plugin for installing prebuilt
[dockerfmt](https://github.com/reteps/dockerfmt) binaries.

## Support

- Stable dockerfmt versions `0.3.8` and later.
- macOS ARM64.
- Linux AMD64 and ARM64.
- Linux GNU and explicit musl archives when the selected release publishes the
  required asset.
- SHA-256 verification from GitHub release metadata before archive extraction.
- Binary archives only. The plugin does not build dockerfmt from source.

Intel macOS, Windows, prereleases, Git references, and unsupported CPU
architectures are outside this plugin's scope.

Version discovery reads stable `vX.Y.Z` Git tags. Installation then reads the
exact release metadata from the GitHub API, so a tag does not prove that the
required archive or digest exists. The API can use an optional `GITHUB_TOKEN`.
The token is sent only to `api.github.com` and is never sent to the release
download host.

## Install

```sh
asdf plugin add dockerfmt https://github.com/kokjinsam/asdf-dockerfmt.git
asdf list all dockerfmt
asdf install dockerfmt 0.5.4
asdf set -u dockerfmt 0.5.4
dockerfmt version
```

The plugin requires Bash, Git, curl, jq, tar with gzip support, and either
`sha256sum` or `shasum`.

## Development

Use asdf `0.16.5`. The exact Just, jq, ShellCheck, and shfmt versions are in
`.tool-versions`. Register those asdf plugins before running:

```sh
just setup
just check
```

Only `just setup` installs the development tools. Other recipes check for the
exact tools and fail when a requirement is missing or incorrect.

To install the oldest supported release and the current stable release in an
isolated ASDF data directory, run:

```sh
just setup "/tmp/dockerfmt-asdf-smoke"
```

This also runs the stdin, file, and `-c` formatter checks against both
installed binaries. The fixture tests do not contact GitHub. They cover
version filtering, platform and musl selection, API failures, digest and
checksum failures, archive safety, paths with spaces, and preservation of
existing files after a failed operation.

## License

MIT. See [LICENSE](LICENSE).
