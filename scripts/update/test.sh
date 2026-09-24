#!/usr/bin/env bash
# Copyright 2026 Carnegie Mellon University. All Rights Reserved.
# Released under a MIT (SEI)-style license. See LICENSE.md in the project root for license information.
#
# Offline tests for update.sh. Run with: task update:test (or task update:test -- <part of a test
# name> to run only the matching tests).
# Sources update.sh, points it at fresh copies of testdata/ for each test, and replaces its
# network, dialog, and command functions with stubs. Each test_* function runs in a subshell.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=update.sh
source "$HERE/update.sh"

# ---------------------------------------------------------------------------------------------
# Helpers

failed=0

# check <description> <expected> <actual>
check() {
  if [[ $2 != "$3" ]]; then
    printf '    %s\n      expected: %s\n      actual:   %s\n' "$1" "${2//$'\n'/$'\n'                }" \
      "${3//$'\n'/$'\n'                }"
    failed=1
  fi
}

# check_status <description> <expected exit status> <command...>
check_status() {
  local description=$1 expected=$2 actual
  shift 2
  "$@" >/dev/null 2>&1 && actual=0 || actual=$?
  check "$description (exit status)" "$expected" "$actual"
}

# Prints the lines that differ between files $1 and $2 as "-old" and "+new", no line numbers.
changes() {
  diff --unchanged-line-format= --old-line-format='-%L' --new-line-format='+%L' "$1" "$2"
}

# Runs every test_* function, or only those whose names contain $1, and fails if any fails. Each
# test runs in a subshell under set -e, like main, so a command that would stop a real run also
# stops the test. (A subshell in an "if" condition would ignore set -e, hence the $? check.)
run_tests() {
  local t status=0
  for t in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
    if [[ -n ${1:-} && $t != *"$1"* ]]; then
      continue
    fi
    (
      setup
      trap 'rc=$?; rm -rf "$WORK"; if ((rc && !failed)); then echo "    stopped at a failing command"; fi' EXIT
      set -e
      "$t"
      exit "$failed"
    )
    if (($? == 0)); then
      echo "ok    $t"
    else
      echo "FAIL  $t"
      status=1
    fi
  done
  return "$status"
}

# Gives each test fresh copies of the fixture files and empty summary lists.
setup() {
  WORK=$(mktemp -d)
  mkdir -p "$WORK/sums"
  cp "$HERE/testdata/Dockerfile" "$HERE/testdata/devcontainer.json" \
    "$HERE/testdata/devcontainer-lock.json" "$WORK/"
  DOCKERFILE=$WORK/Dockerfile
  DEVCONTAINER_JSON=$WORK/devcontainer.json
  LOCK_JSON=$WORK/devcontainer-lock.json
  MANIFEST=$HERE/testdata/tools.json
  load_manifest
  UPDATED=() SKIPPED=() FAILED=() HELD=() REBUILD=false IN_PROGRESS=""
  cp "$DOCKERFILE" "$WORK/Dockerfile.orig"
  cp "$DEVCONTAINER_JSON" "$WORK/devcontainer.json.orig"
}

# ---------------------------------------------------------------------------------------------
# Version rules

test_ver_filter_drops_prereleases_and_short_versions() {
  check "3 components" $'1.2.3\n1.10.0' \
    "$(printf '%s\n' v1.2.3 1.2.4-rc.1 latest 1.2 v1.10.0 1.2.3 | ver_filter 3)"
}

test_ver_filter_cuts_to_pin_granularity() {
  check "2 components" $'2.92\n2.95\n3.0' \
    "$(printf '%s\n' 2.92.0 2.92.1 2.95.0 3.0.0 | ver_filter 2)"
}

test_ver_major_key() {
  check "2.92" 2 "$(ver_major_key 2.92)"
  check "0.9.1" 0.9 "$(ver_major_key 0.9.1)"
  check "0.0.42" 0.0 "$(ver_major_key 0.0.42)"
  check "1" 1 "$(ver_major_key 1)"
}

test_ver_gt_compares_numerically() {
  check_status "1.10 > 1.9" 0 ver_gt 1.10 1.9
  check_status "1.9 > 1.10" 1 ver_gt 1.9 1.10
  check_status "1.9 > 1.9" 1 ver_gt 1.9 1.9
}

test_pick_minor_only() {
  check "rows" "minor 18.3.0" "$(printf '%s\n' v18.2.7 v18.3.0 | pick_candidates 18.2.7)"
}

test_pick_minor_and_major_keeps_granularity() {
  check "rows" $'minor 24.16\nmajor 26.0' \
    "$(printf '%s\n' v24.15.0 v24.16.1 v26.0.0 v22.9.0 | pick_candidates 24.15)"
}

test_pick_major_only() {
  check "rows" "major 30.0.0" "$(printf '%s\n' v29.4.1 v30.0.0 | pick_candidates 29.4.1)"
}

test_pick_zero_x_minor_counts_as_major() {
  check "rows" $'minor 0.9.2\nmajor 0.10.0' \
    "$(printf '%s\n' 0.9.1 0.9.2 0.10.0 | pick_candidates 0.9.1)"
}

test_pick_nothing_when_up_to_date() {
  check "rows" "" "$(printf '%s\n' 3.49.0 3.50.0 | pick_candidates 3.50.0)"
}

test_pick_nothing_when_pin_is_newer_than_all() {
  check "rows" "" "$(printf '%s\n' 4.8 4.9 | pick_candidates 5.0)"
}

test_pick_single_component_feature_ref() {
  check "rows" "major 2" "$(printf '%s\n' 1 1.0 1.0.6 2 2.0 2.0.0 latest | pick_candidates 1)"
}

# Prints the manifest entry named $1, and its index.
entry() { jq -c --arg n "$1" '.[] | select(.name == $n)' "$MANIFEST"; }
index_of() { jq --arg n "$1" 'map(.name) | index($n)' "$MANIFEST"; }

SHA_A=$(printf 'a%.0s' {1..64})
SHA_B=$(printf 'b%.0s' {1..64})
SHA_C=$(printf 'c%.0s' {1..64})
SHA_1=$(printf '1%.0s' {1..64})
SHA_2=$(printf '2%.0s' {1..64})
SHA_3=$(printf '3%.0s' {1..64})

# ---------------------------------------------------------------------------------------------
# Manifest and anchors

test_reads_every_fixture_value() {
  local name
  declare -A want=(
    ["base image"]=2.0.5 ["AWS CLI"]=2.32.9 [Composer]=2.10.3 [omp]=18.2.7 [Vale]=3.12.0
    [".NET SDK (extra)"]=8.0 [Terraform]=1.15 [TFLint]=0.62.0 [Node.js]=24.15
    ["Aspire CLI"]=13.5 ["node Feature"]=2.0 ["k-alias Feature"]=1
  )
  for name in "${!want[@]}"; do
    check "$name" "${want[$name]}" "$(current_value "$(entry "$name")")"
  done
}

test_reads_checksums() {
  check "omp amd64" "$SHA_A" "$(anchor_value "$(anchor "$(entry omp)" sha256:amd64)")"
  check "omp arm64" "$SHA_B" "$(anchor_value "$(anchor "$(entry omp)" sha256:arm64)")"
  check "composer" "$SHA_C" "$(anchor_value "$(anchor "$(entry Composer)" sha256)")"
}

test_option_lookup_stays_inside_its_feature_block() {
  # common-utils has no "version" option; the lookup must not find node's or terraform's.
  local e='{"kind":"feature-option","feature":"ghcr.io/devcontainers/features/common-utils","option":"version"}'
  check_status "common-utils version" 1 current_value "$e"
}

test_feature_names_match_exactly() {
  local e='{"kind":"feature-ref","feature":"ghcr.io/devcontainers/features/no"}'
  check_status "prefix of node" 1 current_value "$e"
}

test_every_pin_in_the_real_files_has_a_manifest_entry() {
  local arg feature real=$UPDATE_DIR/tools.json
  for arg in $(grep -oE '^ARG [A-Z0-9_]+_VERSION=' "$REPO_ROOT/.devcontainer/Dockerfile" | cut -c5- | tr -d =); do
    check "$arg has a tools.json entry" true "$(jq --arg a "$arg" 'any(.[]; .arg == $a)' "$real")"
  done
  for feature in $(grep -oE '"ghcr\.io/[^"]+:[0-9.]+"' "$REPO_ROOT/.devcontainer/devcontainer.json" |
    tr -d '"' | sed 's/:[0-9.]*$//'); do
    check "$feature has a feature-ref entry" true \
      "$(jq --arg f "$feature" 'any(.[]; .kind == "feature-ref" and .feature == $f)' "$real")"
  done
}

test_case_line_lookup_stops_at_next_arg() {
  # Vale's RUN block has no VALE_SHA256; the lookup must not wander into another block.
  local e='{"kind":"dockerfile-arg","arg":"COMPOSER_VERSION","sha256":{"var":"OMP_SHA256"}}'
  check_status "OMP_SHA256 after COMPOSER_VERSION" 1 anchor_value "$(anchor "$e" sha256:amd64)"
}

test_real_manifest_matches_real_files() {
  local e name kind n=0
  MANIFEST=$UPDATE_DIR/tools.json
  DOCKERFILE=$REPO_ROOT/.devcontainer/Dockerfile
  DEVCONTAINER_JSON=$REPO_ROOT/.devcontainer/devcontainer.json
  load_manifest
  check "unique names" "" "$(jq -r '.[].name' "$MANIFEST" | sort | uniq -d)"
  for e in "${ENTRIES[@]}"; do
    n=$((n + 1))
    name=$(field "$e" .name)
    kind=$(field "$e" .kind)
    if [[ $kind == command ]]; then
      check "$name has run" true "$(jq 'has("run")' <<<"$e")"
      continue
    fi
    if ! current_value "$e" >/dev/null; then
      check "$name current value" "a version" "not found"
    fi
    if [[ $(field "$e" .hold) != true ]]; then
      check "$name source" true \
        "$(jq '.source.type | IN("github-release","github-tag","npm","go","node","k8s","mcr","ghcr")' <<<"$e")"
    fi
    if [[ -n $(field "$e" .sha256.arg) ]]; then
      [[ $(anchor_value "$(anchor "$e" sha256)") =~ ^[0-9a-f]{64}$ ]] ||
        check "$name checksum" "64 hex digits" "$(anchor_value "$(anchor "$e" sha256)")"
    fi
    if [[ -n $(field "$e" .sha256.var) ]]; then
      local arch
      for arch in $(jq -r '.sha256.arch | keys[]' <<<"$e"); do
        [[ $(anchor_value "$(anchor "$e" "sha256:$arch")") =~ ^[0-9a-f]{64}$ ]] ||
          check "$name $arch checksum" "64 hex digits" "$(anchor_value "$(anchor "$e" "sha256:$arch")")"
      done
    fi
  done
  check "entries checked" "$(jq length "$MANIFEST")" "$n"
}

run_tests "$@"
