set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Install the exact repository tools. This is the only recipe that installs tools.
setup smoke_dir="":
    #!/usr/bin/env bash
    set -euo pipefail
    asdf_version="$(asdf --version)"
    case "$asdf_version" in
        "asdf version 0.16.5" | "v0.16.5" | "0.16.5") ;;
        *) printf 'asdf 0.16.5 is required; found %s\n' "$asdf_version" >&2; exit 1 ;;
    esac
    while IFS=' ' read -r tool version; do
        [ -n "$tool" ] || continue
        asdf install "$tool" "$version"
    done < .tool-versions
    if [ -n '{{smoke_dir}}' ]; then
        repo_dir="$(pwd -P)"
        mkdir -p '{{smoke_dir}}/plugins'
        plugin_path='{{smoke_dir}}/plugins/dockerfmt'
        if [ -e "$plugin_path" ] || [ -L "$plugin_path" ]; then
            printf 'Smoke directory already contains %s\n' "$plugin_path" >&2
            exit 1
        fi
        ln -s "$repo_dir" "$plugin_path"
        current="$(ASDF_DATA_DIR='{{smoke_dir}}' asdf latest dockerfmt)"
        for version in 0.3.8 "$current"; do
            ASDF_DATA_DIR='{{smoke_dir}}' asdf install dockerfmt "$version"
            ASDF_DATA_DIR='{{smoke_dir}}' asdf reshim dockerfmt "$version"
            executable="$(ASDF_DATA_DIR='{{smoke_dir}}' asdf where dockerfmt "$version")/bin/dockerfmt"
            test -x "$executable"
            ASDF_DATA_DIR='{{smoke_dir}}' ASDF_DOCKERFMT_VERSION="$version" asdf exec dockerfmt version >/dev/null
            tests/runtime.bash "$executable"
        done
    fi

doctor:
    #!/usr/bin/env bash
    set -euo pipefail
    for command in asdf just jq shellcheck shfmt git curl tar awk; do
        command -v "$command" >/dev/null 2>&1 || {
            printf 'Required command is missing: %s\n' "$command" >&2
            exit 1
        }
    done
    asdf_version="$(asdf --version)"
    case "$asdf_version" in
        "asdf version 0.16.5" | "v0.16.5" | "0.16.5") ;;
        *) printf 'asdf 0.16.5 is required; found %s\n' "$asdf_version" >&2; exit 1 ;;
    esac
    test "$(just --version)" = "just 1.54.0"
    jq_version="$(jq --version)"
    case "$jq_version" in
        jq-1.7.1 | jq-1.7.1-*) ;;
        *) printf 'jq 1.7.1 is required; found %s\n' "$jq_version" >&2; exit 1 ;;
    esac
    test "$(shellcheck --version | sed -n '2s/^version: //p')" = "0.11.0"
    test "$(shfmt --version)" = "v3.13.1"

format: doctor
    scripts/format.bash

format-check: doctor
    shfmt -d bin lib scripts tests

lint: doctor
    shellcheck -x bin/* lib/*.bash scripts/*.bash tests/*.bash

test: doctor
    bash tests/plugin.bash

check: doctor format-check lint test
