#!/usr/bin/env bash
# =============================================================================
# Telemon -- Build a release archive
# =============================================================================
# Single source of truth for release packaging. Used by
# .github/workflows/release.yml (on tag push) and by the CI "Release Artifact
# Check" job, which builds and smoke-tests the archive on every push/PR.
#
# Why this exists: packaging used to be an inline `cp` list in release.yml.
# When lib/common.sh was split out of telemon.sh nobody updated that list, so
# every published archive shipped without lib/common.sh and could not start
# (GH #21). The required-entry list below is checked before packaging, and CI
# runs the same script so the two paths cannot drift again.
#
# Usage: bash scripts/build-release-archive.sh <version> [outdir]
#   <version>  release version, with or without the leading "v" (v1.2.2 or 1.2.2)
#   [outdir]   where to write the archives (default: current directory)
# Output: <outdir>/telemon-<version>.tar.gz (always) and .zip (when zip exists)
# =============================================================================
set -euo pipefail

version="${1:-}"
outdir="${2:-.}"

if [[ -z "$version" ]]; then
    echo "Usage: bash scripts/build-release-archive.sh <version> [outdir]" >&2
    exit 1
fi
[[ "$version" == v* ]] || version="v${version}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

pkg_name="telemon-${version}"
pkg_root="${staging}/${pkg_name}"
mkdir -p "$pkg_root"

# Everything the archive needs. `lib/` and `VERSION` are load-bearing:
# every script sources lib/common.sh and the version file is the fallback for
# non-git installs. Keep this list in sync with what the code actually reads.
entries=(
    telemon.sh
    telemon-admin.sh
    lib
    install.sh
    update.sh
    uninstall.sh
    checks.d/example-plugin.sh
    systemd
    docs
    .env.example
    telemon-logrotate.conf
    README.md
    LICENSE
    CHANGELOG.md
    CONTRIBUTING.md
    VERSION
)

cd "$repo_root"
for entry in "${entries[@]}"; do
    if [[ ! -e "$entry" ]]; then
        echo "ERROR: required release entry is missing from the repository: ${entry}" >&2
        exit 1
    fi
    mkdir -p "${pkg_root}/$(dirname "$entry")"
    cp -r "$entry" "${pkg_root}/$(dirname "$entry")/"
done

# Belt and braces: never emit an archive that cannot run
for required in telemon.sh telemon-admin.sh lib/common.sh VERSION; do
    if [[ ! -e "${pkg_root}/${required}" ]]; then
        echo "ERROR: ${required} missing from the staged archive" >&2
        exit 1
    fi
done

mkdir -p "$outdir"
outdir="$(cd "$outdir" && pwd)"
tar -czf "${outdir}/${pkg_name}.tar.gz" -C "$staging" "$pkg_name"
echo "Built ${outdir}/${pkg_name}.tar.gz"

if command -v zip &>/dev/null; then
    (cd "$staging" && zip -qr "${outdir}/${pkg_name}.zip" "$pkg_name")
    echo "Built ${outdir}/${pkg_name}.zip"
else
    echo "WARN: zip not installed — skipping ${pkg_name}.zip" >&2
fi
