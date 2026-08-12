#!/bin/bash
set -euo pipefail

umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${RECALL_CI_REPO_ROOT:-${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$script_dir/../.." && pwd)}}"
workspace="${CI_WORKSPACE:-$(dirname "$repo_root")}"
flutter_version="${RECALL_CI_FLUTTER_VERSION:-3.44.9}"
flutter_root="${RECALL_CI_FLUTTER_ROOT:-$workspace/flutter-$flutter_version}"
flutter_repository="${RECALL_CI_FLUTTER_REPOSITORY:-https://github.com/flutter/flutter.git}"
git_bin="${RECALL_CI_GIT_BIN:-git}"
config_b64="${RECALL_SUPABASE_CONFIG_B64:-}"
build_number="${CI_BUILD_NUMBER:-}"

if [[ -z "$config_b64" ]]; then
  echo "RECALL_SUPABASE_CONFIG_B64 is required and must be marked Secret in Xcode Cloud." >&2
  exit 1
fi

if [[ ! "$build_number" =~ ^[0-9]+$ ]] || (( build_number < 1 )); then
  echo "CI_BUILD_NUMBER must be a positive integer." >&2
  exit 1
fi

if [[ ! -d "$repo_root" ]]; then
  echo "Recall checkout does not exist: $repo_root" >&2
  exit 1
fi

config_dir="$repo_root/config"
config_path="$config_dir/supabase.local.json"
config_tmp="$config_path.tmp.$$"
mkdir -p "$config_dir"

cleanup() {
  status=$?
  rm -f "$config_tmp"
  if (( status != 0 )); then
    rm -f "$config_path"
  fi
}
trap cleanup EXIT

base64_decode_flag="--decode"
if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
  base64_decode_flag="-D"
fi

if ! printf '%s' "$config_b64" | /usr/bin/base64 "$base64_decode_flag" > "$config_tmp"; then
  echo "RECALL_SUPABASE_CONFIG_B64 is not valid base64." >&2
  exit 1
fi

/usr/bin/python3 - "$config_tmp" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)

required = {"SUPABASE_URL", "SUPABASE_ANON_KEY"}
if set(payload) != required:
    raise SystemExit(
        "Recall cloud config must contain only SUPABASE_URL and SUPABASE_ANON_KEY."
    )
if not all(isinstance(payload[key], str) and payload[key].strip() for key in required):
    raise SystemExit("Recall cloud config values must be non-empty strings.")
PY

mv "$config_tmp" "$config_path"

flutter_bin="$flutter_root/bin/flutter"
if [[ ! -x "$flutter_bin" ]]; then
  if [[ -e "$flutter_root" ]]; then
    echo "Flutter SDK path exists but is incomplete: $flutter_root" >&2
    exit 1
  fi
  "$git_bin" clone \
    --depth 1 \
    --branch "$flutter_version" \
    "$flutter_repository" \
    "$flutter_root"
fi

export PATH="$flutter_root/bin:$PATH"

cd "$repo_root"
"$flutter_bin" config --enable-ios --no-cli-animations
"$flutter_bin" pub get
"$flutter_bin" build ios \
  --config-only \
  --release \
  --no-codesign \
  --build-number="$build_number" \
  --dart-define-from-file="$config_path"

echo "Recall Xcode Cloud configuration prepared for build $build_number."
