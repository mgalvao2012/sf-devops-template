#!/usr/bin/env bash
# Copies the framework payload (template/) into a target project, overwriting existing files.
# Git is the safety net: callers require a clean working tree, so every overwrite is
# reviewable and revertible via `git diff` / `git checkout`.
set -euo pipefail

copy_template() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || { echo "template dir '$src' not found" >&2; exit 1; }

  while IFS= read -r -d '' f; do
    local rel="${f#"$src"/}" out="$dst/${f#"$src"/}"
    mkdir -p "$(dirname "$out")"
    [[ -e "$out" ]] && echo "  overwrite: $rel" || echo "  add: $rel"
    cp -p "$f" "$out"
  done < <(find "$src" -type f -print0)
}
