#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/linux_mantenimiento.sh"
TEST_NAME=
TMPDIRS=()

cleanup() {
  local dir
  for dir in "${TMPDIRS[@]}"; do
    [[ -d "$dir" ]] && rm -rf -- "$dir"
  done
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n%s\n' "$TEST_NAME" "$*" >&2
  exit 1
}

assert_contains() {
  local haystack=$1 needle=$2
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"$'\n'"actual output:"$'\n'"$haystack"
}

assert_file_contains() {
  local file=$1 needle=$2
  [[ -f "$file" ]] || fail "missing file: $file"
  grep -F -- "$needle" "$file" >/dev/null || fail "expected $file to contain: $needle"
}

assert_missing() {
  local path=$1
  [[ ! -e "$path" ]] || fail "expected path to be removed: $path"
}

assert_exists() {
  local path=$1
  [[ -e "$path" ]] || fail "expected path to exist: $path"
}

new_home() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/linux-mantenimiento-test.XXXXXX")
  TMPDIRS+=("$dir")
  mkdir -p -- "$dir/home" "$dir/home/.cache/thumbnails" "$dir/home/.config"
  printf '%s\n' "$dir/home"
}

run_script() {
  local home=$1
  shift
  HOME="$home" XDG_CONFIG_HOME="$home/.config" "$SCRIPT" "$@"
}

test_help_and_list() {
  TEST_NAME='help and default list'
  local home out
  home=$(new_home)
  out=$(run_script "$home" --help)
  assert_contains "$out" 'Uso: linux_mantenimiento.sh [opción]'
  out=$(run_script "$home" --list)
  assert_contains "$out" 'Linux Mantenimiento 1.0.0'
  assert_contains "$out" 'thumbs'
}

test_config_commands() {
  TEST_NAME='config commands persist values'
  local home config
  home=$(new_home)
  config="$home/.config/linux-mantenimiento/config"
  run_script "$home" --enable tmp
  run_script "$home" --disable cache
  run_script "$home" --set-days history 0
  assert_file_contains "$config" 'enabled|tmp|1'
  assert_file_contains "$config" 'enabled|cache|0'
  assert_file_contains "$config" 'days|history|0'
}

test_custom_paths_are_validated() {
  TEST_NAME='custom path validation'
  local home custom protected config
  home=$(new_home)
  custom="$home/.local/state/demo-cache"
  protected="$home/Documents/cache"
  config="$home/.config/linux-mantenimiento/config"
  mkdir -p -- "$custom" "$protected"
  run_script "$home" --add-path "$custom" 15
  assert_file_contains "$config" "custom|$custom|15|1"
  if run_script "$home" --add-path "$protected" 15 >/dev/null 2>&1; then
    fail 'protected custom path was accepted'
  fi
}

test_scan_and_run_remove_only_old_candidates() {
  TEST_NAME='scan and run remove only old candidates'
  local home old_file fresh_file out
  home=$(new_home)
  old_file="$home/.cache/thumbnails/old.thumb"
  fresh_file="$home/.cache/thumbnails/fresh.thumb"
  printf 'old\n' > "$old_file"
  printf 'fresh\n' > "$fresh_file"
  touch -d '45 days ago' "$old_file"
  out=$(run_script "$home" --scan)
  assert_contains "$out" 'Escaneo: 1 archivos'
  run_script "$home" --run --yes >/dev/null
  assert_missing "$old_file"
  assert_exists "$fresh_file"
}

test_history_is_truncated() {
  TEST_NAME='history cleanup truncates files'
  local home history
  home=$(new_home)
  history="$home/.bash_history"
  printf 'secret command\n' > "$history"
  run_script "$home" --enable history
  run_script "$home" --run --yes >/dev/null
  [[ -f "$history" ]] || fail 'history file was removed instead of truncated'
  [[ ! -s "$history" ]] || fail 'history file still has content'
}

main() {
  bash -n "$SCRIPT"
  local tests=(
    test_help_and_list
    test_config_commands
    test_custom_paths_are_validated
    test_scan_and_run_remove_only_old_candidates
    test_history_is_truncated
  )
  local test
  for test in "${tests[@]}"; do
    "$test"
    printf 'ok - %s\n' "$TEST_NAME"
  done
}

main "$@"
