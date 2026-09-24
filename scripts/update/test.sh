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

# ---------------------------------------------------------------------------------------------
# Applying edits

test_apply_per_arch_checksums() {
  apply_item "$(entry omp)" 18.3.0 $'amd64 '"$SHA_1"$'\narm64 '"$SHA_2"
  check "diff" "-ARG OMP_VERSION=18.2.7
+ARG OMP_VERSION=18.3.0
-    amd64) OMP_ARCH=\"x64\"; OMP_SHA256=\"$SHA_A\" ;; \\
-    arm64) OMP_ARCH=\"arm64\"; OMP_SHA256=\"$SHA_B\" ;; \\
+    amd64) OMP_ARCH=\"x64\"; OMP_SHA256=\"$SHA_1\" ;; \\
+    arm64) OMP_ARCH=\"arm64\"; OMP_SHA256=\"$SHA_2\" ;; \\" \
    "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}

test_apply_quoted_arg_keeps_quotes() {
  apply_item "$(entry "AWS CLI")" 2.33.0 ""
  check "diff" $'-ARG AWS_CLI_VERSION="2.32.9"\n+ARG AWS_CLI_VERSION="2.33.0"' \
    "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}

test_apply_single_checksum() {
  apply_item "$(entry Composer)" 2.10.4 "- $SHA_3"
  check "diff" "-ARG COMPOSER_VERSION=2.10.3
-ARG COMPOSER_SHA256=$SHA_C
+ARG COMPOSER_VERSION=2.10.4
+ARG COMPOSER_SHA256=$SHA_3" "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}

test_apply_base_image_keeps_suffix() {
  apply_item "$(entry "base image")" 2.1.0 ""
  check "diff" $'-FROM mcr.microsoft.com/devcontainers/dotnet:2.0.5-10.0-noble\n+FROM mcr.microsoft.com/devcontainers/dotnet:2.1.0-10.0-noble' \
    "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}

test_apply_option_keeps_trailing_comment() {
  apply_item "$(entry Node.js)" 24.16 ""
  check "diff" $'-      "version": "24.15", // trailing comments survive too\n+      "version": "24.16", // trailing comments survive too' \
    "$(changes "$WORK/devcontainer.json.orig" "$DEVCONTAINER_JSON")"
}

test_apply_second_option_in_shared_block() {
  apply_item "$(entry TFLint)" 0.63.0 ""
  check "diff" $'-      "tflint": "0.62.0"\n+      "tflint": "0.63.0"' \
    "$(changes "$WORK/devcontainer.json.orig" "$DEVCONTAINER_JSON")"
}

test_apply_ref_then_option_in_same_feature() {
  apply_item "$(entry "node Feature")" 2.1 ""
  apply_item "$(entry Node.js)" 24.16 ""
  check "diff" '-    "ghcr.io/devcontainers/features/node:2.0": {
-      "version": "24.15", // trailing comments survive too
+    "ghcr.io/devcontainers/features/node:2.1": {
+      "version": "24.16", // trailing comments survive too' \
    "$(changes "$WORK/devcontainer.json.orig" "$DEVCONTAINER_JSON")"
}

test_apply_ref_on_empty_block() {
  apply_item "$(entry "k-alias Feature")" 2 ""
  check "diff" $'-    "ghcr.io/jaggedmountain/k-alias/k-alias:1": {},\n+    "ghcr.io/jaggedmountain/k-alias/k-alias:2": {},' \
    "$(changes "$WORK/devcontainer.json.orig" "$DEVCONTAINER_JSON")"
}

test_apply_keeps_inode() {
  local before
  before=$(stat -c %i "$DOCKERFILE")
  apply_item "$(entry Vale)" 3.13.0 ""
  check "inode" "$before" "$(stat -c %i "$DOCKERFILE")"
}

test_failed_edit_restores_file() {
  # Drop the arm64 checksum line so the second checksum edit fails after the version edit.
  sed -i '/arm64) OMP_ARCH/d' "$DOCKERFILE"
  cp "$DOCKERFILE" "$WORK/Dockerfile.broken"
  check_status "apply" 1 apply_item "$(entry omp)" 18.3.0 $'amd64 '"$SHA_1"$'\narm64 '"$SHA_2"
  check "file unchanged" "" "$(changes "$WORK/Dockerfile.broken" "$DOCKERFILE")"
  check "no snapshot left" "" "$(ls "$WORK" | grep snapshot)"
}

test_interrupt_restores_file_in_progress() {
  cp "$DOCKERFILE" "$WORK/snapshot.test"
  echo "half-written" >"$DOCKERFILE"
  IN_PROGRESS="$DOCKERFILE|$WORK/snapshot.test"
  check_status "on_interrupt" 130 on_interrupt_in_subshell
  check "file restored" "" "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}
on_interrupt_in_subshell() { (on_interrupt); }

# Stubs. Tests fill STUB_VERSIONS (entry name -> space-separated versions) and STUB_URLS
# (URL -> sha256). A name or URL that is missing fails the way a 404 would.
declare -A STUB_VERSIONS=() STUB_URLS=()
fetch_versions() {
  local name
  name=$(field "$1" .name)
  echo "$name" >>"$WORK/fetch-calls"
  if [[ -z ${STUB_VERSIONS[$name]+set} ]]; then
    echo "HTTP 404: Not Found" >&2
    return 1
  fi
  printf '%s\n' ${STUB_VERSIONS[$name]}
}
url_sha256() {
  if [[ -z ${STUB_URLS[$1]+set} ]]; then
    echo "curl: (22) The requested URL returned error: 404" >&2
    return 1
  fi
  echo "${STUB_URLS[$1]}"
}
url_exists() { [[ -n ${STUB_URLS[$1]+set} ]]; }

# ---------------------------------------------------------------------------------------------
# Sources and verification

test_verify_per_arch_downloads() {
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-arm64"]=$SHA_2
  check "sums" "amd64 $SHA_1"$'\n'"arm64 $SHA_2" "$(verify_candidate "$(entry omp)" 18.3.0)"
}

test_verify_single_download() {
  STUB_URLS["https://example.test/composer/2.10.4/composer.phar"]=$SHA_3
  check "sums" "- $SHA_3" "$(verify_candidate "$(entry Composer)" 2.10.4)"
}

test_verify_fails_on_missing_arch_download() {
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-x64"]=$SHA_1
  check "message" "cannot download https://example.test/omp/v18.3.0/omp-linux-arm64" \
    "$(verify_candidate "$(entry omp)" 18.3.0 2>&1 >/dev/null | tail -n1)"
  check_status "status" 1 verify_candidate "$(entry omp)" 18.3.0
}

test_verify_existence_only() {
  STUB_URLS["https://example.test/awscli-exe-linux-x86_64-2.33.0.zip"]=x
  STUB_URLS["https://example.test/awscli-exe-linux-aarch64-2.33.0.zip"]=x
  check "no sums" "" "$(verify_candidate "$(entry "AWS CLI")" 2.33.0)"
  check_status "both exist" 0 verify_candidate "$(entry "AWS CLI")" 2.33.0
  check_status "one missing" 1 verify_candidate "$(entry "AWS CLI")" 2.34.0
}

test_plan_one_saves_sums_and_drops_unverifiable_candidates() {
  local i
  i=$(index_of omp)
  STUB_VERSIONS[omp]="v18.2.7 v18.3.0 v19.0.0"
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-arm64"]=$SHA_2
  check "rows" "minor 18.3.0" "$(plan_one "$i" verify 2>/dev/null)"
  check "reason" "19.0.0 skipped: cannot download https://example.test/omp/v19.0.0/omp-linux-x64" \
    "$(plan_one "$i" verify 2>&1 >/dev/null)"
  check "sums" "amd64 $SHA_1"$'\n'"arm64 $SHA_2" "$(cat "$WORK/sums/$i-18.3.0")"
}

test_lookup_with_no_usable_versions_is_an_error() {
  local i
  i=$(index_of omp)
  STUB_VERSIONS[omp]="latest nightly v19.0.0-rc.1"
  lookup_all "" "$WORK/plan" "$i"
  check "error" "lookup found no versions" "$(cat "$WORK/plan/$i.err")"
}

test_url_sha256_hashes_the_download_and_fails_on_error() {
  unset -f url_sha256
  source "$HERE/update.sh"
  curl() {
    local out
    while (($#)); do
      if [[ $1 == -o ]]; then out=$2; fi
      shift
    done
    [[ -n ${STUB_CURL_FAIL:-} ]] && return 22
    printf 'hello\n' >"$out"
  }
  check "sha" "$(printf 'hello\n' | sha256sum | cut -d' ' -f1)" "$(url_sha256 https://example.test/f)"
  STUB_CURL_FAIL=1
  check "no output on failure" "" "$(url_sha256 https://example.test/f)"
  check_status "status on failure" 1 url_sha256 https://example.test/f
  check "no temp files left" "" "$(ls "$WORK" | grep download)"
}

test_lookup_all_records_failures_and_skips_held() {
  local node dotnet vale
  node=$(index_of Node.js) dotnet=$(index_of ".NET SDK (extra)") vale=$(index_of Vale)
  STUB_VERSIONS[Node.js]="v24.15.0 v24.16.0"
  lookup_all "" "$WORK/plan" "$node" "$dotnet" "$vale"
  check "node rows" "minor 24.16" "$(cat "$WORK/plan/$node.rows")"
  check "vale error" "lookup failed: HTTP 404: Not Found" "$(cat "$WORK/plan/$vale.err")"
  check "held not looked up" "" "$(grep -x ".NET SDK (extra)" "$WORK/fetch-calls")"
}

# The real fetch_versions against canned API responses. gh, curl, and npm are stubbed to print
# what the service would return; the jq filters in fetch_versions do the rest.
test_fetch_versions_parses_each_source() {
  source_of() { printf '{"name":"x","source":%s}' "$1"; }
  unset -f fetch_versions
  source "$HERE/update.sh"   # restore the real fetch_versions over the stub
  gh() {
    local jq_filter="" a
    for a in "$@"; do
      if [[ ${prev:-} == --jq ]]; then jq_filter=$a; fi
      prev=$a
    done
    case "$*" in
      *releases*) jq -r "$jq_filter" <<<'[{"tag_name":"v2.0.0","draft":false,"prerelease":false},
        {"tag_name":"v2.1.0-rc1","draft":false,"prerelease":true},
        {"tag_name":"v2.1.0","draft":true,"prerelease":false},
        {"tag_name":"v1.9.9","draft":false,"prerelease":false}]' ;;
      *matching-refs*) jq -r "$jq_filter" <<<'[{"ref":"refs/tags/2.32.9"},{"ref":"refs/tags/2.33.0"}]' ;;
    esac
  }
  npm() { echo '["1.0.0","1.1.0"]'; }
  curl() {
    case "$*" in
      *go.dev*) echo '[{"version":"go1.26.1","stable":true},{"version":"go1.27rc1","stable":false}]' ;;
      *nodejs.org*) echo '[{"version":"v25.1.0","lts":false},{"version":"v24.16.0","lts":"Krypton"}]' ;;
      *dl.k8s.io*) printf 'v1.35.2' ;;
      *mcr.microsoft.com*) echo '{"tags":["2.0.5-10.0-noble","2.0.6-10.0-noble","2-10.0-noble","2.0.6-9.0-noble","dev-10.0-noble"]}' ;;
      *ghcr.io/token*) echo '{"token":"t"}' ;;
      *ghcr.io/v2*) echo '{"tags":["1","1.0","1.0.6","latest"]}' ;;
    esac
  }
  check "github-release" $'v2.0.0\nv1.9.9' "$(fetch_versions "$(source_of '{"type":"github-release","repo":"o/r"}')")"
  check "github-tag" $'2.32.9\n2.33.0' "$(fetch_versions "$(source_of '{"type":"github-tag","repo":"o/r","prefix":"2."}')")"
  check "npm" $'1.0.0\n1.1.0' "$(fetch_versions "$(source_of '{"type":"npm","package":"p"}')")"
  check "go" "1.26.1" "$(fetch_versions "$(source_of '{"type":"go"}')")"
  check "node" "v24.16.0" "$(fetch_versions "$(source_of '{"type":"node"}')")"
  check "k8s" "v1.35.2" "$(fetch_versions "$(source_of '{"type":"k8s"}')")"
  check "mcr" $'2.0.5\n2.0.6\n2\ndev' \
    "$(fetch_versions "$(source_of '{"type":"mcr","image":"devcontainers/dotnet","suffix":"-10.0-noble"}')")"
  check "mcr after filter" $'2.0.5\n2.0.6' \
    "$(fetch_versions "$(source_of '{"type":"mcr","image":"devcontainers/dotnet","suffix":"-10.0-noble"}')" | ver_filter 3)"
  check "ghcr" $'1\n1.0\n1.0.6\nlatest' "$(fetch_versions "$(source_of '{"type":"ghcr","image":"o/f"}')")"
  check_status "unknown type" 1 fetch_versions "$(source_of '{"type":"svn"}')"
}

# dialog stubs: STUB_CHOICES (space-separated tags) overrides the default of choosing every row
# that starts "on"; STUB_CANCEL=1 presses Cancel. Notices are appended to $WORK/notices.
dialog_checklist() {
  shift
  if [[ -n ${STUB_CANCEL:-} ]]; then
    return 1
  fi
  if [[ -n ${STUB_CHOICES+set} ]]; then
    printf '%s\n' $STUB_CHOICES
    return 0
  fi
  while (($#)); do
    if [[ $3 == on ]]; then
      echo "$1"
    fi
    shift 3
  done
}
dialog_yesno() { [[ -z ${STUB_CANCEL:-} ]]; }
dialog_notice() { printf '%s\n%s\n' "$1" "$2" >>"$WORK/notices"; }
clear_screen() { :; }
refresh_lock() {
  echo refreshed >>"$WORK/lock-calls"
  if [[ -n ${STUB_LOCK_WRITE:-} ]]; then
    echo "$STUB_LOCK_WRITE" >"$LOCK_JSON"
  fi
  return "${STUB_LOCK_STATUS:-0}"
}
sync_repos() {
  echo pulled >>"$WORK/sync-calls"
  return "${STUB_SYNC_STATUS:-0}"
}

# ---------------------------------------------------------------------------------------------
# Pins and features steps

test_pins_step_applies_preselected_rows() {
  STUB_VERSIONS["base image"]="2.0.5 2.0.6"
  STUB_VERSIONS["AWS CLI"]="2.32.9"
  STUB_VERSIONS[Composer]="2.10.3"
  STUB_VERSIONS[omp]="v18.2.7 v18.3.0 v19.0.0"
  STUB_VERSIONS[Vale]="v3.12.0"
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-arm64"]=$SHA_2
  STUB_URLS["https://example.test/omp/v19.0.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v19.0.0/omp-linux-arm64"]=$SHA_2
  run_edit_step pins >/dev/null
  check "updated" $'base image  2.0.5 -> 2.0.6\nomp  18.2.7 -> 18.3.0' "$(printf '%s\n' "${UPDATED[@]}")"
  check "omp version" 18.3.0 "$(current_value "$(entry omp)")"
  check "omp arm64 sum" "$SHA_2" "$(anchor_value "$(anchor "$(entry omp)" sha256:arm64)")"
  check "rebuild" true "$REBUILD"
  check "failed" "" "${FAILED[*]}"
}

test_pins_step_major_wins_when_both_rows_chosen() {
  local i
  i=$(index_of omp)
  STUB_VERSIONS[omp]="v18.2.7 v18.3.0 v19.0.0"
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-arm64"]=$SHA_2
  STUB_URLS["https://example.test/omp/v19.0.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v19.0.0/omp-linux-arm64"]=$SHA_2
  STUB_CHOICES="$i:minor $i:major"
  run_edit_step pins >/dev/null
  check "omp version" 19.0.0 "$(current_value "$(entry omp)")"
}

test_pins_step_reports_lookup_and_download_problems() {
  STUB_VERSIONS[omp]="v18.2.7 v18.3.0"
  run_edit_step pins >/dev/null
  check "notice" "Pinned tools (Dockerfile): not offered" "$(head -n1 "$WORK/notices")"
  check "vale skipped" "Vale: lookup failed: HTTP 404: Not Found" "$(printf '%s\n' "${SKIPPED[@]}" | grep '^Vale')"
  check "omp skipped" "omp: 18.3.0 skipped: cannot download https://example.test/omp/v18.3.0/omp-linux-x64" \
    "$(printf '%s\n' "${SKIPPED[@]}" | grep '^omp')"
  check "nothing changed" "" "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}

test_pins_step_survives_esc_on_the_notice() {
  dialog_notice() { return 255; }
  STUB_VERSIONS["base image"]="2.0.5 2.0.6"
  run_edit_step pins >/dev/null
  check "still applied" "base image  2.0.5 -> 2.0.6" "${UPDATED[*]}"
}

test_pins_step_cancel_changes_nothing() {
  STUB_VERSIONS["base image"]="2.0.5 2.0.6"
  STUB_CANCEL=1
  run_edit_step pins >/dev/null
  check "nothing changed" "" "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
  check "skipped" "Pinned tools (Dockerfile): cancelled" "${SKIPPED[-1]}"
  check "updated" "" "${UPDATED[*]}"
}

test_pins_step_records_unchosen_rows() {
  STUB_VERSIONS["base image"]="2.0.5 2.0.6"
  STUB_CHOICES=""
  run_edit_step pins >/dev/null
  check "skipped" "base image: not chosen" "$(printf '%s\n' "${SKIPPED[@]}" | grep '^base image')"
}

test_features_step_refreshes_lock_once_and_reports_held() {
  STUB_VERSIONS[Node.js]="v24.15.0 v24.16.0"
  STUB_VERSIONS[TFLint]="v0.62.0 v0.62.1"
  run_edit_step features >/dev/null
  check "updated" $'TFLint  0.62.0 -> 0.62.1\nNode.js  24.15 -> 24.16' "$(printf '%s\n' "${UPDATED[@]}")"
  check "lock refreshed once" refreshed "$(cat "$WORK/lock-calls")"
  check "held" ".NET SDK (extra) 8.0: kept on 8.0 on purpose" "${HELD[*]}"
}

test_features_step_restores_both_files_when_lock_refresh_fails() {
  # The restore goes back to how the files were when the run started, uncommitted edits
  # included, not to what git has.
  sed -i 's|^  "features": {|  // a local edit that is not committed\n&|' "$DEVCONTAINER_JSON"
  cp "$DEVCONTAINER_JSON" "$WORK/devcontainer.json.start"
  STUB_VERSIONS[Node.js]="v24.15.0 v24.16.0"
  STUB_LOCK_STATUS=1
  STUB_LOCK_WRITE='{"features": {"half-written": true}}'
  run_edit_step features >/dev/null
  check "devcontainer.json restored" "" "$(changes "$WORK/devcontainer.json.start" "$DEVCONTAINER_JSON")"
  check "local edit kept" "  // a local edit that is not committed" "$(grep 'not committed' "$DEVCONTAINER_JSON")"
  check "lock restored" "" "$(changes "$HERE/testdata/devcontainer-lock.json" "$LOCK_JSON")"
  check "failed" "Node.js: lock file refresh failed, devcontainer.json restored" "${FAILED[*]}"
  check "updated" "" "${UPDATED[*]}"
  check "rebuild" false "$REBUILD"
}

test_features_step_lock_row_alone() {
  STUB_CHOICES="lock"
  run_edit_step features >/dev/null
  check "lock refreshed" refreshed "$(cat "$WORK/lock-calls")"
  check "updated" "Feature lock file refreshed" "${UPDATED[*]}"
  check "nothing changed" "" "$(changes "$WORK/devcontainer.json.orig" "$DEVCONTAINER_JSON")"
}

test_features_step_lock_row_alone_reports_a_failed_refresh() {
  STUB_CHOICES="lock"
  STUB_LOCK_STATUS=1
  run_edit_step features >/dev/null
  check "failed" "Feature lock file: refresh failed" "${FAILED[*]}"
  check "updated" "" "${UPDATED[*]}"
}

test_features_step_without_changes_skips_lock() {
  run_edit_step features >/dev/null
  check "no refresh" "" "$(cat "$WORK/lock-calls" 2>/dev/null)"
}

run_tests "$@"
