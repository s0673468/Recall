#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${RECALL_CI_REPO_ROOT:-${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$script_dir/../.." && pwd)}}"
config_path="$repo_root/config/supabase.local.json"

if [[ -f "$config_path" ]]; then
  rm -f -- "$config_path"
fi

echo "Recall Xcode Cloud runtime configuration removed."
