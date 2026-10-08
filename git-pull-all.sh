#!/usr/bin/env bash
# Run `git pull --ff-only` in every component repo under sources/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="${SCRIPT_DIR}/sources"

if [ ! -d "$SOURCES_DIR" ]; then
    echo "No sources/ directory yet. Run ./bootstrap.sh first."
    exit 1
fi

while IFS= read -r -d '' gitdir; do
    dir="$(dirname "$gitdir")"
    name="${dir#"$SOURCES_DIR"/}"

    echo "🔄 Pulling ${name}..."
    if git -C "${dir}" pull --ff-only; then
        echo "✅ ${name} done"
    else
        echo "❌ ${name} failed"
    fi
    echo
done < <(find "$SOURCES_DIR" -mindepth 2 -maxdepth 4 -name .git -type d -print0 | sort -z)
