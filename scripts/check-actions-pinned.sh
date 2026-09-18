#!/usr/bin/env bash
# =============================================================================
# Telemon -- Enforce the GitHub Actions pinning policy
# =============================================================================
# CONTRIBUTING.md requires every third-party action to be pinned to a full
# commit SHA, with the version in a trailing comment; only GitHub-maintained
# actions (actions/*) may use a major version tag.
#
# Why this exists: the first pinning fix covered the one action that broke CI
# and nothing enforced the rule, so two more actions (the release publisher and
# the markdown linter) kept using mutable tags. A retagged or compromised action
# runs arbitrary code in CI, and the release job runs with contents: write, so
# the compromise path ends in what users download (GH #30). CI runs this script
# on every push/PR.
#
# Usage: bash scripts/check-actions-pinned.sh [workflows-dir]
# Exit: 0 all pinned, 1 at least one unpinned reference, 2 no workflow dir
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="${1:-${SCRIPT_DIR}/../.github/workflows}"

# Check one workflow file. Prints every offending reference and returns 1 when
# at least one was found.
check_workflow() {
    local file="$1"
    local line_no=0
    local line ref failures=0

    while IFS= read -r line; do
        line_no=$((line_no + 1))
        [[ "$line" =~ ^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*(.+)$ ]] || continue
        ref="${BASH_REMATCH[2]}"
        ref="${ref%%#*}"                     # drop a trailing comment
        ref="${ref//[[:space:]]/}"           # and any whitespace or quotes
        ref="${ref//\"/}"
        ref="${ref//\'/}"

        case "$ref" in
            # Reusable workflows/actions inside this repository
            ./*) continue ;;
            # Container images are pinned by the workflow author, not a tag we can check
            docker://*) continue ;;
            # GitHub-maintained actions may use a major version tag (CONTRIBUTING.md)
            actions/*) continue ;;
        esac

        if [[ ! "$ref" =~ ^[^@]+@[0-9a-f]{40}$ ]]; then
            printf 'UNPINNED: %s:%s: %s (pin to a 40-character commit SHA)\n' \
                "$file" "$line_no" "$ref" >&2
            failures=$((failures + 1))
        fi
    done < "$file"

    [[ "$failures" -eq 0 ]]
}

main() {
    if [[ ! -d "$WORKFLOWS_DIR" ]]; then
        echo "check-actions-pinned: no workflows directory at '${WORKFLOWS_DIR}'" >&2
        exit 2
    fi

    local file files=0 failures=0
    for file in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
        [[ -f "$file" ]] || continue
        files=$((files + 1))
        check_workflow "$file" || failures=$((failures + 1))
    done

    if [[ "$failures" -gt 0 ]]; then
        echo "check-actions-pinned: ${failures} workflow file(s) reference a mutable action tag — see CONTRIBUTING.md" >&2
        exit 1
    fi

    echo "check-actions-pinned: OK (${files} workflow file(s), every third-party action pinned to a commit SHA)"
}

main "$@"
